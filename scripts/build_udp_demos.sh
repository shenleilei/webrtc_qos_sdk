#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-/root/output}"
LIBATOMIC_DIR="${LIBATOMIC_DIR:-/usr/lib/gcc/x86_64-redhat-linux/10}"
CXX="${CXX:-g++}"

mkdir -p "${PREFIX}/demo"

"${SDK_ROOT}/scripts/build_googcc_bridge.sh"
"${SDK_ROOT}/scripts/build_video_jitter_bridge.sh"

COMMON_FLAGS=(
  -std=c++20
  -I"${PREFIX}/include"
  -I"${SDK_ROOT}"
)

COMMON_LIBS=(
  "${PREFIX}/lib/libwebrtc_qos_googcc_bridge.a"
  "${PREFIX}/lib/libwebrtc_qos_video_jitter_bridge.a"
  "${PREFIX}/lib/libwebrtc_qos_video.a"
  "${PREFIX}/lib/libwebrtc_qos_pacer.a"
  "${PREFIX}/lib/libwebrtc_qos_feedback.a"
  "${PREFIX}/lib/libwebrtc_qos_nack.a"
  "${PREFIX}/lib/libwebrtc_qos_rtcp.a"
  "${PREFIX}/lib/libwebrtc_qos_rtp.a"
  "${PREFIX}/lib/libwebrtc_qos_core.a"
  "${PREFIX}/lib/libwebrtc_qos_googcc_adapter.a"
  "${PREFIX}/lib/libwebrtc_qos_video_jitter_adapter.a"
  -L"${LIBATOMIC_DIR}"
  -lpthread
  -ldl
  -lrt
  -latomic
)

"${CXX}" "${COMMON_FLAGS[@]}" \
  "${SDK_ROOT}/demo/udp_sender/main.cc" \
  "${COMMON_LIBS[@]}" \
  -o "${PREFIX}/demo/udp_sender_demo"

"${CXX}" "${COMMON_FLAGS[@]}" \
  "${SDK_ROOT}/demo/udp_server/main.cc" \
  "${COMMON_LIBS[@]}" \
  -o "${PREFIX}/demo/udp_server_demo"

"${CXX}" "${COMMON_FLAGS[@]}" \
  "${SDK_ROOT}/demo/udp_receiver/main.cc" \
  "${COMMON_LIBS[@]}" \
  -o "${PREFIX}/demo/udp_receiver_demo"

ls -l "${PREFIX}/demo/udp_sender_demo" \
  "${PREFIX}/demo/udp_server_demo" \
  "${PREFIX}/demo/udp_receiver_demo"
