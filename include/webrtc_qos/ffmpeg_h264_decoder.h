#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

struct DecodedVideoFrame {
  uint32_t width = 0;
  uint32_t height = 0;
  int64_t pts = 0;
  std::vector<uint8_t> y_plane;
  std::vector<uint8_t> u_plane;
  std::vector<uint8_t> v_plane;
  uint32_t y_stride = 0;
  uint32_t u_stride = 0;
  uint32_t v_stride = 0;
};

struct FfmpegH264DecoderStats {
  uint32_t decoded_frames = 0;
  uint32_t decode_errors = 0;
};

class FfmpegH264Decoder {
 public:
  FfmpegH264Decoder();
  ~FfmpegH264Decoder();

  FfmpegH264Decoder(const FfmpegH264Decoder&) = delete;
  FfmpegH264Decoder& operator=(const FfmpegH264Decoder&) = delete;

  Status Open();
  Status DecodeAnnexB(const uint8_t* data,
                      size_t size,
                      std::vector<DecodedVideoFrame>* decoded_frames);
  FfmpegH264DecoderStats GetStats() const;
  void Close();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace webrtc_qos
