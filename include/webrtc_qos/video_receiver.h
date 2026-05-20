#pragma once

#include <functional>

#include "webrtc_qos/receiver_qos_observer.h"
#include "webrtc_qos/video_jitter_player.h"

namespace webrtc_qos {

struct VideoReceiverConfig {
  TransportIds ids;
};

struct VideoReceiverCallbacks {
  std::function<void(const EncodedVideoFrame&)> on_frame;
  std::function<void(const DownlinkQuality&)> on_downlink_quality;
  std::function<void(const RecoveryRequest&)> on_recovery_request;
};

class VideoReceiver {
 public:
  VideoReceiver(VideoReceiverConfig config, VideoReceiverCallbacks callbacks);

  Status OnRtpPacket(const RtpPacket& packet, int64_t now_us);
  void SetDownlinkRttMs(uint16_t rtt_ms);
  void MaybeReport(int64_t now_us);

  VideoJitterStats GetJitterStats() const;

 private:
  VideoReceiverConfig config_;
  VideoReceiverCallbacks callbacks_;
  ReceiverQosObserver observer_;
  VideoJitterPlayer jitter_;
};

}  // namespace webrtc_qos
