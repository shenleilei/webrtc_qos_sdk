#include "webrtc_qos/video_play_client.h"

#include <algorithm>
#include <cstdint>
#include <memory>
#include <utility>
#include <vector>

#include "compound_rtcp.h"
#include "webrtc_qos/nack_requester_adapter.h"
#include "webrtc_qos/rtcp_adapter.h"
#include "webrtc_qos/rtp_packet_adapter.h"
#include "webrtc_qos/video_jitter_adapter.h"

namespace webrtc_qos {
namespace {

Status InvalidArgument(const char* message) {
  return Status::Error(StatusCode::kInvalidArgument, message);
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
        nack_requester_(NackRequesterAdapterConfig{100}),
        jitter_(VideoJitterAdapterConfig{config_.session.h264.payload_type,
                                         config_.session.ids.sender_ssrc}) {}

  Status Start() override {
    if (!config_.decoded_access_unit_output) {
      return InvalidArgument(
          "VideoPlayClient requires decoded_access_unit_output");
    }
    if (!config_.transport_output) {
      return InvalidArgument("VideoPlayClient requires transport_output");
    }
    started_ = true;
    return Status::Ok();
  }

  Status Stop() override {
    started_ = false;
    return Status::Ok();
  }

  Status Process(int64_t now_us) override {
    if (!started_) {
      return Status::Error(StatusCode::kUnsupported,
                           "VideoPlayClient is not started");
    }
    return EmitNackRequesterFeedback(now_us);
  }

  Status OnRtpPacket(const uint8_t* rtp_bytes,
                     size_t rtp_size,
                     int64_t receive_time_us) override {
    if (!started_) {
      return Status::Error(StatusCode::kUnsupported,
                           "VideoPlayClient is not started");
    }
    if (rtp_bytes == nullptr || rtp_size == 0) {
      return InvalidArgument("empty RTP packet");
    }

    RtpPacketAdapterParsedPacket parsed;
    if (!ParseRtpPacket(rtp_bytes, rtp_size, RtpConfig(), &parsed)) {
      return Status::Error(StatusCode::kMalformedPacket,
                           "failed to parse RTP packet");
    }
    nack_requester_.OnReceivedPacket(parsed.sequence_number,
                                     /*is_recovered=*/false);
    Status feedback_status = EmitNackRequesterFeedback(receive_time_us);
    if (!feedback_status) {
      return feedback_status;
    }
    if (HasRtpPadding(rtp_bytes, rtp_size)) {
      return Status::Ok();
    }

    VideoJitterPacket jitter_packet;
    jitter_packet.payload_type = parsed.payload_type;
    jitter_packet.marker = parsed.marker;
    jitter_packet.sequence_number = parsed.sequence_number;
    jitter_packet.rtp_timestamp = parsed.timestamp;
    jitter_packet.ssrc = parsed.ssrc;
    jitter_packet.arrival_time_us = receive_time_us;
    jitter_packet.payload = parsed.payload.data();
    jitter_packet.payload_size = parsed.payload.size();

    auto frames = jitter_.InsertPacket(jitter_packet);
    for (const auto& frame : frames) {
      AnnexBAccessUnitView view;
      view.bytes = frame.annexb_access_unit.data();
      view.size = frame.annexb_access_unit.size();
      view.capture_time_us = RtpTimestampToCaptureTimeUs(frame.rtp_timestamp);
      view.keyframe = frame.keyframe;
      Status status = config_.decoded_access_unit_output(view);
      if (!status) {
        return status;
      }
      ++decoded_frames_;
    }
    return Status::Ok();
  }

  Status OnRtcpPacket(const uint8_t* rtcp_bytes,
                      size_t rtcp_size,
                      int64_t receive_time_us) override {
    return ForEachSupportedRtcpPacket(
        rtcp_bytes, rtcp_size,
        [&](const uint8_t*, size_t, const RtcpAdapterParsedPacket& parsed) {
          if (parsed.type != RtcpAdapterPacketType::kReceiverReport) {
            return Status::Ok();
          }
          for (const auto& block : parsed.receiver_report.report_blocks) {
            if (block.media_ssrc != config_.session.ids.sender_ssrc) {
              continue;
            }
            snapshot_.downlink_quality.fraction_lost_q8 = block.fraction_lost;
            const uint32_t rtt_ms = EstimateRttMsFromReceiverReport(
                block.last_sr, block.delay_since_last_sr, receive_time_us);
            if (rtt_ms > 0) {
              nack_requester_.UpdateRtt(rtt_ms);
              snapshot_.downlink_quality.rtt_ms =
                  static_cast<uint16_t>(std::min<uint32_t>(rtt_ms, 0xffffu));
            }
          }
          return Status::Ok();
        });
  }

  QosSnapshot GetQosSnapshot(int64_t now_us) const override {
    QosSnapshot out = snapshot_;
    out.ids = config_.session.ids;
    out.report_time_us = static_cast<uint64_t>(std::max<int64_t>(0, now_us));
    const auto stats = jitter_.stats();
    // The minimal jitter adapter only exposes cumulative counters, not
    // instantaneous queue depth. Keep this field at 0 until the adapter exports
    // a real decodable queue depth metric.
    out.downlink_quality.video_decodable_queue_depth = 0;
    out.dropped_frames = static_cast<uint32_t>(stats.packets_rejected);
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

  int64_t RtpTimestampToCaptureTimeUs(uint32_t rtp_timestamp) {
    if (!has_first_rtp_timestamp_) {
      first_rtp_timestamp_ = rtp_timestamp;
      has_first_rtp_timestamp_ = true;
    }
    const uint32_t timestamp_delta = rtp_timestamp - first_rtp_timestamp_;
    return static_cast<int64_t>(1000000) +
           (static_cast<int64_t>(timestamp_delta) * 1000000) /
               kVideoClockRateHz;
  }

  Status EmitNackRequesterFeedback(int64_t now_us) {
    nack_requester_.ProcessNacks(now_us);
    for (const auto& event : nack_requester_.DrainEvents()) {
      std::vector<uint8_t> rtcp_bytes;
      if (event.type == NackRequesterAdapterEventType::kNack) {
        if (event.rtp_sequence_numbers.empty()) {
          continue;
        }
        RtcpAdapterNack nack;
        nack.sender_ssrc = ResolveReceiverFeedbackSsrc(config_.session);
        nack.media_ssrc = config_.session.ids.sender_ssrc;
        nack.packet_ids = event.rtp_sequence_numbers;
        if (!BuildRtcpNack(nack, &rtcp_bytes)) {
          return Status::Error(StatusCode::kInternalError,
                               "failed to build RTCP NACK");
        }
        ++snapshot_.nack_count;
      } else if (event.type ==
                 NackRequesterAdapterEventType::kKeyFrameRequest) {
        RtcpAdapterPli pli;
        pli.sender_ssrc = ResolveReceiverFeedbackSsrc(config_.session);
        pli.media_ssrc = config_.session.ids.sender_ssrc;
        if (!BuildRtcpPli(pli, &rtcp_bytes)) {
          return Status::Error(StatusCode::kInternalError,
                               "failed to build RTCP PLI");
        }
        ++snapshot_.pli_count;
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

  VideoPlayClientConfig config_;
  NackRequesterAdapter nack_requester_;
  VideoJitterAdapter jitter_;
  QosSnapshot snapshot_;
  bool started_ = false;
  uint32_t decoded_frames_ = 0;
  bool has_first_rtp_timestamp_ = false;
  uint32_t first_rtp_timestamp_ = 0;
};

}  // namespace

std::unique_ptr<VideoPlayClient> CreateVideoPlayClient(
    const VideoPlayClientConfig& config) {
  return std::make_unique<WebRtcVideoPlayClient>(config);
}

}  // namespace webrtc_qos
