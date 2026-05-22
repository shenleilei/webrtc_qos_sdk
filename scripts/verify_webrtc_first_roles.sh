#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-/root/output}"
BUILD_DIR="${BUILD_DIR:-/tmp/webrtc_qos_webrtc_first_demo_build.$$}"

required_targets=(
  WebRtcQosSdk::webrtc_googcc
  WebRtcQosSdk::webrtc_pacing
  WebRtcQosSdk::webrtc_rtp_rtcp
  WebRtcQosSdk::webrtc_video_jitter
  WebRtcQosSdk::webrtc_nack_requester
  WebRtcQosSdk::transport_packet_history
  WebRtcQosSdk::role_push
  WebRtcQosSdk::role_play
  WebRtcQosSdk::role_server
  WebRtcQosSdk::role_transport
)

legacy_targets=(
  WebRtcQosSdk::webrtc_qos_rtp
  WebRtcQosSdk::webrtc_qos_rtcp
  WebRtcQosSdk::webrtc_qos_nack
  WebRtcQosSdk::webrtc_qos_pacer
  WebRtcQosSdk::webrtc_qos_video
)

work_dir="${WORK_DIR:-/tmp/webrtc_qos_webrtc_first_roles.$$}"
rm -rf "${work_dir}"
mkdir -p "${work_dir}"

cat > "${work_dir}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(verify_webrtc_first_roles LANGUAGES CXX)
find_package(WebRtcQosSdk REQUIRED)
foreach(target IN ITEMS
  WebRtcQosSdk::webrtc_googcc
  WebRtcQosSdk::webrtc_pacing
  WebRtcQosSdk::webrtc_rtp_rtcp
  WebRtcQosSdk::webrtc_video_jitter
  WebRtcQosSdk::webrtc_nack_requester
  WebRtcQosSdk::transport_packet_history
  WebRtcQosSdk::role_push
  WebRtcQosSdk::role_play
  WebRtcQosSdk::role_server
  WebRtcQosSdk::role_transport)
  if(NOT TARGET "${target}")
    message(FATAL_ERROR "missing required target: ${target}")
  endif()
endforeach()
foreach(target IN ITEMS
  WebRtcQosSdk::webrtc_qos_rtp
  WebRtcQosSdk::webrtc_qos_rtcp
  WebRtcQosSdk::webrtc_qos_nack
  WebRtcQosSdk::webrtc_qos_pacer
  WebRtcQosSdk::webrtc_qos_video)
  if(TARGET "${target}")
    message(FATAL_ERROR "legacy target still exported: ${target}")
  endif()
endforeach()
add_executable(verify_webrtc_first_roles main.cc)
target_link_libraries(verify_webrtc_first_roles PRIVATE
  WebRtcQosSdk::role_push
  WebRtcQosSdk::role_play
  WebRtcQosSdk::role_server
  WebRtcQosSdk::role_transport)
EOF

cat > "${work_dir}/main.cc" <<'EOF'
#include "webrtc_qos/server_qos_router.h"
#include "webrtc_qos/video_play_client.h"
#include "webrtc_qos/video_push_client.h"

int main() {
  return 0;
}
EOF

cmake -S "${work_dir}" -B "${work_dir}/build" \
  -DCMAKE_PREFIX_PATH="${PREFIX}"
cmake --build "${work_dir}/build" -j2

config="${PREFIX}/lib/cmake/WebRtcQosSdk/WebRtcQosSdkConfig.cmake"
if [[ ! -f "${config}" ]]; then
  echo "missing package config: ${config}" >&2
  exit 1
fi

for target in "${required_targets[@]}"; do
  if ! rg -F "${target}" "${config}" "${PREFIX}/lib/cmake/WebRtcQosSdk" >/dev/null; then
    echo "required role target is not declared by package: ${target}" >&2
    exit 1
  fi
done

for target in "${legacy_targets[@]}"; do
  if rg -F "${target}" "${config}" "${PREFIX}/lib/cmake/WebRtcQosSdk" >/dev/null; then
    echo "legacy role target still present in package: ${target}" >&2
    exit 1
  fi
done

SDK_ROOT="${SDK_ROOT}" PREFIX="${PREFIX}" \
  "${SDK_ROOT}/scripts/verify_no_selfmade_media_stack.sh"
PREFIX="${PREFIX}" "${SDK_ROOT}/scripts/verify_webrtc_modules.sh"
PREFIX="${PREFIX}" "${SDK_ROOT}/scripts/verify_webrtc_first_loopback.sh"
PREFIX="${PREFIX}" "${SDK_ROOT}/scripts/verify_webrtc_first_pacing_probe.sh"
PREFIX="${PREFIX}" "${SDK_ROOT}/scripts/verify_webrtc_first_multitrack.sh"
PREFIX="${PREFIX}" "${SDK_ROOT}/scripts/run_webrtc_first_multitrack_matrix.sh"

rm -rf "${BUILD_DIR}"
cmake -S "${SDK_ROOT}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DWEBRTC_QOS_ENABLE_WEBRTC_FACADE=ON \
  -DWEBRTC_QOS_WEBRTC_MODULE_PREFIX="${PREFIX}" >/dev/null
cmake --build "${BUILD_DIR}" \
  --target webrtc_qos_webrtc_first_loopback_demo \
           webrtc_qos_webrtc_first_udp_demo -j2 >/dev/null
demo_output="$("${BUILD_DIR}/webrtc_qos_webrtc_first_loopback_demo")"
echo "${demo_output}"
if ! grep -q "backend=webrtc_first_facade" <<<"${demo_output}"; then
  echo "WebRTC-first demo did not report WebRTC facade backend" >&2
  exit 1
fi
if ! grep -q "peer_connection=false" <<<"${demo_output}"; then
  echo "WebRTC-first demo must not use PeerConnection" >&2
  exit 1
fi
if ! grep -q "walking_dead_zone_recover_single_track.*pass=true" <<<"${demo_output}"; then
  echo "WebRTC-first demo did not pass single-track weak-network recovery scenario" >&2
  exit 1
fi
if ! grep -q "walking_dead_zone_recover_dual_track.*pass=true" <<<"${demo_output}"; then
  echo "WebRTC-first demo did not pass dual-track weak-network recovery scenario" >&2
  exit 1
fi
udp_demo_output="$("${BUILD_DIR}/webrtc_qos_webrtc_first_udp_demo" selftest 36)"
echo "${udp_demo_output}"
if ! grep -q "udp_selftest backend=webrtc_first_facade" <<<"${udp_demo_output}"; then
  echo "WebRTC-first UDP demo did not report facade backend" >&2
  exit 1
fi
if ! grep -q "transport=udp" <<<"${udp_demo_output}"; then
  echo "WebRTC-first UDP demo did not use UDP transport" >&2
  exit 1
fi
if ! grep -q "peer_connection=false" <<<"${udp_demo_output}"; then
  echo "WebRTC-first UDP demo must not use PeerConnection" >&2
  exit 1
fi
if ! grep -q "pass=true" <<<"${udp_demo_output}"; then
  echo "WebRTC-first UDP demo selftest failed" >&2
  exit 1
fi
udp_sender_output="$("${BUILD_DIR}/webrtc_qos_webrtc_first_udp_demo" \
  sender 0 127.0.0.1:9 3)"
echo "${udp_sender_output}"
if ! grep -q "udp_sender backend=webrtc_first_facade" <<<"${udp_sender_output}"; then
  echo "WebRTC-first UDP sender role did not start with facade backend" >&2
  exit 1
fi
if ! grep -q "transport=udp" <<<"${udp_sender_output}"; then
  echo "WebRTC-first UDP sender role did not use UDP transport" >&2
  exit 1
fi
if ! grep -q "peer_connection=false" <<<"${udp_sender_output}"; then
  echo "WebRTC-first UDP sender role must not use PeerConnection" >&2
  exit 1
fi
udp_server_output="$("${BUILD_DIR}/webrtc_qos_webrtc_first_udp_demo" \
  server 0 127.0.0.1:9 127.0.0.1:10 3)"
echo "${udp_server_output}"
if ! grep -q "udp_server backend=webrtc_first_facade" <<<"${udp_server_output}"; then
  echo "WebRTC-first UDP server role did not start with facade backend" >&2
  exit 1
fi
if ! grep -q "transport=udp" <<<"${udp_server_output}"; then
  echo "WebRTC-first UDP server role did not use UDP transport" >&2
  exit 1
fi
if ! grep -q "peer_connection=false" <<<"${udp_server_output}"; then
  echo "WebRTC-first UDP server role must not use PeerConnection" >&2
  exit 1
fi
udp_receiver_output="$("${BUILD_DIR}/webrtc_qos_webrtc_first_udp_demo" \
  receiver 0 127.0.0.1:9 3)"
echo "${udp_receiver_output}"
if ! grep -q "udp_receiver backend=webrtc_first_facade" <<<"${udp_receiver_output}"; then
  echo "WebRTC-first UDP receiver role did not start with facade backend" >&2
  exit 1
fi
if ! grep -q "transport=udp" <<<"${udp_receiver_output}"; then
  echo "WebRTC-first UDP receiver role did not use UDP transport" >&2
  exit 1
fi
if ! grep -q "peer_connection=false" <<<"${udp_receiver_output}"; then
  echo "WebRTC-first UDP receiver role must not use PeerConnection" >&2
  exit 1
fi

if rg -n "PeerConnection|CreatePeerConnection|rtc::Thread.*Socket|AsyncPacketSocket|BasicPacketSocketFactory" \
    "${SDK_ROOT}/include" "${SDK_ROOT}/src" "${SDK_ROOT}/demo" >/dev/null; then
  echo "WebRTC-first facade must not introduce PeerConnection or WebRTC socket ownership" >&2
  exit 1
fi

if rg -n "webrtc_qos_rtp|webrtc_qos_rtcp|webrtc_qos_nack|webrtc_qos_pacer|webrtc_qos_video" \
    "${config}" "${PREFIX}/lib/cmake/WebRtcQosSdk" >/dev/null; then
  echo "WebRTC-first roles still reference legacy self-made media targets" >&2
  exit 1
fi

echo "WebRTC-first role verification passed"
