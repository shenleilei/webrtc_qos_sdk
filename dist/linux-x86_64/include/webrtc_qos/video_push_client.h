#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>

#include "webrtc_qos/qos_metrics.h"
#include "webrtc_qos/rate_cap.h"
#include "webrtc_qos/session_config.h"
#include "webrtc_qos/status.h"
#include "webrtc_qos/transport_io.h"

namespace webrtc_qos {

struct VideoPushClientConfig {
  SessionConfig session;
  TransportOutput transport_output;
};

class VideoPushClient {
 public:
  virtual ~VideoPushClient() = default;

  virtual Status Start() = 0;
  virtual Status Stop() = 0;
  virtual Status Process(int64_t now_us) = 0;
  virtual Status PushAnnexBAccessUnit(
      const AnnexBAccessUnitView& access_unit) = 0;
  virtual Status OnTransportFeedback(const uint8_t* rtcp_bytes,
                                     size_t rtcp_size,
                                     int64_t receive_time_us) = 0;
  virtual Status OnSenderRateCap(const SenderRateCap& cap) = 0;
  virtual EncoderAdaptation GetEncoderAdaptation(int64_t now_us) const = 0;
  virtual QosSnapshot GetQosSnapshot(int64_t now_us) const = 0;
};

std::unique_ptr<VideoPushClient> CreateVideoPushClient(
    const VideoPushClientConfig& config);

}  // namespace webrtc_qos
