#ifndef SDK_QOS_PACING_ADAPTER_H_
#define SDK_QOS_PACING_ADAPTER_H_

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace webrtc_qos {

struct PacingAdapterConfig {
  uint32_t pacing_bitrate_bps = 1200000;
  uint32_t padding_bitrate_bps = 0;
  uint32_t max_queue_bytes = 512 * 1024;
  uint32_t max_queue_time_ms = 500;
  uint8_t transport_sequence_extension_id = 1;
};

struct PacingAdapterProbeCluster {
  int32_t id = -1;
  uint32_t target_bitrate_bps = 0;
  uint32_t min_probe_count = 0;
  uint32_t min_probe_bytes = 0;
  uint32_t target_duration_us = 0;
  uint32_t min_probe_delta_us = 0;
};

struct PacingAdapterPacket {
  uint32_t ssrc = 0;
  uint16_t rtp_sequence_number = 0;
  int64_t transport_sequence_number = -1;
  int64_t enqueue_time_us = 0;
  bool retransmission = false;
  bool keyframe = false;
  bool padding = false;
  int32_t probe_cluster_id = -1;
  std::vector<uint8_t> bytes;
};

struct PacingAdapterStats {
  uint32_t pacing_bitrate_bps = 0;
  size_t queue_packets = 0;
  size_t queue_bytes = 0;
  uint32_t expected_queue_time_ms = 0;
  uint64_t emitted_packets = 0;
  uint64_t dropped_packets = 0;
  uint64_t emitted_retransmissions = 0;
  uint64_t emitted_keyframe_packets = 0;
  uint64_t emitted_probe_packets = 0;
  uint64_t emitted_probe_bytes = 0;
  uint64_t emitted_padding_packets = 0;
  uint64_t emitted_padding_bytes = 0;
  int32_t last_probe_cluster_id = -1;
};

class PacingAdapter {
 public:
  explicit PacingAdapter(const PacingAdapterConfig& config);
  ~PacingAdapter();

  PacingAdapter(const PacingAdapter&) = delete;
  PacingAdapter& operator=(const PacingAdapter&) = delete;

  void SetRates(uint32_t pacing_bitrate_bps, uint32_t padding_bitrate_bps);
  void SetProbeCluster(const PacingAdapterProbeCluster& probe_cluster);
  void ClearProbeCluster();
  bool EnqueuePacket(const PacingAdapterPacket& packet);
  std::vector<PacingAdapterPacket> Process(int64_t now_us);
  PacingAdapterStats stats() const;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

PacingAdapter* CreatePacingAdapter(const PacingAdapterConfig& config);
void DestroyPacingAdapter(PacingAdapter* adapter);

}  // namespace webrtc_qos

#endif  // SDK_QOS_PACING_ADAPTER_H_
