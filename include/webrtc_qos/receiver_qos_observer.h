#pragma once

#include <set>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

struct ReceiverQosObserverConfig {
  TransportIds ids;
  uint32_t report_interval_ms = 200;
};

class ReceiverQosObserver {
 public:
  explicit ReceiverQosObserver(ReceiverQosObserverConfig config);

  void OnRtpPacketReceived(const RtpPacket& packet, int64_t now_us);
  void OnFrameDecoded(uint32_t rtp_timestamp);
  void SetDownlinkRttMs(uint16_t rtt_ms);

  bool ShouldReport(int64_t now_us) const;
  DownlinkQuality BuildReport(int64_t now_us);
  std::vector<uint16_t> TakeMissingSequenceNumbers();

 private:
  ReceiverQosObserverConfig config_;
  bool initialized_ = false;
  uint16_t max_seq_ = 0;
  uint32_t received_packets_ = 0;
  uint32_t lost_packets_ = 0;
  uint32_t reordered_packets_ = 0;
  uint32_t decoded_frames_ = 0;
  uint32_t report_seq_ = 0;
  uint16_t rtt_ms_ = 0;
  int64_t first_packet_time_us_ = 0;
  int64_t last_report_time_us_ = 0;
  std::set<uint16_t> missing_;
};

}  // namespace webrtc_qos
