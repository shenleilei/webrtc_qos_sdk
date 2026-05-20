#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-/root/output}"
LIBATOMIC_DIR="${LIBATOMIC_DIR:-/usr/lib/gcc/x86_64-redhat-linux/10}"
CXX="${CXX:-g++}"

mkdir -p "${PREFIX}/demo"

"${SDK_ROOT}/scripts/build_googcc_bridge.sh"
"${SDK_ROOT}/scripts/build_video_jitter_bridge.sh"

"${CXX}" -std=c++20 \
  -I"${PREFIX}/include" \
  "${SDK_ROOT}/demo/output_integration/main.cc" \
  "${PREFIX}/lib/libwebrtc_qos_googcc_bridge.a" \
  "${PREFIX}/lib/libwebrtc_qos_video_jitter_bridge.a" \
  "${PREFIX}/lib/libwebrtc_qos_video.a" \
  "${PREFIX}/lib/libwebrtc_qos_pacer.a" \
  "${PREFIX}/lib/libwebrtc_qos_feedback.a" \
  "${PREFIX}/lib/libwebrtc_qos_nack.a" \
  "${PREFIX}/lib/libwebrtc_qos_rtcp.a" \
  "${PREFIX}/lib/libwebrtc_qos_rtp.a" \
  "${PREFIX}/lib/libwebrtc_qos_core.a" \
  "${PREFIX}/lib/libwebrtc_qos_googcc_adapter.a" \
  "${PREFIX}/lib/libwebrtc_qos_video_jitter_adapter.a" \
  -L"${LIBATOMIC_DIR}" \
  -lpthread -ldl -lrt -latomic \
  -o "${PREFIX}/demo/output_integration_demo"

"${PREFIX}/demo/output_integration_demo"
