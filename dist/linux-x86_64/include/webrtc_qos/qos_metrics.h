#pragma once

#include <cstdint>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

struct QosSnapshot {
  TransportIds ids;
  uint64_t report_time_us = 0;
  TargetRates sender_rates;
  DownlinkQuality downlink_quality;
  uint32_t nack_count = 0;
  uint32_t pli_count = 0;
  uint32_t retransmission_count = 0;
  uint32_t freeze_count = 0;
  uint32_t freeze_duration_ms = 0;
  uint32_t jitter_buffer_delay_ms = 0;
  uint32_t dropped_frames = 0;
  uint64_t emitted_probe_packets = 0;
  uint64_t emitted_probe_bytes = 0;
  uint64_t emitted_padding_packets = 0;
  uint64_t emitted_padding_bytes = 0;
  int32_t last_probe_cluster_id = -1;
};

}  // namespace webrtc_qos
