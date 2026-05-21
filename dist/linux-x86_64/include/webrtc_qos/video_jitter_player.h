#pragma once

#include <deque>
#include <map>
#include <memory>
#include <set>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

struct VideoJitterPlayerConfig {
  uint32_t sender_ssrc = 0;
  uint32_t max_reorder_delay_ms = 0;
  uint16_t max_reorder_queue_frames = 0;
  uint32_t max_contiguous_frame_gap_ms = 250;
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
  ~VideoJitterPlayer();

  VideoJitterPlayer(VideoJitterPlayer&&) noexcept;
  VideoJitterPlayer& operator=(VideoJitterPlayer&&) noexcept;
  VideoJitterPlayer(const VideoJitterPlayer&) = delete;
  VideoJitterPlayer& operator=(const VideoJitterPlayer&) = delete;

  Status InsertPacket(const RtpPacket& packet);
  Status InsertPacket(const RtpPacket& packet, int64_t arrival_time_us);
  void Flush(int64_t now_us, bool force);
  bool HasFrame() const;
  Status PopFrame(EncodedVideoFrame* frame);
  VideoJitterStats GetStats() const;

 private:
  struct PartialFrame {
    uint32_t timestamp = 0;
    uint16_t sequence_start = 0;
    uint16_t sequence_end = 0;
    int64_t capture_time_us = 0;
    int64_t first_packet_receive_time_us = 0;
    int64_t last_packet_receive_time_us = 0;
    std::map<uint16_t, RtpPacket> packets;
    VideoFrameType frame_type = VideoFrameType::kUnknown;
    bool has_marker = false;
  };

  Status InsertSingleNalu(const RtpPacket& packet);
  Status InsertFuA(const RtpPacket& packet);
  Status InsertPacketForAssembly(const RtpPacket& packet);
  Status TryAssembleFrame(const PartialFrame& partial,
                          EncodedVideoFrame* frame,
                          bool* incomplete) const;
  void QueueCompletedFrame(EncodedVideoFrame frame);
  void FlushReadyFrames(int64_t now_us, bool force);
  bool ShouldReleaseReadyFrame(const EncodedVideoFrame& frame,
                               int64_t now_us,
                               bool force) const;
  void UpdateQueueStats();

  VideoJitterPlayerConfig config_;
  std::map<uint32_t, PartialFrame> partial_frames_;
  std::map<uint32_t, EncodedVideoFrame> ready_frames_;
  std::deque<EncodedVideoFrame> completed_;
  std::deque<uint32_t> completed_timestamp_order_;
  std::set<uint32_t> completed_timestamps_;
  uint32_t last_released_timestamp_ = 0;
  bool has_released_timestamp_ = false;
  std::vector<uint8_t> cached_sps_;
  std::vector<uint8_t> cached_pps_;
  VideoJitterStats stats_;
  std::unique_ptr<VideoJitterBackend> backend_;
};

}  // namespace webrtc_qos
