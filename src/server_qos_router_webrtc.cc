#include "webrtc_qos/server_qos_router.h"

#include <algorithm>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <unordered_map>
#include <utility>
#include <vector>

#include "compound_rtcp.h"
#include "runtime_logger.h"
#include "video_track_config_utils.h"
#include "webrtc_qos/rate_cap.h"
#include "webrtc_qos/rtcp_adapter.h"
#include "webrtc_qos/rtp_packet_adapter.h"
#include "webrtc_qos/transport_packet_history.h"

namespace webrtc_qos {
namespace {

constexpr uint32_t kServerRelayHopId = 1;
constexpr size_t kMaxTwccFeedbackPackets = 64;

Status InvalidArgument(const char* message) {
  return Status::Error(StatusCode::kInvalidArgument, message);
}

TransportPacketView MakePacketView(const std::vector<uint8_t>& bytes,
                                   const TransportIds& ids,
                                   TransportPacketKind kind,
                                   int64_t send_time_us,
                                   bool retransmission,
                                   bool padding = false) {
  TransportPacketView view;
  view.bytes = bytes.data();
  view.size = bytes.size();
  view.metadata.ids = ids;
  view.metadata.kind = kind;
  view.metadata.send_time_us = send_time_us;
  view.metadata.retransmission = retransmission;
  view.metadata.padding = padding;
  return view;
}

bool HasRtpPadding(const uint8_t* rtp_bytes, size_t rtp_size) {
  return rtp_bytes != nullptr && rtp_size > 0 && (rtp_bytes[0] & 0x20) != 0;
}

uint32_t ResolveServerFeedbackSsrc(const SessionConfig& session) {
  if (session.rtcp.server_feedback_ssrc != 0) {
    return session.rtcp.server_feedback_ssrc;
  }
  uint32_t candidate = session.ids.sender_ssrc ^ 0x5a5a5a5au;
  if (candidate == 0 || candidate == session.ids.receiver_id ||
      candidate == session.ids.sender_ssrc) {
    candidate = 0x7f000001u;
  }
  if (candidate == session.ids.receiver_id ||
      candidate == session.ids.sender_ssrc) {
    candidate ^= 0x01010101u;
  }
  return candidate != 0 ? candidate : 1u;
}

}  // namespace

class WebRtcServerQosRouter final : public ServerQosRouter {
 public:
  explicit WebRtcServerQosRouter(ServerQosRouterConfig config)
      : config_(std::move(config)),
        logger_(config_.logging, "server"),
        packet_history_(TransportPacketHistoryConfig{1000, 3000, 4096}) {
    track_config_status_ =
        ResolveVideoTrackConfigs(config_.session, &track_configs_);
    if (track_config_status_) {
      for (const auto& track_config : track_configs_) {
        sender_ssrc_to_ids_[track_config.ids.sender_ssrc] = track_config.ids;
      }
      primary_sender_ssrc_ =
          track_configs_.empty() ? config_.session.ids.sender_ssrc
                                 : track_configs_.front().ids.sender_ssrc;
    }
  }

  Status Start() override {
    if (!config_.sender_output || !config_.receiver_output) {
      Status status = InvalidArgument(
          "ServerQosRouter requires sender_output and receiver_output");
      logger_.Error("start_failed", config_.session.ids, status);
      return status;
    }
    if (!track_config_status_) {
      logger_.Error("start_failed", config_.session.ids, track_config_status_);
      return track_config_status_;
    }
    started_ = true;
    logger_.Info("start", config_.session.ids);
    return Status::Ok();
  }

  Status Stop() override {
    started_ = false;
    logger_.Info("stop", config_.session.ids);
    logger_.Flush();
    return Status::Ok();
  }

  Status OnSenderRtp(const uint8_t* rtp_bytes,
                     size_t rtp_size,
                     int64_t receive_time_us) override {
    if (!started_) {
      Status status = Status::Error(StatusCode::kUnsupported,
                                    "ServerQosRouter is not started");
      logger_.Warn("sender_rtp_before_start", config_.session.ids, status);
      return status;
    }
    RtpPacketAdapterParsedPacket parsed;
    if (!ParseRtpPacket(rtp_bytes, rtp_size, LegacyRtpConfig(), &parsed)) {
      Status status = Status::Error(StatusCode::kMalformedPacket,
                                    "failed to parse sender RTP");
      logger_.Warn("malformed_rtp", config_.session.ids, status);
      return status;
    }
    const bool padding = HasRtpPadding(rtp_bytes, rtp_size);
    std::vector<uint8_t> copy(rtp_bytes, rtp_bytes + rtp_size);
    if (!padding) {
      packet_history_.Store(
          TransportPacketHistoryKey{kServerRelayHopId, parsed.ssrc,
                                    parsed.sequence_number},
          copy.data(), copy.size(), receive_time_us, false);
      packet_history_.Prune(receive_time_us, last_downlink_quality_.rtt_ms);
    }
    if (parsed.transport_sequence_number.has_value()) {
      RecordTwccPacket(*parsed.transport_sequence_number, receive_time_us);
    }
    Status relay_status = config_.receiver_output(
        MakePacketView(copy, TrackIdsForSsrc(parsed.ssrc),
                       TransportPacketKind::kRtp, receive_time_us, false,
                       padding));
    if (!relay_status) {
      logger_.Error("receiver_output_failed", TrackIdsForSsrc(parsed.ssrc),
                    relay_status);
      return relay_status;
    }
    return MaybeSendUplinkTwcc(receive_time_us);
  }

  Status OnSenderRtcp(const uint8_t* rtcp_bytes,
                      size_t rtcp_size,
                      int64_t receive_time_us) override {
    if (!started_) {
      Status status = Status::Error(StatusCode::kUnsupported,
                                    "ServerQosRouter is not started");
      logger_.Warn("sender_rtcp_before_start", config_.session.ids, status);
      return status;
    }
    if (rtcp_bytes == nullptr || rtcp_size == 0) {
      Status status = InvalidArgument("empty sender RTCP");
      logger_.Warn("malformed_rtcp", config_.session.ids, status);
      return status;
    }
    RtcpPacketIterationStats iteration_stats;
    Status parse_status = ForEachSupportedRtcpPacket(
        rtcp_bytes, rtcp_size,
        [&](const uint8_t* packet_bytes, size_t packet_size,
            const RtcpAdapterParsedPacket& parsed) -> Status {
          if (parsed.type == RtcpAdapterPacketType::kSenderReport) {
            RecordSenderReport(parsed.sender_report, receive_time_us);
          }
          std::vector<uint8_t> copy(packet_bytes, packet_bytes + packet_size);
          const TransportIds ids = TrackIdsForSsrc(PacketMediaSsrc(parsed));
          Status status = config_.receiver_output(MakePacketView(
              copy, ids, TransportPacketKind::kRtcp, receive_time_us, false));
          if (!status) {
            logger_.Error("receiver_output_failed", ids, status);
          }
          return status;
        },
        &iteration_stats);
    if (!parse_status) {
      logger_.Warn("malformed_rtcp", config_.session.ids, parse_status);
      return parse_status;
    }
    snapshot_.unsupported_rtcp_packet_count +=
        static_cast<uint32_t>(iteration_stats.unsupported_packets);
    if (iteration_stats.unsupported_packets > 0) {
      logger_.Warn("unsupported_rtcp_drop", config_.session.ids,
                   Status::Error(StatusCode::kUnsupported,
                                 "unsupported sender RTCP packet dropped"));
    }
    return MaybeSendReceiverReport(receive_time_us);
  }

  Status OnReceiverRtcp(uint32_t receiver_id,
                        const uint8_t* rtcp_bytes,
                        size_t rtcp_size,
                        int64_t receive_time_us) override {
    if (!started_) {
      Status status = Status::Error(StatusCode::kUnsupported,
                                    "ServerQosRouter is not started");
      logger_.Warn("receiver_rtcp_before_start", config_.session.ids, status);
      return status;
    }
    if (rtcp_bytes == nullptr || rtcp_size == 0) {
      Status status = InvalidArgument("empty receiver RTCP");
      logger_.Warn("malformed_rtcp", config_.session.ids, status);
      return status;
    }

    RtcpPacketIterationStats iteration_stats;
    Status status = ForEachSupportedRtcpPacket(
        rtcp_bytes, rtcp_size,
        [&](const uint8_t* packet_bytes, size_t packet_size,
            const RtcpAdapterParsedPacket& parsed) -> Status {
          if (parsed.type == RtcpAdapterPacketType::kNack) {
            return HandleNack(receiver_id, parsed.nack, receive_time_us);
          }
          TransportIds ids = TrackIdsForSsrc(PacketMediaSsrc(parsed));
          ids.receiver_id = receiver_id;
          if (parsed.type == RtcpAdapterPacketType::kPli) {
            ++snapshot_.pli_count;
          }
          std::vector<uint8_t> copy(packet_bytes, packet_bytes + packet_size);
          Status status = config_.sender_output(MakePacketView(
              copy, ids, TransportPacketKind::kRtcp, receive_time_us, false));
          if (!status) {
            logger_.Error("sender_output_failed", ids, status);
          }
          return status;
        },
        &iteration_stats);
    if (!status) {
      logger_.Warn("malformed_rtcp", config_.session.ids, status);
    }
    if (status) {
      snapshot_.unsupported_rtcp_packet_count +=
          static_cast<uint32_t>(iteration_stats.unsupported_packets);
      if (iteration_stats.unsupported_packets > 0) {
        logger_.Warn("unsupported_rtcp_drop", config_.session.ids,
                     Status::Error(StatusCode::kUnsupported,
                                   "unsupported receiver RTCP packet dropped"));
      }
    }
    return status;
  }

  Status OnDownlinkQuality(const DownlinkQuality& quality) override {
    ++rate_cap_seq_;
    const uint32_t receiver_id = ReceiverIdForQuality(quality);
    DownlinkQuality stored_quality = quality;
    stored_quality.ids = config_.session.ids;
    stored_quality.ids.receiver_id = receiver_id;
    last_downlink_quality_ = stored_quality;
    receiver_states_[receiver_id] =
        ReceiverState{stored_quality, BuildReceiverRateCap(stored_quality)};
    logger_.Info("downlink_quality_update", stored_quality.ids);
    return Status::Ok();
  }

  SenderRateCap CurrentSenderRateCap(int64_t now_us) const override {
    const auto selected = SelectWorstReceiver(now_us);
    if (!selected.has_value()) {
      return UnlimitedSenderRateCap(config_.session.ids, rate_cap_seq_, now_us);
    }
    SenderRateCap cap = selected->cap;
    if (receiver_states_.size() > 1) {
      cap.reason_code = static_cast<uint16_t>(RateCapReason::kWorstReceiver);
    }
    return cap;
  }

  QosSnapshot GetQosSnapshot(int64_t now_us) const override {
    QosSnapshot out = snapshot_;
    out.ids = config_.session.ids;
    out.report_time_us = static_cast<uint64_t>(std::max<int64_t>(0, now_us));
    const auto selected = SelectWorstReceiver(now_us);
    out.downlink_quality =
        selected.has_value() ? selected->quality : last_downlink_quality_;
    out.sender_rates.sender_rate_cap_bps =
        CurrentSenderRateCap(now_us).cap_bps;
    return out;
  }

 private:
  struct ReceiverState {
    DownlinkQuality quality;
    SenderRateCap cap;
  };

  struct SenderReportState {
    uint32_t last_sr_lsr = 0;
    int64_t receive_time_us = 0;
  };

  RtpPacketAdapterConfig LegacyRtpConfig() const {
    RtpPacketAdapterConfig config;
    config.payload_type = config_.session.h264.payload_type;
    config.transport_sequence_extension_id = config_.session.twcc.extension_id;
    config.enable_transport_sequence_extension = true;
    return config;
  }

  static uint32_t PacketMediaSsrc(const RtcpAdapterParsedPacket& parsed) {
    switch (parsed.type) {
      case RtcpAdapterPacketType::kSenderReport:
        return parsed.sender_report.sender_ssrc;
      case RtcpAdapterPacketType::kReceiverReport:
        if (!parsed.receiver_report.report_blocks.empty()) {
          return parsed.receiver_report.report_blocks.front().media_ssrc;
        }
        return 0;
      case RtcpAdapterPacketType::kTransportFeedback:
        return parsed.transport_feedback.media_ssrc;
      case RtcpAdapterPacketType::kNack:
        return parsed.nack.media_ssrc;
      case RtcpAdapterPacketType::kPli:
        return parsed.pli.media_ssrc;
      default:
        return 0;
    }
  }

  TransportIds TrackIdsForSsrc(uint32_t sender_ssrc) const {
    auto it = sender_ssrc_to_ids_.find(sender_ssrc);
    if (it != sender_ssrc_to_ids_.end()) {
      return it->second;
    }
    TransportIds ids = config_.session.ids;
    ids.sender_ssrc = sender_ssrc;
    if (ids.source_id == 0) {
      ids.source_id = ids.stream_id;
    }
    ids.track_id = sender_ssrc;
    return ids;
  }

  uint32_t ReceiverIdForQuality(const DownlinkQuality& quality) const {
    if (quality.ids.receiver_id != 0) {
      return quality.ids.receiver_id;
    }
    return config_.session.ids.receiver_id;
  }

  SenderRateCap BuildReceiverRateCap(const DownlinkQuality& quality) const {
    SenderRateCap cap = UnlimitedSenderRateCap(
        config_.session.ids, rate_cap_seq_,
        static_cast<int64_t>(quality.report_time_us));
    cap.ids.receiver_id = quality.ids.receiver_id;
    if (quality.fraction_lost_q8 >= 26 || quality.video_drop_frames > 0) {
      cap.cap_bps =
          std::max<uint32_t>(config_.session.min_bitrate_bps,
                             config_.session.start_bitrate_bps / 2);
      cap.expire_ms = 1000;
      cap.reason_code = static_cast<uint16_t>(RateCapReason::kReceiverLoss);
    }
    return cap;
  }

  bool IsFiniteActiveCap(const SenderRateCap& cap, int64_t now_us) const {
    if (IsUnlimitedRateCap(cap)) {
      return false;
    }
    if (cap.expire_ms == 0) {
      return true;
    }
    return now_us - cap.receive_time_us <=
           static_cast<int64_t>(cap.expire_ms) * 1000;
  }

  static bool IsMoreSevere(const ReceiverState& lhs,
                           const ReceiverState& rhs) {
    if (lhs.cap.cap_bps != rhs.cap.cap_bps) {
      return lhs.cap.cap_bps < rhs.cap.cap_bps;
    }
    if (lhs.quality.fraction_lost_q8 != rhs.quality.fraction_lost_q8) {
      return lhs.quality.fraction_lost_q8 > rhs.quality.fraction_lost_q8;
    }
    if (lhs.quality.video_drop_frames != rhs.quality.video_drop_frames) {
      return lhs.quality.video_drop_frames > rhs.quality.video_drop_frames;
    }
    return lhs.quality.ids.receiver_id < rhs.quality.ids.receiver_id;
  }

  std::optional<ReceiverState> SelectWorstReceiver(int64_t now_us) const {
    std::optional<ReceiverState> selected;
    for (const auto& item : receiver_states_) {
      const ReceiverState& state = item.second;
      if (!IsFiniteActiveCap(state.cap, now_us)) {
        continue;
      }
      if (!selected.has_value() || IsMoreSevere(state, *selected)) {
        selected = state;
      }
    }
    return selected;
  }

  Status HandleNack(uint32_t receiver_id,
                    const RtcpAdapterNack& nack,
                    int64_t receive_time_us) {
    std::vector<uint16_t> missing_packet_ids;
    for (uint16_t packet_id : nack.packet_ids) {
      ++snapshot_.nack_count;
      auto found = packet_history_.Find(TransportPacketHistoryKey{
          kServerRelayHopId, nack.media_ssrc, packet_id});
      if (!found.has_value()) {
        missing_packet_ids.push_back(packet_id);
        continue;
      }
      ++snapshot_.retransmission_count;
      TransportIds ids = TrackIdsForSsrc(nack.media_ssrc);
      ids.receiver_id = receiver_id;
      Status status = config_.receiver_output(MakePacketView(
          found->rtp_bytes, ids, TransportPacketKind::kRtp, receive_time_us,
          true));
      if (!status) {
        logger_.Error("receiver_output_failed", ids, status);
        return status;
      }
      logger_.Info("local_retransmission_hit", ids);
    }
    packet_history_.Prune(receive_time_us, last_downlink_quality_.rtt_ms);

    if (missing_packet_ids.empty()) {
      return Status::Ok();
    }
    logger_.Info("local_retransmission_miss", TrackIdsForSsrc(nack.media_ssrc));
    RtcpAdapterNack forwarded_nack = nack;
    forwarded_nack.packet_ids = std::move(missing_packet_ids);
    std::vector<uint8_t> copy;
    TransportIds ids = TrackIdsForSsrc(nack.media_ssrc);
    ids.receiver_id = receiver_id;
    if (!BuildRtcpNack(forwarded_nack, &copy)) {
      Status status = Status::Error(StatusCode::kInternalError,
                                    "failed to rebuild forwarded RTCP NACK");
      logger_.Error("rtcp_build_failed", ids, status);
      return status;
    }
    Status status = config_.sender_output(
        MakePacketView(copy, ids, TransportPacketKind::kRtcp, receive_time_us,
                       false));
    if (!status) {
      logger_.Error("sender_output_failed", ids, status);
    }
    return status;
  }

  void RecordTwccPacket(uint16_t transport_sequence_number,
                        int64_t receive_time_us) {
    if (!twcc_base_sequence_.has_value()) {
      twcc_base_sequence_ = transport_sequence_number;
      twcc_base_time_us_ = receive_time_us;
    }
    RtcpAdapterTransportFeedbackPacket packet;
    packet.sequence_number = transport_sequence_number;
    packet.delta_since_base_us =
        std::max<int64_t>(0, receive_time_us - twcc_base_time_us_);
    pending_twcc_packets_.push_back(packet);
  }

  Status MaybeSendUplinkTwcc(int64_t now_us) {
    if (pending_twcc_packets_.empty() || !twcc_base_sequence_.has_value()) {
      return Status::Ok();
    }
    const int64_t interval_us =
        static_cast<int64_t>(config_.session.twcc.feedback_interval_ms) * 1000;
    if (last_twcc_send_time_us_ >= 0 &&
        now_us - last_twcc_send_time_us_ < interval_us &&
        pending_twcc_packets_.size() < kMaxTwccFeedbackPackets) {
      return Status::Ok();
    }

    RtcpAdapterTransportFeedback feedback;
    feedback.sender_ssrc = ResolveServerFeedbackSsrc(config_.session);
    feedback.media_ssrc = primary_sender_ssrc_;
    feedback.base_sequence = *twcc_base_sequence_;
    feedback.base_time_us = twcc_base_time_us_;
    feedback.feedback_sequence = next_twcc_feedback_sequence_++;
    feedback.packets = pending_twcc_packets_;

    std::vector<uint8_t> rtcp_bytes;
    if (!BuildRtcpTransportFeedback(feedback, &rtcp_bytes)) {
      Status status = Status::Error(StatusCode::kInternalError,
                                    "failed to build uplink TWCC");
      logger_.Error("rtcp_build_failed", config_.session.ids, status);
      return status;
    }
    pending_twcc_packets_.clear();
    twcc_base_sequence_.reset();
    twcc_base_time_us_ = 0;
    last_twcc_send_time_us_ = now_us;
    Status status = config_.sender_output(
        MakePacketView(rtcp_bytes, config_.session.ids,
                       TransportPacketKind::kRtcp, now_us, false));
    if (!status) {
      logger_.Error("sender_output_failed", config_.session.ids, status);
    }
    return status;
  }

  void RecordSenderReport(const RtcpAdapterSenderReport& sender_report,
                          int64_t receive_time_us) {
    sender_report_states_[sender_report.sender_ssrc] = SenderReportState{
        ((sender_report.ntp_seconds & 0x0000ffffu) << 16) |
            (sender_report.ntp_fractions >> 16),
        receive_time_us};
  }

  Status MaybeSendReceiverReport(int64_t now_us) {
    if (sender_report_states_.empty()) {
      return Status::Ok();
    }
    const int64_t interval_us =
        static_cast<int64_t>(config_.session.rtcp.sr_rr_interval_ms) * 1000;
    if (last_rr_send_time_us_ >= 0 &&
        now_us - last_rr_send_time_us_ < interval_us) {
      return Status::Ok();
    }

    RtcpAdapterReceiverReport rr;
    rr.sender_ssrc = ResolveServerFeedbackSsrc(config_.session);
    for (const auto& item : sender_report_states_) {
      RtcpAdapterReportBlock block;
      block.media_ssrc = item.first;
      block.last_sr = item.second.last_sr_lsr;
      const int64_t delay_us =
          std::max<int64_t>(0, now_us - item.second.receive_time_us);
      block.delay_since_last_sr =
          static_cast<uint32_t>((static_cast<uint64_t>(delay_us) * 65536) /
                                1000000);
      rr.report_blocks.push_back(block);
    }

    std::vector<uint8_t> rtcp_bytes;
    if (!BuildRtcpReceiverReport(rr, &rtcp_bytes)) {
      Status status = Status::Error(StatusCode::kInternalError,
                                    "failed to build RTCP RR");
      logger_.Error("rtcp_build_failed", config_.session.ids, status);
      return status;
    }
    last_rr_send_time_us_ = now_us;
    Status status = config_.sender_output(
        MakePacketView(rtcp_bytes, config_.session.ids,
                       TransportPacketKind::kRtcp, now_us, false));
    if (!status) {
      logger_.Error("sender_output_failed", config_.session.ids, status);
    }
    return status;
  }

  ServerQosRouterConfig config_;
  RuntimeLogger logger_;
  Status track_config_status_ = Status::Ok();
  std::vector<VideoTrackConfig> track_configs_;
  std::unordered_map<uint32_t, TransportIds> sender_ssrc_to_ids_;
  uint32_t primary_sender_ssrc_ = 0;
  TransportPacketHistory packet_history_;
  DownlinkQuality last_downlink_quality_;
  std::map<uint32_t, ReceiverState> receiver_states_;
  std::unordered_map<uint32_t, SenderReportState> sender_report_states_;
  QosSnapshot snapshot_;
  std::vector<RtcpAdapterTransportFeedbackPacket> pending_twcc_packets_;
  std::optional<uint16_t> twcc_base_sequence_;
  int64_t twcc_base_time_us_ = 0;
  int64_t last_twcc_send_time_us_ = -1;
  int64_t last_rr_send_time_us_ = -1;
  uint32_t rate_cap_seq_ = 0;
  uint8_t next_twcc_feedback_sequence_ = 1;
  bool started_ = false;
};

std::unique_ptr<ServerQosRouter> CreateServerQosRouter(
    const ServerQosRouterConfig& config) {
  return std::make_unique<WebRtcServerQosRouter>(config);
}

}  // namespace webrtc_qos
