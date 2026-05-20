#pragma once

#include <deque>
#include <optional>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

class RetransmissionCache {
 public:
  explicit RetransmissionCache(RetransmissionCacheConfig config = {});

  void Store(const RtpPacket& packet, int64_t now_us);
  std::optional<RtpPacket> Find(uint16_t rtp_sequence_number,
                                uint16_t new_transport_sequence_number) const;
  void Prune(int64_t now_us, uint32_t smoothed_rtt_ms);
  size_t size() const { return entries_.size(); }

 private:
  struct Entry {
    RtpPacket packet;
    int64_t store_time_us = 0;
  };

  RetransmissionCacheConfig config_;
  std::deque<Entry> entries_;
};

}  // namespace webrtc_qos
