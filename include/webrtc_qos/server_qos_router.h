#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>

#include "webrtc_qos/control_messages.h"
#include "webrtc_qos/qos_metrics.h"
#include "webrtc_qos/runtime_logging.h"
#include "webrtc_qos/runtime_metrics.h"
#include "webrtc_qos/session_config.h"
#include "webrtc_qos/status.h"
#include "webrtc_qos/transport_io.h"

namespace webrtc_qos {

struct ServerQosRouterConfig {
  SessionConfig session;
  TransportOutput sender_output;
  TransportOutput receiver_output;
  RuntimeLogConfig logging;
  RuntimeMetricsConfig metrics;
};

class ServerQosRouter {
 public:
  virtual ~ServerQosRouter() = default;

  virtual Status Start() = 0;
  virtual Status Stop() = 0;
  virtual Status OnSenderRtp(const uint8_t* rtp_bytes,
                             size_t rtp_size,
                             int64_t receive_time_us) = 0;
  virtual Status OnSenderRtcp(const uint8_t* rtcp_bytes,
                              size_t rtcp_size,
                              int64_t receive_time_us) = 0;
  virtual Status OnReceiverRtcp(uint32_t receiver_id,
                                const uint8_t* rtcp_bytes,
                                size_t rtcp_size,
                                int64_t receive_time_us) = 0;
  virtual Status OnDownlinkQuality(const DownlinkQuality& quality) = 0;
  virtual SenderRateCap CurrentSenderRateCap(int64_t now_us) const = 0;
  virtual QosSnapshot GetQosSnapshot(int64_t now_us) const = 0;
};

std::unique_ptr<ServerQosRouter> CreateServerQosRouter(
    const ServerQosRouterConfig& config);

}  // namespace webrtc_qos
