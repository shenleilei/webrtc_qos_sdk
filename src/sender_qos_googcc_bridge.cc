#include "webrtc_qos/sender_qos_googcc_bridge.h"

#include <algorithm>
#include <cstdint>
#include <memory>
#include <vector>

#include "webrtc_qos/googcc_adapter.h"

namespace webrtc_qos {
namespace {

class GoogCcSenderQosBackend final : public SenderQosBackend {
 public:
  GoogCcSenderQosBackend(const SenderQosControllerConfig& config,
                         int64_t start_time_us)
      : adapter_(GoogCcAdapterConfig{config.start_bitrate_bps,
                                     config.min_bitrate_bps,
                                     config.max_bitrate_bps}) {
    adapter_.OnNetworkAvailable(start_time_us);
    rates_ = adapter_.rates();
  }

  Status OnPacketSent(uint16_t transport_sequence_number,
                      size_t packet_size,
                      int64_t send_time_us) override {
    adapter_.OnSentPacket(transport_sequence_number,
                          static_cast<uint32_t>(
                              std::min<size_t>(packet_size, UINT32_MAX)),
                          send_time_us);
    rates_ = adapter_.rates();
    return Status::Ok();
  }

  Status OnProbePacketSent(uint16_t transport_sequence_number,
                           size_t packet_size,
                           int64_t send_time_us,
                           const ProbeCluster& probe_cluster) override {
    adapter_.OnProbePacketSent(
        transport_sequence_number,
        static_cast<uint32_t>(
            std::min<size_t>(packet_size, UINT32_MAX)),
        send_time_us,
        GoogCcProbeCluster{probe_cluster.id,
                           probe_cluster.target_bitrate_bps,
                           probe_cluster.min_probe_count,
                           probe_cluster.min_probe_bytes,
                           probe_cluster.target_duration_us,
                           probe_cluster.min_probe_delta_us});
    rates_ = adapter_.rates();
    return Status::Ok();
  }

  Status OnUplinkTransportFeedback(
      const UplinkTransportFeedback& feedback) override {
    std::vector<GoogCcPacketFeedback> packets;
    packets.reserve(feedback.packets.size());
    for (const auto& packet : feedback.packets) {
      packets.push_back(GoogCcPacketFeedback{
          packet.transport_sequence_number,
          packet.send_time_us,
          packet.receive_time_us,
          static_cast<uint32_t>(
              std::min<size_t>(packet.packet_size, UINT32_MAX)),
      });
    }
    const int64_t feedback_time_us =
        feedback.reference_time_us > 0 ? feedback.reference_time_us : 0;
    adapter_.OnTransportFeedback(packets, feedback_time_us);
    rates_ = adapter_.rates();
    return Status::Ok();
  }

  Status OnRtcpReceiverReport(const RtcpReceiverReport& report) override {
    adapter_.OnRoundTripTime(report.rtt_ms, report.receive_time_us);
    rates_ = adapter_.rates();
    return Status::Ok();
  }

  Status OnProcessInterval(int64_t at_time_us) override {
    adapter_.OnProcessInterval(at_time_us);
    rates_ = adapter_.rates();
    return Status::Ok();
  }

  Status OnNetworkRouteChange(uint32_t start_bitrate_bps,
                              uint32_t min_bitrate_bps,
                              uint32_t max_bitrate_bps,
                              int64_t at_time_us) override {
    adapter_.OnNetworkRouteChange(start_bitrate_bps, min_bitrate_bps,
                                  max_bitrate_bps, at_time_us);
    rates_ = adapter_.rates();
    return Status::Ok();
  }

  uint32_t target_bitrate_bps() const override {
    return rates_.target_bitrate_bps;
  }

  uint32_t pacing_bitrate_bps() const override {
    return rates_.pacing_bitrate_bps > 0 ? rates_.pacing_bitrate_bps
                                         : rates_.target_bitrate_bps;
  }

  std::vector<ProbeCluster> TakeProbeClusters() override {
    std::vector<GoogCcProbeCluster> adapter_clusters =
        adapter_.TakeProbeClusters();
    std::vector<ProbeCluster> clusters;
    clusters.reserve(adapter_clusters.size());
    for (const auto& cluster : adapter_clusters) {
      clusters.push_back(ProbeCluster{cluster.id,
                                      cluster.target_bitrate_bps,
                                      cluster.min_probe_count,
                                      cluster.min_probe_bytes,
                                      cluster.target_duration_us,
                                      cluster.min_probe_delta_us});
    }
    return clusters;
  }

 private:
  GoogCcAdapter adapter_;
  GoogCcAdapterRates rates_;
};

}  // namespace

std::unique_ptr<SenderQosBackend> CreateGoogCcSenderQosBackend(
    const SenderQosControllerConfig& config,
    int64_t start_time_us) {
  return std::make_unique<GoogCcSenderQosBackend>(config, start_time_us);
}

SenderQosController CreateGoogCcSenderQosController(
    const SenderQosControllerConfig& config,
    int64_t start_time_us) {
  return SenderQosController(config,
                             CreateGoogCcSenderQosBackend(config,
                                                           start_time_us));
}

}  // namespace webrtc_qos
