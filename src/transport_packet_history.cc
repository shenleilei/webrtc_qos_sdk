#include "webrtc_qos/transport_packet_history.h"

#include <algorithm>
#include <utility>

namespace webrtc_qos {

namespace {

bool SameKey(const TransportPacketHistoryKey& a,
             const TransportPacketHistoryKey& b) {
  return a.hop_id == b.hop_id && a.ssrc == b.ssrc &&
         a.rtp_sequence_number == b.rtp_sequence_number;
}

}  // namespace

TransportPacketHistory::TransportPacketHistory(
    TransportPacketHistoryConfig config)
    : config_(config) {}

void TransportPacketHistory::Store(const TransportPacketHistoryKey& key,
                                   const uint8_t* rtp_bytes,
                                   size_t rtp_size,
                                   int64_t send_time_us,
                                   bool retransmission) {
  if (!rtp_bytes || rtp_size == 0) {
    return;
  }
  TransportPacketHistoryPacket packet;
  packet.key = key;
  packet.send_time_us = send_time_us;
  packet.retransmission = retransmission;
  packet.rtp_bytes.assign(rtp_bytes, rtp_bytes + rtp_size);
  entries_.push_back(std::move(packet));
  while (config_.max_packets > 0 && entries_.size() > config_.max_packets) {
    entries_.pop_front();
  }
}

std::optional<TransportPacketHistoryPacket> TransportPacketHistory::Find(
    const TransportPacketHistoryKey& key) const {
  for (auto it = entries_.rbegin(); it != entries_.rend(); ++it) {
    if (SameKey(it->key, key)) {
      return *it;
    }
  }
  return std::nullopt;
}

void TransportPacketHistory::Prune(int64_t now_us, uint32_t smoothed_rtt_ms) {
  const uint32_t hold_ms =
      std::min(config_.max_hold_ms,
               std::max(config_.hold_ms, smoothed_rtt_ms * 3));
  const int64_t hold_us = static_cast<int64_t>(hold_ms) * 1000;
  while (!entries_.empty() &&
         now_us - entries_.front().send_time_us > hold_us) {
    entries_.pop_front();
  }
}

}  // namespace webrtc_qos
