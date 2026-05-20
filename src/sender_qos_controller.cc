#include "webrtc_qos/sender_qos_controller.h"

#include <algorithm>
#include <utility>

namespace webrtc_qos {

SenderQosController::SenderQosController(SenderQosControllerConfig config)
    : config_(config), estimate_bps_(config.start_bitrate_bps) {}

SenderQosController::SenderQosController(
    SenderQosControllerConfig config,
    std::unique_ptr<SenderQosBackend> backend)
    : config_(config),
      estimate_bps_(config.start_bitrate_bps),
      backend_(std::move(backend)) {}

Status SenderQosController::OnPacketSent(uint16_t transport_sequence_number,
                                         size_t packet_size,
                                         int64_t send_time_us) {
  sent_packets_[transport_sequence_number] =
      PacketFeedback{transport_sequence_number, send_time_us, -1, packet_size};
  if (backend_) {
    return backend_->OnPacketSent(transport_sequence_number, packet_size,
                                  send_time_us);
  }
  return Status::Ok();
}

Status SenderQosController::OnUplinkTransportFeedback(
    const UplinkTransportFeedback& feedback) {
  if (feedback.ids.transport_id != config_.ids.transport_id) {
    return Status::Error(StatusCode::kInvalidArgument,
                         "feedback transport_id mismatch");
  }

  if (backend_) {
    Status status = backend_->OnUplinkTransportFeedback(feedback);
    if (!status) {
      return status;
    }
    estimate_bps_ = std::max(config_.min_bitrate_bps,
                             std::min(config_.max_bitrate_bps,
                                      backend_->target_bitrate_bps()));
  }

  size_t reported = 0;
  size_t lost = 0;
  size_t acked_bytes = 0;
  int64_t first_recv_us = -1;
  int64_t last_recv_us = -1;
  for (const auto& packet : feedback.packets) {
    ++reported;
    if (packet.receive_time_us < 0) {
      ++lost;
      continue;
    }
    auto it = sent_packets_.find(packet.transport_sequence_number);
    if (it != sent_packets_.end()) {
      acked_bytes += it->second.packet_size;
      sent_packets_.erase(it);
    } else {
      acked_bytes += packet.packet_size;
    }
    if (first_recv_us < 0 || packet.receive_time_us < first_recv_us) {
      first_recv_us = packet.receive_time_us;
    }
    if (last_recv_us < packet.receive_time_us) {
      last_recv_us = packet.receive_time_us;
    }
  }

  if (reported > 0) {
    loss_fraction_ = static_cast<double>(lost) / static_cast<double>(reported);
  }

  if (backend_) {
    return Status::Ok();
  }

  if (loss_fraction_ > 0.10) {
    estimate_bps_ = static_cast<uint32_t>(estimate_bps_ * 0.85);
  } else if (loss_fraction_ < 0.02 && first_recv_us >= 0 &&
             last_recv_us > first_recv_us) {
    estimate_bps_ = static_cast<uint32_t>(estimate_bps_ * 1.05);
  } else if (acked_bytes > 0 && first_recv_us >= 0 &&
             last_recv_us > first_recv_us) {
    const double seconds = (last_recv_us - first_recv_us) / 1000000.0;
    const uint32_t recv_bps =
        static_cast<uint32_t>((acked_bytes * 8) / std::max(seconds, 0.001));
    estimate_bps_ = static_cast<uint32_t>(estimate_bps_ * 0.8 + recv_bps * 0.2);
  }
  estimate_bps_ =
      std::max(config_.min_bitrate_bps,
               std::min(config_.max_bitrate_bps, estimate_bps_));
  return Status::Ok();
}

Status SenderQosController::OnRtcpReceiverReport(
    const RtcpReceiverReport& report) {
  if (report.sender_ssrc != 0 && report.sender_ssrc != config_.ids.sender_ssrc) {
    return Status::Error(StatusCode::kInvalidArgument,
                         "RR sender_ssrc mismatch");
  }
  rtt_ms_ = report.rtt_ms;
  if (backend_) {
    return backend_->OnRtcpReceiverReport(report);
  }
  return Status::Ok();
}

Status SenderQosController::OnSenderRateCap(const SenderRateCap& cap) {
  if (cap.cap_bps == 0) {
    return Status::Error(StatusCode::kInvalidArgument,
                         "cap_bps=0 is reserved in Phase-1a");
  }
  rate_cap_bps_ = cap.cap_bps;
  if (cap.expire_ms == 0 || cap.cap_bps == kUnlimitedRateCapBps) {
    rate_cap_expire_time_us_ = 0;
  } else {
    rate_cap_expire_time_us_ =
        cap.receive_time_us + static_cast<int64_t>(cap.expire_ms) * 1000;
  }
  return Status::Ok();
}

TargetRates SenderQosController::GetTargetRates(int64_t now_us) const {
  uint32_t effective_cap = rate_cap_bps_;
  if (rate_cap_expire_time_us_ > 0 && now_us >= rate_cap_expire_time_us_) {
    effective_cap = kUnlimitedRateCapBps;
  }
  const uint32_t final_target =
      effective_cap == kUnlimitedRateCapBps
          ? estimate_bps_
          : std::min(estimate_bps_, effective_cap);
  return TargetRates{estimate_bps_, effective_cap, final_target, rtt_ms_,
                     loss_fraction_};
}

}  // namespace webrtc_qos
