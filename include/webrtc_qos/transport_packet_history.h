#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <vector>

namespace webrtc_qos {

struct TransportPacketHistoryConfig {
  uint32_t hold_ms = 1000;
  uint32_t max_hold_ms = 3000;
  size_t max_packets = 4096;
};

struct TransportPacketHistoryKey {
  uint32_t hop_id = 0;
  uint32_t ssrc = 0;
  uint16_t rtp_sequence_number = 0;
};

struct TransportPacketHistoryPacket {
  TransportPacketHistoryKey key;
  int64_t send_time_us = 0;
  bool retransmission = false;
  std::vector<uint8_t> rtp_bytes;
};

class TransportPacketHistory {
 public:
  explicit TransportPacketHistory(TransportPacketHistoryConfig config = {});

  void Store(const TransportPacketHistoryKey& key,
             const uint8_t* rtp_bytes,
             size_t rtp_size,
             int64_t send_time_us,
             bool retransmission);
  std::optional<TransportPacketHistoryPacket> Find(
      const TransportPacketHistoryKey& key) const;
  void Prune(int64_t now_us, uint32_t smoothed_rtt_ms);
  size_t size() const { return entries_.size(); }

 private:
  TransportPacketHistoryConfig config_;
  std::deque<TransportPacketHistoryPacket> entries_;
};

}  // namespace webrtc_qos
