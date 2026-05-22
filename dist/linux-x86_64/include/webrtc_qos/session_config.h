#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

struct H264SessionConfig {
  uint8_t payload_type = kH264PayloadType;
  uint32_t clock_rate_hz = kVideoClockRateHz;
  uint32_t profile_level_id = kH264ProfileLevelId;
  uint16_t max_rtp_payload_bytes = kMaxRtpPayloadBytes;
  uint16_t max_width = 1280;
  uint16_t max_height = 720;
  uint16_t max_fps = 30;
  bool packetization_mode_1 = true;
  bool allow_single_nalu = true;
  bool allow_fua = true;
  bool allow_stapa = false;
  bool allow_b_frames = false;
  bool require_sps_pps_before_idr = true;
};

struct TwccSessionConfig {
  uint8_t extension_id = kTransportWideCcExtensionId;
  const char* extension_uri = kTransportWideCcUri;
  uint16_t feedback_interval_ms = 50;
};

struct RtcpSessionConfig {
  uint16_t sr_rr_interval_ms = 1000;
  // Sender SSRC used by play-side receiver feedback such as NACK/PLI.
  // If left at 0, the facade derives a stable SSRC distinct from receiver_id.
  uint32_t receiver_feedback_ssrc = 0;
  // Sender SSRC used by server-generated uplink feedback such as TWCC/RR.
  // If left at 0, the facade derives a stable SSRC distinct from receiver_id.
  uint32_t server_feedback_ssrc = 0;
};

struct VideoTrackConfig {
  TransportIds ids;
  H264SessionConfig h264;
  uint32_t weight = 100;
  bool enabled = true;
  bool base_track = false;
};

struct SessionConfig {
  TransportIds ids;
  H264SessionConfig h264;
  std::vector<VideoTrackConfig> video_tracks;
  TwccSessionConfig twcc;
  RtcpSessionConfig rtcp;
  uint32_t start_bitrate_bps = 1200000;
  uint32_t min_bitrate_bps = 300000;
  uint32_t max_bitrate_bps = 2500000;
  std::string debug_name;
};

struct AnnexBAccessUnitView {
  const uint8_t* bytes = nullptr;
  size_t size = 0;
  int64_t capture_time_us = 0;
  bool keyframe = false;
  TransportIds ids;
};

}  // namespace webrtc_qos
