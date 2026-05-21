#include "webrtc_qos/video_jitter_player.h"

#include <utility>

#include "h264_annexb.h"

namespace webrtc_qos {

VideoJitterPlayer::VideoJitterPlayer(VideoJitterPlayerConfig config)
    : config_(config) {}

VideoJitterPlayer::VideoJitterPlayer(
    VideoJitterPlayerConfig config,
    std::unique_ptr<VideoJitterBackend> backend)
    : config_(config), backend_(std::move(backend)) {}

Status VideoJitterPlayer::InsertPacket(const RtpPacket& packet) {
  return InsertPacket(packet, packet.receive_time_us);
}

Status VideoJitterPlayer::InsertPacket(const RtpPacket& packet,
                                       int64_t arrival_time_us) {
  if (backend_) {
    return backend_->InsertPacket(packet, arrival_time_us);
  }
  RtpPacket normalized = packet;
  normalized.receive_time_us = arrival_time_us;
  if (normalized.payload_type != kH264PayloadType) {
    return Status::Error(StatusCode::kUnsupported, "unexpected payload type");
  }
  if (normalized.ssrc != 0 && config_.sender_ssrc != 0 &&
      normalized.ssrc != config_.sender_ssrc) {
    return Status::Error(StatusCode::kInvalidArgument, "SSRC mismatch");
  }
  if (normalized.payload.empty()) {
    return Status::Error(StatusCode::kMalformedPacket, "empty H264 RTP payload");
  }
  const uint8_t type = normalized.payload[0] & 0x1f;
  if (type >= 1 && type <= 23) {
    return InsertSingleNalu(normalized);
  }
  if (type == 28) {
    return InsertFuA(normalized);
  }
  return Status::Error(StatusCode::kUnsupported, "unsupported H264 RTP type");
}

void VideoJitterPlayer::Flush(int64_t now_us, bool force) {
  if (backend_) {
    return;
  }
  FlushReadyFrames(now_us, force);
}

bool VideoJitterPlayer::HasFrame() const {
  if (backend_) {
    return backend_->HasFrame();
  }
  return !completed_.empty();
}

Status VideoJitterPlayer::PopFrame(EncodedVideoFrame* frame) {
  if (backend_) {
    return backend_->PopFrame(frame);
  }
  if (!frame) {
    return Status::Error(StatusCode::kInvalidArgument, "null output frame");
  }
  if (completed_.empty()) {
    return Status::Error(StatusCode::kInvalidArgument, "no completed frame");
  }
  *frame = std::move(completed_.front());
  completed_.pop_front();
  UpdateQueueStats();
  return Status::Ok();
}

VideoJitterStats VideoJitterPlayer::GetStats() const {
  if (backend_) {
    return backend_->GetStats();
  }
  return stats_;
}

Status VideoJitterPlayer::InsertSingleNalu(const RtpPacket& packet) {
  const H264NaluType type = GetNaluType(packet.payload);
  if (type == H264NaluType::kSps) {
    cached_sps_ = packet.payload;
  } else if (type == H264NaluType::kPps) {
    cached_pps_ = packet.payload;
  }
  return InsertPacketForAssembly(packet);
}

Status VideoJitterPlayer::InsertFuA(const RtpPacket& packet) {
  if (packet.payload.size() < 3) {
    return Status::Error(StatusCode::kMalformedPacket, "short FU-A payload");
  }
  return InsertPacketForAssembly(packet);
}

Status VideoJitterPlayer::InsertPacketForAssembly(const RtpPacket& packet) {
  if (completed_timestamps_.find(packet.timestamp) !=
      completed_timestamps_.end()) {
    return Status::Ok();
  }
  PartialFrame& partial = partial_frames_[packet.timestamp];
  if (partial.packets.empty()) {
    partial.timestamp = packet.timestamp;
    partial.sequence_start = packet.sequence_number;
    partial.capture_time_us = packet.capture_time_us;
    partial.first_packet_receive_time_us = packet.receive_time_us;
  }
  partial.sequence_start = std::min(partial.sequence_start, packet.sequence_number);
  partial.sequence_end = std::max(partial.sequence_end, packet.sequence_number);
  partial.last_packet_receive_time_us =
      std::max(partial.last_packet_receive_time_us, packet.receive_time_us);
  partial.has_marker = partial.has_marker || packet.marker;
  partial.packets[packet.sequence_number] = packet;

  EncodedVideoFrame frame;
  bool incomplete = false;
  Status status = TryAssembleFrame(partial, &frame, &incomplete);
  if (!status) {
    return status;
  }
  if (!incomplete) {
    partial_frames_.erase(packet.timestamp);
    QueueCompletedFrame(std::move(frame));
    FlushReadyFrames(packet.receive_time_us, false);
  }
  return Status::Ok();
}

Status VideoJitterPlayer::TryAssembleFrame(const PartialFrame& partial,
                                           EncodedVideoFrame* frame,
                                           bool* incomplete) const {
  if (!frame || !incomplete) {
    return Status::Error(StatusCode::kInvalidArgument,
                         "null frame assembly output");
  }
  *incomplete = true;
  if (!partial.has_marker || partial.packets.empty()) {
    return Status::Ok();
  }
  uint16_t previous = partial.packets.begin()->first;
  bool first = true;
  for (const auto& [seq, unused] : partial.packets) {
    (void)unused;
    if (!first && static_cast<uint16_t>(previous + 1) != seq) {
      return Status::Ok();
    }
    previous = seq;
    first = false;
  }

  std::vector<std::vector<uint8_t>> nalus;
  std::vector<uint8_t> fu_nalu;
  bool assembling_fu = false;
  for (const auto& [unused, packet] : partial.packets) {
    (void)unused;
    if (packet.payload.empty()) {
      return Status::Error(StatusCode::kMalformedPacket, "empty RTP payload");
    }
    const uint8_t type = packet.payload[0] & 0x1f;
    if (type >= 1 && type <= 23) {
      if (assembling_fu) {
        return Status::Error(StatusCode::kMalformedPacket,
                             "interrupted FU-A sequence");
      }
      nalus.push_back(packet.payload);
      continue;
    }
    if (type != 28 || packet.payload.size() < 3) {
      return Status::Error(StatusCode::kUnsupported,
                           "unsupported H264 RTP type");
    }
    const uint8_t fu_indicator = packet.payload[0];
    const uint8_t fu_header = packet.payload[1];
    const bool start = (fu_header & 0x80) != 0;
    const bool end = (fu_header & 0x40) != 0;
    const uint8_t nal_type = fu_header & 0x1f;
    const uint8_t reconstructed_header = (fu_indicator & 0xe0) | nal_type;
    if (start) {
      if (assembling_fu) {
        return Status::Error(StatusCode::kMalformedPacket,
                             "nested FU-A start");
      }
      assembling_fu = true;
      fu_nalu.clear();
      fu_nalu.push_back(reconstructed_header);
    } else if (!assembling_fu) {
      return Status::Ok();
    }
    fu_nalu.insert(fu_nalu.end(), packet.payload.begin() + 2,
                   packet.payload.end());
    if (end) {
      nalus.push_back(std::move(fu_nalu));
      fu_nalu.clear();
      assembling_fu = false;
    }
  }
  if (assembling_fu || nalus.empty()) {
    return Status::Ok();
  }

  std::vector<std::vector<uint8_t>> out_nalus;
  const VideoFrameType frame_type = ClassifyAccessUnit(nalus);
  if (frame_type == VideoFrameType::kIdr) {
    bool has_sps = false;
    bool has_pps = false;
    for (const auto& nalu : nalus) {
      const H264NaluType type = GetNaluType(nalu);
      has_sps = has_sps || type == H264NaluType::kSps;
      has_pps = has_pps || type == H264NaluType::kPps;
    }
    if (!has_sps && !cached_sps_.empty()) {
      out_nalus.push_back(cached_sps_);
    }
    if (!has_pps && !cached_pps_.empty()) {
      out_nalus.push_back(cached_pps_);
    }
  }
  out_nalus.insert(out_nalus.end(), nalus.begin(), nalus.end());
  frame->annexb_access_unit = JoinAnnexB(out_nalus);
  frame->rtp_timestamp = partial.timestamp;
  frame->rtp_sequence_start = partial.sequence_start;
  frame->rtp_sequence_end = partial.sequence_end;
  frame->capture_time_us = partial.capture_time_us;
  frame->first_packet_receive_time_us = partial.first_packet_receive_time_us;
  frame->completed_time_us = partial.last_packet_receive_time_us;
  frame->frame_type = frame_type;
  frame->keyframe = frame_type == VideoFrameType::kIdr;
  *incomplete = false;
  return Status::Ok();
}

void VideoJitterPlayer::QueueCompletedFrame(EncodedVideoFrame frame) {
  if (!completed_timestamps_.insert(frame.rtp_timestamp).second) {
    ++stats_.dropped_frames;
    return;
  }
  if (has_released_timestamp_ &&
      frame.rtp_timestamp <= last_released_timestamp_) {
    completed_timestamps_.erase(frame.rtp_timestamp);
    ++stats_.dropped_frames;
    return;
  }
  completed_timestamp_order_.push_back(frame.rtp_timestamp);
  while (completed_timestamp_order_.size() > 256) {
    completed_timestamps_.erase(completed_timestamp_order_.front());
    completed_timestamp_order_.pop_front();
  }
  ready_frames_[frame.rtp_timestamp] = std::move(frame);
  ++stats_.completed_frames;
  UpdateQueueStats();
}

void VideoJitterPlayer::FlushReadyFrames(int64_t now_us, bool force) {
  while (!ready_frames_.empty()) {
    auto it = ready_frames_.begin();
    if (!ShouldReleaseReadyFrame(it->second, now_us, force)) {
      break;
    }
    completed_.push_back(std::move(ready_frames_.begin()->second));
    ready_frames_.erase(ready_frames_.begin());
    last_released_timestamp_ = completed_.back().rtp_timestamp;
    has_released_timestamp_ = true;
  }
  UpdateQueueStats();
}

bool VideoJitterPlayer::ShouldReleaseReadyFrame(
    const EncodedVideoFrame& frame,
    int64_t now_us,
    bool force) const {
  if (force || config_.max_reorder_delay_ms == 0 ||
      config_.max_reorder_queue_frames == 0 || !has_released_timestamp_) {
    return true;
  }
  const uint32_t timestamp_delta = frame.rtp_timestamp - last_released_timestamp_;
  const uint32_t frame_gap_ms = timestamp_delta / 90;
  if (frame_gap_ms <= config_.max_contiguous_frame_gap_ms) {
    return true;
  }
  const int64_t first_receive_us = frame.first_packet_receive_time_us > 0
                                       ? frame.first_packet_receive_time_us
                                       : frame.completed_time_us;
  const bool waited_long_enough =
      first_receive_us > 0 &&
      now_us - first_receive_us >=
          static_cast<int64_t>(config_.max_reorder_delay_ms) * 1000;
  return waited_long_enough ||
         ready_frames_.size() >= config_.max_reorder_queue_frames;
}

void VideoJitterPlayer::UpdateQueueStats() {
  stats_.decodable_queue_depth = static_cast<uint16_t>(completed_.size());
  stats_.jitter_frames =
      static_cast<uint16_t>(completed_.size() + ready_frames_.size());
}

}  // namespace webrtc_qos
