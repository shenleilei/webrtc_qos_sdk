#include "webrtc_qos/video_push_client.h"

#include <algorithm>
#include <cstdint>
#include <memory>
#include <unordered_map>
#include <utility>
#include <vector>

#include "compound_rtcp.h"
#include "webrtc_qos/googcc_adapter.h"
#include "webrtc_qos/h264_rtp_adapter.h"
#include "webrtc_qos/pacing_adapter.h"
#include "webrtc_qos/rtcp_adapter.h"
#include "webrtc_qos/rtp_packet_adapter.h"
#include "webrtc_qos/transport_packet_history.h"

namespace webrtc_qos {
namespace {

constexpr uint32_t kNtpUnixEpochOffsetSeconds = 2208988800u;
constexpr uint32_t kPacingMultiplierNumerator = 5;
constexpr uint32_t kPacingMultiplierDenominator = 2;
constexpr uint32_t kMaxPacingQueueBytes = 2 * 1024 * 1024;
constexpr uint32_t kMaxPacingQueueTimeMs = 1500;
constexpr uint32_t kSenderPacketHistoryHopId = 0;
constexpr int64_t kSentPacketStateMinHoldUs = 5 * 1000 * 1000;
constexpr uint32_t kSenderHistoryHoldMs = 3000;
constexpr uint32_t kSenderHistoryMaxHoldMs = 10000;

Status InvalidArgument(const char* message) {
  return Status::Error(StatusCode::kInvalidArgument, message);
}

Status InternalError(const char* message) {
  return Status::Error(StatusCode::kInternalError, message);
}

bool SequenceNumberAtOrAfter(uint16_t lhs, uint16_t rhs) {
  return static_cast<int16_t>(lhs - rhs) >= 0;
}

class WebRtcVideoPushClient final : public VideoPushClient {
 public:
  explicit WebRtcVideoPushClient(VideoPushClientConfig config)
      : config_(std::move(config)),
        googcc_(GoogCcAdapterConfig{config_.session.start_bitrate_bps,
                                    config_.session.min_bitrate_bps,
                                    config_.session.max_bitrate_bps}),
        pacer_(std::make_unique<PacingAdapter>(
            PacingAdapterConfig{config_.session.start_bitrate_bps, 0,
                                kMaxPacingQueueBytes,
                                kMaxPacingQueueTimeMs,
                                config_.session.twcc.extension_id})),
        packet_history_(TransportPacketHistoryConfig{kSenderHistoryHoldMs,
                                                     kSenderHistoryMaxHoldMs,
                                                     4096}),
        sender_rate_cap_(UnlimitedSenderRateCap(config_.session.ids, 0, 0)) {}

  Status Start() override {
    if (!config_.transport_output) {
      return InvalidArgument("VideoPushClient requires transport_output");
    }
    started_ = true;
    googcc_.OnNetworkAvailable(0);
    googcc_.OnNetworkRouteChange(config_.session.start_bitrate_bps,
                                 config_.session.min_bitrate_bps,
                                 config_.session.max_bitrate_bps, 0);
    pacer_->Process(0);
    ApplyProbeClusters();
    ApplyGoogCcRates(0);
    return Status::Ok();
  }

  Status Stop() override {
    started_ = false;
    return Status::Ok();
  }

  Status Process(int64_t now_us) override {
    if (!started_) {
      return Status::Error(StatusCode::kUnsupported,
                           "VideoPushClient is not started");
    }
    PruneState(now_us);
    Status drain_status = DrainPacer(now_us);
    if (!drain_status) {
      return drain_status;
    }
    googcc_.OnProcessInterval(now_us);
    ApplyProbeClusters();
    ApplyGoogCcRates(now_us);
    return MaybeSendSenderReport(now_us);
  }

  Status PushAnnexBAccessUnit(const AnnexBAccessUnitView& access_unit) override {
    if (!started_) {
      return Status::Error(StatusCode::kUnsupported,
                           "VideoPushClient is not started");
    }
    if (access_unit.bytes == nullptr || access_unit.size == 0) {
      return InvalidArgument("empty Annex-B access unit");
    }

    std::vector<H264RtpPayload> payloads;
    if (!PacketizeH264AnnexB(access_unit.bytes, access_unit.size,
                             H264RtpPacketizerConfig{
                                 config_.session.h264.max_rtp_payload_bytes},
                             &payloads)) {
      return Status::Error(StatusCode::kMalformedPacket,
                           "failed to packetize H264 Annex-B AU");
    }

    struct PendingPacket {
      uint16_t transport_sequence_number = 0;
      int64_t capture_time_us = 0;
      PacingAdapterPacket packet;
    };
    std::vector<PendingPacket> pending_packets;
    pending_packets.reserve(payloads.size());
    size_t access_unit_bytes = 0;

    uint16_t rtp_sequence_number = next_rtp_sequence_number_;
    uint16_t transport_sequence_number = next_transport_sequence_number_;
    for (const auto& payload : payloads) {
      std::vector<uint8_t> rtp_bytes;
      RtpPacketAdapterBuildInput rtp_input;
      rtp_input.payload_type = config_.session.h264.payload_type;
      rtp_input.marker = payload.marker;
      rtp_input.sequence_number = rtp_sequence_number++;
      rtp_input.timestamp = RtpTimestamp(access_unit.capture_time_us);
      rtp_input.ssrc = config_.session.ids.sender_ssrc;
      rtp_input.transport_sequence_number = transport_sequence_number++;
      rtp_input.payload = payload.payload.data();
      rtp_input.payload_size = payload.payload.size();
      if (!BuildRtpPacket(rtp_input, RtpConfig(), &rtp_bytes)) {
        return InternalError("failed to build RTP packet");
      }

      PacingAdapterPacket pacing_packet;
      pacing_packet.ssrc = config_.session.ids.sender_ssrc;
      pacing_packet.rtp_sequence_number = rtp_input.sequence_number;
      pacing_packet.transport_sequence_number =
          *rtp_input.transport_sequence_number;
      pacing_packet.enqueue_time_us = access_unit.capture_time_us;
      pacing_packet.keyframe = payload.keyframe || access_unit.keyframe;
      pacing_packet.bytes = std::move(rtp_bytes);
      access_unit_bytes += pacing_packet.bytes.size();
      pending_packets.push_back(PendingPacket{
          *rtp_input.transport_sequence_number, access_unit.capture_time_us,
          std::move(pacing_packet)});
    }

    const auto pacer_stats = pacer_->stats();
    if (pacer_stats.queue_bytes + access_unit_bytes > kMaxPacingQueueBytes) {
      ++snapshot_.dropped_frames;
      return Status::Error(StatusCode::kQueueFull,
                           "WebRTC pacing adapter queue bytes would overflow");
    }

    for (auto& pending : pending_packets) {
      if (!pacer_->EnqueuePacket(pending.packet)) {
        ResetPacerQueue(pending.capture_time_us);
        ++snapshot_.dropped_frames;
        return Status::Error(StatusCode::kQueueFull,
                             "WebRTC pacing adapter rejected RTP packet");
      }
    }
    next_rtp_sequence_number_ = rtp_sequence_number;
    next_transport_sequence_number_ = transport_sequence_number;
    if (access_unit.keyframe) {
      keyframe_request_pending_ = false;
    }

    return Status::Ok();
  }

  Status OnTransportFeedback(const uint8_t* rtcp_bytes,
                             size_t rtcp_size,
                             int64_t receive_time_us) override {
    PruneState(receive_time_us);
    return ForEachSupportedRtcpPacket(
        rtcp_bytes, rtcp_size,
        [&](const uint8_t* packet_bytes, size_t packet_size,
            const RtcpAdapterParsedPacket& parsed) -> Status {
          if (parsed.type == RtcpAdapterPacketType::kTransportFeedback) {
            std::vector<GoogCcPacketFeedback> feedback;
            feedback.reserve(parsed.transport_feedback.packets.size());
            for (const auto& packet : parsed.transport_feedback.packets) {
              auto sent = sent_packets_.find(packet.sequence_number);
              if (sent == sent_packets_.end()) {
                continue;
              }
              GoogCcPacketFeedback item;
              item.transport_sequence_number = packet.sequence_number;
              item.send_time_us = sent->second.send_time_us;
              item.packet_size_bytes = sent->second.packet_size_bytes;
              if (packet.delta_since_base_us >= 0) {
                item.receive_time_us =
                    parsed.transport_feedback.base_time_us +
                    packet.delta_since_base_us;
              }
              feedback.push_back(item);
            }
            if (!feedback.empty()) {
              googcc_.OnTransportFeedback(feedback, receive_time_us);
              googcc_.OnProcessInterval(receive_time_us);
              ApplyProbeClusters();
              ApplyGoogCcRates(receive_time_us);
            }
            for (const auto& packet : parsed.transport_feedback.packets) {
              if (packet.delta_since_base_us >= 0) {
                sent_packets_.erase(packet.sequence_number);
              }
            }
            return Status::Ok();
          }
          if (parsed.type == RtcpAdapterPacketType::kReceiverReport) {
            for (const auto& block : parsed.receiver_report.report_blocks) {
              if (block.media_ssrc != config_.session.ids.sender_ssrc) {
                continue;
              }
              const uint32_t rtt_ms = EstimateRttMsFromReceiverReport(
                  block.last_sr, block.delay_since_last_sr, receive_time_us);
              if (rtt_ms > 0) {
                latest_rtt_ms_ = rtt_ms;
                googcc_.OnRoundTripTime(rtt_ms, receive_time_us);
                googcc_.OnProcessInterval(receive_time_us);
                ApplyProbeClusters();
                ApplyGoogCcRates(receive_time_us);
              }
            }
            return Status::Ok();
          }
          if (parsed.type == RtcpAdapterPacketType::kNack) {
            return HandleNack(parsed.nack, receive_time_us);
          }
          if (parsed.type == RtcpAdapterPacketType::kPli) {
            (void)packet_bytes;
            (void)packet_size;
            ++snapshot_.pli_count;
            keyframe_request_pending_ = true;
            return Status::Ok();
          }
          return Status::Ok();
        });
  }

  Status OnSenderRateCap(const SenderRateCap& cap) override {
    const uint32_t old_final_target_bps = FinalTargetBps(cap.receive_time_us);
    sender_rate_cap_ = cap;
    const uint32_t new_final_target_bps = FinalTargetBps(cap.receive_time_us);
    if (new_final_target_bps < old_final_target_bps) {
      ResetPacerQueue(cap.receive_time_us);
    }
    ApplyGoogCcRates(cap.receive_time_us);
    return Status::Ok();
  }

  Status OnNetworkRouteChange(uint32_t start_bitrate_bps,
                              uint32_t min_bitrate_bps,
                              uint32_t max_bitrate_bps,
                              int64_t at_time_us) override {
    const uint32_t old_final_target_bps = FinalTargetBps(at_time_us);
    config_.session.start_bitrate_bps = start_bitrate_bps;
    config_.session.min_bitrate_bps = min_bitrate_bps;
    config_.session.max_bitrate_bps = max_bitrate_bps;
    googcc_.OnNetworkRouteChange(start_bitrate_bps, min_bitrate_bps,
                                 max_bitrate_bps, at_time_us);
    const uint32_t new_final_target_bps = FinalTargetBps(at_time_us);
    if (new_final_target_bps < old_final_target_bps) {
      ResetPacerQueue(at_time_us);
    }
    ApplyProbeClusters();
    ApplyGoogCcRates(at_time_us);
    return Status::Ok();
  }

  EncoderAdaptation GetEncoderAdaptation(int64_t now_us) const override {
    (void)now_us;
    EncoderAdaptation out;
    out.target_bitrate_bps = FinalTargetBps(now_us);
    out.max_fps = SuggestedMaxFps(out.target_bitrate_bps);
    out.request_keyframe = keyframe_request_pending_;
    return out;
  }

  QosSnapshot GetQosSnapshot(int64_t now_us) const override {
    QosSnapshot out = snapshot_;
    out.ids = config_.session.ids;
    out.report_time_us = static_cast<uint64_t>(std::max<int64_t>(0, now_us));
    out.sender_rates.googcc_target_bps = googcc_.rates().target_bitrate_bps;
    out.sender_rates.sender_rate_cap_bps = EffectiveSenderRateCapBps(now_us);
    out.sender_rates.final_target_bps = FinalTargetBps(now_us);
    out.sender_rates.pacing_bps = pacer_->stats().pacing_bitrate_bps;
    out.sender_rates.rtt_ms = latest_rtt_ms_;
    out.jitter_buffer_delay_ms = pacer_->stats().expected_queue_time_ms;
    out.dropped_frames = snapshot_.dropped_frames;
    out.emitted_padding_packets = pacer_->stats().emitted_padding_packets;
    out.emitted_padding_bytes = pacer_->stats().emitted_padding_bytes;
    return out;
  }

 private:
  RtpPacketAdapterConfig RtpConfig() const {
    RtpPacketAdapterConfig config;
    config.payload_type = config_.session.h264.payload_type;
    config.transport_sequence_extension_id = config_.session.twcc.extension_id;
    config.enable_transport_sequence_extension = true;
    return config;
  }

  uint32_t RtpTimestamp(int64_t capture_time_us) {
    if (first_capture_time_us_ < 0) {
      first_capture_time_us_ = capture_time_us;
    }
    const int64_t delta_us =
        std::max<int64_t>(0, capture_time_us - first_capture_time_us_);
    return first_rtp_timestamp_ +
           static_cast<uint32_t>((delta_us * kVideoClockRateHz) / 1000000);
  }

  Status DrainPacer(int64_t now_us) {
    std::vector<PacingAdapterPacket> emitted;
    for (int i = 0; i < 200; ++i) {
      auto batch = pacer_->Process(now_us);
      if (batch.empty()) {
        break;
      }
      emitted.insert(emitted.end(), std::make_move_iterator(batch.begin()),
                     std::make_move_iterator(batch.end()));
    }

    for (const auto& packet : emitted) {
      Status status = EmitPacketNow(packet, now_us);
      if (!status) {
        return status;
      }
    }
    if (!emitted.empty()) {
      googcc_.OnProcessInterval(now_us);
      ApplyGoogCcRates(now_us);
      Status sr_status = MaybeSendSenderReport(now_us);
      if (!sr_status) {
        return sr_status;
      }
    }
    return Status::Ok();
  }

  uint32_t EffectiveSenderRateCapBps(int64_t now_us) const {
    if (IsUnlimitedRateCap(sender_rate_cap_)) {
      return kUnlimitedRateCapBps;
    }
    if (sender_rate_cap_.expire_ms != 0 &&
        now_us - sender_rate_cap_.receive_time_us >
            static_cast<int64_t>(sender_rate_cap_.expire_ms) * 1000) {
      return kUnlimitedRateCapBps;
    }
    return std::max<uint32_t>(config_.session.min_bitrate_bps,
                              sender_rate_cap_.cap_bps);
  }

  uint32_t FinalTargetBps(int64_t now_us) const {
    const uint32_t googcc_target =
        std::max<uint32_t>(config_.session.min_bitrate_bps,
                           googcc_.rates().target_bitrate_bps);
    const uint32_t sender_rate_cap_bps = EffectiveSenderRateCapBps(now_us);
    if (sender_rate_cap_bps == kUnlimitedRateCapBps) {
      return googcc_target;
    }
    return std::min<uint32_t>(
        googcc_target, sender_rate_cap_bps);
  }

  uint32_t SuggestedMaxFps(uint32_t target_bps) const {
    const uint32_t max_fps = std::max<uint16_t>(1, config_.session.h264.max_fps);
    if (target_bps <= config_.session.min_bitrate_bps) {
      return std::min<uint32_t>(max_fps, 5);
    }
    if (target_bps <= config_.session.start_bitrate_bps / 2) {
      return std::min<uint32_t>(max_fps, 10);
    }
    if (target_bps <= (config_.session.start_bitrate_bps * 3) / 4) {
      return std::min<uint32_t>(max_fps, 15);
    }
    return max_fps;
  }

  void ApplyGoogCcRates(int64_t now_us) {
    pacer_->SetRates(EffectivePacingBps(now_us), 0);
  }

  void ApplyProbeClusters() {
    for (const auto& probe : googcc_.TakeProbeClusters()) {
      if (probe.id < 0 || probe.target_bitrate_bps == 0) {
        continue;
      }
      PacingAdapterProbeCluster pacing_probe;
      pacing_probe.id = probe.id;
      pacing_probe.target_bitrate_bps = probe.target_bitrate_bps;
      pacing_probe.min_probe_count = probe.min_probe_count;
      pacing_probe.min_probe_bytes = probe.min_probe_bytes;
      pacing_probe.target_duration_us = probe.target_duration_us;
      pacing_probe.min_probe_delta_us = probe.min_probe_delta_us;
      pacer_->SetProbeCluster(pacing_probe);
      active_probe_clusters_[probe.id] = probe;
    }
  }

  void ResetPacerQueue(int64_t now_us) {
    keyframe_request_pending_ = true;
    pacer_ = std::make_unique<PacingAdapter>(
        PacingAdapterConfig{EffectivePacingBps(now_us), 0,
                            kMaxPacingQueueBytes,
                            kMaxPacingQueueTimeMs,
                            config_.session.twcc.extension_id});
    if (now_us >= 0) {
      pacer_->Process(now_us);
    }
    active_probe_clusters_.clear();
  }

  uint32_t EffectivePacingBps(int64_t now_us) const {
    const uint32_t final_target_bps = FinalTargetBps(now_us);
    const uint64_t min_pacing_bps =
        (static_cast<uint64_t>(final_target_bps) * kPacingMultiplierNumerator) /
        kPacingMultiplierDenominator;
    uint32_t pacing_bps = googcc_.rates().pacing_bitrate_bps;
    if (pacing_bps == 0) {
      pacing_bps = static_cast<uint32_t>(
          std::min<uint64_t>(min_pacing_bps, config_.session.max_bitrate_bps));
    }
    pacing_bps = std::max<uint32_t>(
        pacing_bps,
        static_cast<uint32_t>(
            std::min<uint64_t>(min_pacing_bps, config_.session.max_bitrate_bps)));
    const uint32_t sender_rate_cap_bps = EffectiveSenderRateCapBps(now_us);
    if (sender_rate_cap_bps != kUnlimitedRateCapBps) {
      const uint64_t capped_pacing_bps =
          (static_cast<uint64_t>(sender_rate_cap_bps) *
           kPacingMultiplierNumerator) /
          kPacingMultiplierDenominator;
      pacing_bps = std::min<uint32_t>(
          pacing_bps,
          static_cast<uint32_t>(
              std::min<uint64_t>(capped_pacing_bps,
                                 config_.session.max_bitrate_bps)));
    }
    return std::max<uint32_t>(config_.session.min_bitrate_bps, pacing_bps);
  }

  static uint32_t EstimateRttMsFromReceiverReport(uint32_t last_sr,
                                                  uint32_t delay_since_last_sr,
                                                  int64_t receive_time_us) {
    if (last_sr == 0) {
      return 0;
    }
    const uint32_t seconds =
        kNtpUnixEpochOffsetSeconds +
        static_cast<uint32_t>(receive_time_us / 1000000);
    const uint32_t fractions = static_cast<uint32_t>(
        ((static_cast<uint64_t>(receive_time_us % 1000000) << 32) /
         1000000));
    const uint32_t now_ntp_middle_32 =
        ((seconds & 0x0000ffffu) << 16) | (fractions >> 16);
    const uint32_t delay_ntp = delay_since_last_sr;
    const uint32_t rtt_ntp = now_ntp_middle_32 - last_sr - delay_ntp;
    return static_cast<uint32_t>((static_cast<uint64_t>(rtt_ntp) * 1000) /
                                 65536);
  }

  Status MaybeSendSenderReport(int64_t now_us) {
    const int64_t interval_us =
        static_cast<int64_t>(config_.session.rtcp.sr_rr_interval_ms) * 1000;
    if (last_sr_send_time_us_ >= 0 &&
        now_us - last_sr_send_time_us_ < interval_us) {
      return Status::Ok();
    }

    RtcpAdapterSenderReport sr;
    sr.sender_ssrc = config_.session.ids.sender_ssrc;
    sr.ntp_seconds =
        kNtpUnixEpochOffsetSeconds + static_cast<uint32_t>(now_us / 1000000);
    sr.ntp_fractions = static_cast<uint32_t>(
        ((static_cast<uint64_t>(now_us % 1000000) << 32) / 1000000));
    sr.rtp_timestamp = RtpTimestamp(now_us);
    sr.packet_count = sent_rtp_packet_count_;
    sr.octet_count = sent_rtp_octet_count_;

    std::vector<uint8_t> rtcp_bytes;
    if (!BuildRtcpSenderReport(sr, &rtcp_bytes)) {
      return Status::Error(StatusCode::kInternalError,
                           "failed to build RTCP SR");
    }
    TransportPacketView view;
    view.bytes = rtcp_bytes.data();
    view.size = rtcp_bytes.size();
    view.metadata.ids = config_.session.ids;
    view.metadata.kind = TransportPacketKind::kRtcp;
    view.metadata.send_time_us = now_us;
    Status status = config_.transport_output(view);
    if (!status) {
      return status;
    }
    last_sr_send_time_us_ = now_us;
    return Status::Ok();
  }

  struct SentPacketInfo {
    int64_t send_time_us = 0;
    uint32_t packet_size_bytes = 0;
  };

  Status EnqueueRetransmission(const PacingAdapterPacket& packet) {
    const auto pacer_stats = pacer_->stats();
    if (pacer_stats.queue_bytes + packet.bytes.size() > kMaxPacingQueueBytes) {
      ++snapshot_.dropped_retransmission_packets;
      return Status::Ok();
    }
    if (!pacer_->EnqueuePacket(packet)) {
      ++snapshot_.dropped_retransmission_packets;
    }
    return Status::Ok();
  }

  Status HandleNack(const RtcpAdapterNack& nack, int64_t receive_time_us) {
    for (uint16_t packet_id : nack.packet_ids) {
      auto found = packet_history_.Find(TransportPacketHistoryKey{
          kSenderPacketHistoryHopId, config_.session.ids.sender_ssrc,
          packet_id});
      if (!found.has_value()) {
        continue;
      }
      RtpPacketAdapterParsedPacket parsed;
      if (!ParseRtpPacket(found->rtp_bytes.data(), found->rtp_bytes.size(),
                          RtpConfig(), &parsed)) {
        continue;
      }
      std::vector<uint8_t> rebuilt_bytes;
      RtpPacketAdapterBuildInput rtp_input;
      rtp_input.payload_type = parsed.payload_type;
      rtp_input.marker = parsed.marker;
      rtp_input.sequence_number = parsed.sequence_number;
      rtp_input.timestamp = parsed.timestamp;
      rtp_input.ssrc = parsed.ssrc;
      rtp_input.transport_sequence_number = next_transport_sequence_number_++;
      rtp_input.payload = parsed.payload.data();
      rtp_input.payload_size = parsed.payload.size();
      if (!BuildRtpPacket(rtp_input, RtpConfig(), &rebuilt_bytes)) {
        return InternalError("failed to rebuild retransmission RTP packet");
      }
      PacingAdapterPacket packet;
      packet.ssrc = parsed.ssrc;
      packet.rtp_sequence_number = parsed.sequence_number;
      packet.transport_sequence_number = *rtp_input.transport_sequence_number;
      packet.enqueue_time_us = receive_time_us;
      packet.retransmission = true;
      packet.bytes = std::move(rebuilt_bytes);
      Status status = EnqueueRetransmission(packet);
      if (!status) {
        return status;
      }
    }
    return Status::Ok();
  }

  Status EmitPacketNow(const PacingAdapterPacket& packet, int64_t now_us) {
    TransportPacketView view;
    view.bytes = packet.bytes.data();
    view.size = packet.bytes.size();
    view.metadata.ids = config_.session.ids;
    view.metadata.kind = TransportPacketKind::kRtp;
    view.metadata.send_time_us = now_us;
    view.metadata.retransmission = packet.retransmission;
    view.metadata.padding = packet.padding;
    Status status = config_.transport_output(view);
    if (!status) {
      return status;
    }
    if (packet.transport_sequence_number >= 0) {
      const auto transport_sequence_number =
          static_cast<uint16_t>(packet.transport_sequence_number);
      sent_packets_[transport_sequence_number] =
          SentPacketInfo{now_us, static_cast<uint32_t>(packet.bytes.size())};
      if (packet.probe_cluster_id >= 0) {
        GoogCcProbeCluster cluster;
        const auto cluster_it = active_probe_clusters_.find(
            static_cast<int32_t>(packet.probe_cluster_id));
        if (cluster_it != active_probe_clusters_.end()) {
          cluster = cluster_it->second;
        }
        googcc_.OnProbePacketSent(
            transport_sequence_number,
            static_cast<uint32_t>(packet.bytes.size()), now_us, cluster);
        ++snapshot_.emitted_probe_packets;
        snapshot_.emitted_probe_bytes += packet.bytes.size();
        snapshot_.last_probe_cluster_id = packet.probe_cluster_id;
      } else {
        googcc_.OnSentPacket(transport_sequence_number,
                             static_cast<uint32_t>(packet.bytes.size()),
                             now_us);
      }
    }
    if (packet.padding) {
      const uint16_t next_rtp_sequence_number =
          static_cast<uint16_t>(packet.rtp_sequence_number + 1);
      if (SequenceNumberAtOrAfter(next_rtp_sequence_number,
                                  next_rtp_sequence_number_)) {
        next_rtp_sequence_number_ = next_rtp_sequence_number;
      }
    }
    if (packet.transport_sequence_number >= 0) {
      if (packet.padding) {
        const uint16_t next_transport_sequence_number =
            static_cast<uint16_t>(packet.transport_sequence_number + 1);
        if (SequenceNumberAtOrAfter(next_transport_sequence_number,
                                    next_transport_sequence_number_)) {
          next_transport_sequence_number_ = next_transport_sequence_number;
        }
      }
    }
    if (!packet.padding && !packet.retransmission) {
      ++sent_rtp_packet_count_;
      sent_rtp_octet_count_ += packet.bytes.size();
      packet_history_.Store(
          TransportPacketHistoryKey{kSenderPacketHistoryHopId,
                                    config_.session.ids.sender_ssrc,
                                    packet.rtp_sequence_number},
          packet.bytes.data(), packet.bytes.size(), now_us, false);
    } else if (!packet.padding && packet.retransmission) {
      ++snapshot_.retransmission_count;
    }
    return Status::Ok();
  }

  void PruneState(int64_t now_us) {
    packet_history_.Prune(now_us, latest_rtt_ms_);
    const int64_t hold_us = std::max<int64_t>(
        kSentPacketStateMinHoldUs,
        static_cast<int64_t>(std::max<uint32_t>(latest_rtt_ms_, 1u)) * 3000);
    for (auto it = sent_packets_.begin(); it != sent_packets_.end();) {
      if (now_us - it->second.send_time_us > hold_us) {
        it = sent_packets_.erase(it);
      } else {
        ++it;
      }
    }
  }

  VideoPushClientConfig config_;
  GoogCcAdapter googcc_;
  std::unique_ptr<PacingAdapter> pacer_;
  TransportPacketHistory packet_history_;
  QosSnapshot snapshot_;
  std::unordered_map<uint16_t, SentPacketInfo> sent_packets_;
  std::unordered_map<int32_t, GoogCcProbeCluster> active_probe_clusters_;
  bool started_ = false;
  uint16_t next_rtp_sequence_number_ = 1;
  uint16_t next_transport_sequence_number_ = 1;
  uint32_t first_rtp_timestamp_ = 90000;
  int64_t first_capture_time_us_ = -1;
  SenderRateCap sender_rate_cap_;
  uint32_t latest_rtt_ms_ = 0;
  bool keyframe_request_pending_ = false;
  uint32_t sent_rtp_packet_count_ = 0;
  uint32_t sent_rtp_octet_count_ = 0;
  int64_t last_sr_send_time_us_ = -1;
};

}  // namespace

std::unique_ptr<VideoPushClient> CreateVideoPushClient(
    const VideoPushClientConfig& config) {
  return std::make_unique<WebRtcVideoPushClient>(config);
}

}  // namespace webrtc_qos
