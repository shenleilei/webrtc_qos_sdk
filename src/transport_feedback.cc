#include "webrtc_qos/transport_feedback.h"

#include "byte_io.h"

namespace webrtc_qos {
namespace {

constexpr uint16_t kDownlinkQualityHeaderLen = 46;
constexpr uint16_t kSenderRateCapHeaderLen = 24;

Status ParseError(const char* message) {
  return Status::Error(StatusCode::kMalformedPacket, message);
}

}  // namespace

std::vector<uint8_t> SerializeDownlinkQuality(const DownlinkQuality& report) {
  std::vector<uint8_t> out;
  out.reserve(kDownlinkQualityHeaderLen);
  WriteU8(&out, 1);
  WriteU8(&out, kMsgTypeDownlinkQualityV1);
  WriteU16(&out, kDownlinkQualityHeaderLen);
  WriteU32(&out, report.ids.session_id);
  WriteU32(&out, report.ids.stream_id);
  WriteU32(&out, report.ids.sender_ssrc);
  WriteU32(&out, report.ids.receiver_id);
  WriteU32(&out, report.report_seq);
  WriteU64(&out, report.report_time_us);
  WriteU16(&out, report.rtt_ms);
  WriteU16(&out, report.fraction_lost_q8);
  WriteU16(&out, report.reorder_ratio_q8);
  WriteU16(&out, report.flags);
  WriteU32(&out, report.recv_bitrate_bps);
  WriteU16(&out, report.video_jitter_frames);
  WriteU16(&out, report.video_decodable_queue_depth);
  WriteU16(&out, report.video_drop_frames);
  WriteU16(&out, report.last_pli_reason);
  return out;
}

Status ParseDownlinkQuality(const uint8_t* data,
                            size_t size,
                            DownlinkQuality* report) {
  if (!data || !report) {
    return Status::Error(StatusCode::kInvalidArgument, "null quality input");
  }
  size_t pos = 0;
  uint8_t version = 0;
  uint8_t msg_type = 0;
  uint16_t header_len = 0;
  if (!ReadU8(data, size, &pos, &version) ||
      !ReadU8(data, size, &pos, &msg_type) ||
      !ReadU16(data, size, &pos, &header_len)) {
    return ParseError("short downlink quality header");
  }
  if (version != 1 || msg_type != kMsgTypeDownlinkQualityV1 ||
      header_len != kDownlinkQualityHeaderLen || size < header_len) {
    return ParseError("invalid downlink quality header");
  }
  if (!ReadU32(data, size, &pos, &report->ids.session_id) ||
      !ReadU32(data, size, &pos, &report->ids.stream_id) ||
      !ReadU32(data, size, &pos, &report->ids.sender_ssrc) ||
      !ReadU32(data, size, &pos, &report->ids.receiver_id) ||
      !ReadU32(data, size, &pos, &report->report_seq) ||
      !ReadU64(data, size, &pos, &report->report_time_us) ||
      !ReadU16(data, size, &pos, &report->rtt_ms) ||
      !ReadU16(data, size, &pos, &report->fraction_lost_q8) ||
      !ReadU16(data, size, &pos, &report->reorder_ratio_q8) ||
      !ReadU16(data, size, &pos, &report->flags) ||
      !ReadU32(data, size, &pos, &report->recv_bitrate_bps) ||
      !ReadU16(data, size, &pos, &report->video_jitter_frames) ||
      !ReadU16(data, size, &pos, &report->video_decodable_queue_depth) ||
      !ReadU16(data, size, &pos, &report->video_drop_frames) ||
      !ReadU16(data, size, &pos, &report->last_pli_reason)) {
    return ParseError("short downlink quality body");
  }
  return Status::Ok();
}

std::vector<uint8_t> SerializeSenderRateCap(const SenderRateCap& cap) {
  std::vector<uint8_t> out;
  out.reserve(kSenderRateCapHeaderLen);
  WriteU8(&out, 1);
  WriteU8(&out, kMsgTypeSenderRateCapV1);
  WriteU16(&out, kSenderRateCapHeaderLen);
  WriteU32(&out, cap.ids.session_id);
  WriteU32(&out, cap.ids.stream_id);
  WriteU32(&out, cap.controller_seq);
  WriteU32(&out, cap.cap_bps);
  WriteU16(&out, cap.expire_ms);
  WriteU16(&out, cap.reason_code);
  return out;
}

Status ParseSenderRateCap(const uint8_t* data,
                          size_t size,
                          SenderRateCap* cap) {
  if (!data || !cap) {
    return Status::Error(StatusCode::kInvalidArgument, "null rate cap input");
  }
  size_t pos = 0;
  uint8_t version = 0;
  uint8_t msg_type = 0;
  uint16_t header_len = 0;
  if (!ReadU8(data, size, &pos, &version) ||
      !ReadU8(data, size, &pos, &msg_type) ||
      !ReadU16(data, size, &pos, &header_len)) {
    return ParseError("short rate cap header");
  }
  if (version != 1 || msg_type != kMsgTypeSenderRateCapV1 ||
      header_len != kSenderRateCapHeaderLen || size < header_len) {
    return ParseError("invalid rate cap header");
  }
  if (!ReadU32(data, size, &pos, &cap->ids.session_id) ||
      !ReadU32(data, size, &pos, &cap->ids.stream_id) ||
      !ReadU32(data, size, &pos, &cap->controller_seq) ||
      !ReadU32(data, size, &pos, &cap->cap_bps) ||
      !ReadU16(data, size, &pos, &cap->expire_ms) ||
      !ReadU16(data, size, &pos, &cap->reason_code)) {
    return ParseError("short rate cap body");
  }
  return Status::Ok();
}

}  // namespace webrtc_qos
