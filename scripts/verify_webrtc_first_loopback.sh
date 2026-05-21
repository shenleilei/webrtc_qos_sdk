#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/root/output}"
WORK_DIR="${WORK_DIR:-/tmp/webrtc_qos_webrtc_first_loopback.$$}"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

cat > "${WORK_DIR}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(webrtc_qos_webrtc_first_loopback LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(WebRtcQosSdk REQUIRED CONFIG)

foreach(target IN ITEMS
  WebRtcQosSdk::webrtc_rtp_rtcp
  WebRtcQosSdk::webrtc_pacing
  WebRtcQosSdk::webrtc_video_jitter)
  if(NOT TARGET "${target}")
    message(FATAL_ERROR "missing WebRTC-first loopback target: ${target}")
  endif()
endforeach()

add_executable(webrtc_first_loopback main.cc)
target_link_libraries(webrtc_first_loopback PRIVATE
  WebRtcQosSdk::webrtc_rtp_rtcp
  WebRtcQosSdk::webrtc_pacing
  WebRtcQosSdk::webrtc_video_jitter)
EOF

cat > "${WORK_DIR}/main.cc" <<'EOF'
#include <cstdint>
#include <iostream>
#include <utility>
#include <vector>

#include "webrtc_qos/h264_rtp_adapter.h"
#include "webrtc_qos/pacing_adapter.h"
#include "webrtc_qos/rtp_packet_adapter.h"
#include "webrtc_qos/types.h"
#include "webrtc_qos/video_jitter_adapter.h"

namespace {

bool Check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    return false;
  }
  return true;
}

void AppendStartCodeAndNalu(const uint8_t* nalu,
                            size_t nalu_size,
                            std::vector<uint8_t>* out) {
  out->push_back(0x00);
  out->push_back(0x00);
  out->push_back(0x00);
  out->push_back(0x01);
  out->insert(out->end(), nalu, nalu + nalu_size);
}

bool StartsWithAnnexB(const std::vector<uint8_t>& data) {
  return data.size() >= 4 && data[0] == 0x00 && data[1] == 0x00 &&
         data[2] == 0x00 && data[3] == 0x01;
}

std::vector<uint8_t> MakeValidH264AccessUnit() {
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
  bool ok = true;
  constexpr uint32_t kSsrc = 0x12345678;
  constexpr uint32_t kTimestamp = 90000;

  const std::vector<uint8_t> au = MakeValidH264AccessUnit();
  std::vector<webrtc_qos::H264RtpPayload> h264_payloads;
  ok &= Check(webrtc_qos::PacketizeH264AnnexB(au.data(), au.size(), {1200},
                                              &h264_payloads),
              "H264 Annex-B packetize");
  ok &= Check(h264_payloads.size() == 3, "SPS/PPS/IDR payload count");
  if (!ok) {
    return 1;
  }

  webrtc_qos::RtpPacketAdapterConfig rtp_config;
  rtp_config.payload_type = webrtc_qos::kH264PayloadType;
  rtp_config.transport_sequence_extension_id =
      webrtc_qos::kTransportWideCcExtensionId;

  webrtc_qos::PacingAdapter pacer(
      webrtc_qos::PacingAdapterConfig{1200000, 0, 512 * 1024, 500});
  pacer.Process(0);

  uint16_t rtp_seq = 100;
  uint16_t transport_seq = 1000;
  for (const auto& payload : h264_payloads) {
    std::vector<uint8_t> rtp_bytes;
    webrtc_qos::RtpPacketAdapterBuildInput rtp_input;
    rtp_input.payload_type = webrtc_qos::kH264PayloadType;
    rtp_input.marker = payload.marker;
    rtp_input.sequence_number = rtp_seq;
    rtp_input.timestamp = kTimestamp;
    rtp_input.ssrc = kSsrc;
    rtp_input.transport_sequence_number = transport_seq;
    rtp_input.payload = payload.payload.data();
    rtp_input.payload_size = payload.payload.size();
    ok &= Check(webrtc_qos::BuildRtpPacket(rtp_input, rtp_config, &rtp_bytes),
                "RTP packet build");

    webrtc_qos::PacingAdapterPacket pacing_packet;
    pacing_packet.ssrc = kSsrc;
    pacing_packet.rtp_sequence_number = rtp_seq;
    pacing_packet.transport_sequence_number = transport_seq;
    pacing_packet.enqueue_time_us = 0;
    pacing_packet.keyframe = payload.keyframe;
    pacing_packet.bytes = std::move(rtp_bytes);
    ok &= Check(pacer.EnqueuePacket(pacing_packet), "pacer enqueue");
    ++rtp_seq;
    ++transport_seq;
  }
  if (!ok) {
    return 2;
  }

  std::vector<webrtc_qos::PacingAdapterPacket> emitted;
  for (int64_t now_us = 5000; now_us <= 500000; now_us += 5000) {
    auto batch = pacer.Process(now_us);
    emitted.insert(emitted.end(),
                   std::make_move_iterator(batch.begin()),
                   std::make_move_iterator(batch.end()));
    if (emitted.size() == h264_payloads.size()) {
      break;
    }
  }
  ok &= Check(emitted.size() == h264_payloads.size(), "pacer drains packets");

  webrtc_qos::VideoJitterAdapter jitter({webrtc_qos::kH264PayloadType, kSsrc});
  std::vector<webrtc_qos::VideoJitterFrame> completed_frames;
  int64_t arrival_time_us = 1000000;
  uint16_t expected_transport_seq = 1000;
  for (const auto& packet : emitted) {
    webrtc_qos::RtpPacketAdapterParsedPacket parsed;
    ok &= Check(webrtc_qos::ParseRtpPacket(packet.bytes.data(),
                                           packet.bytes.size(),
                                           rtp_config, &parsed),
                "RTP packet parse");
    ok &= Check(parsed.transport_sequence_number.has_value() &&
                    *parsed.transport_sequence_number == expected_transport_seq,
                "TWCC RTP header extension");

    webrtc_qos::VideoJitterPacket jitter_packet;
    jitter_packet.payload_type = parsed.payload_type;
    jitter_packet.marker = parsed.marker;
    jitter_packet.sequence_number = parsed.sequence_number;
    jitter_packet.rtp_timestamp = parsed.timestamp;
    jitter_packet.ssrc = parsed.ssrc;
    jitter_packet.arrival_time_us = arrival_time_us;
    jitter_packet.payload = parsed.payload.data();
    jitter_packet.payload_size = parsed.payload.size();
    auto frames = jitter.InsertPacket(jitter_packet);
    completed_frames.insert(completed_frames.end(),
                            std::make_move_iterator(frames.begin()),
                            std::make_move_iterator(frames.end()));
    arrival_time_us += 5000;
    ++expected_transport_seq;
  }

  ok &= Check(completed_frames.size() == 1, "one completed video frame");
  if (!completed_frames.empty()) {
    ok &= Check(completed_frames[0].keyframe, "completed frame is keyframe");
    ok &= Check(StartsWithAnnexB(completed_frames[0].annexb_access_unit),
                "receiver outputs Annex-B AU");
    ok &= Check(completed_frames[0].rtp_sequence_start == 100 &&
                    completed_frames[0].rtp_sequence_end == 102,
                "frame RTP sequence range");
  }

  const auto pacing_stats = pacer.stats();
  const auto jitter_stats = jitter.stats();
  std::cout << "webrtc_first_loopback passed"
            << " h264_payloads=" << h264_payloads.size()
            << " emitted=" << emitted.size()
            << " pacing_queue=" << pacing_stats.queue_packets
            << " jitter_packets=" << jitter_stats.packets_inserted
            << " frames=" << jitter_stats.frames_completed
            << " annexb_bytes="
            << (completed_frames.empty()
                    ? 0
                    : completed_frames[0].annexb_access_unit.size())
            << "\n";
  return ok ? 0 : 3;
}
EOF

cmake -S "${WORK_DIR}" -B "${WORK_DIR}/build" \
  -DCMAKE_PREFIX_PATH="${PREFIX}" >/dev/null
cmake --build "${WORK_DIR}/build" -j2 >/dev/null
"${WORK_DIR}/build/webrtc_first_loopback"
