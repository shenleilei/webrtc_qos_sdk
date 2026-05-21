#include "webrtc_qos/video_sender.h"

#include <algorithm>

#include "h264_annexb.h"

namespace webrtc_qos {

VideoSender::VideoSender(VideoSenderConfig config, SenderPacer* pacer)
    : config_(config),
      pacer_(pacer),
      next_rtp_sequence_number_(config.initial_rtp_sequence_number),
      next_transport_sequence_number_(config.initial_transport_sequence_number) {}

uint32_t VideoSender::RtpTimestampForCaptureTime(int64_t capture_time_us) const {
  if (capture_time_us <= 0) {
    return config_.initial_rtp_timestamp;
  }
  const uint64_t delta =
      (static_cast<uint64_t>(capture_time_us) * kVideoClockRateHz + 500000) /
      1000000;
  return config_.initial_rtp_timestamp + static_cast<uint32_t>(delta);
}

Status VideoSender::SendAnnexBAccessUnit(const uint8_t* data,
                                         size_t size,
                                         int64_t capture_time_us) {
  if (!pacer_) {
    return Status::Error(StatusCode::kInvalidArgument, "pacer not set");
  }
  std::vector<std::vector<uint8_t>> nalus;
  Status status = SplitAnnexB(data, size, &nalus);
  if (!status) {
    return status;
  }
  VideoFrameType frame_type = VideoFrameType::kUnknown;
  status = ValidateAccessUnit(nalus, &frame_type);
  if (!status) {
    return status;
  }

  const uint32_t rtp_timestamp = RtpTimestampForCaptureTime(capture_time_us);
  for (size_t i = 0; i < nalus.size(); ++i) {
    const bool marker = i + 1 == nalus.size();
    status =
        EnqueueNalu(nalus[i], marker, frame_type, capture_time_us, rtp_timestamp);
    if (!status && frame_type != VideoFrameType::kP) {
      return status;
    }
  }
  return Status::Ok();
}

Status VideoSender::ValidateAccessUnit(
    const std::vector<std::vector<uint8_t>>& nalus,
    VideoFrameType* frame_type) const {
  bool has_slice = false;
  *frame_type = ClassifyAccessUnit(nalus);
  for (const auto& nalu : nalus) {
    const H264NaluType type = GetNaluType(nalu);
    if (type == H264NaluType::kUnspecified) {
      return Status::Error(StatusCode::kMalformedPacket, "empty H264 NALU");
    }
    if (type == H264NaluType::kSps && nalu.size() >= 4) {
      const uint8_t profile_idc = nalu[1];
      const uint8_t profile_iop = nalu[2];
      const uint8_t level_idc = nalu[3];
      const bool constrained_baseline =
          profile_idc == 0x42 && (profile_iop & 0xc0) == 0xc0;
      if (!constrained_baseline || level_idc != 0x1f) {
        return Status::Error(StatusCode::kUnsupported,
                             "H264 SPS is not constrained-baseline level 3.1");
      }
    }
    if (IsBFrameSlice(nalu)) {
      return Status::Error(StatusCode::kUnsupported,
                           "B frames are forbidden in Phase-1a");
    }
    if (type == H264NaluType::kNonIdr || type == H264NaluType::kIdr) {
      has_slice = true;
    }
  }
  if (!has_slice) {
    return Status::Error(StatusCode::kInvalidArgument,
                         "access unit has no video slice");
  }
  if (*frame_type == VideoFrameType::kUnknown) {
    return Status::Error(StatusCode::kUnsupported,
                         "unsupported H264 access unit");
  }
  return Status::Ok();
}

Status VideoSender::EnqueueNalu(const std::vector<uint8_t>& nalu,
                                bool marker,
                                VideoFrameType frame_type,
                                int64_t capture_time_us,
                                uint32_t rtp_timestamp) {
  if (nalu.size() <= kMaxRtpPayloadBytes) {
    RtpPacket packet;
    packet.payload_type = kH264PayloadType;
    packet.marker = marker;
    packet.sequence_number = next_rtp_sequence_number_++;
    packet.timestamp = rtp_timestamp;
    packet.ssrc = config_.ids.sender_ssrc;
    packet.transport_sequence_number = next_transport_sequence_number_++;
    packet.capture_time_us = capture_time_us;
    packet.payload = nalu;
    return pacer_->Enqueue(SendPacket{packet, frame_type, false, 33});
  }

  if (nalu.empty()) {
    return Status::Error(StatusCode::kMalformedPacket, "empty FU-A NALU");
  }
  const uint8_t nalu_header = nalu[0];
  const uint8_t nri = nalu_header & 0x60;
  const uint8_t type = nalu_header & 0x1f;
  const uint8_t fu_indicator = nri | 28;
  size_t offset = 1;
  while (offset < nalu.size()) {
    const size_t remaining = nalu.size() - offset;
    const size_t chunk = std::min<size_t>(remaining, kMaxRtpPayloadBytes - 2);
    const bool start = offset == 1;
    const bool end = offset + chunk == nalu.size();
    RtpPacket packet;
    packet.payload_type = kH264PayloadType;
    packet.marker = marker && end;
    packet.sequence_number = next_rtp_sequence_number_++;
    packet.timestamp = rtp_timestamp;
    packet.ssrc = config_.ids.sender_ssrc;
    packet.transport_sequence_number = next_transport_sequence_number_++;
    packet.capture_time_us = capture_time_us;
    packet.payload.reserve(chunk + 2);
    packet.payload.push_back(fu_indicator);
    packet.payload.push_back(static_cast<uint8_t>((start ? 0x80 : 0x00) |
                                                  (end ? 0x40 : 0x00) | type));
    packet.payload.insert(packet.payload.end(), nalu.begin() + offset,
                          nalu.begin() + offset + chunk);
    Status status = pacer_->Enqueue(
        SendPacket{packet, frame_type, false, end ? 33u : 0u});
    if (!status && frame_type != VideoFrameType::kP) {
      return status;
    }
    offset += chunk;
  }
  return Status::Ok();
}

}  // namespace webrtc_qos
