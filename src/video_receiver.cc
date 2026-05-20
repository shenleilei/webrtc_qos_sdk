#include "webrtc_qos/video_receiver.h"

namespace webrtc_qos {

VideoReceiver::VideoReceiver(VideoReceiverConfig config,
                             VideoReceiverCallbacks callbacks)
    : config_(config),
      callbacks_(std::move(callbacks)),
      observer_(ReceiverQosObserverConfig{config.ids, 200}),
      jitter_(VideoJitterPlayerConfig{config.ids.sender_ssrc}) {}

Status VideoReceiver::OnRtpPacket(const RtpPacket& packet, int64_t now_us) {
  observer_.OnRtpPacketReceived(packet, now_us);
  Status status = jitter_.InsertPacket(packet);
  if (!status) {
    RecoveryRequest request;
    request.type = RecoveryRequest::Type::kPli;
    request.sender_ssrc = config_.ids.sender_ssrc;
    request.reason = status.message;
    if (callbacks_.on_recovery_request) {
      callbacks_.on_recovery_request(request);
    }
    return status;
  }

  while (jitter_.HasFrame()) {
    EncodedVideoFrame frame;
    Status pop_status = jitter_.PopFrame(&frame);
    if (!pop_status) {
      return pop_status;
    }
    observer_.OnFrameDecoded(frame.rtp_timestamp);
    if (callbacks_.on_frame) {
      callbacks_.on_frame(frame);
    }
  }

  std::vector<uint16_t> missing = observer_.TakeMissingSequenceNumbers();
  if (!missing.empty() && callbacks_.on_recovery_request) {
    RecoveryRequest request;
    request.type = RecoveryRequest::Type::kNack;
    request.sender_ssrc = config_.ids.sender_ssrc;
    request.missing_rtp_sequence_numbers = std::move(missing);
    request.reason = "missing RTP sequence numbers";
    callbacks_.on_recovery_request(request);
  }
  return Status::Ok();
}

void VideoReceiver::SetDownlinkRttMs(uint16_t rtt_ms) {
  observer_.SetDownlinkRttMs(rtt_ms);
}

void VideoReceiver::MaybeReport(int64_t now_us) {
  if (!observer_.ShouldReport(now_us)) {
    return;
  }
  DownlinkQuality report = observer_.BuildReport(now_us);
  VideoJitterStats stats = jitter_.GetStats();
  report.video_jitter_frames = stats.jitter_frames;
  report.video_decodable_queue_depth = stats.decodable_queue_depth;
  report.video_drop_frames = stats.dropped_frames;
  if (callbacks_.on_downlink_quality) {
    callbacks_.on_downlink_quality(report);
  }
}

VideoJitterStats VideoReceiver::GetJitterStats() const {
  return jitter_.GetStats();
}

}  // namespace webrtc_qos
