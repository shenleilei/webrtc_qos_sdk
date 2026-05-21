#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
WEBRTC_ROOT="${WEBRTC_ROOT:-/root/src}"
PREFIX="${PREFIX:-/root/output}"
BUILD_DIR="${BUILD_DIR:-${SDK_ROOT}/build}"
SOAK_DURATION_SEC="${SOAK_DURATION_SEC:-8}"
SOAK_MATRIX_RUNS="${SOAK_MATRIX_RUNS:-1}"

cmake --build "${BUILD_DIR}" -j2
cmake --install "${BUILD_DIR}" --prefix "${PREFIX}"

"${BUILD_DIR}/webrtc_qos_selftest"
"${BUILD_DIR}/qos_loopback_demo"
"${BUILD_DIR}/capture_push_demo"
"${BUILD_DIR}/receive_play_demo"
"${BUILD_DIR}/transport_port_demo"
"${BUILD_DIR}/production_transport_demo"
"${BUILD_DIR}/dynamic_qos_demo"
if [[ -x "${BUILD_DIR}/ffmpeg_encoder_demo" ]]; then
  "${BUILD_DIR}/ffmpeg_encoder_demo"
fi
if [[ -x "${BUILD_DIR}/long_stream_qoe_demo" ]]; then
  "${BUILD_DIR}/long_stream_qoe_demo" \
    --strategy=adaptive \
    --summary=/tmp/webrtc_qos_long_stream_qoe_adaptive.json
fi

"${PREFIX}/demo/webrtc_qos_googcc_smoke"
"${PREFIX}/demo/webrtc_qos_video_jitter_smoke"

"${SDK_ROOT}/scripts/build_output_integration_demo.sh"
"${SDK_ROOT}/scripts/build_udp_demos.sh"
BUILD_DIR="${BUILD_DIR}" "${SDK_ROOT}/scripts/run_dynamic_qos_matrix.sh"
if [[ -x "${BUILD_DIR}/long_stream_qoe_demo" ]]; then
  BUILD_DIR="${BUILD_DIR}" "${SDK_ROOT}/scripts/run_long_stream_qoe_matrix.sh"
fi
BUILD_DEMOS=0 RUNS=1 "${SDK_ROOT}/scripts/run_udp_netem_matrix.sh"
BUILD_DIR="${BUILD_DIR}" "${SDK_ROOT}/scripts/run_udp_direct_long_stream_smoke.sh"
BUILD_DEMOS=0 DURATION_SEC="${SOAK_DURATION_SEC}" MATRIX_RUNS="${SOAK_MATRIX_RUNS}" \
  "${SDK_ROOT}/scripts/run_udp_soak.sh"
"${SDK_ROOT}/scripts/verify_role_linking.sh"
"${SDK_ROOT}/scripts/verify_cmake_package.sh"

if [[ -d "${WEBRTC_ROOT}" ]]; then
  (
    cd "${WEBRTC_ROOT}"
    PATH=/root/py311bin:/root/depot_tools:$PATH \
      gn path out/qos_min //sdk_qos:webrtc_qos_video_jitter_adapter_complete //third_party/protobuf:protoc
    PATH=/root/py311bin:/root/depot_tools:$PATH \
      gn path out/qos_min //sdk_qos:webrtc_qos_video_jitter_adapter_complete //third_party/libyuv:libyuv
    PATH=/root/py311bin:/root/depot_tools:$PATH \
      gn path out/qos_min //sdk_qos:webrtc_qos_video_jitter_adapter_complete //modules/rtp_rtcp:rtp_rtcp
    PATH=/root/py311bin:/root/depot_tools:$PATH \
      gn path out/qos_min //sdk_qos:webrtc_qos_googcc_adapter_complete //third_party/protobuf:protoc
  )
fi

required_files=(
  "${PREFIX}/include/webrtc_qos/transport_port.h"
  "${PREFIX}/include/webrtc_qos/production_transport_adapter.h"
  "${PREFIX}/include/webrtc_qos/sender_qos_controller.h"
  "${PREFIX}/include/webrtc_qos/video_jitter_player.h"
  "${PREFIX}/lib/libwebrtc_qos_transport.a"
  "${PREFIX}/lib/libwebrtc_qos_googcc_adapter.a"
  "${PREFIX}/lib/libwebrtc_qos_video_jitter_adapter.a"
  "${PREFIX}/lib/cmake/WebRtcQosSdk/WebRtcQosSdkConfig.cmake"
  "${PREFIX}/demo/transport_port_demo"
  "${PREFIX}/demo/production_transport_demo"
  "${PREFIX}/demo/dynamic_qos_demo"
  "${PREFIX}/demo/udp_sender_demo"
  "${PREFIX}/demo/udp_server_demo"
  "${PREFIX}/demo/udp_receiver_demo"
)

if [[ -x "${BUILD_DIR}/ffmpeg_encoder_demo" ]]; then
  required_files+=(
    "${PREFIX}/include/webrtc_qos/ffmpeg_h264_encoder.h"
    "${PREFIX}/include/webrtc_qos/ffmpeg_h264_decoder.h"
    "${PREFIX}/lib/libwebrtc_qos_ffmpeg_encoder.a"
    "${PREFIX}/lib/libwebrtc_qos_ffmpeg_decoder.a"
    "${PREFIX}/demo/ffmpeg_encoder_demo"
    "${PREFIX}/demo/long_stream_qoe_demo"
  )
fi

for path in "${required_files[@]}"; do
  if [[ ! -f "${path}" ]]; then
    echo "missing required Phase-1a artifact: ${path}" >&2
    exit 1
  fi
done

echo "phase1a verification passed prefix=${PREFIX}"
