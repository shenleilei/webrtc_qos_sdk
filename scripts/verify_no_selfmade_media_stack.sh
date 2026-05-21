#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-}"

legacy_paths=(
  include/webrtc_qos/rtp_packet.h
  include/webrtc_qos/rtcp_packets.h
  include/webrtc_qos/sender_pacer.h
  include/webrtc_qos/receiver_qos_observer.h
  include/webrtc_qos/retransmission_cache.h
  include/webrtc_qos/video_sender.h
  include/webrtc_qos/video_receiver.h
  include/webrtc_qos/video_jitter_player.h
  include/webrtc_qos/transport_feedback.h
  src/rtp_packet.cc
  src/rtp_packet.h
  src/rtcp_packets.cc
  src/sender_pacer.cc
  src/receiver_qos_observer.cc
  src/retransmission_cache.cc
  src/video_sender.cc
  src/video_receiver.cc
  src/video_jitter_player.cc
  src/transport_feedback.cc
)

legacy_targets=(
  webrtc_qos_rtp
  webrtc_qos_rtcp
  webrtc_qos_nack
  webrtc_qos_pacer
  webrtc_qos_video
)

violations=0
for path in "${legacy_paths[@]}"; do
  if [[ -e "${SDK_ROOT}/${path}" ]]; then
    echo "legacy self-made media stack path still exists: ${path}" >&2
    violations=$((violations + 1))
  fi
done

for target in "${legacy_targets[@]}"; do
  if rg -n "(^|[^A-Za-z0-9_])${target}([^A-Za-z0-9_]|$)" \
      "${SDK_ROOT}/CMakeLists.txt" "${SDK_ROOT}/cmake" >/dev/null; then
    echo "legacy self-made CMake target still exported/referenced: ${target}" >&2
    violations=$((violations + 1))
  fi
done

if [[ -n "${PREFIX}" ]]; then
  legacy_archives=(
    libwebrtc_qos_rtp.a
    libwebrtc_qos_rtcp.a
    libwebrtc_qos_nack.a
    libwebrtc_qos_pacer.a
    libwebrtc_qos_video.a
  )
  for archive in "${legacy_archives[@]}"; do
    if [[ -f "${PREFIX}/lib/${archive}" ]]; then
      echo "legacy self-made archive still exists in dist: ${archive}" >&2
      violations=$((violations + 1))
    fi
  done
fi

if ((violations > 0)); then
  echo "self-made media stack verification failed: ${violations} violation(s)" >&2
  exit 1
fi

echo "self-made media stack verification passed"
