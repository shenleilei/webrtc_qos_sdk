#pragma once

#include <cstdint>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

struct QosSnapshot {
  TransportIds ids;
  uint64_t report_time_us = 0;
  TargetRates sender_rates;
  DownlinkQuality downlink_quality;
  // Recovery-side counters accumulated by the facade. Push reports emitted
  // retransmissions; play/server report observed or forwarded recovery events.
  uint32_t nack_count = 0;
  uint32_t pli_count = 0;
  uint32_t retransmission_count = 0;
  uint32_t dropped_retransmission_packets = 0;
  uint32_t unsupported_rtcp_packet_count = 0;
  // QoE-style freeze counters may be left at 0 by minimal transport facades
  // and instead be computed by higher-level decode/QoE harnesses.
  uint32_t freeze_count = 0;
  uint32_t freeze_duration_ms = 0;
  uint32_t jitter_buffer_delay_ms = 0;
  uint32_t dropped_frames = 0;
  // Sender-side pacer/probe accounting.
  uint64_t emitted_probe_packets = 0;
  uint64_t emitted_probe_bytes = 0;
  uint64_t emitted_padding_packets = 0;
  uint64_t emitted_padding_bytes = 0;
  int32_t last_probe_cluster_id = -1;
  // Role worker health. A large tick gap usually means the embedding business
  // thread stopped calling Process() or the router event loop stalled.
  uint32_t process_tick_count = 0;
  uint64_t process_tick_gap_us = 0;
  uint64_t max_process_tick_gap_us = 0;
};

}  // namespace webrtc_qos
