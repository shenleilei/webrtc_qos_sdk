#ifndef SDK_QOS_GOOGCC_ADAPTER_H_
#define SDK_QOS_GOOGCC_ADAPTER_H_

#include <cstdint>
#include <memory>
#include <vector>

namespace webrtc_qos {

struct GoogCcAdapterConfig {
  uint32_t start_bitrate_bps = 1200000;
  uint32_t min_bitrate_bps = 300000;
  uint32_t max_bitrate_bps = 2500000;
};

struct GoogCcPacketFeedback {
  int64_t transport_sequence_number = 0;
  int64_t send_time_us = 0;
  int64_t receive_time_us = -1;
  uint32_t packet_size_bytes = 0;
};

struct GoogCcAdapterRates {
  uint32_t target_bitrate_bps = 0;
  uint32_t pacing_bitrate_bps = 0;
};

struct GoogCcProbeCluster {
  int32_t id = -1;
  uint32_t target_bitrate_bps = 0;
  uint32_t min_probe_count = 0;
  uint32_t min_probe_bytes = 0;
  uint32_t target_duration_us = 0;
  uint32_t min_probe_delta_us = 0;
};

class GoogCcAdapter {
 public:
  explicit GoogCcAdapter(const GoogCcAdapterConfig& config);
  ~GoogCcAdapter();

  GoogCcAdapter(const GoogCcAdapter&) = delete;
  GoogCcAdapter& operator=(const GoogCcAdapter&) = delete;

  void OnNetworkAvailable(int64_t at_time_us);
  void OnNetworkRouteChange(uint32_t start_bitrate_bps,
                            uint32_t min_bitrate_bps,
                            uint32_t max_bitrate_bps,
                            int64_t at_time_us);
  void OnSentPacket(int64_t transport_sequence_number,
                    uint32_t packet_size_bytes,
                    int64_t send_time_us);
  void OnProbePacketSent(int64_t transport_sequence_number,
                         uint32_t packet_size_bytes,
                         int64_t send_time_us,
                         const GoogCcProbeCluster& probe_cluster);
  void OnRoundTripTime(uint32_t rtt_ms, int64_t at_time_us);
  void OnTransportFeedback(const std::vector<GoogCcPacketFeedback>& feedback,
                           int64_t feedback_time_us);
  // GoogCC expects this to be called periodically. WebRTC's factory interval
  // is 25 ms; the SDK facade should drive it from the sender worker thread.
  void OnProcessInterval(int64_t at_time_us);

  GoogCcAdapterRates rates() const;
  std::vector<GoogCcProbeCluster> TakeProbeClusters();

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace webrtc_qos

#endif  // SDK_QOS_GOOGCC_ADAPTER_H_
