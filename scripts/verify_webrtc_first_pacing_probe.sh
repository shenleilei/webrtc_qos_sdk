#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/root/output}"
WORK_DIR="${WORK_DIR:-/tmp/webrtc_qos_pacing_probe.$$}"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

cat > "${WORK_DIR}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(verify_webrtc_first_pacing_probe LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(WebRtcQosSdk REQUIRED CONFIG)

if(NOT TARGET WebRtcQosSdk::role_push)
  message(FATAL_ERROR "missing WebRtcQosSdk::role_push")
endif()

add_executable(verify_webrtc_first_pacing_probe main.cc)
target_link_libraries(verify_webrtc_first_pacing_probe PRIVATE
  WebRtcQosSdk::role_push)
EOF

cat > "${WORK_DIR}/main.cc" <<'EOF'
#include <cstdint>
#include <iostream>
#include <memory>
#include <vector>

#include "webrtc_qos/video_push_client.h"

namespace {

void AppendStartCodeAndNalu(const uint8_t* nalu,
                            size_t nalu_size,
                            std::vector<uint8_t>* out) {
  out->push_back(0x00);
  out->push_back(0x00);
  out->push_back(0x00);
  out->push_back(0x01);
  out->insert(out->end(), nalu, nalu + nalu_size);
}

std::vector<uint8_t> MakeAccessUnit() {
  const uint8_t sps[] = {0x67, 0x42, 0xc0, 0x15, 0x8c, 0x68, 0x14, 0x19,
                         0x79, 0xe0, 0x1e, 0x11, 0x08, 0xd4, 0x00, 0x04};
  const uint8_t pps[] = {0x68, 0xce, 0x3c, 0x80, 0x00, 0x2e};
  const uint8_t idr[] = {0x65, 0xb8, 0x00, 0x04, 0x08, 0x79,
                         0x31, 0x40, 0x00, 0x42, 0xae, 0x4d};
  std::vector<uint8_t> au;
  AppendStartCodeAndNalu(sps, sizeof(sps), &au);
  AppendStartCodeAndNalu(pps, sizeof(pps), &au);
  AppendStartCodeAndNalu(idr, sizeof(idr), &au);
  return au;
}

}  // namespace

int main() {
  webrtc_qos::SessionConfig session;
  session.ids.session_id = 1;
  session.ids.stream_id = 1;
  session.ids.transport_id = 1;
  session.ids.sender_ssrc = 0x12345678;
  session.start_bitrate_bps = 1200000;
  session.min_bitrate_bps = 300000;
  session.max_bitrate_bps = 2500000;

  uint32_t rtp_packets = 0;
  webrtc_qos::VideoPushClientConfig config;
  config.session = session;
  config.transport_output = [&](const webrtc_qos::TransportPacketView& packet) {
    if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtp) {
      ++rtp_packets;
    }
    return webrtc_qos::Status::Ok();
  };

  std::unique_ptr<webrtc_qos::VideoPushClient> push =
      webrtc_qos::CreateVideoPushClient(config);
  if (!push || !push->Start()) {
    return 1;
  }

  const std::vector<uint8_t> au = MakeAccessUnit();
  webrtc_qos::AnnexBAccessUnitView view;
  view.bytes = au.data();
  view.size = au.size();
  view.capture_time_us = 1000000;
  view.keyframe = true;
  if (!push->PushAnnexBAccessUnit(view)) {
    return 2;
  }
  for (int64_t now_us = 1001000; now_us <= 1200000; now_us += 5000) {
    if (!push->Process(now_us)) {
      return 3;
    }
  }

  const auto snapshot = push->GetQosSnapshot(1200000);
  if (rtp_packets == 0) {
    return 4;
  }
  if (snapshot.emitted_probe_packets == 0 ||
      snapshot.emitted_probe_bytes == 0 ||
      snapshot.last_probe_cluster_id < 0) {
    std::cerr << "missing push probe stats"
              << " packets=" << snapshot.emitted_probe_packets
              << " bytes=" << snapshot.emitted_probe_bytes
              << " cluster=" << snapshot.last_probe_cluster_id << "\n";
    return 5;
  }
  std::cout << "webrtc_first_pacing_probe passed"
            << " rtp_packets=" << rtp_packets
            << " probe_packets=" << snapshot.emitted_probe_packets
            << " probe_bytes=" << snapshot.emitted_probe_bytes
            << " probe_cluster=" << snapshot.last_probe_cluster_id << "\n";
  return 0;
}
EOF

cmake -S "${WORK_DIR}" -B "${WORK_DIR}/build" \
  -DCMAKE_PREFIX_PATH="${PREFIX}" >/dev/null
cmake --build "${WORK_DIR}/build" -j2 >/dev/null
"${WORK_DIR}/build/verify_webrtc_first_pacing_probe"
