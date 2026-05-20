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
  if (packet.payload_type != kH264PayloadType) {
    return Status::Error(StatusCode::kUnsupported, "unexpected payload type");
  }
  if (packet.ssrc != 0 && config_.sender_ssrc != 0 &&
      packet.ssrc != config_.sender_ssrc) {
    return Status::Error(StatusCode::kInvalidArgument, "SSRC mismatch");
  }
  if (packet.payload.empty()) {
    return Status::Error(StatusCode::kMalformedPacket, "empty H264 RTP payload");
  }
  const uint8_t type = packet.payload[0] & 0x1f;
  if (type >= 1 && type <= 23) {
    return InsertSingleNalu(packet);
  }
  if (type == 28) {
    return InsertFuA(packet);
  }
  return Status::Error(StatusCode::kUnsupported, "unsupported H264 RTP type");
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
  stats_.decodable_queue_depth = static_cast<uint16_t>(completed_.size());
  return Status::Ok();
}

VideoJitterStats VideoJitterPlayer::GetStats() const {
  if (backend_) {
    return backend_->GetStats();
  }
  return stats_;
}

Status VideoJitterPlayer::InsertSingleNalu(const RtpPacket& packet) {
  if (current_.timestamp != packet.timestamp) {
    if (!current_.nalus.empty()) {
      current_.corrupt = true;
      ++stats_.dropped_frames;
    }
    current_ = PartialFrame{};
    current_.timestamp = packet.timestamp;
  }
  current_.nalus.push_back(packet.payload);
  const H264NaluType type = GetNaluType(packet.payload);
  if (type == H264NaluType::kSps) {
    cached_sps_ = packet.payload;
  } else if (type == H264NaluType::kPps) {
    cached_pps_ = packet.payload;
  }
  current_.frame_type = ClassifyAccessUnit(current_.nalus);
  if (packet.marker) {
    CompleteFrame(packet.timestamp);
  }
  return Status::Ok();
}

Status VideoJitterPlayer::InsertFuA(const RtpPacket& packet) {
  if (packet.payload.size() < 3) {
    return Status::Error(StatusCode::kMalformedPacket, "short FU-A payload");
  }
  if (current_.timestamp != packet.timestamp) {
    if (!current_.nalus.empty()) {
      current_.corrupt = true;
      ++stats_.dropped_frames;
    }
    current_ = PartialFrame{};
    current_.timestamp = packet.timestamp;
  }
  const uint8_t fu_indicator = packet.payload[0];
  const uint8_t fu_header = packet.payload[1];
  const bool start = (fu_header & 0x80) != 0;
  const bool end = (fu_header & 0x40) != 0;
  const uint8_t nal_type = fu_header & 0x1f;
  const uint8_t reconstructed_header = (fu_indicator & 0xe0) | nal_type;

  if (start) {
    current_.nalus.emplace_back();
    current_.nalus.back().push_back(reconstructed_header);
  } else if (current_.nalus.empty()) {
    current_.corrupt = true;
    return Status::Error(StatusCode::kMalformedPacket,
                         "FU-A continuation without start");
  }
  current_.nalus.back().insert(current_.nalus.back().end(),
                               packet.payload.begin() + 2,
                               packet.payload.end());
  if (end) {
    current_.frame_type = ClassifyAccessUnit(current_.nalus);
  }
  if (packet.marker) {
    CompleteFrame(packet.timestamp);
  }
  return Status::Ok();
}

void VideoJitterPlayer::CompleteFrame(uint32_t timestamp) {
  if (current_.corrupt || current_.nalus.empty()) {
    current_ = PartialFrame{};
    ++stats_.dropped_frames;
    return;
  }
  std::vector<std::vector<uint8_t>> out_nalus;
  const VideoFrameType frame_type = ClassifyAccessUnit(current_.nalus);
  if (frame_type == VideoFrameType::kIdr) {
    bool has_sps = false;
    bool has_pps = false;
    for (const auto& nalu : current_.nalus) {
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
  out_nalus.insert(out_nalus.end(), current_.nalus.begin(),
                   current_.nalus.end());
  EncodedVideoFrame frame;
  frame.annexb_access_unit = JoinAnnexB(out_nalus);
  frame.rtp_timestamp = timestamp;
  frame.frame_type = frame_type;
  frame.keyframe = frame_type == VideoFrameType::kIdr;
  completed_.push_back(std::move(frame));
  ++stats_.completed_frames;
  stats_.decodable_queue_depth = static_cast<uint16_t>(completed_.size());
  stats_.jitter_frames = stats_.decodable_queue_depth;
  current_ = PartialFrame{};
}

}  // namespace webrtc_qos
