#include "webrtc_qos/video_play_client.h"

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
#include "webrtc_qos/nack_requester_adapter.h"
#include "webrtc_qos/rtcp_adapter.h"
#include "webrtc_qos/rtp_packet_adapter.h"
#include "webrtc_qos/video_jitter_adapter.h"

namespace webrtc_qos {
namespace {

Status InvalidArgument(const char* message) {
  return Status::Error(StatusCode::kInvalidArgument, message);
}

bool IsMalformedInputStatus(const Status& status) {
  return status.code == StatusCode::kInvalidArgument ||
         status.code == StatusCode::kMalformedPacket;
}

bool HasRtpPadding(const uint8_t* rtp_bytes, size_t rtp_size) {
  return rtp_bytes != nullptr && rtp_size > 0 && (rtp_bytes[0] & 0x20) != 0;
}

uint32_t ResolveReceiverFeedbackSsrc(const SessionConfig& session) {
  if (session.rtcp.receiver_feedback_ssrc != 0) {
    return session.rtcp.receiver_feedback_ssrc;
  }
  if (session.ids.receiver_id != 0) {
    const uint32_t candidate = session.ids.receiver_id | 0x80000000u;
    if (candidate != session.ids.sender_ssrc) {
      return candidate;
    }
  }
  const uint32_t fallback = session.ids.sender_ssrc ^ 0x00ff00ffu;
  return fallback != 0 ? fallback : 1u;
}

class WebRtcVideoPlayClient final : public VideoPlayClient {
 public:
  explicit WebRtcVideoPlayClient(VideoPlayClientConfig config)
      : config_(std::move(config)),
        logger_(config_.logging, "play"),
        metrics_writer_(config_.metrics, "play"),
        alert_writer_(config_.alerts, "play") {
    track_config_status_ =
        ResolveVideoTrackConfigs(config_.session, &track_configs_);
    if (track_config_status_) {
      for (const auto& track_config : track_configs_) {
        TrackState state;
        state.config = track_config;
        state.snapshot.ids = track_config.ids;
        state.nack_requester =
            std::make_unique<NackRequesterAdapter>(NackRequesterAdapterConfig{100});
        state.jitter = std::make_unique<VideoJitterAdapter>(
            VideoJitterAdapterConfig{track_config.h264.payload_type,
                                     track_config.ids.sender_ssrc});
        primary_track_id_ = primary_track_id_ == 0 && track_config.base_track
                                ? track_config.ids.track_id
                                : primary_track_id_;
        sender_ssrc_to_track_id_[track_config.ids.sender_ssrc] =
            track_config.ids.track_id;
        track_states_.emplace(track_config.ids.track_id, std::move(state));
      }
      if (primary_track_id_ == 0) {
        primary_track_id_ = PrimaryTrackId(track_configs_);
      }
    }
  }

  Status Start() override {
    if (!config_.decoded_access_unit_output) {
      Status status = InvalidArgument(
          "VideoPlayClient requires decoded_access_unit_output");
      logger_.Error("start_failed", config_.session.ids, status);
      return status;
    }
    if (!config_.transport_output) {
      Status status = InvalidArgument("VideoPlayClient requires transport_output");
      logger_.Error("start_failed", config_.session.ids, status);
      return status;
    }
    if (!track_config_status_) {
      logger_.Error("start_failed", config_.session.ids, track_config_status_);
      return track_config_status_;
    }
    started_ = true;
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
                                    "VideoPlayClient is not started");
      logger_.Warn("process_before_start", config_.session.ids, status);
      return status;
    }
    RecordProcessTick(now_us);
    for (auto& item : track_states_) {
      Status status = EmitNackRequesterFeedback(item.second, now_us);
      if (!status) {
        return status;
      }
    }
    MaybeWriteMetrics(now_us);
    MaybeWriteQosAlerts(now_us);
    return Status::Ok();
  }

  Status OnRtpPacket(const uint8_t* rtp_bytes,
                     size_t rtp_size,
                     int64_t receive_time_us) override {
    if (!started_) {
      Status status = Status::Error(StatusCode::kUnsupported,
                                    "VideoPlayClient is not started");
      logger_.Warn("rtp_before_start", config_.session.ids, status);
      return status;
    }
    if (rtp_bytes == nullptr || rtp_size == 0) {
      Status status = InvalidArgument("empty RTP packet");
      logger_.Warn("malformed_rtp", config_.session.ids, status);
      if (alert_writer_.config().alert_on_malformed_packet) {
        alert_writer_.Error("malformed_rtp", "network_qos",
                            config_.session.ids, receive_time_us, status);
      }
      return status;
    }

    RtpPacketAdapterParsedPacket parsed;
    if (!ParseRtpPacket(rtp_bytes, rtp_size, LegacyRtpConfig(), &parsed)) {
      Status status = Status::Error(StatusCode::kMalformedPacket,
                                    "failed to parse RTP packet");
      logger_.Warn("malformed_rtp", config_.session.ids, status);
      if (alert_writer_.config().alert_on_malformed_packet) {
        alert_writer_.Error("malformed_rtp", "network_qos",
                            config_.session.ids, receive_time_us, status);
      }
      return status;
    }

    TrackState& track = EnsureTrackStateForSsrc(parsed.ssrc, parsed.payload_type);
    track.nack_requester->OnReceivedPacket(parsed.sequence_number,
                                           /*is_recovered=*/false);
    Status feedback_status = EmitNackRequesterFeedback(track, receive_time_us);
    if (!feedback_status) {
      return feedback_status;
    }
    if (HasRtpPadding(rtp_bytes, rtp_size)) {
      return Status::Ok();
    }
    RecordRtpInput(receive_time_us);

    VideoJitterPacket jitter_packet;
    jitter_packet.payload_type = parsed.payload_type;
    jitter_packet.marker = parsed.marker;
    jitter_packet.sequence_number = parsed.sequence_number;
    jitter_packet.rtp_timestamp = parsed.timestamp;
    jitter_packet.ssrc = parsed.ssrc;
    jitter_packet.arrival_time_us = receive_time_us;
    jitter_packet.payload = parsed.payload.data();
    jitter_packet.payload_size = parsed.payload.size();

    auto frames = track.jitter->InsertPacket(jitter_packet);
    for (const auto& frame : frames) {
      AnnexBAccessUnitView view;
      view.bytes = frame.annexb_access_unit.data();
      view.size = frame.annexb_access_unit.size();
      view.capture_time_us =
          RtpTimestampToCaptureTimeUs(track, frame.rtp_timestamp);
      view.keyframe = frame.keyframe;
      view.ids = track.config.ids;
      Status status = config_.decoded_access_unit_output(view);
      if (!status) {
        logger_.Error("decode_au_output_failed", view.ids, status);
        if (alert_writer_.config().alert_on_media_failure) {
          alert_writer_.Error("decode_output_failed", "media_quality",
                              view.ids, receive_time_us, status);
        }
        return status;
      }
      ++track.decoded_frames;
      logger_.Info("decode_au_output", view.ids);
    }
    return Status::Ok();
  }

  Status OnRtcpPacket(const uint8_t* rtcp_bytes,
                      size_t rtcp_size,
                      int64_t receive_time_us) override {
    Status status = ForEachSupportedRtcpPacket(
        rtcp_bytes, rtcp_size,
        [&](const uint8_t*, size_t, const RtcpAdapterParsedPacket& parsed) {
          if (parsed.type != RtcpAdapterPacketType::kReceiverReport) {
            return Status::Ok();
          }
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
              track->nack_requester->UpdateRtt(rtt_ms);
              track->snapshot.downlink_quality.rtt_ms =
                  static_cast<uint16_t>(std::min<uint32_t>(rtt_ms, 0xffffu));
            }
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

  QosSnapshot GetQosSnapshot(int64_t now_us) const override {
    QosSnapshot out = snapshot_;
    const TrackState* primary_track = FindTrackByTrackId(primary_track_id_);
    if (primary_track != nullptr) {
      out.downlink_quality = primary_track->snapshot.downlink_quality;
    }
    out.ids = config_.session.ids;
    out.report_time_us = static_cast<uint64_t>(std::max<int64_t>(0, now_us));
    for (const auto& item : track_states_) {
      out.nack_count += item.second.snapshot.nack_count;
      out.pli_count += item.second.snapshot.pli_count;
      out.dropped_frames +=
          static_cast<uint32_t>(item.second.jitter->stats().packets_rejected);
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
    const auto stats = track->jitter->stats();
    out->downlink_quality.video_decodable_queue_depth = 0;
    out->dropped_frames = static_cast<uint32_t>(stats.packets_rejected);
    return true;
  }

 private:
  struct TrackState {
    VideoTrackConfig config;
    std::unique_ptr<NackRequesterAdapter> nack_requester;
    std::unique_ptr<VideoJitterAdapter> jitter;
    QosSnapshot snapshot;
    uint32_t decoded_frames = 0;
    bool has_first_rtp_timestamp = false;
    uint32_t first_rtp_timestamp = 0;
  };

  RtpPacketAdapterConfig LegacyRtpConfig() const {
    RtpPacketAdapterConfig config;
    config.payload_type = config_.session.h264.payload_type;
    config.transport_sequence_extension_id = config_.session.twcc.extension_id;
    config.enable_transport_sequence_extension = true;
    return config;
  }

  int64_t RtpTimestampToCaptureTimeUs(TrackState& track,
                                      uint32_t rtp_timestamp) const {
    if (!track.has_first_rtp_timestamp) {
      track.first_rtp_timestamp = rtp_timestamp;
      track.has_first_rtp_timestamp = true;
    }
    const uint32_t timestamp_delta = rtp_timestamp - track.first_rtp_timestamp;
    return static_cast<int64_t>(1000000) +
           (static_cast<int64_t>(timestamp_delta) * 1000000) /
               kVideoClockRateHz;
  }

  TrackState& EnsureTrackStateForSsrc(uint32_t sender_ssrc,
                                      uint8_t payload_type) {
    TrackState* existing = FindTrackBySenderSsrc(sender_ssrc);
    if (existing != nullptr) {
      return *existing;
    }

    VideoTrackConfig track_config;
    track_config.ids = config_.session.ids;
    track_config.ids.sender_ssrc = sender_ssrc;
    track_config.ids.track_id = sender_ssrc;
    if (track_config.ids.source_id == 0) {
      track_config.ids.source_id = config_.session.ids.stream_id;
    }
    track_config.h264 = config_.session.h264;
    track_config.h264.payload_type = payload_type;

    TrackState state;
    state.config = track_config;
    state.snapshot.ids = track_config.ids;
    state.nack_requester =
        std::make_unique<NackRequesterAdapter>(NackRequesterAdapterConfig{100});
    state.jitter = std::make_unique<VideoJitterAdapter>(
        VideoJitterAdapterConfig{track_config.h264.payload_type,
                                 track_config.ids.sender_ssrc});
    sender_ssrc_to_track_id_[track_config.ids.sender_ssrc] =
        track_config.ids.track_id;
    auto inserted =
        track_states_.emplace(track_config.ids.track_id, std::move(state));
    return inserted.first->second;
  }

  TrackState* FindTrackBySenderSsrc(uint32_t sender_ssrc) {
    auto it = sender_ssrc_to_track_id_.find(sender_ssrc);
    if (it == sender_ssrc_to_track_id_.end()) {
      return nullptr;
    }
    auto track_it = track_states_.find(it->second);
    return track_it == track_states_.end() ? nullptr : &track_it->second;
  }

  TrackState* FindTrackByTrackId(uint32_t track_id) {
    auto it = track_states_.find(track_id);
    return it == track_states_.end() ? nullptr : &it->second;
  }

  const TrackState* FindTrackByTrackId(uint32_t track_id) const {
    auto it = track_states_.find(track_id);
    return it == track_states_.end() ? nullptr : &it->second;
  }

  Status EmitNackRequesterFeedback(TrackState& track, int64_t now_us) {
    track.nack_requester->ProcessNacks(now_us);
    for (const auto& event : track.nack_requester->DrainEvents()) {
      std::vector<uint8_t> rtcp_bytes;
      if (event.type == NackRequesterAdapterEventType::kNack) {
        if (event.rtp_sequence_numbers.empty()) {
          continue;
        }
        RtcpAdapterNack nack;
        nack.sender_ssrc = ResolveReceiverFeedbackSsrc(config_.session);
        nack.media_ssrc = track.config.ids.sender_ssrc;
        nack.packet_ids = event.rtp_sequence_numbers;
        if (!BuildRtcpNack(nack, &rtcp_bytes)) {
          Status status = Status::Error(StatusCode::kInternalError,
                                        "failed to build RTCP NACK");
          logger_.Error("rtcp_build_failed", track.config.ids, status);
          return status;
        }
        ++track.snapshot.nack_count;
        logger_.Info("nack_generated", track.config.ids);
        if (alert_writer_.config().alert_on_recovery_events) {
          alert_writer_.Warn("nack_generated", "network_qos",
                             track.config.ids, now_us,
                             track.snapshot.nack_count, 0);
        }
      } else if (event.type ==
                 NackRequesterAdapterEventType::kKeyFrameRequest) {
        RtcpAdapterPli pli;
        pli.sender_ssrc = ResolveReceiverFeedbackSsrc(config_.session);
        pli.media_ssrc = track.config.ids.sender_ssrc;
        if (!BuildRtcpPli(pli, &rtcp_bytes)) {
          Status status = Status::Error(StatusCode::kInternalError,
                                        "failed to build RTCP PLI");
          logger_.Error("rtcp_build_failed", track.config.ids, status);
          return status;
        }
        ++track.snapshot.pli_count;
        logger_.Info("pli_generated", track.config.ids);
        if (alert_writer_.config().alert_on_recovery_events) {
          alert_writer_.Warn("pli_generated", "media_quality",
                             track.config.ids, now_us,
                             track.snapshot.pli_count, 0);
        }
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
    }
    return Status::Ok();
  }

  static uint32_t EstimateRttMsFromReceiverReport(uint32_t last_sr,
                                                  uint32_t delay_since_last_sr,
                                                  int64_t receive_time_us) {
    if (last_sr == 0) {
      return 0;
    }
    const uint32_t now_ntp_middle_32 =
        static_cast<uint32_t>((receive_time_us * 65536) / 1000000);
    const uint32_t rtt_ntp =
        now_ntp_middle_32 - last_sr - delay_since_last_sr;
    return static_cast<uint32_t>((static_cast<uint64_t>(rtt_ntp) * 1000) /
                                 65536);
  }

  void MaybeWriteMetrics(int64_t now_us) {
    RefreshRtpInputGap(now_us);
    if (!metrics_writer_.ShouldWrite(now_us)) {
      return;
    }
    metrics_writer_.WriteSession(GetQosSnapshot(now_us));
    if (!metrics_writer_.include_track_snapshots()) {
      return;
    }
    for (const auto& track_config : track_configs_) {
      QosSnapshot snapshot;
      if (GetTrackQosSnapshot(track_config.ids.track_id, now_us, &snapshot)) {
        metrics_writer_.WriteTrack(snapshot);
      }
    }
  }

  void MaybeWriteQosAlerts(int64_t now_us) {
    const RuntimeAlertConfig& alert_config = alert_writer_.config();
    RefreshRtpInputGap(now_us);
    if (alert_config.alert_on_process_tick_gap &&
        snapshot_.process_tick_gap_us >
            static_cast<uint64_t>(alert_config.max_process_tick_gap_ms) *
                1000) {
      logger_.Warn("process_tick_gap", config_.session.ids,
                   Status::Error(StatusCode::kInternalError,
                                 "play Process tick gap exceeded threshold"));
      alert_writer_.Warn("process_tick_gap", "availability",
                         config_.session.ids, now_us,
                         snapshot_.process_tick_gap_us,
                         static_cast<uint64_t>(
                             alert_config.max_process_tick_gap_ms) *
                             1000);
    }
    if (alert_config.alert_on_media_flow_gap) {
      const uint64_t threshold_us =
          static_cast<uint64_t>(alert_config.max_rtp_input_gap_ms) * 1000;
      if (snapshot_.rtp_input_gap_us > threshold_us) {
        logger_.Warn("receiver_rtp_input_gap", config_.session.ids,
                     Status::Error(StatusCode::kInternalError,
                                   "receiver RTP input gap exceeded threshold"));
        alert_writer_.Warn("receiver_rtp_input_gap", "availability",
                           config_.session.ids, now_us,
                           snapshot_.rtp_input_gap_us, threshold_us);
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
    for (const auto& item : track_states_) {
      const auto stats = item.second.jitter->stats();
      if (stats.packets_rejected >= alert_config.video_drop_frames_threshold) {
        alert_writer_.Warn("jitter_packet_drop", "media_quality",
                           item.second.config.ids, now_us,
                           stats.packets_rejected,
                           alert_config.video_drop_frames_threshold);
      }
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

  void RecordRtpInput(int64_t now_us) {
    if (last_rtp_input_time_us_ < 0) {
      snapshot_.rtp_input_gap_us = 0;
      last_rtp_input_time_us_ = now_us;
      return;
    }
    if (now_us < last_rtp_input_time_us_) {
      return;
    }
    snapshot_.rtp_input_gap_us =
        static_cast<uint64_t>(now_us - last_rtp_input_time_us_);
    snapshot_.max_rtp_input_gap_us =
        std::max(snapshot_.max_rtp_input_gap_us,
                 snapshot_.rtp_input_gap_us);
    last_rtp_input_time_us_ = now_us;
  }

  void RefreshRtpInputGap(int64_t now_us) {
    if (last_rtp_input_time_us_ < 0 || now_us < last_rtp_input_time_us_) {
      return;
    }
    snapshot_.rtp_input_gap_us =
        static_cast<uint64_t>(now_us - last_rtp_input_time_us_);
    snapshot_.max_rtp_input_gap_us =
        std::max(snapshot_.max_rtp_input_gap_us,
                 snapshot_.rtp_input_gap_us);
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

  VideoPlayClientConfig config_;
  RuntimeLogger logger_;
  RuntimeMetricsWriter metrics_writer_;
  RuntimeAlertWriter alert_writer_;
  Status track_config_status_ = Status::Ok();
  std::vector<VideoTrackConfig> track_configs_;
  uint32_t primary_track_id_ = 0;
  std::unordered_map<uint32_t, TrackState> track_states_;
  std::unordered_map<uint32_t, uint32_t> sender_ssrc_to_track_id_;
  QosSnapshot snapshot_;
  bool started_ = false;
  int64_t last_process_tick_time_us_ = -1;
  int64_t last_rtp_input_time_us_ = -1;
};

}  // namespace

std::unique_ptr<VideoPlayClient> CreateVideoPlayClient(
    const VideoPlayClientConfig& config) {
  return std::make_unique<WebRtcVideoPlayClient>(config);
}

}  // namespace webrtc_qos
