#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>

#include "webrtc_qos/qos_metrics.h"
#include "webrtc_qos/session_config.h"
#include "webrtc_qos/status.h"
#include "webrtc_qos/transport_io.h"

namespace webrtc_qos {

using AnnexBAccessUnitCallback =
    std::function<Status(const AnnexBAccessUnitView& access_unit)>;

struct VideoPlayClientConfig {
  SessionConfig session;
  TransportOutput transport_output;
  AnnexBAccessUnitCallback decoded_access_unit_output;
};

class VideoPlayClient {
 public:
  virtual ~VideoPlayClient() = default;

  virtual Status Start() = 0;
  virtual Status Stop() = 0;
  virtual Status OnRtpPacket(const uint8_t* rtp_bytes,
                             size_t rtp_size,
                             int64_t receive_time_us) = 0;
  virtual Status OnRtcpPacket(const uint8_t* rtcp_bytes,
                              size_t rtcp_size,
                              int64_t receive_time_us) = 0;
  // Returns transport/recovery-side receiver stats such as NACK/PLI/loss/RTT.
  // QoE metrics like PSNR/SSIM/playable ratio are produced by upper decode/QoE
  // harnesses, not by the public VideoPlayClient API.
  virtual QosSnapshot GetQosSnapshot(int64_t now_us) const = 0;
};

std::unique_ptr<VideoPlayClient> CreateVideoPlayClient(
    const VideoPlayClientConfig& config);

}  // namespace webrtc_qos
