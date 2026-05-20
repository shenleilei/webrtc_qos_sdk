#include "webrtc_qos/sender_qos_controller.h"

#include <algorithm>
#include <utility>

namespace webrtc_qos {

SenderQosController::SenderQosController(SenderQosControllerConfig config)
    : config_(config),
      estimate_bps_(config.start_bitrate_bps),
      pacing_bps_(config.start_bitrate_bps) {}

SenderQosController::SenderQosController(
    SenderQosControllerConfig config,
    std::unique_ptr<SenderQosBackend> backend)
    : config_(config),
      estimate_bps_(config.start_bitrate_bps),
      pacing_bps_(config.start_bitrate_bps),
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

Status SenderQosController::OnProbePacketSent(
    uint16_t transport_sequence_number,
    size_t packet_size,
    int64_t send_time_us,
    const ProbeCluster& probe_cluster) {
  sent_packets_[transport_sequence_number] =
      PacketFeedback{transport_sequence_number, send_time_us, -1, packet_size};
  if (backend_) {
    return backend_->OnProbePacketSent(transport_sequence_number, packet_size,
                                       send_time_us, probe_cluster);
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
    pacing_bps_ = std::max(config_.min_bitrate_bps,
                           std::min(config_.max_bitrate_bps * 2,
                                    backend_->pacing_bitrate_bps()));
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
    if (!has_loss_sample_) {
      smoothed_loss_fraction_ = loss_fraction_;
      has_loss_sample_ = true;
    } else {
      constexpr double kLossRiseEwmaWeight = 0.35;
      constexpr double kLossFallEwmaWeight = 0.55;
      const double loss_weight =
          loss_fraction_ > smoothed_loss_fraction_ ? kLossRiseEwmaWeight
                                                   : kLossFallEwmaWeight;
      smoothed_loss_fraction_ =
          smoothed_loss_fraction_ * (1.0 - loss_weight) +
          loss_fraction_ * loss_weight;
    }
  }

  if (backend_) {
    return Status::Ok();
  }

  uint32_t recv_bps = 0;
  const bool has_recv_rate =
      acked_bytes > 0 && first_recv_us >= 0 && last_recv_us > first_recv_us;
  if (has_recv_rate) {
    const double seconds = (last_recv_us - first_recv_us) / 1000000.0;
    recv_bps =
        static_cast<uint32_t>((acked_bytes * 8) / std::max(seconds, 0.001));
  }

  if (loss_fraction_ >= 0.30) {
    estimate_bps_ = static_cast<uint32_t>(estimate_bps_ * 0.50);
  } else if (loss_fraction_ >= 0.15) {
    estimate_bps_ = static_cast<uint32_t>(estimate_bps_ * 0.70);
  } else if (loss_fraction_ >= 0.05) {
    estimate_bps_ = static_cast<uint32_t>(estimate_bps_ * 0.85);
  } else if (has_recv_rate) {
    double recv_weight = recv_bps >= estimate_bps_ ? 0.30 : 0.35;
    if (recv_bps < estimate_bps_ / 4) {
      recv_weight = 0.70;
    } else if (recv_bps < estimate_bps_ / 2) {
      recv_weight = 0.55;
    }
    const double keep_weight = 1.0 - recv_weight;
    estimate_bps_ = static_cast<uint32_t>(
        estimate_bps_ * keep_weight + recv_bps * recv_weight);
  } else if (loss_fraction_ < 0.02) {
    estimate_bps_ = static_cast<uint32_t>(estimate_bps_ * 1.05);
  }
  estimate_bps_ =
      std::max(config_.min_bitrate_bps,
               std::min(config_.max_bitrate_bps, estimate_bps_));
  pacing_bps_ = estimate_bps_;
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

Status SenderQosController::OnProcessInterval(int64_t at_time_us) {
  if (!backend_) {
    return Status::Ok();
  }
  Status status = backend_->OnProcessInterval(at_time_us);
  if (!status) {
    return status;
  }
  estimate_bps_ = std::max(config_.min_bitrate_bps,
                           std::min(config_.max_bitrate_bps,
                                    backend_->target_bitrate_bps()));
  pacing_bps_ = std::max(config_.min_bitrate_bps,
                         std::min(config_.max_bitrate_bps * 2,
                                  backend_->pacing_bitrate_bps()));
  return Status::Ok();
}

Status SenderQosController::OnNetworkRouteChange(uint32_t start_bitrate_bps,
                                                 int64_t at_time_us) {
  estimate_bps_ = std::max(config_.min_bitrate_bps,
                           std::min(config_.max_bitrate_bps,
                                    start_bitrate_bps));
  pacing_bps_ = estimate_bps_;
  sent_packets_.clear();
  smoothed_loss_fraction_ = 0.0;
  has_loss_sample_ = false;
  if (!backend_) {
    return Status::Ok();
  }
  Status status = backend_->OnNetworkRouteChange(
      estimate_bps_, config_.min_bitrate_bps, config_.max_bitrate_bps,
      at_time_us);
  if (!status) {
    return status;
  }
  estimate_bps_ = std::max(config_.min_bitrate_bps,
                           std::min(config_.max_bitrate_bps,
                                    backend_->target_bitrate_bps()));
  pacing_bps_ = std::max(config_.min_bitrate_bps,
                         std::min(config_.max_bitrate_bps * 2,
                                  backend_->pacing_bitrate_bps()));
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

std::vector<ProbeCluster> SenderQosController::TakeProbeClusters() {
  if (!backend_) {
    return {};
  }
  return backend_->TakeProbeClusters();
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
  const uint32_t final_pacing =
      effective_cap == kUnlimitedRateCapBps
          ? pacing_bps_
          : std::min(pacing_bps_, effective_cap);
  return TargetRates{estimate_bps_, final_pacing, effective_cap, final_target,
                     rtt_ms_, loss_fraction_};
}

EncoderAdaptation SenderQosController::GetEncoderAdaptation(
    int64_t now_us) const {
  const TargetRates rates = GetTargetRates(now_us);
  EncoderAdaptation adaptation;
  adaptation.target_bitrate_bps = rates.final_target_bps;
  const double effective_loss =
      has_loss_sample_ ? smoothed_loss_fraction_ : rates.loss_fraction;
  const bool severe_capacity = rates.final_target_bps < 150000;
  const bool severe_rtt = rates.rtt_ms >= 800;
  const bool very_constrained_capacity = rates.final_target_bps < 180000;
  const bool catastrophic_loss = effective_loss >= 0.45;
  const bool constrained_capacity = rates.final_target_bps < 300000;
  const bool high_rtt = rates.rtt_ms >= 400;
  const bool high_loss = effective_loss >= 0.08;
  const bool moderate_capacity = rates.final_target_bps < 800000;
  const bool moderate_rtt = rates.rtt_ms >= 250;
  const bool moderate_loss = effective_loss >= 0.03;

  if (severe_capacity || severe_rtt ||
      (very_constrained_capacity && (rates.rtt_ms >= 500 ||
                                     catastrophic_loss))) {
    adaptation.max_fps = 5;
  } else if (constrained_capacity || high_rtt || high_loss) {
    adaptation.max_fps = 10;
  } else if (moderate_capacity || moderate_rtt || moderate_loss) {
    adaptation.max_fps = 15;
  } else {
    adaptation.max_fps = 30;
  }
  adaptation.request_keyframe =
      rates.rtt_ms >= 500 || effective_loss >= 0.15;
  return adaptation;
}

}  // namespace webrtc_qos
