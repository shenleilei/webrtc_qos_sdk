#include "webrtc_qos/sender_pacer.h"

#include <algorithm>

namespace webrtc_qos {

SenderPacer::SenderPacer(SenderPacerConfig config,
                         SendPacketCallback send_callback)
    : config_(config),
      send_callback_(std::move(send_callback)),
      target_bps_(config.start_bitrate_bps) {}

Status SenderPacer::Enqueue(const SendPacket& packet) {
  if (!send_callback_) {
    return Status::Error(StatusCode::kInvalidArgument,
                         "SendPacket callback not set");
  }
  QueuedPacket queued;
  queued.packet = packet;
  queued.bytes = packet.packet.payload.size() + 20;
  queued.enqueue_time_us = packet.packet.capture_time_us;
  if (ShouldDropForQueueLimit(queued)) {
    if (packet.frame_type == VideoFrameType::kP && !packet.retransmission) {
      ++stats_.dropped_packets;
      ++stats_.dropped_access_units;
      if (config_.wait_for_idr_after_p_drop) {
        stats_.waiting_for_idr = true;
      }
      return Status::Error(StatusCode::kQueueFull, "dropped queued P frame");
    }
    Status drop_status = DropQueuedPFrames();
    if (!drop_status) {
      return drop_status;
    }
    if (ShouldDropForQueueLimit(queued)) {
      return Status::Error(StatusCode::kQueueFull, "pacer queue is full");
    }
  }

  if (packet.retransmission) {
    retransmission_queue_.push_back(std::move(queued));
  } else {
    if (packet.frame_type == VideoFrameType::kIdr) {
      stats_.waiting_for_idr = false;
    } else if (config_.wait_for_idr_after_p_drop && stats_.waiting_for_idr &&
               packet.frame_type == VideoFrameType::kP) {
      ++stats_.dropped_packets;
      ++stats_.dropped_access_units;
      return Status::Error(StatusCode::kQueueFull,
                           "waiting for IDR after P frame drop");
    }
    media_queue_.push_back(std::move(queued));
  }
  stats_.queued_packets = retransmission_queue_.size() + media_queue_.size();
  stats_.queued_bytes += packet.packet.payload.size() + 20;
  return Status::Ok();
}

Status SenderPacer::EnqueueAccessUnit(const std::vector<SendPacket>& packets) {
  if (packets.empty()) {
    return Status::Error(StatusCode::kInvalidArgument,
                         "empty access unit packet list");
  }
  if (!send_callback_) {
    return Status::Error(StatusCode::kInvalidArgument,
                         "SendPacket callback not set");
  }

  size_t access_unit_bytes = 0;
  uint32_t access_unit_duration_ms = 0;
  bool has_media = false;
  bool is_p_frame = false;
  bool has_idr = false;
  std::vector<QueuedPacket> queued_packets;
  queued_packets.reserve(packets.size());
  for (const SendPacket& packet : packets) {
    QueuedPacket queued;
    queued.packet = packet;
    queued.bytes = packet.packet.payload.size() + 20;
    queued.enqueue_time_us = packet.packet.capture_time_us;
    access_unit_bytes += queued.bytes;
    access_unit_duration_ms += packet.media_duration_ms;
    has_media = has_media || !packet.retransmission;
    is_p_frame = is_p_frame || (packet.frame_type == VideoFrameType::kP &&
                                !packet.retransmission);
    has_idr = has_idr || (packet.frame_type == VideoFrameType::kIdr &&
                          !packet.retransmission);
    queued_packets.push_back(std::move(queued));
  }

  if (has_media) {
    if (has_idr) {
      stats_.waiting_for_idr = false;
    } else if (config_.wait_for_idr_after_p_drop && stats_.waiting_for_idr &&
               is_p_frame) {
      stats_.dropped_packets += packets.size();
      ++stats_.dropped_access_units;
      return Status::Error(StatusCode::kQueueFull,
                           "waiting for IDR after P frame drop");
    }
  }

  const size_t queued_bytes = stats_.queued_bytes + access_unit_bytes;
  uint32_t queued_ms = access_unit_duration_ms;
  for (const auto& item : media_queue_) {
    queued_ms += item.packet.media_duration_ms;
  }
  if (queued_bytes > config_.max_queue_bytes ||
      queued_ms > static_cast<uint32_t>(config_.max_queue_ms)) {
    if (is_p_frame) {
      stats_.dropped_packets += packets.size();
      ++stats_.dropped_access_units;
      if (config_.wait_for_idr_after_p_drop) {
        stats_.waiting_for_idr = true;
      }
      return Status::Error(StatusCode::kQueueFull,
                           "dropped P access unit");
    }
    Status drop_status = DropQueuedPFrames();
    if (!drop_status) {
      return drop_status;
    }
    const size_t retry_bytes = stats_.queued_bytes + access_unit_bytes;
    queued_ms = access_unit_duration_ms;
    for (const auto& item : media_queue_) {
      queued_ms += item.packet.media_duration_ms;
    }
    if (retry_bytes > config_.max_queue_bytes ||
        queued_ms > static_cast<uint32_t>(config_.max_queue_ms)) {
      return Status::Error(StatusCode::kQueueFull, "pacer queue is full");
    }
  }

  for (QueuedPacket& queued : queued_packets) {
    if (queued.packet.retransmission) {
      retransmission_queue_.push_back(std::move(queued));
    } else {
      media_queue_.push_back(std::move(queued));
    }
  }
  stats_.queued_packets = retransmission_queue_.size() + media_queue_.size();
  stats_.queued_bytes += access_unit_bytes;
  return Status::Ok();
}

Status SenderPacer::Tick(int64_t now_us) {
  if (last_tick_us_ == 0) {
    last_tick_us_ = now_us;
  }
  DropExpiredMediaPackets(now_us);
  if (config_.wait_for_idr_after_p_drop && stats_.waiting_for_idr) {
    Status drop_status = DropQueuedPFrames();
    if (!drop_status) {
      return drop_status;
    }
  }
  const int64_t delta_us = std::max<int64_t>(0, now_us - last_tick_us_);
  last_tick_us_ = now_us;
  budget_bytes_ += (static_cast<double>(target_bps_) / 8.0) *
                   (static_cast<double>(delta_us) / 1000000.0);
  const double max_budget = (static_cast<double>(target_bps_) / 8.0) * 0.1;
  budget_bytes_ = std::min(budget_bytes_, std::max(1200.0, max_budget));

  auto send_from = [&](std::deque<QueuedPacket>* queue) -> Status {
    while (!queue->empty()) {
      const size_t bytes = queue->front().bytes;
      const bool is_retransmission = queue->front().packet.retransmission;
      const bool is_idr = queue->front().packet.frame_type == VideoFrameType::kIdr;
      const double required_budget =
          (is_retransmission || is_idr) ? std::min<double>(bytes, 1200) : bytes;
      if (budget_bytes_ < required_budget) {
        break;
      }
      SendPacket packet = queue->front().packet;
      queue->pop_front();
      Status status = send_callback_(packet.packet);
      if (!status) {
        return status;
      }
      budget_bytes_ -= std::min<double>(budget_bytes_, bytes);
      ++stats_.sent_packets;
      stats_.queued_bytes =
          stats_.queued_bytes > bytes ? stats_.queued_bytes - bytes : 0;
    }
    return Status::Ok();
  };

  Status status = send_from(&retransmission_queue_);
  if (!status) {
    return status;
  }
  status = send_from(&media_queue_);
  stats_.queued_packets = retransmission_queue_.size() + media_queue_.size();
  return status;
}

void SenderPacer::SetTargetBitrate(uint32_t target_bps) {
  target_bps_ = std::max<uint32_t>(1, target_bps);
}

SenderPacerStats SenderPacer::GetStats() const {
  SenderPacerStats stats = stats_;
  stats.queued_packets = retransmission_queue_.size() + media_queue_.size();
  return stats;
}

bool SenderPacer::ShouldDropForQueueLimit(const QueuedPacket& packet) const {
  const size_t queued_bytes = stats_.queued_bytes + packet.bytes;
  if (queued_bytes > config_.max_queue_bytes) {
    return true;
  }
  uint32_t queued_ms = packet.packet.media_duration_ms;
  for (const auto& item : media_queue_) {
    queued_ms += item.packet.media_duration_ms;
  }
  return queued_ms > static_cast<uint32_t>(config_.max_queue_ms);
}

void SenderPacer::DropExpiredMediaPackets(int64_t now_us) {
  if (config_.max_media_packet_age_ms <= 0) {
    return;
  }
  const int64_t max_age_us =
      static_cast<int64_t>(config_.max_media_packet_age_ms) * 1000;
  size_t removed_bytes = 0;
  size_t removed_packets = 0;
  uint64_t removed_access_units = 0;
  while (!media_queue_.empty()) {
    const QueuedPacket& front = media_queue_.front();
    const bool expired =
        front.enqueue_time_us > 0 && now_us - front.enqueue_time_us > max_age_us;
    if (!expired || front.packet.frame_type != VideoFrameType::kP) {
      break;
    }
    const uint32_t timestamp = front.packet.packet.timestamp;
    bool removed_any = false;
    while (!media_queue_.empty() &&
           media_queue_.front().packet.packet.timestamp == timestamp) {
      removed_bytes += media_queue_.front().bytes;
      ++removed_packets;
      removed_any = true;
      media_queue_.pop_front();
    }
    if (removed_any) {
      ++removed_access_units;
    }
  }
  if (removed_packets == 0) {
    return;
  }
  stats_.queued_bytes =
      stats_.queued_bytes > removed_bytes ? stats_.queued_bytes - removed_bytes
                                          : 0;
  stats_.dropped_packets += removed_packets;
  stats_.dropped_access_units += removed_access_units;
  if (config_.wait_for_idr_after_p_drop) {
    stats_.waiting_for_idr = true;
  }
  stats_.queued_packets = retransmission_queue_.size() + media_queue_.size();
}

Status SenderPacer::DropQueuedPFrames() {
  size_t removed_bytes = 0;
  size_t removed_packets = 0;
  uint64_t removed_access_units = 0;
  uint32_t last_removed_timestamp = 0;
  bool has_last_removed_timestamp = false;
  for (auto it = media_queue_.begin(); it != media_queue_.end();) {
    if (it->packet.frame_type == VideoFrameType::kP) {
      const uint32_t timestamp = it->packet.packet.timestamp;
      if (!has_last_removed_timestamp || timestamp != last_removed_timestamp) {
        ++removed_access_units;
        last_removed_timestamp = timestamp;
        has_last_removed_timestamp = true;
      }
      removed_bytes += it->bytes;
      ++removed_packets;
      it = media_queue_.erase(it);
    } else {
      ++it;
    }
  }
  if (removed_packets == 0) {
    return Status::Ok();
  }
  stats_.queued_bytes =
      stats_.queued_bytes > removed_bytes ? stats_.queued_bytes - removed_bytes
                                          : 0;
  stats_.dropped_packets += removed_packets;
  stats_.dropped_access_units += removed_access_units;
  if (config_.wait_for_idr_after_p_drop) {
    stats_.waiting_for_idr = true;
  }
  stats_.queued_packets = retransmission_queue_.size() + media_queue_.size();
  return Status::Ok();
}

}  // namespace webrtc_qos
