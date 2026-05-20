#pragma once

#include <deque>
#include <memory>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

struct VideoJitterPlayerConfig {
  uint32_t sender_ssrc = 0;
};

struct VideoJitterStats {
  uint32_t completed_frames = 0;
  uint32_t dropped_frames = 0;
  uint16_t decodable_queue_depth = 0;
  uint16_t jitter_frames = 0;
};

class VideoJitterBackend {
 public:
  virtual ~VideoJitterBackend() = default;

  virtual Status InsertPacket(const RtpPacket& packet,
                              int64_t arrival_time_us) = 0;
  virtual bool HasFrame() const = 0;
  virtual Status PopFrame(EncodedVideoFrame* frame) = 0;
  virtual VideoJitterStats GetStats() const = 0;
};

class VideoJitterPlayer {
 public:
  explicit VideoJitterPlayer(VideoJitterPlayerConfig config);
  VideoJitterPlayer(VideoJitterPlayerConfig config,
                    std::unique_ptr<VideoJitterBackend> backend);

  VideoJitterPlayer(VideoJitterPlayer&&) noexcept = default;
  VideoJitterPlayer& operator=(VideoJitterPlayer&&) noexcept = default;
  VideoJitterPlayer(const VideoJitterPlayer&) = delete;
  VideoJitterPlayer& operator=(const VideoJitterPlayer&) = delete;

  Status InsertPacket(const RtpPacket& packet);
  Status InsertPacket(const RtpPacket& packet, int64_t arrival_time_us);
  bool HasFrame() const;
  Status PopFrame(EncodedVideoFrame* frame);
  VideoJitterStats GetStats() const;

 private:
  struct PartialFrame {
    uint32_t timestamp = 0;
    std::vector<std::vector<uint8_t>> nalus;
    VideoFrameType frame_type = VideoFrameType::kUnknown;
    bool has_marker = false;
    bool corrupt = false;
  };

  Status InsertSingleNalu(const RtpPacket& packet);
  Status InsertFuA(const RtpPacket& packet);
  void CompleteFrame(uint32_t timestamp);

  VideoJitterPlayerConfig config_;
  PartialFrame current_;
  std::deque<EncodedVideoFrame> completed_;
  std::vector<uint8_t> cached_sps_;
  std::vector<uint8_t> cached_pps_;
  VideoJitterStats stats_;
  std::unique_ptr<VideoJitterBackend> backend_;
};

}  // namespace webrtc_qos
