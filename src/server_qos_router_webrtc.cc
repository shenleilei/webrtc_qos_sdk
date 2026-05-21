#include "webrtc_qos/server_qos_router.h"

#include <algorithm>
#include <cstdint>
#include <map>
#include <optional>
#include <memory>
#include <utility>
#include <vector>

#include "compound_rtcp.h"
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

TransportIds IdsForReceiver(const TransportIds& base_ids, uint32_t receiver_id) {
  TransportIds ids = base_ids;
  ids.receiver_id = receiver_id;
  return ids;
}

}  // namespace

class WebRtcServerQosRouter final : public ServerQosRouter {
 public:
  explicit WebRtcServerQosRouter(ServerQosRouterConfig config)
      : config_(std::move(config)),
        packet_history_(TransportPacketHistoryConfig{1000, 3000, 4096}) {}

  Status Start() override {
    if (!config_.sender_output || !config_.receiver_output) {
      return InvalidArgument(
          "ServerQosRouter requires sender_output and receiver_output");
    }
    started_ = true;
    return Status::Ok();
  }

  Status Stop() override {
    started_ = false;
    return Status::Ok();
  }

  Status OnSenderRtp(const uint8_t* rtp_bytes,
                     size_t rtp_size,
                     int64_t receive_time_us) override {
    if (!started_) {
      return Status::Error(StatusCode::kUnsupported,
                           "ServerQosRouter is not started");
    }
    RtpPacketAdapterParsedPacket parsed;
    if (!ParseRtpPacket(rtp_bytes, rtp_size, RtpConfig(), &parsed)) {
      return Status::Error(StatusCode::kMalformedPacket,
                           "failed to parse sender RTP");
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
        MakePacketView(copy, config_.session.ids, TransportPacketKind::kRtp,
                       receive_time_us, false, padding));
    if (!relay_status) {
      return relay_status;
    }
    return MaybeSendUplinkTwcc(receive_time_us);
  }

  Status OnSenderRtcp(const uint8_t* rtcp_bytes,
                      size_t rtcp_size,
                      int64_t receive_time_us) override {
    if (!started_) {
      return Status::Error(StatusCode::kUnsupported,
                           "ServerQosRouter is not started");
    }
    if (rtcp_bytes == nullptr || rtcp_size == 0) {
      return InvalidArgument("empty sender RTCP");
    }
    Status parse_status = ForEachSupportedRtcpPacket(
        rtcp_bytes, rtcp_size,
        [&](const uint8_t*, size_t, const RtcpAdapterParsedPacket& parsed) {
          if (parsed.type == RtcpAdapterPacketType::kSenderReport) {
            RecordSenderReport(parsed.sender_report, receive_time_us);
          }
          return Status::Ok();
        });
    if (!parse_status) {
      return parse_status;
    }
    std::vector<uint8_t> copy(rtcp_bytes, rtcp_bytes + rtcp_size);
    Status relay_status = config_.receiver_output(
        MakePacketView(copy, config_.session.ids, TransportPacketKind::kRtcp,
                       receive_time_us, false));
    if (!relay_status) {
      return relay_status;
    }
    return MaybeSendReceiverReport(receive_time_us);
  }

  Status OnReceiverRtcp(uint32_t receiver_id,
                        const uint8_t* rtcp_bytes,
                        size_t rtcp_size,
                        int64_t receive_time_us) override {
    if (!started_) {
      return Status::Error(StatusCode::kUnsupported,
                           "ServerQosRouter is not started");
    }
    if (rtcp_bytes == nullptr || rtcp_size == 0) {
      return InvalidArgument("empty receiver RTCP");
    }

    return ForEachSupportedRtcpPacket(
        rtcp_bytes, rtcp_size,
        [&](const uint8_t* packet_bytes, size_t packet_size,
            const RtcpAdapterParsedPacket& parsed) -> Status {
          if (parsed.type == RtcpAdapterPacketType::kNack) {
            return HandleNack(receiver_id, parsed.nack, receive_time_us);
          }
          if (parsed.type == RtcpAdapterPacketType::kPli) {
            ++snapshot_.pli_count;
          }
          std::vector<uint8_t> copy(packet_bytes, packet_bytes + packet_size);
          return config_.sender_output(
              MakePacketView(copy,
                             IdsForReceiver(config_.session.ids, receiver_id),
                             TransportPacketKind::kRtcp, receive_time_us,
                             false));
        });
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

  RtpPacketAdapterConfig RtpConfig() const {
    RtpPacketAdapterConfig config;
    config.payload_type = config_.session.h264.payload_type;
    config.transport_sequence_extension_id = config_.session.twcc.extension_id;
    config.enable_transport_sequence_extension = true;
    return config;
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
      Status status = config_.receiver_output(MakePacketView(
          found->rtp_bytes, IdsForReceiver(config_.session.ids, receiver_id),
          TransportPacketKind::kRtp, receive_time_us, true));
      if (!status) {
        return status;
      }
    }
    packet_history_.Prune(receive_time_us, last_downlink_quality_.rtt_ms);

    if (missing_packet_ids.empty()) {
      return Status::Ok();
    }
    RtcpAdapterNack forwarded_nack = nack;
    forwarded_nack.packet_ids = std::move(missing_packet_ids);
    std::vector<uint8_t> copy;
    if (!BuildRtcpNack(forwarded_nack, &copy)) {
      return Status::Error(StatusCode::kInternalError,
                           "failed to rebuild forwarded RTCP NACK");
    }
    return config_.sender_output(
        MakePacketView(copy, IdsForReceiver(config_.session.ids, receiver_id),
                       TransportPacketKind::kRtcp, receive_time_us, false));
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
    feedback.sender_ssrc = config_.session.ids.receiver_id;
    feedback.media_ssrc = config_.session.ids.sender_ssrc;
    feedback.base_sequence = *twcc_base_sequence_;
    feedback.base_time_us = twcc_base_time_us_;
    feedback.feedback_sequence = next_twcc_feedback_sequence_++;
    feedback.packets = pending_twcc_packets_;

    std::vector<uint8_t> rtcp_bytes;
    if (!BuildRtcpTransportFeedback(feedback, &rtcp_bytes)) {
      return Status::Error(StatusCode::kInternalError,
                           "failed to build uplink TWCC");
    }
    pending_twcc_packets_.clear();
    twcc_base_sequence_.reset();
    twcc_base_time_us_ = 0;
    last_twcc_send_time_us_ = now_us;
    return config_.sender_output(
        MakePacketView(rtcp_bytes, config_.session.ids,
                       TransportPacketKind::kRtcp, now_us, false));
  }

  void RecordSenderReport(const RtcpAdapterSenderReport& sender_report,
                          int64_t receive_time_us) {
    if (sender_report.sender_ssrc != config_.session.ids.sender_ssrc) {
      return;
    }
    last_sender_report_lsr_ =
        ((sender_report.ntp_seconds & 0x0000ffffu) << 16) |
        (sender_report.ntp_fractions >> 16);
    last_sender_report_receive_time_us_ = receive_time_us;
  }

  Status MaybeSendReceiverReport(int64_t now_us) {
    if (last_sender_report_lsr_ == 0) {
      return Status::Ok();
    }
    const int64_t interval_us =
        static_cast<int64_t>(config_.session.rtcp.sr_rr_interval_ms) * 1000;
    if (last_rr_send_time_us_ >= 0 &&
        now_us - last_rr_send_time_us_ < interval_us) {
      return Status::Ok();
    }

    RtcpAdapterReportBlock block;
    block.media_ssrc = config_.session.ids.sender_ssrc;
    block.last_sr = last_sender_report_lsr_;
    const int64_t delay_us =
        std::max<int64_t>(0, now_us - last_sender_report_receive_time_us_);
    block.delay_since_last_sr =
        static_cast<uint32_t>((static_cast<uint64_t>(delay_us) * 65536) /
                              1000000);

    RtcpAdapterReceiverReport rr;
    rr.sender_ssrc = config_.session.ids.receiver_id;
    rr.report_blocks.push_back(block);

    std::vector<uint8_t> rtcp_bytes;
    if (!BuildRtcpReceiverReport(rr, &rtcp_bytes)) {
      return Status::Error(StatusCode::kInternalError,
                           "failed to build RTCP RR");
    }
    last_rr_send_time_us_ = now_us;
    return config_.sender_output(
        MakePacketView(rtcp_bytes, config_.session.ids,
                       TransportPacketKind::kRtcp, now_us, false));
  }

  ServerQosRouterConfig config_;
  TransportPacketHistory packet_history_;
  DownlinkQuality last_downlink_quality_;
  std::map<uint32_t, ReceiverState> receiver_states_;
  QosSnapshot snapshot_;
  std::vector<RtcpAdapterTransportFeedbackPacket> pending_twcc_packets_;
  std::optional<uint16_t> twcc_base_sequence_;
  int64_t twcc_base_time_us_ = 0;
  int64_t last_twcc_send_time_us_ = -1;
  uint32_t last_sender_report_lsr_ = 0;
  int64_t last_sender_report_receive_time_us_ = 0;
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
