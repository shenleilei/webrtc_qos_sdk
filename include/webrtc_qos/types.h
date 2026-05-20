#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace webrtc_qos {

constexpr uint8_t kH264PayloadType = 96;
constexpr uint32_t kVideoClockRateHz = 90000;
constexpr uint32_t kH264ProfileLevelId = 0x42e01f;
constexpr uint16_t kMaxRtpPayloadBytes = 1200;
constexpr uint8_t kTransportWideCcExtensionId = 1;
constexpr const char* kTransportWideCcUri =
    "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01";

constexpr int kPacerTickMs = 5;
constexpr int kPacerMaxQueueMs = 500;
constexpr size_t kPacerMaxQueueBytes = 512 * 1024;
constexpr uint32_t kUnlimitedRateCapBps = 0xffffffffu;

using ClockNowUs = std::function<int64_t()>;

enum class StatusCode {
  kOk = 0,
  kInvalidArgument,
  kUnsupported,
  kMalformedPacket,
  kQueueFull,
  kInternalError,
};

struct Status {
  StatusCode code = StatusCode::kOk;
  std::string message;

  static Status Ok() { return {}; }
  static Status Error(StatusCode code, std::string message) {
    return Status{code, std::move(message)};
  }
  explicit operator bool() const { return code == StatusCode::kOk; }
};

struct TransportIds {
  uint32_t session_id = 0;
  uint32_t stream_id = 0;
  uint32_t transport_id = 0;
  uint32_t sender_ssrc = 0;
  uint32_t receiver_id = 0;
};

struct RtpPacket {
  uint8_t payload_type = kH264PayloadType;
  bool marker = false;
  uint16_t sequence_number = 0;
  uint32_t timestamp = 0;
  uint32_t ssrc = 0;
  uint16_t transport_sequence_number = 0;
  int64_t capture_time_us = 0;
  int64_t receive_time_us = 0;
  std::vector<uint8_t> payload;
};

enum class VideoFrameType {
  kUnknown = 0,
  kIdr,
  kP,
  kParameterSet,
};

struct EncodedVideoFrame {
  std::vector<uint8_t> annexb_access_unit;
  uint32_t rtp_timestamp = 0;
  VideoFrameType frame_type = VideoFrameType::kUnknown;
  bool keyframe = false;
};

struct SendPacket {
  RtpPacket packet;
  VideoFrameType frame_type = VideoFrameType::kUnknown;
  bool retransmission = false;
  uint32_t media_duration_ms = 0;
};

using SendPacketCallback = std::function<Status(const RtpPacket&)>;

struct RtcpReceiverReport {
  uint32_t sender_ssrc = 0;
  uint32_t last_sender_report = 0;
  uint32_t delay_since_last_sender_report = 0;
  int64_t receive_time_us = 0;
  uint32_t rtt_ms = 0;
};

struct PacketFeedback {
  uint16_t transport_sequence_number = 0;
  int64_t send_time_us = 0;
  int64_t receive_time_us = -1;
  size_t packet_size = 0;
};

struct UplinkTransportFeedback {
  TransportIds ids;
  uint16_t feedback_seq = 0;
  int64_t reference_time_us = 0;
  std::vector<PacketFeedback> packets;
};

struct DownlinkQuality {
  TransportIds ids;
  uint32_t report_seq = 0;
  uint64_t report_time_us = 0;
  uint16_t rtt_ms = 0;
  uint16_t fraction_lost_q8 = 0;
  uint16_t reorder_ratio_q8 = 0;
  uint16_t flags = 0;
  uint32_t recv_bitrate_bps = 0;
  uint16_t video_jitter_frames = 0;
  uint16_t video_decodable_queue_depth = 0;
  uint16_t video_drop_frames = 0;
  uint16_t last_pli_reason = 0;
};

struct SenderRateCap {
  TransportIds ids;
  uint32_t controller_seq = 0;
  uint32_t cap_bps = kUnlimitedRateCapBps;
  uint16_t expire_ms = 0;
  uint16_t reason_code = 0;
  int64_t receive_time_us = 0;
};

struct TargetRates {
  uint32_t googcc_target_bps = 1200000;
  uint32_t pacing_bps = 1200000;
  uint32_t sender_rate_cap_bps = kUnlimitedRateCapBps;
  uint32_t final_target_bps = 1200000;
  uint32_t rtt_ms = 0;
  double loss_fraction = 0.0;
};

struct EncoderAdaptation {
  uint32_t target_bitrate_bps = 1200000;
  uint32_t max_fps = 30;
  bool request_keyframe = false;
};

struct RetransmissionCacheConfig {
  uint32_t hold_ms = 1000;
  uint32_t max_hold_ms = 3000;
};

struct RecoveryRequest {
  enum class Type {
    kNone = 0,
    kNack,
    kPli,
  };

  Type type = Type::kNone;
  uint32_t sender_ssrc = 0;
  std::vector<uint16_t> missing_rtp_sequence_numbers;
  std::string reason;
};

}  // namespace webrtc_qos
