#pragma once

#include <deque>
#include <vector>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

struct SenderPacerConfig {
  uint32_t start_bitrate_bps = 1200000;
  int tick_ms = kPacerTickMs;
  int max_queue_ms = kPacerMaxQueueMs;
  size_t max_queue_bytes = kPacerMaxQueueBytes;
  int max_media_packet_age_ms = 1400;
  bool wait_for_idr_after_p_drop = true;
};

struct SenderPacerStats {
  size_t queued_packets = 0;
  size_t queued_bytes = 0;
  uint64_t sent_packets = 0;
  uint64_t dropped_packets = 0;
  uint64_t dropped_access_units = 0;
  bool waiting_for_idr = false;
};

class SenderPacer {
 public:
  SenderPacer(SenderPacerConfig config, SendPacketCallback send_callback);

  Status Enqueue(const SendPacket& packet);
  Status EnqueueAccessUnit(const std::vector<SendPacket>& packets);
  Status Tick(int64_t now_us);
  void SetTargetBitrate(uint32_t target_bps);
  SenderPacerStats GetStats() const;

 private:
  struct QueuedPacket {
    SendPacket packet;
    size_t bytes = 0;
    int64_t enqueue_time_us = 0;
  };

  bool ShouldDropForQueueLimit(const QueuedPacket& packet) const;
  void DropExpiredMediaPackets(int64_t now_us);
  Status DropQueuedPFrames();

  SenderPacerConfig config_;
  SendPacketCallback send_callback_;
  uint32_t target_bps_;
  double budget_bytes_ = 0.0;
  int64_t last_tick_us_ = 0;
  std::deque<QueuedPacket> retransmission_queue_;
  std::deque<QueuedPacket> media_queue_;
  SenderPacerStats stats_;
};

}  // namespace webrtc_qos
