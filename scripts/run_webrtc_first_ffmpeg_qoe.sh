#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WEBRTC_PREFIX="${WEBRTC_PREFIX:-${SDK_ROOT}/dist/linux-x86_64}"
REQUESTED_WORK_DIR="${WORK_DIR:-}"
WORK_DIR="${REQUESTED_WORK_DIR:-/tmp/webrtc_qos_ffmpeg_qoe.$$}"
REQUESTED_PREFIX="${QOE_PREFIX:-${PREFIX:-}}"
PREFIX="${REQUESTED_PREFIX:-/tmp/webrtc_qos_ffmpeg_qoe_prefix.$$}"
PREFIX_IS_TEMP=0
if [[ -z "${REQUESTED_PREFIX}" ]]; then
  PREFIX_IS_TEMP=1
fi
CLEANUP_WORK_DIR="${CLEANUP_WORK_DIR:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/webrtc_first_ffmpeg_qoe}"
OUTPUT_BASENAME="${OUTPUT_BASENAME:-webrtc_first_ffmpeg_qoe}"
FRAMES="${FRAMES:-30}"
WIDTH="${WIDTH:-160}"
HEIGHT="${HEIGHT:-90}"
SCENARIO="${SCENARIO:-baseline}"
SCENARIOS="${SCENARIOS:-${SCENARIO}}"
START_BITRATE_BPS="${START_BITRATE_BPS:-400000}"
MIN_BITRATE_BPS="${MIN_BITRATE_BPS:-150000}"
MAX_BITRATE_BPS="${MAX_BITRATE_BPS:-800000}"
MIN_PLAYABLE_RATIO="${MIN_PLAYABLE_RATIO:-0.8}"
MIN_AVG_PSNR_Y="${MIN_AVG_PSNR_Y:-20.0}"
MIN_AVG_SSIM_Y="${MIN_AVG_SSIM_Y:-0.80}"
SEEDS="${SEEDS:-1}"
CONTENT_MODE="${CONTENT_MODE:-block_motion}"
CONTENT_MODES="${CONTENT_MODES:-${CONTENT_MODE}}"
MAX_WEAK_SEND_RPS="${MAX_WEAK_SEND_RPS:-15.0}"
MAX_WEAK_RTP_PPS="${MAX_WEAK_RTP_PPS:-150.0}"
MAX_WEAK_TARGET_BPS="${MAX_WEAK_TARGET_BPS:-0}"
MAX_WEAK_ENCODER_FPS="${MAX_WEAK_ENCODER_FPS:-10}"
MAX_RECOVERY_TIME_MS="${MAX_RECOVERY_TIME_MS:-1000}"
RENDERER_PROXY_TARGET_DELAY_MS="${RENDERER_PROXY_TARGET_DELAY_MS:-350}"
MAX_RENDERER_PROXY_LATE_MS="${MAX_RENDERER_PROXY_LATE_MS:-150}"
MAX_RENDERER_PROXY_LATENCY_MS="${MAX_RENDERER_PROXY_LATENCY_MS:-500}"
MAX_RENDERER_PROXY_LATE_FRAMES="${MAX_RENDERER_PROXY_LATE_FRAMES:-0}"
MAX_RENDERER_PROXY_DROP_FRAMES="${MAX_RENDERER_PROXY_DROP_FRAMES:-0}"
MAX_RENDERER_PROXY_GAP_MS="${MAX_RENDERER_PROXY_GAP_MS:-150}"

WEBRTC_PREFIX_ABS="$(readlink -m "${WEBRTC_PREFIX}")"
PREFIX_ABS="$(readlink -m "${PREFIX}")"
SDK_ROOT_ABS="$(readlink -m "${SDK_ROOT}")"
if [[ "${PREFIX_ABS}" == "${WEBRTC_PREFIX_ABS}" ]]; then
  PREFIX="/tmp/webrtc_qos_ffmpeg_qoe_prefix.$$"
  PREFIX_IS_TEMP=1
  PREFIX_ABS="$(readlink -m "${PREFIX}")"
fi
if [[ -z "${PREFIX_ABS}" || "${PREFIX_ABS}" == "/" ||
      "${PREFIX_ABS}" == "${SDK_ROOT_ABS}" ||
      "${PREFIX_ABS}" == "${WEBRTC_PREFIX_ABS}" ]]; then
  echo "unsafe QoE working prefix: ${PREFIX}" >&2
  exit 2
fi

cleanup_qoe_tmp() {
  local status=$?
  trap - EXIT
  if [[ "${CLEANUP_WORK_DIR}" == "1" && -z "${REQUESTED_WORK_DIR}" &&
        "${WORK_DIR}" == /tmp/webrtc_qos_ffmpeg_qoe.* ]]; then
    rm -rf -- "${WORK_DIR}"
  fi
  if [[ "${CLEANUP_WORK_DIR}" == "1" && "${PREFIX_IS_TEMP}" == "1" &&
        "${PREFIX}" == /tmp/webrtc_qos_ffmpeg_qoe_prefix.* ]]; then
    rm -rf -- "${PREFIX}"
  fi
  exit "${status}"
}
trap cleanup_qoe_tmp EXIT

rm -rf "${WORK_DIR}"
if [[ "${PREFIX_IS_TEMP}" == "1" ]]; then
  rm -rf "${PREFIX}"
fi
mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}" "${PREFIX}"
cp -a "${WEBRTC_PREFIX}/." "${PREFIX}/"

cmake -S "${SDK_ROOT}" -B "${WORK_DIR}/sdk_build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DWEBRTC_QOS_ENABLE_FFMPEG_ENCODER=ON \
  -DWEBRTC_QOS_INSTALL_FFMPEG_ENCODER=ON >/dev/null
cmake --build "${WORK_DIR}/sdk_build" -j2 >/dev/null
cmake --install "${WORK_DIR}/sdk_build" \
  --prefix "${WORK_DIR}/ffmpeg_prefix" >/dev/null

cp -a "${WORK_DIR}/ffmpeg_prefix/lib/libwebrtc_qos_ffmpeg_"*.a \
  "${PREFIX}/lib/"
cp -a "${WORK_DIR}/ffmpeg_prefix/include/webrtc_qos/ffmpeg_h264_"*.h \
  "${PREFIX}/include/webrtc_qos/"

cat > "${WORK_DIR}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(webrtc_first_ffmpeg_qoe LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(WebRtcQosSdk REQUIRED CONFIG)

foreach(target IN ITEMS
  WebRtcQosSdk::role_push
  WebRtcQosSdk::role_play
  WebRtcQosSdk::role_server
  WebRtcQosSdk::webrtc_qos_ffmpeg_encoder
  WebRtcQosSdk::webrtc_qos_ffmpeg_decoder)
  if(NOT TARGET "${target}")
    message(FATAL_ERROR "missing required QoE target: ${target}")
  endif()
endforeach()

add_executable(webrtc_first_ffmpeg_qoe main.cc)
target_link_libraries(webrtc_first_ffmpeg_qoe PRIVATE
  WebRtcQosSdk::role_push
  WebRtcQosSdk::role_play
  WebRtcQosSdk::role_server
  WebRtcQosSdk::webrtc_qos_ffmpeg_encoder
  WebRtcQosSdk::webrtc_qos_ffmpeg_decoder)
EOF

cat > "${WORK_DIR}/main.cc" <<'EOF'
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "webrtc_qos/ffmpeg_h264_decoder.h"
#include "webrtc_qos/ffmpeg_h264_encoder.h"
#include "webrtc_qos/rtcp_adapter.h"
#include "webrtc_qos/rtp_packet_adapter.h"
#include "webrtc_qos/server_qos_router.h"
#include "webrtc_qos/video_play_client.h"
#include "webrtc_qos/video_push_client.h"

namespace {

constexpr int64_t kNoPts = static_cast<int64_t>(0x8000000000000000LL);
constexpr int64_t kMediaStartTimeUs = 1000000;
constexpr int64_t kFrameDurationUs = 33333;
constexpr int kFrameRate = 30;

struct Packet {
  webrtc_qos::TransportPacketKind kind = webrtc_qos::TransportPacketKind::kRtp;
  std::vector<uint8_t> bytes;
  bool retransmission = false;
  bool padding = false;
};

struct Metrics {
  std::string scenario;
  int seed = 1;
  int source_frames = 0;
  int encoded_frames = 0;
  int pushed_frames = 0;
  int push_queue_full = 0;
  int decoded_frames = 0;
  int rtp_dropped_downlink = 0;
  int nacks = 0;
  int retransmissions = 0;
  int decode_errors = 0;
  int freeze_count = 0;
  int freeze_duration_ms = 0;
  int max_inter_render_gap_ms = 0;
  int last_decoded_original_frame = -1;
  int renderer_proxy_rendered_frames = 0;
  int renderer_proxy_late_frames = 0;
  int renderer_proxy_drop_frames = 0;
  int renderer_proxy_max_latency_ms = 0;
  int renderer_proxy_max_wait_ms = 0;
  int64_t renderer_proxy_total_latency_us = 0;
  int64_t renderer_proxy_total_wait_us = 0;
  int64_t renderer_proxy_last_render_time_us = kNoPts;
  int renderer_proxy_inter_render_gap_count = 0;
  int renderer_proxy_max_inter_render_gap_ms = 0;
  int renderer_proxy_max_jitter_ms = 0;
  int64_t renderer_proxy_total_inter_render_gap_us = 0;
  int64_t renderer_proxy_total_jitter_us = 0;
  int total_bad_ticks = 0;
  int total_recovery_ticks = 0;
  int encoded_bad_ticks = 0;
  int encoded_recovery_ticks = 0;
  int rtp_sent = 0;
  int bad_rtp_sent = 0;
  int recovery_rtp_sent = 0;
  uint32_t min_target_bps = UINT32_MAX;
  uint32_t final_target_bps = 0;
  uint32_t min_encoder_fps = UINT32_MAX;
  uint32_t final_encoder_fps = 0;
  uint32_t min_bad_target_bps = UINT32_MAX;
  uint32_t max_bad_target_bps = 0;
  uint32_t max_recovery_target_bps = 0;
  uint32_t min_bad_encoder_fps = UINT32_MAX;
  uint32_t max_bad_encoder_fps = 0;
  uint32_t max_recovery_encoder_fps = 0;
  int recovery_start_frame = -1;
  int target_recovered_frame = -1;
  int fps_recovered_frame = -1;
  int full_recovered_frame = -1;
  int target_recovery_time_ms = -1;
  int fps_recovery_time_ms = -1;
  int full_recovery_time_ms = -1;
  double avg_psnr_y = 0.0;
  double min_psnr_y = 100.0;
  double avg_ssim_y = 0.0;
  double min_ssim_y = 1.0;
  double playable_ratio = 0.0;
};

struct RendererProxyConfig {
  int target_delay_ms = 150;
  int max_late_ms = 50;
  int max_latency_ms = 250;
};

struct ScenarioConfig {
  std::string name = "baseline";
  int bad_start = -1;
  int bad_end = -1;
  bool oscillating_bad_windows = false;
  bool inject_rate_cap = false;
  bool drop_dead_zone = false;
  bool periodic_loss = false;
  bool expect_rate_drop = false;
  bool expect_recovery = false;
  bool expect_final_low = false;
  bool expect_nack = false;
  bool expect_retransmission = false;
  double min_playable_ratio = 0.9;
  double min_avg_psnr_y = 20.0;
  double min_avg_ssim_y = 0.80;
};

struct SourceMode {
  std::string mode = "block_motion";
  std::string label = "block_motion";
  bool capture_i420 = false;
  std::string capture_i420_path;
};

Packet CopyPacket(const webrtc_qos::TransportPacketView& view) {
  Packet packet;
  packet.kind = view.metadata.kind;
  packet.retransmission = view.metadata.retransmission;
  packet.padding = view.metadata.padding;
  packet.bytes.assign(view.bytes, view.bytes + view.size);
  return packet;
}

SourceMode ParseSourceMode(const std::string& content_mode) {
  SourceMode source;
  source.mode = content_mode;
  source.label = content_mode;
  constexpr char kCapturePrefix[] = "capture_i420:";
  if (content_mode.rfind(kCapturePrefix, 0) != 0) {
    return source;
  }

  const std::string rest = content_mode.substr(sizeof(kCapturePrefix) - 1);
  const size_t sep = rest.find(':');
  if (sep == std::string::npos || sep == 0 || sep + 1 >= rest.size()) {
    std::cerr << "capture_i420 content mode must be "
              << "capture_i420:<label>:<raw_i420_path>\n";
    std::exit(2);
  }
  source.capture_i420 = true;
  source.label = rest.substr(0, sep);
  source.capture_i420_path = rest.substr(sep + 1);
  return source;
}

uint32_t Hash32(uint32_t x) {
  x ^= x >> 16;
  x *= 0x7feb352dU;
  x ^= x >> 15;
  x *= 0x846ca68bU;
  x ^= x >> 16;
  return x;
}

bool ReadWholeFile(const std::string& path, std::vector<uint8_t>* bytes) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    return false;
  }
  in.seekg(0, std::ios::end);
  const std::streamoff size = in.tellg();
  if (size <= 0) {
    return false;
  }
  in.seekg(0, std::ios::beg);
  bytes->resize(static_cast<size_t>(size));
  in.read(reinterpret_cast<char*>(bytes->data()), size);
  return in.good() || in.eof();
}

bool LoadCaptureI420Source(const SourceMode& source,
                           int width,
                           int height,
                           std::vector<uint8_t>* bytes,
                           int* frame_count) {
  if (!source.capture_i420) {
    *frame_count = 0;
    return true;
  }
  if ((width % 2) != 0 || (height % 2) != 0) {
    std::cerr << "capture_i420 requires even width/height\n";
    return false;
  }
  if (!ReadWholeFile(source.capture_i420_path, bytes)) {
    std::cerr << "failed to read capture_i420 source: "
              << source.capture_i420_path << "\n";
    return false;
  }
  const size_t frame_size =
      static_cast<size_t>(width) * height * 3 / 2;
  if (bytes->size() < frame_size) {
    std::cerr << "capture_i420 source is smaller than one frame: "
              << source.capture_i420_path << "\n";
    return false;
  }
  *frame_count = static_cast<int>(bytes->size() / frame_size);
  if ((bytes->size() % frame_size) != 0) {
    std::cerr << "warning: capture_i420 source has trailing bytes: "
              << source.capture_i420_path << "\n";
  }
  return true;
}

void FillCaptureI420(const std::vector<uint8_t>& bytes,
                     int capture_frames,
                     int frame,
                     int width,
                     int height,
                     std::vector<uint8_t>* y,
                     std::vector<uint8_t>* u,
                     std::vector<uint8_t>* v) {
  const size_t y_size = static_cast<size_t>(width) * height;
  const size_t uv_size = static_cast<size_t>(width / 2) * (height / 2);
  const size_t frame_size = y_size + uv_size * 2;
  const int source_frame = capture_frames <= 0 ? 0 : frame % capture_frames;
  const uint8_t* base = bytes.data() +
                        static_cast<size_t>(source_frame) * frame_size;
  y->assign(base, base + y_size);
  u->assign(base + y_size, base + y_size + uv_size);
  v->assign(base + y_size + uv_size, base + frame_size);
}

void FillBlockMotionI420(int frame,
                         int seed,
                         int width,
                         int height,
                         std::vector<uint8_t>* y,
                         std::vector<uint8_t>* u,
                         std::vector<uint8_t>* v) {
  y->resize(static_cast<size_t>(width) * height);
  u->resize(static_cast<size_t>(width / 2) * (height / 2));
  v->resize(static_cast<size_t>(width / 2) * (height / 2));
  for (int row = 0; row < height; ++row) {
    for (int col = 0; col < width; ++col) {
      const int block_x = (col + seed * 13 + frame * (1 + seed % 3)) / 16;
      const int block_y = (row + seed * 7 + frame * (1 + seed % 2)) / 16;
      (*y)[static_cast<size_t>(row) * width + col] =
          static_cast<uint8_t>(
              (block_y * (17 + seed % 5) + block_x * (11 + seed % 7) +
               row / 8 + col / 8 + frame * (9 + seed % 5) + seed * 17) &
              0xff);
    }
  }
  std::fill(u->begin(), u->end(),
            static_cast<uint8_t>(96 + (frame + seed * 3) % 32));
  std::fill(v->begin(), v->end(),
            static_cast<uint8_t>(160 - (frame + seed * 5) % 32));
}

void FillStressI420(int frame,
                    int seed,
                    int width,
                    int height,
                    std::vector<uint8_t>* y,
                    std::vector<uint8_t>* u,
                    std::vector<uint8_t>* v) {
  y->resize(static_cast<size_t>(width) * height);
  u->resize(static_cast<size_t>(width / 2) * (height / 2));
  v->resize(static_cast<size_t>(width / 2) * (height / 2));

  for (int row = 0; row < height; ++row) {
    for (int col = 0; col < width; ++col) {
      const int moving_x = col + frame * (3 + seed % 5) + seed * 17;
      const int moving_y = row + frame * (2 + seed % 3) + seed * 11;
      const int checker = (((moving_x / 8) + (moving_y / 8)) & 1) ? 220 : 36;
      const int diagonal = (moving_x * 5 + moving_y * 3 + frame * 13) & 0xff;
      const uint32_t noise = Hash32(static_cast<uint32_t>(
          col * 73856093U ^ row * 19349663U ^ frame * 83492791U ^
          seed * 2654435761U));
      const int fine = static_cast<int>(noise & 0x7f);
      const int value = (checker * 5 + diagonal * 3 + fine * 2) / 10;
      (*y)[static_cast<size_t>(row) * width + col] =
          static_cast<uint8_t>(std::max(0, std::min(255, value)));
    }
  }

  const int chroma_width = width / 2;
  const int chroma_height = height / 2;
  for (int row = 0; row < chroma_height; ++row) {
    for (int col = 0; col < chroma_width; ++col) {
      const uint32_t h = Hash32(static_cast<uint32_t>(
          col * 83492791U ^ row * 2654435761U ^ frame * 19349663U ^
          seed * 73856093U));
      const int stripe = ((col + row * 2 + frame * (1 + seed % 4)) & 31);
      (*u)[static_cast<size_t>(row) * chroma_width + col] =
          static_cast<uint8_t>(80 + ((stripe * 3 + (h & 0x3f)) % 96));
      (*v)[static_cast<size_t>(row) * chroma_width + col] =
          static_cast<uint8_t>(96 + ((stripe * 5 + ((h >> 8) & 0x3f)) % 96));
    }
  }
}

void FillCameraPanI420(int frame,
                       int seed,
                       int width,
                       int height,
                       std::vector<uint8_t>* y,
                       std::vector<uint8_t>* u,
                       std::vector<uint8_t>* v) {
  y->resize(static_cast<size_t>(width) * height);
  u->resize(static_cast<size_t>(width / 2) * (height / 2));
  v->resize(static_cast<size_t>(width / 2) * (height / 2));
  const int pan_x = frame * (4 + seed % 4) + seed * 19;
  const int pan_y = frame * (2 + seed % 3) + seed * 11;
  for (int row = 0; row < height; ++row) {
    for (int col = 0; col < width; ++col) {
      const int world_x = col + pan_x;
      const int world_y = row + pan_y;
      const int skyline = height / 3 + ((world_x / 24 + seed * 7) % 31) - 15;
      int value = row < skyline ? 96 + (world_y / 5) % 48
                                : 48 + ((world_x / 9 + world_y / 17) % 96);
      if (((world_x / 64 + seed) % 7 == 0) && row > skyline) {
        value = 150 + ((world_y / 4) % 70);
      }
      (*y)[static_cast<size_t>(row) * width + col] =
          static_cast<uint8_t>(std::max(0, std::min(255, value)));
    }
  }
  std::fill(u->begin(), u->end(),
            static_cast<uint8_t>(104 + (seed * 3 + frame / 3) % 20));
  std::fill(v->begin(), v->end(),
            static_cast<uint8_t>(146 + (seed * 5 + frame / 4) % 24));
}

void FillSceneCutI420(int frame,
                      int seed,
                      int width,
                      int height,
                      std::vector<uint8_t>* y,
                      std::vector<uint8_t>* u,
                      std::vector<uint8_t>* v) {
  const int scene = frame / 10;
  const int local_frame = frame % 10;
  if ((scene & 1) == 0) {
    FillBlockMotionI420(local_frame * 3 + scene, seed + scene * 13, width,
                        height, y, u, v);
    return;
  }
  FillCameraPanI420(local_frame * 4 + scene, seed + scene * 17, width, height,
                    y, u, v);
}

void FillLowLightNoiseI420(int frame,
                           int seed,
                           int width,
                           int height,
                           std::vector<uint8_t>* y,
                           std::vector<uint8_t>* u,
                           std::vector<uint8_t>* v) {
  y->resize(static_cast<size_t>(width) * height);
  u->resize(static_cast<size_t>(width / 2) * (height / 2));
  v->resize(static_cast<size_t>(width / 2) * (height / 2));
  for (int row = 0; row < height; ++row) {
    for (int col = 0; col < width; ++col) {
      const uint32_t noise = Hash32(static_cast<uint32_t>(
          col * 19349663U ^ row * 83492791U ^ frame * 2654435761U ^
          seed * 73856093U));
      const int moving_shadow =
          ((col + frame * (1 + seed % 3)) / 48 +
           (row + frame * (2 + seed % 2)) / 48) %
          3;
      const int base = 22 + moving_shadow * 10 + static_cast<int>(noise % 22);
      (*y)[static_cast<size_t>(row) * width + col] =
          static_cast<uint8_t>(std::max(0, std::min(255, base)));
    }
  }
  std::fill(u->begin(), u->end(),
            static_cast<uint8_t>(118 + (frame + seed) % 10));
  std::fill(v->begin(), v->end(),
            static_cast<uint8_t>(132 + (frame + seed * 2) % 10));
}

void FillSyntheticI420(const std::string& content_mode,
                       int frame,
                       int seed,
                       int width,
                       int height,
                       std::vector<uint8_t>* y,
                       std::vector<uint8_t>* u,
                       std::vector<uint8_t>* v) {
  if (content_mode == "stress" || content_mode == "high_complexity") {
    FillStressI420(frame, seed, width, height, y, u, v);
    return;
  }
  if (content_mode == "camera_pan") {
    FillCameraPanI420(frame, seed, width, height, y, u, v);
    return;
  }
  if (content_mode == "scene_cut") {
    FillSceneCutI420(frame, seed, width, height, y, u, v);
    return;
  }
  if (content_mode == "low_light_noise") {
    FillLowLightNoiseI420(frame, seed, width, height, y, u, v);
    return;
  }
  FillBlockMotionI420(frame, seed, width, height, y, u, v);
}

double PsnrY(const std::vector<uint8_t>& ref,
             const webrtc_qos::DecodedVideoFrame& decoded) {
  if (decoded.y_plane.empty() || decoded.width == 0 || decoded.height == 0) {
    return 0.0;
  }
  const size_t n = std::min(ref.size(), decoded.y_plane.size());
  if (n == 0) {
    return 0.0;
  }
  double mse = 0.0;
  for (size_t i = 0; i < n; ++i) {
    const double d = static_cast<double>(ref[i]) - decoded.y_plane[i];
    mse += d * d;
  }
  mse /= static_cast<double>(n);
  if (mse <= 0.000001) {
    return 100.0;
  }
  return 10.0 * std::log10((255.0 * 255.0) / mse);
}

double SsimY(const std::vector<uint8_t>& ref,
             const webrtc_qos::DecodedVideoFrame& decoded) {
  if (decoded.y_plane.empty() || decoded.width == 0 || decoded.height == 0) {
    return 0.0;
  }
  const size_t n = std::min(ref.size(), decoded.y_plane.size());
  if (n < 2) {
    return 0.0;
  }

  double sum_ref = 0.0;
  double sum_dec = 0.0;
  for (size_t i = 0; i < n; ++i) {
    sum_ref += ref[i];
    sum_dec += decoded.y_plane[i];
  }
  const double mean_ref = sum_ref / static_cast<double>(n);
  const double mean_dec = sum_dec / static_cast<double>(n);

  double var_ref = 0.0;
  double var_dec = 0.0;
  double covariance = 0.0;
  for (size_t i = 0; i < n; ++i) {
    const double ref_delta = static_cast<double>(ref[i]) - mean_ref;
    const double dec_delta = static_cast<double>(decoded.y_plane[i]) - mean_dec;
    var_ref += ref_delta * ref_delta;
    var_dec += dec_delta * dec_delta;
    covariance += ref_delta * dec_delta;
  }
  const double denom = static_cast<double>(n - 1);
  var_ref /= denom;
  var_dec /= denom;
  covariance /= denom;

  constexpr double kL = 255.0;
  constexpr double kC1 = (0.01 * kL) * (0.01 * kL);
  constexpr double kC2 = (0.03 * kL) * (0.03 * kL);
  const double numerator = (2.0 * mean_ref * mean_dec + kC1) *
                           (2.0 * covariance + kC2);
  const double denominator =
      (mean_ref * mean_ref + mean_dec * mean_dec + kC1) *
      (var_ref + var_dec + kC2);
  if (denominator <= 0.0) {
    return 0.0;
  }
  return std::max(0.0, std::min(1.0, numerator / denominator));
}

bool ParseRtpSeq(const std::vector<uint8_t>& bytes,
                 const webrtc_qos::SessionConfig& session,
                 uint16_t* seq) {
  webrtc_qos::RtpPacketAdapterConfig config;
  config.payload_type = session.h264.payload_type;
  config.transport_sequence_extension_id = session.twcc.extension_id;
  config.enable_transport_sequence_extension = true;
  webrtc_qos::RtpPacketAdapterParsedPacket parsed;
  if (!webrtc_qos::ParseRtpPacket(bytes.data(), bytes.size(), config,
                                  &parsed)) {
    return false;
  }
  *seq = parsed.sequence_number;
  return true;
}

double TickRate(int count, int ticks) {
  return ticks <= 0 ? 0.0 : static_cast<double>(count) * 30.0 / ticks;
}

void AccountFreezeProxy(int original_frame, Metrics* metrics) {
  constexpr int kFreezeThresholdMs = 500;
  if (metrics->last_decoded_original_frame >= 0) {
    const int frame_gap =
        std::max(1, original_frame - metrics->last_decoded_original_frame);
    const int gap_ms = frame_gap * 1000 / 30;
    metrics->max_inter_render_gap_ms =
        std::max(metrics->max_inter_render_gap_ms, gap_ms);
    if (gap_ms > kFreezeThresholdMs) {
      ++metrics->freeze_count;
      metrics->freeze_duration_ms += gap_ms - kFreezeThresholdMs;
    }
  }
  metrics->last_decoded_original_frame = original_frame;
}

void AccountRendererProxy(int original_frame,
                          int64_t decode_complete_time_us,
                          const RendererProxyConfig& config,
                          Metrics* metrics) {
  if (original_frame < 0 || decode_complete_time_us <= 0) {
    return;
  }
  const int64_t capture_time_us =
      kMediaStartTimeUs + static_cast<int64_t>(original_frame) * kFrameDurationUs;
  const int64_t target_render_time_us =
      capture_time_us + static_cast<int64_t>(config.target_delay_ms) * 1000;
  const int64_t max_render_time_us =
      capture_time_us + static_cast<int64_t>(config.max_latency_ms) * 1000;
  if (decode_complete_time_us > max_render_time_us) {
    ++metrics->renderer_proxy_drop_frames;
    return;
  }
  const int64_t render_time_us =
      std::max(target_render_time_us, decode_complete_time_us);
  const int64_t late_by_us = render_time_us - target_render_time_us;
  if (late_by_us > static_cast<int64_t>(config.max_late_ms) * 1000) {
    ++metrics->renderer_proxy_late_frames;
  }
  const int64_t latency_us = render_time_us - capture_time_us;
  const int64_t wait_us = std::max<int64_t>(0, target_render_time_us -
                                                   decode_complete_time_us);
  if (metrics->renderer_proxy_last_render_time_us != kNoPts) {
    const int64_t render_gap_us =
        std::max<int64_t>(0, render_time_us -
                                 metrics->renderer_proxy_last_render_time_us);
    const int64_t jitter_us = std::llabs(render_gap_us - kFrameDurationUs);
    ++metrics->renderer_proxy_inter_render_gap_count;
    metrics->renderer_proxy_total_inter_render_gap_us += render_gap_us;
    metrics->renderer_proxy_total_jitter_us += jitter_us;
    metrics->renderer_proxy_max_inter_render_gap_ms =
        std::max(metrics->renderer_proxy_max_inter_render_gap_ms,
                 static_cast<int>((render_gap_us + 999) / 1000));
    metrics->renderer_proxy_max_jitter_ms =
        std::max(metrics->renderer_proxy_max_jitter_ms,
                 static_cast<int>((jitter_us + 999) / 1000));
  }
  metrics->renderer_proxy_last_render_time_us = render_time_us;
  ++metrics->renderer_proxy_rendered_frames;
  metrics->renderer_proxy_total_latency_us += latency_us;
  metrics->renderer_proxy_total_wait_us += wait_us;
  metrics->renderer_proxy_max_latency_ms =
      std::max(metrics->renderer_proxy_max_latency_ms,
               static_cast<int>((latency_us + 999) / 1000));
  metrics->renderer_proxy_max_wait_ms =
      std::max(metrics->renderer_proxy_max_wait_ms,
               static_cast<int>((wait_us + 999) / 1000));
}

uint32_t QuantizeBitrateBps(uint32_t bitrate_bps) {
  constexpr uint32_t kStepBps = 50000;
  return std::max<uint32_t>(kStepBps,
                            ((bitrate_bps + kStepBps / 2) / kStepBps) *
                                kStepBps);
}

bool InBadWindow(const ScenarioConfig& scenario, int frame_index) {
  if (scenario.oscillating_bad_windows && frame_index >= scenario.bad_start &&
      frame_index <= scenario.bad_end) {
    const int phase = (frame_index - scenario.bad_start) / 4;
    return phase % 2 == 0;
  }
  return frame_index >= scenario.bad_start && frame_index <= scenario.bad_end;
}

bool InRecoveryWindow(const ScenarioConfig& scenario, int frame_index) {
  if (scenario.oscillating_bad_windows && frame_index >= scenario.bad_start &&
      frame_index <= scenario.bad_end) {
    return !InBadWindow(scenario, frame_index);
  }
  return scenario.bad_end >= 0 && frame_index > scenario.bad_end;
}

ScenarioConfig MakeScenario(const std::string& name,
                            int frames,
                            double min_playable_ratio,
                            double min_avg_psnr_y,
                            double min_avg_ssim_y) {
  ScenarioConfig scenario;
  scenario.name = name;
  scenario.min_playable_ratio = min_playable_ratio;
  scenario.min_avg_psnr_y = min_avg_psnr_y;
  scenario.min_avg_ssim_y = min_avg_ssim_y;
  if (name == "baseline") {
    return scenario;
  }
  scenario.bad_start = std::max(1, frames / 4);
  scenario.bad_end = std::max(scenario.bad_start, frames / 2);
  if (name == "bandwidth_cliff_recover") {
    scenario.inject_rate_cap = true;
    scenario.expect_rate_drop = true;
    scenario.expect_recovery = true;
    return scenario;
  }
  if (name == "weak_network_low_rps_low_bitrate") {
    scenario.bad_start = std::max(1, frames / 4);
    scenario.bad_end = std::max(scenario.bad_start, frames * 3 / 4);
    scenario.inject_rate_cap = true;
    scenario.expect_rate_drop = true;
    scenario.expect_recovery = true;
    scenario.min_playable_ratio = std::min(min_playable_ratio, 0.75);
    return scenario;
  }
  if (name == "sustained_low_bandwidth_low_rps") {
    scenario.bad_start = std::max(1, frames / 4);
    scenario.bad_end = frames - 1;
    scenario.inject_rate_cap = true;
    scenario.expect_rate_drop = true;
    scenario.expect_final_low = true;
    scenario.min_playable_ratio = std::min(min_playable_ratio, 0.75);
    return scenario;
  }
  if (name == "weak_start_low_bandwidth_low_rps") {
    scenario.bad_start = 0;
    scenario.bad_end = frames - 1;
    scenario.inject_rate_cap = true;
    scenario.expect_rate_drop = true;
    scenario.expect_final_low = true;
    scenario.min_playable_ratio = std::min(min_playable_ratio, 0.75);
    return scenario;
  }
  if (name == "walking_dead_zone_recover") {
    scenario.inject_rate_cap = true;
    scenario.drop_dead_zone = true;
    scenario.expect_rate_drop = true;
    scenario.expect_recovery = true;
    scenario.expect_nack = true;
    scenario.expect_retransmission = true;
    scenario.min_playable_ratio = std::min(min_playable_ratio, 0.75);
    return scenario;
  }
  if (name == "jitter_loss_recover") {
    scenario.periodic_loss = true;
    scenario.expect_nack = true;
    scenario.expect_retransmission = true;
    scenario.min_playable_ratio = std::min(min_playable_ratio, 0.8);
    return scenario;
  }
  if (name == "oscillating_edge_recover") {
    scenario.bad_start = std::max(1, frames / 5);
    scenario.bad_end = std::max(scenario.bad_start, frames * 4 / 5);
    scenario.oscillating_bad_windows = true;
    scenario.inject_rate_cap = true;
    scenario.periodic_loss = true;
    scenario.expect_rate_drop = true;
    scenario.expect_recovery = true;
    scenario.expect_nack = true;
    scenario.expect_retransmission = true;
    scenario.min_playable_ratio = std::min(min_playable_ratio, 0.8);
    return scenario;
  }
  std::cerr << "unknown scenario: " << name << "\n";
  std::exit(2);
}

void CountPlayRtcp(const Packet& packet, Metrics* metrics) {
  webrtc_qos::RtcpAdapterParsedPacket parsed;
  if (webrtc_qos::ParseRtcpPacket(packet.bytes.data(), packet.bytes.size(),
                                  &parsed) &&
      parsed.type == webrtc_qos::RtcpAdapterPacketType::kNack) {
    ++metrics->nacks;
  }
}

void AccountDecodedFrames(const std::vector<webrtc_qos::DecodedVideoFrame>& decoded,
                          const std::vector<std::vector<uint8_t>>& refs_y,
                          int64_t decode_complete_time_us,
                          const RendererProxyConfig& renderer_proxy_config,
                          Metrics* metrics) {
  for (const auto& frame : decoded) {
    const int original_frame =
        frame.pts == kNoPts
            ? -1
            : static_cast<int>((frame.pts - kMediaStartTimeUs +
                                kFrameDurationUs / 2) /
                               kFrameDurationUs);
    if (original_frame >= 0 &&
        static_cast<size_t>(original_frame) < refs_y.size() &&
        !refs_y[original_frame].empty()) {
      AccountFreezeProxy(original_frame, metrics);
      AccountRendererProxy(original_frame, decode_complete_time_us,
                           renderer_proxy_config, metrics);
      const double psnr = PsnrY(refs_y[original_frame], frame);
      const double ssim = SsimY(refs_y[original_frame], frame);
      metrics->avg_psnr_y += psnr;
      metrics->min_psnr_y = std::min(metrics->min_psnr_y, psnr);
      metrics->avg_ssim_y += ssim;
      metrics->min_ssim_y = std::min(metrics->min_ssim_y, ssim);
    }
    ++metrics->decoded_frames;
  }
}

}  // namespace

int main(int argc, char** argv) {
  const int frames = argc >= 2 ? std::max(1, std::stoi(argv[1])) : 12;
  const int width = argc >= 3 ? std::max(16, std::stoi(argv[2])) : 160;
  const int height = argc >= 4 ? std::max(16, std::stoi(argv[3])) : 90;
  const std::string csv_path =
      argc >= 5 ? argv[4] : "webrtc_first_ffmpeg_qoe.csv";
  const std::string scenario_name = argc >= 6 ? argv[5] : "baseline";
  const uint32_t start_bitrate_bps =
      argc >= 7 ? static_cast<uint32_t>(std::stoul(argv[6])) : 400000;
  const uint32_t min_bitrate_bps =
      argc >= 8 ? static_cast<uint32_t>(std::stoul(argv[7])) : 150000;
  const uint32_t max_bitrate_bps =
      argc >= 9 ? static_cast<uint32_t>(std::stoul(argv[8])) : 800000;
  const double min_playable_ratio = argc >= 10 ? std::stod(argv[9]) : 0.9;
  const double min_avg_psnr_y = argc >= 11 ? std::stod(argv[10]) : 20.0;
  const double min_avg_ssim_y = argc >= 12 ? std::stod(argv[11]) : 0.80;
  const int seed = argc >= 13 ? std::max(1, std::stoi(argv[12])) : 1;
  const std::string content_mode = argc >= 14 ? argv[13] : "block_motion";
  const SourceMode source_mode = ParseSourceMode(content_mode);
  const double max_weak_send_rps = argc >= 15 ? std::stod(argv[14]) : 15.0;
  const double max_weak_rtp_pps = argc >= 16 ? std::stod(argv[15]) : 150.0;
  const uint32_t max_weak_target_bps =
      argc >= 17 ? static_cast<uint32_t>(std::stoul(argv[16])) : 0;
  const uint32_t max_weak_encoder_fps =
      argc >= 18 ? static_cast<uint32_t>(std::stoul(argv[17])) : 10;
  const int max_recovery_time_ms =
      argc >= 19 ? std::max(0, std::stoi(argv[18])) : 1000;
  const RendererProxyConfig renderer_proxy_config{
      argc >= 20 ? std::max(0, std::stoi(argv[19])) : 350,
      argc >= 21 ? std::max(0, std::stoi(argv[20])) : 150,
      argc >= 22 ? std::max(1, std::stoi(argv[21])) : 500};
  const int max_renderer_proxy_late_frames =
      argc >= 23 ? std::max(0, std::stoi(argv[22])) : 0;
  const int max_renderer_proxy_drop_frames =
      argc >= 24 ? std::max(0, std::stoi(argv[23])) : 0;
  const int max_renderer_proxy_gap_ms =
      argc >= 25 ? std::max(1, std::stoi(argv[24])) : 150;
  const ScenarioConfig scenario =
      MakeScenario(scenario_name, frames, min_playable_ratio, min_avg_psnr_y,
                   min_avg_ssim_y);

  Metrics metrics;
  metrics.scenario = scenario.name;
  metrics.seed = seed;
  webrtc_qos::SessionConfig session;
  session.ids.session_id = 1;
  session.ids.stream_id = 1;
  session.ids.transport_id = 1;
  session.ids.sender_ssrc = 0x12345678;
  session.ids.receiver_id = 0x2222;
  session.h264.max_width = static_cast<uint16_t>(width);
  session.h264.max_height = static_cast<uint16_t>(height);
  session.start_bitrate_bps = start_bitrate_bps;
  session.min_bitrate_bps = min_bitrate_bps;
  session.max_bitrate_bps = max_bitrate_bps;

  std::vector<Packet> push_output;
  std::vector<Packet> play_output;
  std::vector<Packet> server_to_sender;
  std::vector<Packet> server_to_receiver;
  size_t push_i = 0;
  size_t play_i = 0;
  size_t server_sender_i = 0;
  size_t server_receiver_i = 0;
  std::vector<std::vector<uint8_t>> refs_y(static_cast<size_t>(frames));
  std::vector<int> encoded_frame_indices;
  std::vector<uint8_t> capture_i420_bytes;
  int capture_i420_frames = 0;
  if (!LoadCaptureI420Source(source_mode, width, height, &capture_i420_bytes,
                             &capture_i420_frames)) {
    return 12;
  }

  webrtc_qos::FfmpegH264Encoder encoder;
  webrtc_qos::FfmpegH264EncoderConfig encoder_config;
  encoder_config.width = static_cast<uint32_t>(width);
  encoder_config.height = static_cast<uint32_t>(height);
  encoder_config.fps = 30;
  encoder_config.bitrate_bps = start_bitrate_bps;
  encoder_config.gop_size = 30;
  if (!encoder.Open(encoder_config)) {
    std::cerr << "encoder open failed\n";
    return 2;
  }
  uint32_t current_encoder_bitrate_bps = encoder_config.bitrate_bps;
  uint32_t current_encoder_fps = encoder_config.fps;
  int last_encoder_reconfig_frame = -1000000;
  bool force_next_keyframe = false;
  int64_t current_decode_complete_time_us = kMediaStartTimeUs;

  webrtc_qos::FfmpegH264Decoder decoder;
  if (!decoder.Open()) {
    std::cerr << "decoder open failed\n";
    return 3;
  }

  webrtc_qos::VideoPushClientConfig push_config;
  push_config.session = session;
  push_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        push_output.push_back(CopyPacket(packet));
        return webrtc_qos::Status::Ok();
      };

  webrtc_qos::VideoPlayClientConfig play_config;
  play_config.session = session;
  play_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        play_output.push_back(CopyPacket(packet));
        return webrtc_qos::Status::Ok();
      };
  play_config.decoded_access_unit_output =
      [&](const webrtc_qos::AnnexBAccessUnitView& au) {
        std::vector<webrtc_qos::DecodedVideoFrame> decoded;
        auto status = decoder.DecodeAnnexB(au.bytes, au.size,
                                           au.capture_time_us, &decoded);
        if (!status) {
          ++metrics.decode_errors;
          return webrtc_qos::Status::Ok();
        }
        AccountDecodedFrames(decoded, refs_y, current_decode_complete_time_us,
                             renderer_proxy_config, &metrics);
        return webrtc_qos::Status::Ok();
      };

  webrtc_qos::ServerQosRouterConfig server_config;
  server_config.session = session;
  server_config.sender_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        server_to_sender.push_back(CopyPacket(packet));
        return webrtc_qos::Status::Ok();
      };
  server_config.receiver_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        server_to_receiver.push_back(CopyPacket(packet));
        return webrtc_qos::Status::Ok();
      };

  auto push = webrtc_qos::CreateVideoPushClient(push_config);
  auto play = webrtc_qos::CreateVideoPlayClient(play_config);
  auto server = webrtc_qos::CreateServerQosRouter(server_config);
  if (!push || !play || !server || !push->Start() || !play->Start() ||
      !server->Start()) {
    std::cerr << "failed to start facade roles\n";
    return 4;
  }

  auto drain_server_to_sender = [&](int64_t now_us) {
    while (server_sender_i < server_to_sender.size()) {
      const Packet& packet = server_to_sender[server_sender_i++];
      if (packet.kind == webrtc_qos::TransportPacketKind::kRtcp) {
        (void)push->OnTransportFeedback(packet.bytes.data(),
                                        packet.bytes.size(), now_us);
      }
    }
  };

  auto drain_play_output = [&](int64_t now_us) {
    while (play_i < play_output.size()) {
      const Packet& packet = play_output[play_i++];
      if (packet.kind != webrtc_qos::TransportPacketKind::kRtcp) {
        continue;
      }
      CountPlayRtcp(packet, &metrics);
      (void)server->OnReceiverRtcp(session.ids.receiver_id,
                                   packet.bytes.data(), packet.bytes.size(),
                                   now_us);
    }
  };

  auto drain_server_to_receiver = [&](int frame_index, int64_t now_us) {
    while (server_receiver_i < server_to_receiver.size()) {
      const Packet& packet = server_to_receiver[server_receiver_i++];
      if (packet.kind == webrtc_qos::TransportPacketKind::kRtcp) {
        (void)play->OnRtcpPacket(packet.bytes.data(), packet.bytes.size(),
                                 now_us);
        continue;
      }
      uint16_t seq = 0;
      if (!ParseRtpSeq(packet.bytes, session, &seq)) {
        return;
      }
      const bool in_bad_window = InBadWindow(scenario, frame_index);
      const uint16_t loss_mod = static_cast<uint16_t>(9 + (seed % 5));
      const uint16_t loss_remainder =
          static_cast<uint16_t>((2 + seed) % loss_mod);
      const bool drop = !packet.retransmission && in_bad_window &&
                        ((scenario.drop_dead_zone) ||
                         (scenario.periodic_loss &&
                          seq % loss_mod == loss_remainder));
      if (drop) {
        ++metrics.rtp_dropped_downlink;
        continue;
      }
      if (packet.retransmission) {
        ++metrics.retransmissions;
      }
      current_decode_complete_time_us = now_us;
      (void)play->OnRtpPacket(packet.bytes.data(), packet.bytes.size(), now_us);
    }
  };

  auto pump = [&](int frame_index, int64_t now_us) {
    for (int guard = 0; guard < 64; ++guard) {
      const size_t before = push_i + play_i + server_sender_i + server_receiver_i;
      drain_server_to_sender(now_us);
      drain_server_to_receiver(frame_index, now_us);
      drain_play_output(now_us);
      drain_server_to_sender(now_us);
      drain_server_to_receiver(frame_index, now_us);
      const size_t after = push_i + play_i + server_sender_i + server_receiver_i;
      if (before == after) {
        break;
      }
    }
    (void)play->Process(now_us);
  };

  auto drain_push_output = [&](int frame_index, int64_t now_us) {
    while (push_i < push_output.size()) {
      const Packet& packet = push_output[push_i++];
      if (packet.kind == webrtc_qos::TransportPacketKind::kRtp) {
        ++metrics.rtp_sent;
        // Weak-network send-rate gates should measure original media emission,
        // not sender-side retransmission or padding traffic.
        if (!packet.retransmission && !packet.padding) {
          if (InBadWindow(scenario, frame_index)) {
            ++metrics.bad_rtp_sent;
          }
          if (InRecoveryWindow(scenario, frame_index)) {
            ++metrics.recovery_rtp_sent;
          }
        }
        (void)server->OnSenderRtp(packet.bytes.data(), packet.bytes.size(),
                                  now_us);
      } else if (packet.kind == webrtc_qos::TransportPacketKind::kRtcp) {
        (void)server->OnSenderRtcp(packet.bytes.data(), packet.bytes.size(),
                                   now_us);
      }
      pump(frame_index, now_us);
    }
  };

  for (int frame = 0; frame < frames; ++frame) {
    const int64_t now_us =
        kMediaStartTimeUs + static_cast<int64_t>(frame) * kFrameDurationUs;
    const bool in_bad_window = InBadWindow(scenario, frame);
    const bool in_recovery_window = InRecoveryWindow(scenario, frame);
    auto process_status = push->Process(now_us);
    if (!process_status) {
      std::cerr << "push process failed frame=" << frame
                << " message=" << process_status.message << "\n";
      return 10;
    }
    drain_push_output(frame, now_us);
    pump(frame, now_us);
    if (in_bad_window) {
      ++metrics.total_bad_ticks;
    }
    if (in_recovery_window) {
      ++metrics.total_recovery_ticks;
    }

    if (scenario.inject_rate_cap) {
      webrtc_qos::DownlinkQuality quality;
      quality.ids = session.ids;
      quality.report_seq = frame + 1;
      quality.report_time_us = static_cast<uint64_t>(now_us);
      if (in_bad_window) {
        quality.fraction_lost_q8 = 192;
        quality.video_drop_frames = 1;
        quality.recv_bitrate_bps = min_bitrate_bps;
      }
      if (!server->OnDownlinkQuality(quality)) {
        std::cerr << "server rejected downlink quality\n";
        return 7;
      }
      const auto cap = server->CurrentSenderRateCap(now_us);
      if (!push->OnSenderRateCap(cap)) {
        std::cerr << "push rejected sender rate cap\n";
        return 8;
      }
    }

    const auto adaptation = push->GetEncoderAdaptation(now_us);
    metrics.min_target_bps =
        std::min(metrics.min_target_bps, adaptation.target_bitrate_bps);
    metrics.final_target_bps = adaptation.target_bitrate_bps;
    metrics.min_encoder_fps =
        std::min(metrics.min_encoder_fps, adaptation.max_fps);
    metrics.final_encoder_fps = adaptation.max_fps;
    if (in_bad_window) {
      metrics.min_bad_target_bps =
          std::min(metrics.min_bad_target_bps, adaptation.target_bitrate_bps);
      metrics.max_bad_target_bps =
          std::max(metrics.max_bad_target_bps, adaptation.target_bitrate_bps);
      metrics.min_bad_encoder_fps =
          std::min(metrics.min_bad_encoder_fps, adaptation.max_fps);
      metrics.max_bad_encoder_fps =
          std::max(metrics.max_bad_encoder_fps, adaptation.max_fps);
    }
    if (in_recovery_window) {
      if (metrics.recovery_start_frame < 0) {
        metrics.recovery_start_frame = frame;
      }
      if (metrics.target_recovered_frame < 0 &&
          adaptation.target_bitrate_bps >= start_bitrate_bps) {
        metrics.target_recovered_frame = frame;
      }
      if (metrics.fps_recovered_frame < 0 && adaptation.max_fps >= 25) {
        metrics.fps_recovered_frame = frame;
      }
      if (metrics.full_recovered_frame < 0 &&
          adaptation.target_bitrate_bps >= start_bitrate_bps &&
          adaptation.max_fps >= 25) {
        metrics.full_recovered_frame = frame;
      }
      metrics.max_recovery_target_bps =
          std::max(metrics.max_recovery_target_bps,
                   adaptation.target_bitrate_bps);
      metrics.max_recovery_encoder_fps =
          std::max(metrics.max_recovery_encoder_fps, adaptation.max_fps);
    }

    const uint32_t target_bitrate_bps = QuantizeBitrateBps(
        std::max<uint32_t>(min_bitrate_bps, adaptation.target_bitrate_bps));
    const uint32_t target_fps = std::max<uint32_t>(1, adaptation.max_fps);
    const bool need_encoder_reconfig =
        (target_bitrate_bps != current_encoder_bitrate_bps ||
         target_fps != current_encoder_fps) &&
        frame - last_encoder_reconfig_frame >= 10;
    if (need_encoder_reconfig) {
      if (!encoder.SetRates(target_bitrate_bps, target_fps)) {
        std::cerr << "encoder SetRates failed frame=" << frame << "\n";
        return 9;
      }
      current_encoder_bitrate_bps = target_bitrate_bps;
      current_encoder_fps = target_fps;
      last_encoder_reconfig_frame = frame;
    }

    const int fps_interval =
        adaptation.max_fps >= 25
            ? 1
            : (adaptation.max_fps >= 15 ? 2
                                        : (adaptation.max_fps >= 10 ? 3 : 6));
    if (frame % fps_interval != 0) {
      continue;
    }
    if (in_bad_window) {
      ++metrics.encoded_bad_ticks;
    }
    if (in_recovery_window) {
      ++metrics.encoded_recovery_ticks;
    }

    std::vector<uint8_t> y;
    std::vector<uint8_t> u;
    std::vector<uint8_t> v;
    if (source_mode.capture_i420) {
      FillCaptureI420(capture_i420_bytes, capture_i420_frames, frame, width,
                      height, &y, &u, &v);
    } else {
      FillSyntheticI420(content_mode, frame, seed, width, height, &y, &u, &v);
    }
    refs_y[frame] = y;
    std::vector<uint8_t> au;
    const bool force_keyframe =
        force_next_keyframe || adaptation.request_keyframe || frame % 30 == 0;
    auto status = encoder.EncodeI420(y.data(), width, u.data(), width / 2,
                                     v.data(), width / 2, force_keyframe,
                                     &au);
    if (!status) {
      std::cerr << "encode failed frame=" << frame << "\n";
      return 5;
    }
    ++metrics.encoded_frames;
    webrtc_qos::AnnexBAccessUnitView view;
    view.bytes = au.data();
    view.size = au.size();
    view.capture_time_us = now_us;
    view.keyframe = force_keyframe;
    auto push_status = push->PushAnnexBAccessUnit(view);
    if (!push_status) {
      if (push_status.code == webrtc_qos::StatusCode::kQueueFull) {
        ++metrics.push_queue_full;
        force_next_keyframe = true;
        continue;
      }
      std::cerr << "push failed frame=" << frame
                << " message=" << push_status.message << "\n";
      return 6;
    }
    force_next_keyframe = false;
    ++metrics.source_frames;
    ++metrics.pushed_frames;
    encoded_frame_indices.push_back(frame);
    process_status = push->Process(now_us + 1000);
    if (!process_status) {
      std::cerr << "push process after AU failed frame=" << frame
                << " message=" << process_status.message << "\n";
      return 11;
    }
    drain_push_output(frame, now_us + 1000);
    pump(frame, now_us + 2000);
  }

  pump(frames, kMediaStartTimeUs + static_cast<int64_t>(frames) *
                                  kFrameDurationUs + 1000000);
  std::vector<webrtc_qos::DecodedVideoFrame> flushed;
  auto flush_status = decoder.Flush(&flushed);
  if (!flush_status) {
    ++metrics.decode_errors;
  } else {
    AccountDecodedFrames(
        flushed, refs_y,
        kMediaStartTimeUs + static_cast<int64_t>(frames) * kFrameDurationUs,
        renderer_proxy_config, &metrics);
  }
  const auto decoder_stats = decoder.GetStats();
  metrics.decode_errors += static_cast<int>(decoder_stats.decode_errors);
  if (metrics.decoded_frames > 0) {
    metrics.avg_psnr_y /= metrics.decoded_frames;
    metrics.avg_ssim_y /= metrics.decoded_frames;
    metrics.playable_ratio =
        static_cast<double>(metrics.decoded_frames) / metrics.source_frames;
  } else {
    metrics.min_psnr_y = 0.0;
    metrics.min_ssim_y = 0.0;
  }
  if (metrics.min_target_bps == UINT32_MAX) {
    metrics.min_target_bps = 0;
  }
  if (metrics.min_encoder_fps == UINT32_MAX) {
    metrics.min_encoder_fps = 0;
  }
  if (metrics.min_bad_target_bps == UINT32_MAX) {
    metrics.min_bad_target_bps = 0;
  }
  if (metrics.min_bad_encoder_fps == UINT32_MAX) {
    metrics.min_bad_encoder_fps = 0;
  }
  auto recovery_ms = [](int start_frame, int recovered_frame) {
    if (start_frame < 0 || recovered_frame < start_frame) {
      return -1;
    }
    return (recovered_frame - start_frame) * 1000 / 30;
  };
  metrics.target_recovery_time_ms =
      recovery_ms(metrics.recovery_start_frame, metrics.target_recovered_frame);
  metrics.fps_recovery_time_ms =
      recovery_ms(metrics.recovery_start_frame, metrics.fps_recovered_frame);
  metrics.full_recovery_time_ms =
      recovery_ms(metrics.recovery_start_frame, metrics.full_recovered_frame);

  const double bad_send_rps =
      TickRate(metrics.encoded_bad_ticks, metrics.total_bad_ticks);
  const double bad_rtp_pps =
      TickRate(metrics.bad_rtp_sent, metrics.total_bad_ticks);
  const double recovery_send_rps =
      TickRate(metrics.encoded_recovery_ticks, metrics.total_recovery_ticks);
  const double recovery_rtp_pps =
      TickRate(metrics.recovery_rtp_sent, metrics.total_recovery_ticks);
  const double renderer_proxy_avg_latency_ms =
      metrics.renderer_proxy_rendered_frames == 0
          ? 0.0
          : static_cast<double>(metrics.renderer_proxy_total_latency_us) /
                metrics.renderer_proxy_rendered_frames / 1000.0;
  const double renderer_proxy_avg_wait_ms =
      metrics.renderer_proxy_rendered_frames == 0
          ? 0.0
          : static_cast<double>(metrics.renderer_proxy_total_wait_us) /
                metrics.renderer_proxy_rendered_frames / 1000.0;
  const double renderer_proxy_avg_gap_ms =
      metrics.renderer_proxy_inter_render_gap_count == 0
          ? 0.0
          : static_cast<double>(
                metrics.renderer_proxy_total_inter_render_gap_us) /
                metrics.renderer_proxy_inter_render_gap_count / 1000.0;
  const double renderer_proxy_avg_jitter_ms =
      metrics.renderer_proxy_inter_render_gap_count == 0
          ? 0.0
          : static_cast<double>(metrics.renderer_proxy_total_jitter_us) /
                metrics.renderer_proxy_inter_render_gap_count / 1000.0;
  bool pass = metrics.playable_ratio >= scenario.min_playable_ratio &&
              metrics.decode_errors == 0 &&
              metrics.avg_psnr_y >= scenario.min_avg_psnr_y &&
              metrics.avg_ssim_y >= scenario.min_avg_ssim_y &&
              metrics.freeze_count == 0 &&
              metrics.renderer_proxy_rendered_frames > 0 &&
              metrics.renderer_proxy_late_frames <=
                  max_renderer_proxy_late_frames &&
              metrics.renderer_proxy_drop_frames <=
                  max_renderer_proxy_drop_frames &&
              metrics.renderer_proxy_max_latency_ms <=
                  renderer_proxy_config.max_latency_ms &&
              metrics.renderer_proxy_max_inter_render_gap_ms <=
                  max_renderer_proxy_gap_ms;
  if (scenario.expect_rate_drop) {
    const uint32_t weak_target_limit_bps =
        max_weak_target_bps > 0
            ? max_weak_target_bps
            : std::max<uint32_t>(min_bitrate_bps * 2, min_bitrate_bps);
    pass = pass && bad_send_rps <= max_weak_send_rps &&
           bad_rtp_pps <= max_weak_rtp_pps &&
           metrics.min_bad_target_bps > 0 &&
           metrics.max_bad_target_bps > 0 &&
           metrics.min_bad_target_bps <= weak_target_limit_bps &&
           metrics.max_bad_target_bps <= weak_target_limit_bps &&
           metrics.min_bad_encoder_fps <= max_weak_encoder_fps &&
           metrics.max_bad_encoder_fps <= max_weak_encoder_fps;
  }
  if (scenario.expect_recovery) {
    pass = pass && recovery_send_rps >= 25.0 &&
           recovery_rtp_pps > bad_rtp_pps &&
           metrics.max_recovery_target_bps >= start_bitrate_bps &&
           metrics.max_recovery_encoder_fps >= 25 &&
           metrics.full_recovery_time_ms >= 0 &&
           metrics.full_recovery_time_ms <= max_recovery_time_ms;
  }
  if (scenario.expect_final_low) {
    pass = pass && metrics.final_target_bps <=
                       std::max<uint32_t>(min_bitrate_bps * 2,
                                          min_bitrate_bps) &&
           metrics.final_encoder_fps <= 10;
  }
  if (scenario.expect_nack) {
    pass = pass && metrics.nacks > 0;
  }
  if (scenario.expect_retransmission) {
    pass = pass && metrics.retransmissions > 0;
  }

  std::ofstream out(csv_path);
  out << "scenario,content_mode,seed,source_frames,encoded_frames,pushed_frames,"
         "push_queue_full,decoded_frames,playable_ratio,"
         "rtp_dropped_downlink,nacks,retransmissions,decode_errors,"
         "avg_psnr_y,min_psnr_y,avg_ssim_y,min_ssim_y,"
         "freeze_count,freeze_duration_ms,"
         "max_inter_render_gap_ms,renderer_proxy_rendered_frames,"
         "renderer_proxy_late_frames,renderer_proxy_drop_frames,"
         "renderer_proxy_avg_latency_ms,renderer_proxy_max_latency_ms,"
         "renderer_proxy_avg_wait_ms,renderer_proxy_max_wait_ms,"
         "renderer_proxy_avg_gap_ms,renderer_proxy_max_gap_ms,"
         "renderer_proxy_avg_jitter_ms,renderer_proxy_max_jitter_ms,"
         "renderer_proxy_target_delay_ms,max_renderer_proxy_late_ms,"
         "max_renderer_proxy_latency_ms,max_renderer_proxy_gap_ms,"
         "bad_send_rps,bad_rtp_pps,"
         "recovery_send_rps,recovery_rtp_pps,min_target_bps,"
         "final_target_bps,min_encoder_fps,final_encoder_fps,"
         "min_bad_target_bps,max_bad_target_bps,max_recovery_target_bps,"
         "min_bad_encoder_fps,max_bad_encoder_fps,"
         "max_recovery_encoder_fps,target_recovery_time_ms,"
         "fps_recovery_time_ms,full_recovery_time_ms,"
         "max_recovery_time_ms,pass\n";
  out << metrics.scenario << ',' << source_mode.label << ',' << metrics.seed << ','
      << metrics.source_frames << ',' << metrics.encoded_frames << ','
      << metrics.pushed_frames << ',' << metrics.push_queue_full << ','
      << metrics.decoded_frames << ',' << metrics.playable_ratio << ','
      << metrics.rtp_dropped_downlink << ',' << metrics.nacks << ','
      << metrics.retransmissions << ',' << metrics.decode_errors << ','
      << metrics.avg_psnr_y << ',' << metrics.min_psnr_y << ','
      << metrics.avg_ssim_y << ',' << metrics.min_ssim_y << ','
      << metrics.freeze_count << ',' << metrics.freeze_duration_ms << ','
      << metrics.max_inter_render_gap_ms << ','
      << metrics.renderer_proxy_rendered_frames << ','
      << metrics.renderer_proxy_late_frames << ','
      << metrics.renderer_proxy_drop_frames << ','
      << renderer_proxy_avg_latency_ms << ','
      << metrics.renderer_proxy_max_latency_ms << ','
      << renderer_proxy_avg_wait_ms << ','
      << metrics.renderer_proxy_max_wait_ms << ','
      << renderer_proxy_avg_gap_ms << ','
      << metrics.renderer_proxy_max_inter_render_gap_ms << ','
      << renderer_proxy_avg_jitter_ms << ','
      << metrics.renderer_proxy_max_jitter_ms << ','
      << renderer_proxy_config.target_delay_ms << ','
      << renderer_proxy_config.max_late_ms << ','
      << renderer_proxy_config.max_latency_ms << ','
      << max_renderer_proxy_gap_ms << ',' << bad_send_rps << ','
      << bad_rtp_pps << ',' << recovery_send_rps << ','
      << recovery_rtp_pps << ',' << metrics.min_target_bps << ','
      << metrics.final_target_bps << ',' << metrics.min_encoder_fps << ','
      << metrics.final_encoder_fps << ',' << metrics.min_bad_target_bps << ','
      << metrics.max_bad_target_bps << ','
      << metrics.max_recovery_target_bps << ','
      << metrics.min_bad_encoder_fps << ','
      << metrics.max_bad_encoder_fps << ','
      << metrics.max_recovery_encoder_fps << ','
      << metrics.target_recovery_time_ms << ','
      << metrics.fps_recovery_time_ms << ','
      << metrics.full_recovery_time_ms << ','
      << max_recovery_time_ms << ','
      << (pass ? "true" : "false") << '\n';

  std::cout << "ffmpeg_qoe scenario=" << metrics.scenario
            << " seed=" << metrics.seed
            << " content_mode=" << source_mode.label
            << " source=" << metrics.source_frames
            << " encoded=" << metrics.encoded_frames
            << " pushed=" << metrics.pushed_frames
            << " push_queue_full=" << metrics.push_queue_full
            << " decoded=" << metrics.decoded_frames
            << " playable_ratio=" << metrics.playable_ratio
            << " dropped=" << metrics.rtp_dropped_downlink
            << " nack=" << metrics.nacks
            << " retransmission=" << metrics.retransmissions
            << " decode_errors=" << metrics.decode_errors
            << " avg_psnr_y=" << metrics.avg_psnr_y
            << " min_psnr_y=" << metrics.min_psnr_y
            << " avg_ssim_y=" << metrics.avg_ssim_y
            << " min_ssim_y=" << metrics.min_ssim_y
            << " freeze_count=" << metrics.freeze_count
            << " freeze_duration_ms=" << metrics.freeze_duration_ms
            << " max_inter_render_gap_ms=" << metrics.max_inter_render_gap_ms
            << " renderer_proxy_rendered="
            << metrics.renderer_proxy_rendered_frames
            << " renderer_proxy_late="
            << metrics.renderer_proxy_late_frames
            << " renderer_proxy_drop="
            << metrics.renderer_proxy_drop_frames
            << " renderer_proxy_avg_latency_ms="
            << renderer_proxy_avg_latency_ms
            << " renderer_proxy_max_latency_ms="
            << metrics.renderer_proxy_max_latency_ms
            << " renderer_proxy_avg_wait_ms=" << renderer_proxy_avg_wait_ms
            << " renderer_proxy_max_wait_ms="
            << metrics.renderer_proxy_max_wait_ms
            << " renderer_proxy_avg_gap_ms=" << renderer_proxy_avg_gap_ms
            << " renderer_proxy_max_gap_ms="
            << metrics.renderer_proxy_max_inter_render_gap_ms
            << " renderer_proxy_avg_jitter_ms=" << renderer_proxy_avg_jitter_ms
            << " renderer_proxy_max_jitter_ms="
            << metrics.renderer_proxy_max_jitter_ms
            << " bad_send_rps=" << bad_send_rps
            << " bad_rtp_pps=" << bad_rtp_pps
            << " max_weak_send_rps=" << max_weak_send_rps
            << " max_weak_rtp_pps=" << max_weak_rtp_pps
            << " recovery_send_rps=" << recovery_send_rps
            << " recovery_rtp_pps=" << recovery_rtp_pps
            << " min_target=" << metrics.min_target_bps
            << " final_target=" << metrics.final_target_bps
            << " min_fps=" << metrics.min_encoder_fps
            << " final_fps=" << metrics.final_encoder_fps
            << " bad_min_target=" << metrics.min_bad_target_bps
            << " bad_max_target=" << metrics.max_bad_target_bps
            << " recovery_max_target=" << metrics.max_recovery_target_bps
            << " bad_min_fps=" << metrics.min_bad_encoder_fps
            << " bad_max_fps=" << metrics.max_bad_encoder_fps
            << " recovery_max_fps=" << metrics.max_recovery_encoder_fps
            << " target_recovery_ms=" << metrics.target_recovery_time_ms
            << " fps_recovery_ms=" << metrics.fps_recovery_time_ms
            << " full_recovery_ms=" << metrics.full_recovery_time_ms
            << " max_recovery_ms=" << max_recovery_time_ms
            << " pass=" << (pass ? "true" : "false") << "\n";
  return pass ? 0 : 1;
}
EOF

cmake -S "${WORK_DIR}" -B "${WORK_DIR}/build" \
  -DCMAKE_PREFIX_PATH="${PREFIX}" >/dev/null
cmake --build "${WORK_DIR}/build" -j2 >/dev/null

CSV_PATH="${OUTPUT_DIR}/${OUTPUT_BASENAME}.csv"
LOG_PATH="${OUTPUT_DIR}/${OUTPUT_BASENAME}.log"
rm -f "${CSV_PATH}" "${LOG_PATH}"
tmp_csvs=()
ok=1
for seed in ${SEEDS}; do
  for content_mode in ${CONTENT_MODES}; do
    for scenario in ${SCENARIOS}; do
      safe_content_mode="$(printf '%s' "${content_mode}" | sed 's/[^A-Za-z0-9_.-]/_/g')"
      scenario_csv="${WORK_DIR}/${scenario}_${safe_content_mode}_seed_${seed}.csv"
      tmp_csvs+=("${scenario_csv}")
      if ! "${WORK_DIR}/build/webrtc_first_ffmpeg_qoe" \
          "${FRAMES}" "${WIDTH}" "${HEIGHT}" "${scenario_csv}" "${scenario}" \
          "${START_BITRATE_BPS}" "${MIN_BITRATE_BPS}" "${MAX_BITRATE_BPS}" \
          "${MIN_PLAYABLE_RATIO}" "${MIN_AVG_PSNR_Y}" "${MIN_AVG_SSIM_Y}" \
          "${seed}" \
          "${content_mode}" "${MAX_WEAK_SEND_RPS}" "${MAX_WEAK_RTP_PPS}" \
          "${MAX_WEAK_TARGET_BPS}" "${MAX_WEAK_ENCODER_FPS}" \
          "${MAX_RECOVERY_TIME_MS}" \
          "${RENDERER_PROXY_TARGET_DELAY_MS}" \
          "${MAX_RENDERER_PROXY_LATE_MS}" \
          "${MAX_RENDERER_PROXY_LATENCY_MS}" \
          "${MAX_RENDERER_PROXY_LATE_FRAMES}" \
          "${MAX_RENDERER_PROXY_DROP_FRAMES}" \
          "${MAX_RENDERER_PROXY_GAP_MS}" \
          | tee -a "${LOG_PATH}"; then
        ok=0
      fi
    done
  done
done

for csv in "${tmp_csvs[@]}"; do
  if [[ ! -s "${CSV_PATH}" ]]; then
    cat "${csv}" >"${CSV_PATH}"
  else
    tail -n +2 "${csv}" >>"${CSV_PATH}"
  fi
done

echo "wrote ${CSV_PATH}"
if [[ "${ok}" -ne 1 ]]; then
  exit 1
fi
