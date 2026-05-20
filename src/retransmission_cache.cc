#include "webrtc_qos/retransmission_cache.h"

#include <algorithm>

namespace webrtc_qos {

RetransmissionCache::RetransmissionCache(RetransmissionCacheConfig config)
    : config_(config) {}

void RetransmissionCache::Store(const RtpPacket& packet, int64_t now_us) {
  entries_.push_back(Entry{packet, now_us});
}

std::optional<RtpPacket> RetransmissionCache::Find(
    uint16_t rtp_sequence_number,
    uint16_t new_transport_sequence_number) const {
  for (auto it = entries_.rbegin(); it != entries_.rend(); ++it) {
    if (it->packet.sequence_number == rtp_sequence_number) {
      RtpPacket retransmission = it->packet;
      retransmission.transport_sequence_number = new_transport_sequence_number;
      return retransmission;
    }
  }
  return std::nullopt;
}

void RetransmissionCache::Prune(int64_t now_us, uint32_t smoothed_rtt_ms) {
  const uint32_t hold_ms =
      std::min(config_.max_hold_ms,
               std::max(config_.hold_ms, smoothed_rtt_ms * 3));
  const int64_t hold_us = static_cast<int64_t>(hold_ms) * 1000;
  while (!entries_.empty() && now_us - entries_.front().store_time_us > hold_us) {
    entries_.pop_front();
  }
}

}  // namespace webrtc_qos
