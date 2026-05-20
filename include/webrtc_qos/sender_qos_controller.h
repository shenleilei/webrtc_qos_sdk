#pragma once

#include <cstdint>
#include <memory>
#include <unordered_map>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

struct SenderQosControllerConfig {
  TransportIds ids;
  uint32_t start_bitrate_bps = 1200000;
  uint32_t min_bitrate_bps = 300000;
  uint32_t max_bitrate_bps = 2500000;
};

class SenderQosBackend {
 public:
  virtual ~SenderQosBackend() = default;

  virtual Status OnPacketSent(uint16_t transport_sequence_number,
                              size_t packet_size,
                              int64_t send_time_us) = 0;
  virtual Status OnUplinkTransportFeedback(
      const UplinkTransportFeedback& feedback) = 0;
  virtual Status OnRtcpReceiverReport(const RtcpReceiverReport& report) = 0;
  virtual uint32_t target_bitrate_bps() const = 0;
  virtual uint32_t pacing_bitrate_bps() const { return target_bitrate_bps(); }
};

class SenderQosController {
 public:
  explicit SenderQosController(SenderQosControllerConfig config);
  SenderQosController(SenderQosControllerConfig config,
                      std::unique_ptr<SenderQosBackend> backend);

  SenderQosController(SenderQosController&&) noexcept = default;
  SenderQosController& operator=(SenderQosController&&) noexcept = default;
  SenderQosController(const SenderQosController&) = delete;
  SenderQosController& operator=(const SenderQosController&) = delete;

  Status OnPacketSent(uint16_t transport_sequence_number,
                      size_t packet_size,
                      int64_t send_time_us);
  Status OnUplinkTransportFeedback(const UplinkTransportFeedback& feedback);
  Status OnRtcpReceiverReport(const RtcpReceiverReport& report);
  Status OnSenderRateCap(const SenderRateCap& cap);

  TargetRates GetTargetRates(int64_t now_us) const;
  EncoderAdaptation GetEncoderAdaptation(int64_t now_us) const;

 private:
  SenderQosControllerConfig config_;
  uint32_t estimate_bps_;
  uint32_t pacing_bps_;
  uint32_t rate_cap_bps_ = kUnlimitedRateCapBps;
  int64_t rate_cap_expire_time_us_ = 0;
  uint32_t rtt_ms_ = 0;
  double loss_fraction_ = 0.0;
  std::unordered_map<uint16_t, PacketFeedback> sent_packets_;
  std::unique_ptr<SenderQosBackend> backend_;
};

}  // namespace webrtc_qos
