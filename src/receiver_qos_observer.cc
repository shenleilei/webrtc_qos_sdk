#include "webrtc_qos/receiver_qos_observer.h"

#include <algorithm>

namespace webrtc_qos {

ReceiverQosObserver::ReceiverQosObserver(ReceiverQosObserverConfig config)
    : config_(config) {}

void ReceiverQosObserver::OnRtpPacketReceived(const RtpPacket& packet,
                                              int64_t now_us) {
  if (!initialized_) {
    initialized_ = true;
    max_seq_ = packet.sequence_number;
    first_packet_time_us_ = now_us;
  } else {
    const uint16_t expected = static_cast<uint16_t>(max_seq_ + 1);
    if (packet.sequence_number == expected) {
      max_seq_ = packet.sequence_number;
    } else if (static_cast<uint16_t>(packet.sequence_number - max_seq_) <
               0x8000) {
      uint16_t missing = expected;
      while (missing != packet.sequence_number) {
        missing_.insert(missing);
        ++lost_packets_;
        ++missing;
      }
      max_seq_ = packet.sequence_number;
    } else {
      ++reordered_packets_;
      missing_.erase(packet.sequence_number);
    }
  }
  ++received_packets_;
}

void ReceiverQosObserver::OnFrameDecoded(uint32_t /*rtp_timestamp*/) {
  ++decoded_frames_;
}

void ReceiverQosObserver::SetDownlinkRttMs(uint16_t rtt_ms) {
  rtt_ms_ = rtt_ms;
}

bool ReceiverQosObserver::ShouldReport(int64_t now_us) const {
  return last_report_time_us_ == 0 ||
         now_us - last_report_time_us_ >=
             static_cast<int64_t>(config_.report_interval_ms) * 1000;
}

DownlinkQuality ReceiverQosObserver::BuildReport(int64_t now_us) {
  DownlinkQuality report;
  report.ids = config_.ids;
  report.report_seq = ++report_seq_;
  report.report_time_us = static_cast<uint64_t>(now_us);
  report.rtt_ms = rtt_ms_;
  const uint32_t total = std::max<uint32_t>(1, received_packets_ + lost_packets_);
  report.fraction_lost_q8 =
      static_cast<uint16_t>(std::min<uint32_t>(255, lost_packets_ * 256 / total));
  report.reorder_ratio_q8 = static_cast<uint16_t>(
      std::min<uint32_t>(255, reordered_packets_ * 256 / total));
  const int64_t elapsed_us = std::max<int64_t>(1, now_us - first_packet_time_us_);
  report.recv_bitrate_bps =
      static_cast<uint32_t>((received_packets_ * 1200ull * 8ull * 1000000ull) /
                            static_cast<uint64_t>(elapsed_us));
  report.video_drop_frames = static_cast<uint16_t>(lost_packets_);
  last_report_time_us_ = now_us;
  return report;
}

std::vector<uint16_t> ReceiverQosObserver::TakeMissingSequenceNumbers() {
  std::vector<uint16_t> out(missing_.begin(), missing_.end());
  missing_.clear();
  return out;
}

}  // namespace webrtc_qos
