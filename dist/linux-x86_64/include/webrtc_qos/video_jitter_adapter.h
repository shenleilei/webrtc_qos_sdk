#ifndef SDK_QOS_VIDEO_JITTER_ADAPTER_H_
#define SDK_QOS_VIDEO_JITTER_ADAPTER_H_

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace webrtc_qos {

struct VideoJitterAdapterConfig {
  uint8_t payload_type = 96;
  uint32_t ssrc = 0;
};

struct VideoJitterPacket {
  uint8_t payload_type = 96;
  bool marker = false;
  uint16_t sequence_number = 0;
  uint32_t rtp_timestamp = 0;
  uint32_t ssrc = 0;
  int64_t arrival_time_us = 0;
  const uint8_t* payload = nullptr;
  size_t payload_size = 0;
};

struct VideoJitterFrame {
  uint16_t rtp_sequence_start = 0;
  uint16_t rtp_sequence_end = 0;
  uint32_t rtp_timestamp = 0;
  bool keyframe = false;
  uint16_t width = 0;
  uint16_t height = 0;
  std::vector<uint8_t> annexb_access_unit;
};

struct VideoJitterAdapterStats {
  uint64_t packets_inserted = 0;
  uint64_t packets_rejected = 0;
  uint64_t frames_completed = 0;
};

class VideoJitterAdapter {
 public:
  explicit VideoJitterAdapter(const VideoJitterAdapterConfig& config);
  ~VideoJitterAdapter();

  VideoJitterAdapter(const VideoJitterAdapter&) = delete;
  VideoJitterAdapter& operator=(const VideoJitterAdapter&) = delete;

  std::vector<VideoJitterFrame> InsertPacket(const VideoJitterPacket& packet);
  VideoJitterAdapterStats stats() const;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace webrtc_qos

#endif  // SDK_QOS_VIDEO_JITTER_ADAPTER_H_
