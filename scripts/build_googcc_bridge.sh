#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-/root/output}"
BUILD_DIR="${BUILD_DIR:-${SDK_ROOT}/build_googcc_bridge}"
LIBATOMIC_DIR="${LIBATOMIC_DIR:-/usr/lib/gcc/x86_64-redhat-linux/10}"
CXX="${CXX:-g++}"
AR="${AR:-ar}"

mkdir -p "${BUILD_DIR}" "${PREFIX}/lib" "${PREFIX}/include/webrtc_qos" \
  "${PREFIX}/demo"

"${CXX}" -std=c++20 -O2 -fPIC \
  -I"${SDK_ROOT}/include" \
  -I"${PREFIX}/include" \
  -c "${SDK_ROOT}/src/sender_qos_googcc_bridge.cc" \
  -o "${BUILD_DIR}/sender_qos_googcc_bridge.o"

rm -f "${PREFIX}/lib/libwebrtc_qos_googcc_bridge.a"
"${AR}" rcs "${PREFIX}/lib/libwebrtc_qos_googcc_bridge.a" \
  "${BUILD_DIR}/sender_qos_googcc_bridge.o"

cp "${SDK_ROOT}/include/webrtc_qos/sender_qos_googcc_bridge.h" \
  "${PREFIX}/include/webrtc_qos/sender_qos_googcc_bridge.h"

"${CXX}" -std=c++20 \
  -I"${PREFIX}/include" \
  "${SDK_ROOT}/demo/googcc_bridge_smoke/main.cc" \
  "${PREFIX}/lib/libwebrtc_qos_googcc_bridge.a" \
  "${PREFIX}/lib/libwebrtc_qos_feedback.a" \
  "${PREFIX}/lib/libwebrtc_qos_googcc_adapter.a" \
  -L"${LIBATOMIC_DIR}" \
  -lpthread -ldl -lrt -latomic \
  -o "${PREFIX}/demo/webrtc_qos_googcc_bridge_smoke"

"${PREFIX}/demo/webrtc_qos_googcc_bridge_smoke"
