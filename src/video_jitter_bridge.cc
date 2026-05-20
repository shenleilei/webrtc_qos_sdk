#include "webrtc_qos/video_jitter_bridge.h"

#include <deque>
#include <memory>
#include <unordered_set>
#include <utility>

#include "webrtc_qos/video_jitter_adapter.h"

namespace webrtc_qos {
namespace {

class WebRtcVideoJitterBackend final : public VideoJitterBackend {
 public:
  explicit WebRtcVideoJitterBackend(const VideoJitterPlayerConfig& config)
      : adapter_(VideoJitterAdapterConfig{kH264PayloadType,
                                          config.sender_ssrc}) {}

  Status InsertPacket(const RtpPacket& packet,
                      int64_t arrival_time_us) override {
    VideoJitterPacket adapter_packet;
    adapter_packet.payload_type = packet.payload_type;
    adapter_packet.marker = packet.marker;
    adapter_packet.sequence_number = packet.sequence_number;
    adapter_packet.rtp_timestamp = packet.timestamp;
    adapter_packet.ssrc = packet.ssrc;
    adapter_packet.arrival_time_us = arrival_time_us;
    adapter_packet.payload = packet.payload.data();
    adapter_packet.payload_size = packet.payload.size();

    std::vector<VideoJitterFrame> frames =
        adapter_.InsertPacket(adapter_packet);
    for (auto& adapter_frame : frames) {
      if (completed_timestamps_.find(adapter_frame.rtp_timestamp) !=
          completed_timestamps_.end()) {
        ++stats_.dropped_frames;
        continue;
      }
      EncodedVideoFrame frame;
      frame.annexb_access_unit = std::move(adapter_frame.annexb_access_unit);
      frame.rtp_timestamp = adapter_frame.rtp_timestamp;
      frame.keyframe = adapter_frame.keyframe;
      frame.frame_type = adapter_frame.keyframe ? VideoFrameType::kIdr
                                                : VideoFrameType::kP;
      completed_.push_back(std::move(frame));
      completed_timestamps_.insert(adapter_frame.rtp_timestamp);
      ++stats_.completed_frames;
    }
    stats_.decodable_queue_depth = static_cast<uint16_t>(completed_.size());
    stats_.jitter_frames = stats_.decodable_queue_depth;
    const VideoJitterAdapterStats adapter_stats = adapter_.stats();
    if (adapter_stats.packets_rejected > last_adapter_packets_rejected_) {
      stats_.dropped_frames += static_cast<uint32_t>(
          adapter_stats.packets_rejected - last_adapter_packets_rejected_);
      last_adapter_packets_rejected_ = adapter_stats.packets_rejected;
    }
    return Status::Ok();
  }

  bool HasFrame() const override { return !completed_.empty(); }

  Status PopFrame(EncodedVideoFrame* frame) override {
    if (!frame) {
      return Status::Error(StatusCode::kInvalidArgument, "null output frame");
    }
    if (completed_.empty()) {
      return Status::Error(StatusCode::kInvalidArgument, "no completed frame");
    }
    *frame = std::move(completed_.front());
    completed_.pop_front();
    stats_.decodable_queue_depth = static_cast<uint16_t>(completed_.size());
    stats_.jitter_frames = stats_.decodable_queue_depth;
    return Status::Ok();
  }

  VideoJitterStats GetStats() const override { return stats_; }

 private:
  VideoJitterAdapter adapter_;
  std::deque<EncodedVideoFrame> completed_;
  std::unordered_set<uint32_t> completed_timestamps_;
  VideoJitterStats stats_;
  uint32_t last_adapter_packets_rejected_ = 0;
};

}  // namespace

std::unique_ptr<VideoJitterBackend> CreateWebRtcVideoJitterBackend(
    const VideoJitterPlayerConfig& config) {
  return std::make_unique<WebRtcVideoJitterBackend>(config);
}

VideoJitterPlayer CreateWebRtcVideoJitterPlayer(
    const VideoJitterPlayerConfig& config) {
  return VideoJitterPlayer(config, CreateWebRtcVideoJitterBackend(config));
}

}  // namespace webrtc_qos
