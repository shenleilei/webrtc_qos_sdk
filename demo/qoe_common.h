#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

#include "webrtc_qos/ffmpeg_h264_decoder.h"

namespace webrtc_qos::demo {

struct I420Frame {
  uint32_t width = 0;
  uint32_t height = 0;
  std::vector<uint8_t> y;
  std::vector<uint8_t> u;
  std::vector<uint8_t> v;
};

inline void FillI420Frame(uint32_t width,
                          uint32_t height,
                          const std::string& content_profile,
                          int frame_index,
                          std::vector<uint8_t>* y,
                          std::vector<uint8_t>* u,
                          std::vector<uint8_t>* v) {
  y->resize(width * height);
  u->resize(width * height / 4);
  v->resize(width * height / 4);
  for (uint32_t row = 0; row < height; ++row) {
    for (uint32_t col = 0; col < width; ++col) {
      uint32_t luma = 0;
      if (content_profile == "low_motion") {
        luma = 86 + (col * 42 / std::max<uint32_t>(1, width)) +
               (row * 20 / std::max<uint32_t>(1, height)) +
               static_cast<uint32_t>((frame_index / 8) % 6);
      } else if (content_profile == "detail_motion") {
        const uint32_t checker =
            (((col / 16) + (row / 16) +
              static_cast<uint32_t>(frame_index / 4)) &
             1u)
                ? 104
                : 152;
        const uint32_t diagonal =
            ((col * 2 + row + static_cast<uint32_t>(frame_index * 3)) % 32);
        luma = checker + diagonal / 4;
      } else {
        luma = 48 + (col * 96 / std::max<uint32_t>(1, width)) +
               (row * 48 / std::max<uint32_t>(1, height));
      }
      (*y)[row * width + col] =
          static_cast<uint8_t>(std::min<uint32_t>(255, luma));
    }
  }
  const uint32_t square =
      content_profile == "detail_motion" ? std::max<uint32_t>(10, width / 7)
                                          : std::max<uint32_t>(8, width / 8);
  const uint32_t x_step = content_profile == "low_motion" ? 1 : 3;
  const uint32_t y_step = content_profile == "low_motion" ? 1 : 2;
  const uint32_t x0 =
      static_cast<uint32_t>((frame_index * x_step) %
                            std::max<uint32_t>(1, width - square));
  const uint32_t y0 =
      static_cast<uint32_t>((frame_index * y_step) %
                            std::max<uint32_t>(1, height - square));
  const uint8_t square_luma =
      content_profile == "detail_motion" ? 235 : 210;
  for (uint32_t row = y0; row < y0 + square && row < height; ++row) {
    for (uint32_t col = x0; col < x0 + square && col < width; ++col) {
      (*y)[row * width + col] = square_luma;
    }
  }
  const uint8_t u_value =
      content_profile == "low_motion"
          ? 112
          : static_cast<uint8_t>(96 + (frame_index % 8));
  const uint8_t v_value =
      content_profile == "detail_motion"
          ? static_cast<uint8_t>(132 + (frame_index % 16))
          : static_cast<uint8_t>(150 - (frame_index % 8));
  std::fill(u->begin(), u->end(), u_value);
  std::fill(v->begin(), v->end(), v_value);
}

inline I420Frame MakeI420Frame(uint32_t width,
                               uint32_t height,
                               const std::string& content_profile,
                               int frame_index) {
  I420Frame frame;
  frame.width = width;
  frame.height = height;
  FillI420Frame(width, height, content_profile, frame_index, &frame.y, &frame.u,
                &frame.v);
  return frame;
}

inline double ComputePlaneSse(const uint8_t* reference,
                              const uint8_t* decoded,
                              size_t size) {
  double sse = 0.0;
  for (size_t i = 0; i < size; ++i) {
    const int diff =
        static_cast<int>(reference[i]) - static_cast<int>(decoded[i]);
    sse += static_cast<double>(diff * diff);
  }
  return sse;
}

inline double ComputeI420Psnr(const I420Frame& reference,
                              const DecodedVideoFrame& decoded) {
  if (reference.width != decoded.width || reference.height != decoded.height ||
      reference.y.empty() || reference.u.empty() || reference.v.empty() ||
      decoded.y_plane.empty() || decoded.u_plane.empty() ||
      decoded.v_plane.empty()) {
    return 0.0;
  }
  const size_t y_size = static_cast<size_t>(reference.width) * reference.height;
  const size_t uv_size = static_cast<size_t>(reference.width / 2) *
                         static_cast<size_t>(reference.height / 2);
  if (reference.y.size() != y_size || reference.u.size() != uv_size ||
      reference.v.size() != uv_size || decoded.y_plane.size() != y_size ||
      decoded.u_plane.size() != uv_size || decoded.v_plane.size() != uv_size) {
    return 0.0;
  }
  const double sse =
      ComputePlaneSse(reference.y.data(), decoded.y_plane.data(), y_size) +
      ComputePlaneSse(reference.u.data(), decoded.u_plane.data(), uv_size) +
      ComputePlaneSse(reference.v.data(), decoded.v_plane.data(), uv_size);
  if (sse <= 0.0) {
    return 99.0;
  }
  const double samples = static_cast<double>(y_size + 2 * uv_size);
  const double mse = sse / samples;
  return 10.0 * std::log10((255.0 * 255.0) / mse);
}

}  // namespace webrtc_qos::demo
