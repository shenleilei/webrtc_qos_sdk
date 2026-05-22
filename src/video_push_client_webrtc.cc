#include "webrtc_qos/video_push_client.h"

#include <algorithm>
#include <cstdint>
#include <memory>
#include <unordered_map>
#include <utility>
#include <vector>

#include "compound_rtcp.h"
#include "runtime_alert_writer.h"
#include "runtime_logger.h"
#include "runtime_metrics_writer.h"
#include "video_track_config_utils.h"
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

bool IsMalformedInputStatus(const Status& status) {
  return status.code == StatusCode::kInvalidArgument ||
         status.code == StatusCode::kMalformedPacket;
}

bool SequenceNumberAtOrAfter(uint16_t lhs, uint16_t rhs) {
  return static_cast<int16_t>(lhs - rhs) >= 0;
}

class WebRtcVideoPushClient final : public VideoPushClient {
 public:
  explicit WebRtcVideoPushClient(VideoPushClientConfig config)
      : config_(std::move(config)),
        logger_(config_.logging, "push"),
        metrics_writer_(config_.metrics, "push"),
        alert_writer_(config_.alerts, "push"),
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
        sender_rate_cap_(UnlimitedSenderRateCap(config_.session.ids, 0, 0)) {
    track_config_status_ =
        ResolveVideoTrackConfigs(config_.session, &track_configs_);
    primary_track_id_ = PrimaryTrackId(track_configs_);
    if (track_config_status_) {
      for (const auto& track_config : track_configs_) {
        TrackState track_state;
        track_state.config = track_config;
        track_state.snapshot.ids = track_config.ids;
        track_states_.emplace(track_config.ids.track_id, std::move(track_state));
        sender_ssrc_to_track_id_[track_config.ids.sender_ssrc] =
            track_config.ids.track_id;
      }
    }
  }

  Status Start() override {
    if (!config_.transport_output) {
      Status status = InvalidArgument("VideoPushClient requires transport_output");
      logger_.Error("start_failed", config_.session.ids, status);
      return status;
    }
    if (!track_config_status_) {
      logger_.Error("start_failed", config_.session.ids, track_config_status_);
      return track_config_status_;
    }
    started_ = true;
    googcc_.OnNetworkAvailable(0);
    googcc_.OnNetworkRouteChange(config_.session.start_bitrate_bps,
                                 config_.session.min_bitrate_bps,
                                 config_.session.max_bitrate_bps, 0);
    pacer_->Process(0);
    ApplyProbeClusters();
    ApplyGoogCcRates(0);
    logger_.Info("config_dump", config_.session.ids,
                 RuntimeConfigDumpFields(config_.session, config_.logging,
                                         config_.metrics, config_.alerts,
                                         track_configs_.size()));
    logger_.Info("start", config_.session.ids);
    return Status::Ok();
  }

  Status Stop() override {
    started_ = false;
    logger_.Info("stop", config_.session.ids);
    logger_.Flush();
    metrics_writer_.Flush();
    alert_writer_.Flush();
    return Status::Ok();
  }

  Status Process(int64_t now_us) override {
    if (!started_) {
      Status status = Status::Error(StatusCode::kUnsupported,
                                    "VideoPushClient is not started");
      logger_.Warn("process_before_start", config_.session.ids, status);
      return status;
    }
    RecordProcessTick(now_us);
    PruneState(now_us);
    Status drain_status = DrainPacer(now_us);
    if (!drain_status) {
      return drain_status;
    }
    googcc_.OnProcessInterval(now_us);
    ApplyProbeClusters();
    ApplyGoogCcRates(now_us);
    Status rtcp_status = MaybeSendSenderReports(now_us);
    if (!rtcp_status) {
      return rtcp_status;
    }
    MaybeWriteMetrics(now_us);
    MaybeWriteQosAlerts(now_us);
    return Status::Ok();
  }

  Status PushAnnexBAccessUnit(const AnnexBAccessUnitView& access_unit) override {
    if (!started_) {
      Status status = Status::Error(StatusCode::kUnsupported,
                                    "VideoPushClient is not started");
      logger_.Warn("push_before_start", access_unit.ids, status);
      return status;
    }
    if (access_unit.bytes == nullptr || access_unit.size == 0) {
      Status status = InvalidArgument("empty Annex-B access unit");
      logger_.Warn("push_au_rejected", access_unit.ids, status);
      return status;
    }

    TrackState* track = ResolveTrackForAccessUnit(access_unit);
    if (track == nullptr) {
      Status status = InvalidArgument(
          "multi-track push requires track_id or sender_ssrc in access unit");
      logger_.Warn("push_au_rejected", access_unit.ids, status);
      return status;
    }

    std::vector<H264RtpPayload> payloads;
    if (!PacketizeH264AnnexB(access_unit.bytes, access_unit.size,
                             H264RtpPacketizerConfig{
                                 track->config.h264.max_rtp_payload_bytes},
                             &payloads)) {
      Status status = Status::Error(StatusCode::kMalformedPacket,
                                    "failed to packetize H264 Annex-B AU");
      logger_.Warn("packetize_failed", track->config.ids, status);
      if (alert_writer_.config().alert_on_malformed_packet) {
        alert_writer_.Error("malformed_h264", "media_quality",
                            track->config.ids, access_unit.capture_time_us,
                            status);
      }
      return status;
    }

    struct PendingPacket {
      PacingAdapterPacket packet;
    };
    std::vector<PendingPacket> pending_packets;
    pending_packets.reserve(payloads.size());
    size_t access_unit_bytes = 0;

    uint16_t rtp_sequence_number = track->next_rtp_sequence_number;
    uint16_t transport_sequence_number = next_transport_sequence_number_;
    for (const auto& payload : payloads) {
      std::vector<uint8_t> rtp_bytes;
      RtpPacketAdapterBuildInput rtp_input;
      rtp_input.payload_type = track->config.h264.payload_type;
      rtp_input.marker = payload.marker;
      rtp_input.sequence_number = rtp_sequence_number++;
      rtp_input.timestamp = RtpTimestamp(*track, access_unit.capture_time_us);
      rtp_input.ssrc = track->config.ids.sender_ssrc;
      rtp_input.transport_sequence_number = transport_sequence_number++;
      rtp_input.payload = payload.payload.data();
      rtp_input.payload_size = payload.payload.size();
      if (!BuildRtpPacket(rtp_input, RtpConfig(track->config), &rtp_bytes)) {
        Status status = InternalError("failed to build RTP packet");
        logger_.Error("rtp_build_failed", track->config.ids, status);
        return status;
      }

      PacingAdapterPacket pacing_packet;
      pacing_packet.ssrc = track->config.ids.sender_ssrc;
      pacing_packet.rtp_sequence_number = rtp_input.sequence_number;
      pacing_packet.transport_sequence_number =
          *rtp_input.transport_sequence_number;
      pacing_packet.enqueue_time_us = access_unit.capture_time_us;
      pacing_packet.keyframe = payload.keyframe || access_unit.keyframe;
      pacing_packet.bytes = std::move(rtp_bytes);
      access_unit_bytes += pacing_packet.bytes.size();
      pending_packets.push_back(PendingPacket{std::move(pacing_packet)});
    }

    const auto pacer_stats = pacer_->stats();
    if (pacer_stats.queue_bytes + access_unit_bytes > kMaxPacingQueueBytes) {
      ++track->snapshot.dropped_frames;
      Status status = Status::Error(
          StatusCode::kQueueFull,
          "WebRTC pacing adapter queue bytes would overflow");
      logger_.Warn("pacer_enqueue_failed", track->config.ids, status);
      if (alert_writer_.config().alert_on_media_failure) {
        alert_writer_.Error("pacer_enqueue_failed", "media_quality",
                            track->config.ids, access_unit.capture_time_us,
                            status);
      }
      return status;
    }

    for (auto& pending : pending_packets) {
      if (!pacer_->EnqueuePacket(pending.packet)) {
        ResetPacerQueue(access_unit.capture_time_us);
        ++track->snapshot.dropped_frames;
        Status status = Status::Error(StatusCode::kQueueFull,
                                      "WebRTC pacing adapter rejected RTP packet");
        logger_.Warn("pacer_enqueue_failed", track->config.ids, status);
        if (alert_writer_.config().alert_on_media_failure) {
          alert_writer_.Error("pacer_enqueue_failed", "media_quality",
                              track->config.ids, access_unit.capture_time_us,
                              status);
        }
        return status;
      }
    }
    track->next_rtp_sequence_number = rtp_sequence_number;
    next_transport_sequence_number_ = transport_sequence_number;
    if (access_unit.keyframe) {
      track->keyframe_request_pending = false;
    }

    logger_.Info("push_au", track->config.ids);
    return Status::Ok();
  }

  Status OnTransportFeedback(const uint8_t* rtcp_bytes,
                             size_t rtcp_size,
                             int64_t receive_time_us) override {
    PruneState(receive_time_us);
    Status status = ForEachSupportedRtcpPacket(
        rtcp_bytes, rtcp_size,
        [&](const uint8_t*, size_t, const RtcpAdapterParsedPacket& parsed)
            -> Status {
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
            uint32_t max_rtt_ms = 0;
            for (const auto& block : parsed.receiver_report.report_blocks) {
              TrackState* track = FindTrackBySenderSsrc(block.media_ssrc);
              if (track == nullptr) {
                continue;
              }
              track->snapshot.downlink_quality.fraction_lost_q8 =
                  block.fraction_lost;
              const uint32_t rtt_ms = EstimateRttMsFromReceiverReport(
                  block.last_sr, block.delay_since_last_sr, receive_time_us);
              if (rtt_ms > 0) {
                track->snapshot.downlink_quality.rtt_ms =
                    static_cast<uint16_t>(std::min<uint32_t>(rtt_ms, 0xffffu));
                max_rtt_ms = std::max(max_rtt_ms, rtt_ms);
              }
            }
            if (max_rtt_ms > 0) {
              latest_rtt_ms_ = max_rtt_ms;
              googcc_.OnRoundTripTime(max_rtt_ms, receive_time_us);
              googcc_.OnProcessInterval(receive_time_us);
              ApplyProbeClusters();
              ApplyGoogCcRates(receive_time_us);
            }
            return Status::Ok();
          }
          if (parsed.type == RtcpAdapterPacketType::kNack) {
            return HandleNack(parsed.nack, receive_time_us);
          }
          if (parsed.type == RtcpAdapterPacketType::kPli) {
            TrackState* track = FindTrackBySenderSsrc(parsed.pli.media_ssrc);
            if (track != nullptr) {
              ++track->snapshot.pli_count;
              track->keyframe_request_pending = true;
            }
            return Status::Ok();
          }
          return Status::Ok();
        });
    if (!status && IsMalformedInputStatus(status)) {
      logger_.Warn("malformed_rtcp", config_.session.ids, status);
      if (alert_writer_.config().alert_on_malformed_packet) {
        alert_writer_.Error("malformed_rtcp", "network_qos",
                            config_.session.ids, receive_time_us, status);
      }
    }
    return status;
  }

  Status OnSenderRateCap(const SenderRateCap& cap) override {
    const uint32_t old_final_target_bps = FinalTargetBps(cap.receive_time_us);
    sender_rate_cap_ = cap;
    const uint32_t new_final_target_bps = FinalTargetBps(cap.receive_time_us);
    if (new_final_target_bps < old_final_target_bps) {
      ResetPacerQueue(cap.receive_time_us);
    }
    ApplyGoogCcRates(cap.receive_time_us);
    logger_.Info("sender_rate_cap_update", cap.ids);
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
    logger_.Info("network_route_change", config_.session.ids);
    return Status::Ok();
  }

  EncoderAdaptation GetEncoderAdaptation(int64_t now_us) const override {
    EncoderAdaptation out;
    (void)GetTrackEncoderAdaptation(primary_track_id_, now_us, &out);
    return out;
  }

  bool GetTrackEncoderAdaptation(uint32_t track_id,
                                 int64_t now_us,
                                 EncoderAdaptation* out) const override {
    const TrackState* track = FindTrackByTrackId(track_id);
    if (track == nullptr || out == nullptr) {
      return false;
    }
    out->target_bitrate_bps = TrackTargetBps(*track, now_us);
    out->max_fps = SuggestedMaxFps(*track, out->target_bitrate_bps);
    out->request_keyframe = track->keyframe_request_pending;
    return true;
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
    out.emitted_padding_packets = pacer_->stats().emitted_padding_packets;
    out.emitted_padding_bytes = pacer_->stats().emitted_padding_bytes;
    out.dropped_frames = 0;
    out.nack_count = 0;
    out.pli_count = 0;
    out.retransmission_count = 0;
    out.dropped_retransmission_packets = 0;
    for (const auto& item : track_states_) {
      out.dropped_frames += item.second.snapshot.dropped_frames;
      out.nack_count += item.second.snapshot.nack_count;
      out.pli_count += item.second.snapshot.pli_count;
      out.retransmission_count += item.second.snapshot.retransmission_count;
      out.dropped_retransmission_packets +=
          item.second.snapshot.dropped_retransmission_packets;
    }
    return out;
  }

  bool GetTrackQosSnapshot(uint32_t track_id,
                           int64_t now_us,
                           QosSnapshot* out) const override {
    const TrackState* track = FindTrackByTrackId(track_id);
    if (track == nullptr || out == nullptr) {
      return false;
    }
    *out = track->snapshot;
    out->ids = track->config.ids;
    out->report_time_us = static_cast<uint64_t>(std::max<int64_t>(0, now_us));
    out->sender_rates.googcc_target_bps = googcc_.rates().target_bitrate_bps;
    out->sender_rates.sender_rate_cap_bps = EffectiveSenderRateCapBps(now_us);
    out->sender_rates.final_target_bps = TrackTargetBps(*track, now_us);
    out->sender_rates.pacing_bps = pacer_->stats().pacing_bitrate_bps;
    out->sender_rates.rtt_ms = latest_rtt_ms_;
    out->jitter_buffer_delay_ms = pacer_->stats().expected_queue_time_ms;
    out->emitted_padding_packets = pacer_->stats().emitted_padding_packets;
    out->emitted_padding_bytes = pacer_->stats().emitted_padding_bytes;
    return true;
  }

 private:
  struct TrackState {
    VideoTrackConfig config;
    QosSnapshot snapshot;
    uint16_t next_rtp_sequence_number = 1;
    uint32_t first_rtp_timestamp = 90000;
    int64_t first_capture_time_us = -1;
    bool keyframe_request_pending = false;
    uint32_t sent_rtp_packet_count = 0;
    uint32_t sent_rtp_octet_count = 0;
    int64_t last_sr_send_time_us_ = -1;
  };

  RtpPacketAdapterConfig RtpConfig(const VideoTrackConfig& track) const {
    RtpPacketAdapterConfig config;
    config.payload_type = track.h264.payload_type;
    config.transport_sequence_extension_id = config_.session.twcc.extension_id;
    config.enable_transport_sequence_extension = true;
    return config;
  }

  uint32_t RtpTimestamp(TrackState& track, int64_t capture_time_us) const {
    if (track.first_capture_time_us < 0) {
      track.first_capture_time_us = capture_time_us;
    }
    const int64_t delta_us =
        std::max<int64_t>(0, capture_time_us - track.first_capture_time_us);
    return track.first_rtp_timestamp +
           static_cast<uint32_t>((delta_us * kVideoClockRateHz) / 1000000);
  }

  TrackState* ResolveTrackForAccessUnit(const AnnexBAccessUnitView& access_unit) {
    if (access_unit.ids.track_id != 0) {
      return FindTrackByTrackId(access_unit.ids.track_id);
    }
    if (access_unit.ids.sender_ssrc != 0) {
      return FindTrackBySenderSsrc(access_unit.ids.sender_ssrc);
    }
    if (track_states_.size() == 1) {
      return FindTrackByTrackId(primary_track_id_);
    }
    return nullptr;
  }

  TrackState* FindTrackByTrackId(uint32_t track_id) {
    auto it = track_states_.find(track_id);
    return it == track_states_.end() ? nullptr : &it->second;
  }

  const TrackState* FindTrackByTrackId(uint32_t track_id) const {
    auto it = track_states_.find(track_id);
    return it == track_states_.end() ? nullptr : &it->second;
  }

  TrackState* FindTrackBySenderSsrc(uint32_t sender_ssrc) {
    auto it = sender_ssrc_to_track_id_.find(sender_ssrc);
    if (it == sender_ssrc_to_track_id_.end()) {
      return nullptr;
    }
    return FindTrackByTrackId(it->second);
  }

  const TrackState* FindTrackBySenderSsrc(uint32_t sender_ssrc) const {
    auto it = sender_ssrc_to_track_id_.find(sender_ssrc);
    if (it == sender_ssrc_to_track_id_.end()) {
      return nullptr;
    }
    return FindTrackByTrackId(it->second);
  }

  uint32_t TotalEnabledTrackWeight() const {
    uint32_t total_weight = 0;
    for (const auto& item : track_states_) {
      if (item.second.config.enabled) {
        total_weight += std::max<uint32_t>(1, item.second.config.weight);
      }
    }
    return std::max<uint32_t>(1, total_weight);
  }

  uint32_t AllocateTrackTargetBps(const TrackState& track,
                                  uint32_t source_target_bps,
                                  uint32_t source_floor_bps) const {
    if (track_states_.size() <= 1) {
      return source_target_bps;
    }

    const bool is_base_track = track.config.base_track;
    const uint32_t reserved_base_floor =
        is_base_track ? std::min(source_target_bps, source_floor_bps) : 0u;
    const uint32_t remaining_bps =
        source_target_bps > source_floor_bps
            ? source_target_bps - source_floor_bps
            : 0u;
    const uint64_t weighted_share =
        (static_cast<uint64_t>(remaining_bps) *
         std::max<uint32_t>(1, track.config.weight)) /
        TotalEnabledTrackWeight();
    return static_cast<uint32_t>(weighted_share) + reserved_base_floor;
  }

  uint32_t TrackTargetBps(const TrackState& track, int64_t now_us) const {
    const uint32_t source_target_bps = FinalTargetBps(now_us);
    return AllocateTrackTargetBps(track, source_target_bps,
                                  config_.session.min_bitrate_bps);
  }

  uint32_t TrackStartBitrateBps(const TrackState& track) const {
    return AllocateTrackTargetBps(track, config_.session.start_bitrate_bps,
                                  config_.session.min_bitrate_bps);
  }

  uint32_t SuggestedMaxFps(const TrackState& track, uint32_t target_bps) const {
    const uint32_t max_fps = std::max<uint16_t>(1, track.config.h264.max_fps);
    if (target_bps == 0) {
      return 0;
    }
    if (track.config.base_track && target_bps <= config_.session.min_bitrate_bps) {
      return std::min<uint32_t>(max_fps, 5);
    }
    const uint32_t track_start_bps = TrackStartBitrateBps(track);
    if (target_bps <= std::max<uint32_t>(1u, track_start_bps / 2)) {
      return std::min<uint32_t>(max_fps, 10);
    }
    if (target_bps <= (track_start_bps * 3) / 4) {
      return std::min<uint32_t>(max_fps, 15);
    }
    return max_fps;
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
      Status sr_status = MaybeSendSenderReports(now_us);
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
    return std::min<uint32_t>(googcc_target, sender_rate_cap_bps);
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
    for (auto& item : track_states_) {
      item.second.keyframe_request_pending = true;
    }
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

  Status MaybeSendSenderReports(int64_t now_us) {
    for (auto& item : track_states_) {
      TrackState& track = item.second;
      if (track.sent_rtp_packet_count == 0) {
        continue;
      }
      const int64_t interval_us =
          static_cast<int64_t>(config_.session.rtcp.sr_rr_interval_ms) * 1000;
      if (track.last_sr_send_time_us_ >= 0 &&
          now_us - track.last_sr_send_time_us_ < interval_us) {
        continue;
      }

      RtcpAdapterSenderReport sr;
      sr.sender_ssrc = track.config.ids.sender_ssrc;
      sr.ntp_seconds =
          kNtpUnixEpochOffsetSeconds + static_cast<uint32_t>(now_us / 1000000);
      sr.ntp_fractions = static_cast<uint32_t>(
          ((static_cast<uint64_t>(now_us % 1000000) << 32) / 1000000));
      sr.rtp_timestamp = RtpTimestamp(track, now_us);
      sr.packet_count = track.sent_rtp_packet_count;
      sr.octet_count = track.sent_rtp_octet_count;

      std::vector<uint8_t> rtcp_bytes;
      if (!BuildRtcpSenderReport(sr, &rtcp_bytes)) {
        return Status::Error(StatusCode::kInternalError,
                             "failed to build RTCP SR");
      }
      TransportPacketView view;
      view.bytes = rtcp_bytes.data();
      view.size = rtcp_bytes.size();
      view.metadata.ids = track.config.ids;
      view.metadata.kind = TransportPacketKind::kRtcp;
      view.metadata.send_time_us = now_us;
      Status status = config_.transport_output(view);
      if (!status) {
        RecordTransportFailure(track.config.ids, now_us);
        logger_.Error("transport_output_failed", track.config.ids, status);
        if (alert_writer_.config().alert_on_transport_failure) {
          alert_writer_.Error("transport_output_failed", "availability",
                              track.config.ids, now_us, status);
        }
        return status;
      }
      RecordTransportSuccess();
      track.last_sr_send_time_us_ = now_us;
    }
    return Status::Ok();
  }

  struct SentPacketInfo {
    int64_t send_time_us = 0;
    uint32_t packet_size_bytes = 0;
  };

  Status EnqueueRetransmission(const PacingAdapterPacket& packet) {
    const auto pacer_stats = pacer_->stats();
    if (pacer_stats.queue_bytes + packet.bytes.size() > kMaxPacingQueueBytes) {
      TrackState* track = FindTrackBySenderSsrc(packet.ssrc);
      if (track != nullptr) {
        ++track->snapshot.dropped_retransmission_packets;
        const Status status =
            Status::Error(StatusCode::kQueueFull,
                          "retransmission would overflow pacer queue");
        logger_.Warn("sender_retransmission_drop", track->config.ids, status);
        if (alert_writer_.config().alert_on_recovery_events) {
          alert_writer_.Warn("sender_retransmission_drop", "network_qos",
                             track->config.ids, packet.enqueue_time_us,
                             track->snapshot.dropped_retransmission_packets,
                             0);
        }
      }
      return Status::Ok();
    }
    if (!pacer_->EnqueuePacket(packet)) {
      TrackState* track = FindTrackBySenderSsrc(packet.ssrc);
      if (track != nullptr) {
        ++track->snapshot.dropped_retransmission_packets;
        const Status status = Status::Error(StatusCode::kQueueFull,
                                            "pacer rejected retransmission");
        logger_.Warn("sender_retransmission_drop", track->config.ids, status);
        if (alert_writer_.config().alert_on_recovery_events) {
          alert_writer_.Warn("sender_retransmission_drop", "network_qos",
                             track->config.ids, packet.enqueue_time_us,
                             track->snapshot.dropped_retransmission_packets,
                             0);
        }
      }
    } else {
      TrackState* track = FindTrackBySenderSsrc(packet.ssrc);
      if (track != nullptr) {
        logger_.Info("sender_retransmission_enqueue", track->config.ids);
        if (alert_writer_.config().alert_on_recovery_events) {
          alert_writer_.Warn("sender_retransmission_enqueue", "network_qos",
                             track->config.ids, packet.enqueue_time_us,
                             track->snapshot.retransmission_count + 1, 0);
        }
      }
    }
    return Status::Ok();
  }

  Status HandleNack(const RtcpAdapterNack& nack, int64_t receive_time_us) {
    TrackState* track = FindTrackBySenderSsrc(nack.media_ssrc);
    if (track == nullptr) {
      return Status::Ok();
    }
    for (uint16_t packet_id : nack.packet_ids) {
      auto found = packet_history_.Find(TransportPacketHistoryKey{
          kSenderPacketHistoryHopId, nack.media_ssrc, packet_id});
      if (!found.has_value()) {
        continue;
      }
      RtpPacketAdapterParsedPacket parsed;
      if (!ParseRtpPacket(found->rtp_bytes.data(), found->rtp_bytes.size(),
                          RtpConfig(track->config), &parsed)) {
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
      if (!BuildRtpPacket(rtp_input, RtpConfig(track->config), &rebuilt_bytes)) {
        Status status =
            InternalError("failed to rebuild retransmission RTP packet");
        logger_.Error("sender_retransmission_rebuild_failed",
                      track->config.ids, status);
        return status;
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
    TrackState* track = FindTrackBySenderSsrc(packet.ssrc);
    if (track == nullptr) {
      Status status = InternalError("missing track state for emitted packet");
      logger_.Error("rtp_emit_failed", config_.session.ids, status);
      return status;
    }

    TransportPacketView view;
    view.bytes = packet.bytes.data();
    view.size = packet.bytes.size();
    view.metadata.ids = track->config.ids;
    view.metadata.kind = TransportPacketKind::kRtp;
    view.metadata.send_time_us = now_us;
    view.metadata.retransmission = packet.retransmission;
    view.metadata.padding = packet.padding;
    Status status = config_.transport_output(view);
    if (!status) {
      RecordTransportFailure(track->config.ids, now_us);
      logger_.Error("transport_output_failed", track->config.ids, status);
      if (alert_writer_.config().alert_on_transport_failure) {
        alert_writer_.Error("transport_output_failed", "availability",
                            track->config.ids, now_us, status);
      }
      return status;
    }
    RecordTransportSuccess();
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
    if (packet.padding && packet.transport_sequence_number >= 0) {
      const uint16_t next_transport_sequence_number =
          static_cast<uint16_t>(packet.transport_sequence_number + 1);
      if (SequenceNumberAtOrAfter(next_transport_sequence_number,
                                  next_transport_sequence_number_)) {
        next_transport_sequence_number_ = next_transport_sequence_number;
      }
    }
    if (!packet.padding && !packet.retransmission) {
      ++track->sent_rtp_packet_count;
      track->sent_rtp_octet_count += packet.bytes.size();
      RecordRtpOutput(now_us);
      packet_history_.Store(
          TransportPacketHistoryKey{kSenderPacketHistoryHopId,
                                    track->config.ids.sender_ssrc,
                                    packet.rtp_sequence_number},
          packet.bytes.data(), packet.bytes.size(), now_us, false);
    } else if (!packet.padding && packet.retransmission) {
      ++track->snapshot.retransmission_count;
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

  void MaybeWriteMetrics(int64_t now_us) {
    RefreshRtpOutputGap(now_us);
    if (!metrics_writer_.ShouldWrite(now_us)) {
      return;
    }
    const EncoderAdaptation session_adaptation = GetEncoderAdaptation(now_us);
    metrics_writer_.WriteSession(GetQosSnapshot(now_us), &session_adaptation);
    if (!metrics_writer_.include_track_snapshots()) {
      return;
    }
    for (const auto& track_config : track_configs_) {
      QosSnapshot snapshot;
      EncoderAdaptation adaptation;
      if (GetTrackQosSnapshot(track_config.ids.track_id, now_us, &snapshot) &&
          GetTrackEncoderAdaptation(track_config.ids.track_id, now_us,
                                    &adaptation)) {
        metrics_writer_.WriteTrack(snapshot, &adaptation);
      }
    }
  }

  void MaybeWriteQosAlerts(int64_t now_us) {
    const RuntimeAlertConfig& alert_config = alert_writer_.config();
    RefreshRtpOutputGap(now_us);
    if (alert_config.alert_on_process_tick_gap &&
        snapshot_.process_tick_gap_us >
            static_cast<uint64_t>(alert_config.max_process_tick_gap_ms) *
                1000) {
      logger_.Warn("process_tick_gap", config_.session.ids,
                   Status::Error(StatusCode::kInternalError,
                                 "push Process tick gap exceeded threshold"));
      alert_writer_.Warn("process_tick_gap", "availability",
                         config_.session.ids, now_us,
                         snapshot_.process_tick_gap_us,
                         static_cast<uint64_t>(
                             alert_config.max_process_tick_gap_ms) *
                             1000);
    }
    if (alert_config.alert_on_media_flow_gap) {
      const uint64_t threshold_us =
          static_cast<uint64_t>(alert_config.max_rtp_output_gap_ms) * 1000;
      if (snapshot_.rtp_output_gap_us > threshold_us) {
        logger_.Warn("sender_rtp_output_gap", config_.session.ids,
                     Status::Error(StatusCode::kInternalError,
                                   "sender RTP output gap exceeded threshold"));
        alert_writer_.Warn("sender_rtp_output_gap", "availability",
                           config_.session.ids, now_us,
                           snapshot_.rtp_output_gap_us, threshold_us);
      }
    }
    if (alert_config.alert_on_transport_failure &&
        alert_config.consecutive_transport_failures_threshold > 0 &&
        snapshot_.consecutive_transport_failures >=
            alert_config.consecutive_transport_failures_threshold) {
      alert_writer_.Warn("consecutive_transport_failures", "availability",
                         config_.session.ids, now_us,
                         snapshot_.consecutive_transport_failures,
                         alert_config.consecutive_transport_failures_threshold);
    }
    if (!alert_config.alert_on_qos_degradation) {
      return;
    }
    const QosSnapshot snapshot = GetQosSnapshot(now_us);
    const EncoderAdaptation adaptation = GetEncoderAdaptation(now_us);
    if (snapshot.sender_rates.final_target_bps > 0 &&
        snapshot.sender_rates.final_target_bps <=
            alert_config.low_target_bps) {
      alert_writer_.Warn("low_target_bitrate", "media_quality", snapshot.ids,
                         now_us, snapshot.sender_rates.final_target_bps,
                         alert_config.low_target_bps);
    }
    if (adaptation.max_fps > 0 &&
        adaptation.max_fps <= alert_config.low_encoder_fps) {
      alert_writer_.Warn("low_encoder_fps", "media_quality", snapshot.ids,
                         now_us, adaptation.max_fps,
                         alert_config.low_encoder_fps);
    }
  }

  void RecordProcessTick(int64_t now_us) {
    const uint64_t safe_now_us =
        static_cast<uint64_t>(std::max<int64_t>(0, now_us));
    snapshot_.report_time_us = safe_now_us;
    ++snapshot_.process_tick_count;
    if (last_process_tick_time_us_ < 0) {
      snapshot_.process_tick_gap_us = 0;
      last_process_tick_time_us_ = now_us;
      return;
    }
    if (now_us < last_process_tick_time_us_) {
      return;
    }
    snapshot_.process_tick_gap_us =
        static_cast<uint64_t>(now_us - last_process_tick_time_us_);
    snapshot_.max_process_tick_gap_us =
        std::max(snapshot_.max_process_tick_gap_us,
                 snapshot_.process_tick_gap_us);
    last_process_tick_time_us_ = now_us;
  }

  void RecordRtpOutput(int64_t now_us) {
    if (last_rtp_output_time_us_ < 0) {
      snapshot_.rtp_output_gap_us = 0;
      last_rtp_output_time_us_ = now_us;
      return;
    }
    if (now_us < last_rtp_output_time_us_) {
      return;
    }
    snapshot_.rtp_output_gap_us =
        static_cast<uint64_t>(now_us - last_rtp_output_time_us_);
    snapshot_.max_rtp_output_gap_us =
        std::max(snapshot_.max_rtp_output_gap_us,
                 snapshot_.rtp_output_gap_us);
    last_rtp_output_time_us_ = now_us;
  }

  void RefreshRtpOutputGap(int64_t now_us) {
    if (last_rtp_output_time_us_ < 0 || now_us < last_rtp_output_time_us_) {
      return;
    }
    snapshot_.rtp_output_gap_us =
        static_cast<uint64_t>(now_us - last_rtp_output_time_us_);
    snapshot_.max_rtp_output_gap_us =
        std::max(snapshot_.max_rtp_output_gap_us,
                 snapshot_.rtp_output_gap_us);
  }

  void RecordTransportSuccess() {
    snapshot_.consecutive_transport_failures = 0;
  }

  void RecordTransportFailure(const TransportIds& ids, int64_t now_us) {
    ++snapshot_.transport_failure_count;
    ++snapshot_.consecutive_transport_failures;
    snapshot_.max_consecutive_transport_failures =
        std::max(snapshot_.max_consecutive_transport_failures,
                 snapshot_.consecutive_transport_failures);
    const RuntimeAlertConfig& alert_config = alert_writer_.config();
    if (alert_config.alert_on_transport_failure &&
        alert_config.consecutive_transport_failures_threshold > 0 &&
        snapshot_.consecutive_transport_failures >=
            alert_config.consecutive_transport_failures_threshold) {
      alert_writer_.Warn("consecutive_transport_failures", "availability", ids,
                         now_us, snapshot_.consecutive_transport_failures,
                         alert_config.consecutive_transport_failures_threshold);
    }
  }

  VideoPushClientConfig config_;
  RuntimeLogger logger_;
  RuntimeMetricsWriter metrics_writer_;
  RuntimeAlertWriter alert_writer_;
  Status track_config_status_ = Status::Ok();
  std::vector<VideoTrackConfig> track_configs_;
  uint32_t primary_track_id_ = 0;
  std::unordered_map<uint32_t, TrackState> track_states_;
  std::unordered_map<uint32_t, uint32_t> sender_ssrc_to_track_id_;
  GoogCcAdapter googcc_;
  std::unique_ptr<PacingAdapter> pacer_;
  TransportPacketHistory packet_history_;
  QosSnapshot snapshot_;
  std::unordered_map<uint16_t, SentPacketInfo> sent_packets_;
  std::unordered_map<int32_t, GoogCcProbeCluster> active_probe_clusters_;
  bool started_ = false;
  uint16_t next_transport_sequence_number_ = 1;
  SenderRateCap sender_rate_cap_;
  uint32_t latest_rtt_ms_ = 0;
  int64_t last_process_tick_time_us_ = -1;
  int64_t last_rtp_output_time_us_ = -1;
};

}  // namespace

std::unique_ptr<VideoPushClient> CreateVideoPushClient(
    const VideoPushClientConfig& config) {
  return std::make_unique<WebRtcVideoPushClient>(config);
}

}  // namespace webrtc_qos
