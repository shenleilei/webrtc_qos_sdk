#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

struct FfmpegH264EncoderConfig {
  uint32_t width = 1280;
  uint32_t height = 720;
  uint32_t fps = 30;
  uint32_t bitrate_bps = 1200000;
  uint32_t gop_size = 60;
};

class FfmpegH264Encoder {
 public:
  FfmpegH264Encoder();
  ~FfmpegH264Encoder();

  FfmpegH264Encoder(const FfmpegH264Encoder&) = delete;
  FfmpegH264Encoder& operator=(const FfmpegH264Encoder&) = delete;

  Status Open(const FfmpegH264EncoderConfig& config);
  Status SetRates(uint32_t bitrate_bps, uint32_t fps);
  Status EncodeI420(const uint8_t* y,
                    int y_stride,
                    const uint8_t* u,
                    int u_stride,
                    const uint8_t* v,
                    int v_stride,
                    bool force_keyframe,
                    std::vector<uint8_t>* annexb_access_unit);
  void Close();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace webrtc_qos
