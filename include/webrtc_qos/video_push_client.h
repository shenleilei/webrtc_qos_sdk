#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>

#include "webrtc_qos/qos_metrics.h"
#include "webrtc_qos/rate_cap.h"
#include "webrtc_qos/runtime_logging.h"
#include "webrtc_qos/runtime_metrics.h"
#include "webrtc_qos/session_config.h"
#include "webrtc_qos/status.h"
#include "webrtc_qos/transport_io.h"

namespace webrtc_qos {

struct VideoPushClientConfig {
  SessionConfig session;
  TransportOutput transport_output;
  RuntimeLogConfig logging;
  RuntimeMetricsConfig metrics;
};

class VideoPushClient {
 public:
  virtual ~VideoPushClient() = default;

  virtual Status Start() = 0;
  virtual Status Stop() = 0;
  // Drive pacer, GoogCC and periodic RTCP on a sender worker thread.
  // Call this continuously even when there is no new access unit to push.
  virtual Status Process(int64_t now_us) = 0;
  virtual Status PushAnnexBAccessUnit(
      const AnnexBAccessUnitView& access_unit) = 0;
  virtual Status OnTransportFeedback(const uint8_t* rtcp_bytes,
                                     size_t rtcp_size,
                                     int64_t receive_time_us) = 0;
  // Inform the sender that the business-side network route or bitrate envelope
  // changed, so the facade can forward a WebRTC route change into GoogCC.
  virtual Status OnNetworkRouteChange(uint32_t start_bitrate_bps,
                                      uint32_t min_bitrate_bps,
                                      uint32_t max_bitrate_bps,
                                      int64_t at_time_us) = 0;
  virtual Status OnSenderRateCap(const SenderRateCap& cap) = 0;
  virtual EncoderAdaptation GetEncoderAdaptation(int64_t now_us) const = 0;
  virtual bool GetTrackEncoderAdaptation(uint32_t track_id,
                                         int64_t now_us,
                                         EncoderAdaptation* out) const = 0;
  virtual QosSnapshot GetQosSnapshot(int64_t now_us) const = 0;
  virtual bool GetTrackQosSnapshot(uint32_t track_id,
                                   int64_t now_us,
                                   QosSnapshot* out) const = 0;
};

std::unique_ptr<VideoPushClient> CreateVideoPushClient(
    const VideoPushClientConfig& config);

}  // namespace webrtc_qos
