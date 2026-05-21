#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/root/output}"
WORK_DIR="${WORK_DIR:-/tmp/webrtc_qos_cmake_consumer}"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

cat > "${WORK_DIR}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(webrtc_qos_cmake_consumer LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(WebRtcQosSdk REQUIRED CONFIG)

add_executable(consumer main.cc)
target_link_libraries(consumer PRIVATE
  WebRtcQosSdk::role_transport
  WebRtcQosSdk::webrtc_qos_rtcp)

add_executable(server_role server_role.cc)
target_link_libraries(server_role PRIVATE WebRtcQosSdk::role_server)

add_executable(push_role push_role.cc)
target_link_libraries(push_role PRIVATE WebRtcQosSdk::role_push)

add_executable(play_role play_role.cc)
target_link_libraries(play_role PRIVATE WebRtcQosSdk::role_play)

add_executable(prototype_role prototype_role.cc)
target_link_libraries(prototype_role PRIVATE WebRtcQosSdk::role_prototype)

if(TARGET WebRtcQosSdk::webrtc_qos_ffmpeg_encoder)
  add_executable(ffmpeg_encoder_link ffmpeg_encoder_link.cc)
  target_link_libraries(ffmpeg_encoder_link PRIVATE
    WebRtcQosSdk::webrtc_qos_ffmpeg_encoder)
endif()

if(TARGET WebRtcQosSdk::webrtc_qos_ffmpeg_decoder)
  add_executable(ffmpeg_decoder_link ffmpeg_decoder_link.cc)
  target_link_libraries(ffmpeg_decoder_link PRIVATE
    WebRtcQosSdk::webrtc_qos_ffmpeg_decoder)
endif()
EOF

cat > "${WORK_DIR}/main.cc" <<'EOF'
#include <vector>

#include "webrtc_qos/production_transport_adapter.h"
#include "webrtc_qos/rtcp_packets.h"
#include "webrtc_qos/transport_port.h"

int main() {
  webrtc_qos::TransportIds ids{1, 1, 1, 0x12345678, 2};
  webrtc_qos::TransportPort port(
      [](const webrtc_qos::TransportMessage& message) {
        return message.type == webrtc_qos::TransportMessageType::kRtcpPli
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInvalidArgument,
                         "unexpected message type");
      });
  webrtc_qos::RtcpPli pli;
  pli.sender_ssrc = ids.receiver_id;
  pli.media_ssrc = ids.sender_ssrc;
  std::vector<uint8_t> payload = webrtc_qos::SerializeRtcpPli(pli);
  if (!port.Send(webrtc_qos::TransportMessageType::kRtcpPli, ids, payload,
                 1000000)) {
    return 1;
  }

  webrtc_qos::OwnedTransportMessage queued;
  webrtc_qos::ProductionTransportAdapter adapter(
      [&](const webrtc_qos::OwnedTransportMessage& message) {
        queued = message;
        return webrtc_qos::Status::Ok();
      });
  if (!adapter.Send(webrtc_qos::TransportMessageType::kRtcpPli, ids, payload,
                    1000000)) {
    return 2;
  }
  webrtc_qos::TransportPort moved_port(std::move(port));
  if (!moved_port.Send(webrtc_qos::TransportMessageType::kRtcpPli, ids,
                       payload, 1000100)) {
    return 3;
  }
  return queued.lane == webrtc_qos::ProductionTransportLane::kUnreliableControl
             ? 0
             : 4;
}
EOF

cat > "${WORK_DIR}/server_role.cc" <<'EOF'
#include "webrtc_qos/retransmission_cache.h"
#include "webrtc_qos/rtcp_packets.h"
#include "webrtc_qos/rtp_packet.h"

int main() {
  webrtc_qos::RtpPacket packet;
  packet.sequence_number = 7;
  packet.transport_sequence_number = 9;
  packet.ssrc = 0x12345678;
  packet.payload = {0x65, 1, 2, 3};
  auto encoded = webrtc_qos::SerializeRtpPacket(packet);
  webrtc_qos::RtpPacket parsed;
  if (!webrtc_qos::ParseRtpPacket(encoded.data(), encoded.size(), &parsed)) {
    return 1;
  }
  webrtc_qos::RetransmissionCache cache;
  cache.Store(parsed, 1000000);
  webrtc_qos::RtcpNack nack;
  nack.sender_ssrc = 2;
  nack.media_ssrc = packet.ssrc;
  nack.lost_rtp_sequence_numbers = {7};
  auto nack_bytes = webrtc_qos::SerializeRtcpNack(nack);
  return cache.Find(7, 10).has_value() && !nack_bytes.empty() ? 0 : 1;
}
EOF

cat > "${WORK_DIR}/push_role.cc" <<'EOF'
#include "webrtc_qos/sender_qos_googcc_bridge.h"
#include "webrtc_qos/sender_pacer.h"
#include "webrtc_qos/video_sender.h"

int main() {
  webrtc_qos::TransportIds ids{1, 1, 1, 0x12345678, 2};
  webrtc_qos::SenderQosControllerConfig qos_config;
  qos_config.ids = ids;
  auto qos = webrtc_qos::CreateGoogCcSenderQosController(qos_config, 1000000);
  auto moved_qos = std::move(qos);
  webrtc_qos::SenderPacer pacer(
      webrtc_qos::SenderPacerConfig{},
      [&](const webrtc_qos::RtpPacket& packet) {
        return moved_qos.OnPacketSent(packet.transport_sequence_number,
                                      packet.payload.size() + 20, 1000000);
      });
  webrtc_qos::VideoSender sender(webrtc_qos::VideoSenderConfig{ids}, &pacer);
  const uint8_t au[] = {0, 0, 0, 1, 0x67, 0x42, 0xe0, 0x1f,
                        0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80,
                        0, 0, 0, 1, 0x65, 1,    2,    3};
  if (!sender.SendAnnexBAccessUnit(au, sizeof(au), 1000000)) {
    return 1;
  }
  return moved_qos.GetTargetRates(1000000).final_target_bps > 0 ? 0 : 2;
}
EOF

cat > "${WORK_DIR}/play_role.cc" <<'EOF'
#include "webrtc_qos/rtp_packet.h"
#include "webrtc_qos/video_jitter_bridge.h"

int main() {
  webrtc_qos::TransportIds ids{1, 1, 1, 0x12345678, 2};
  auto jitter = webrtc_qos::CreateWebRtcVideoJitterPlayer(
      webrtc_qos::VideoJitterPlayerConfig{ids.sender_ssrc});
  auto moved_jitter = std::move(jitter);
  const uint8_t sps[] = {0x67, 0x42, 0xe0, 0x1f, 0x8c, 0x68, 0x14, 0x19,
                         0x79, 0xe0, 0x1e, 0x11, 0x08, 0xd4, 0x00, 0x04};
  const uint8_t pps[] = {0x68, 0xce, 0x3c, 0x80, 0x00, 0x2e};
  const uint8_t idr[] = {0x65, 0xb8, 0x00, 0x04, 0x08, 0x79,
                         0x31, 0x40, 0x00, 0x42, 0xae, 0x4d};

  auto make_packet = [&](uint16_t seq, bool marker, const uint8_t* payload,
                         size_t size) {
    webrtc_qos::RtpPacket packet;
    packet.payload_type = webrtc_qos::kH264PayloadType;
    packet.marker = marker;
    packet.sequence_number = seq;
    packet.timestamp = 90000;
    packet.ssrc = ids.sender_ssrc;
    packet.transport_sequence_number = seq;
    packet.payload.assign(payload, payload + size);
    return packet;
  };

  auto status =
      moved_jitter.InsertPacket(make_packet(100, false, sps, sizeof(sps)),
                                1000000);
  if (!status) {
    return 1;
  }
  status = moved_jitter.InsertPacket(make_packet(101, false, pps, sizeof(pps)),
                                     1001000);
  if (!status) {
    return 2;
  }
  status = moved_jitter.InsertPacket(make_packet(102, true, idr, sizeof(idr)),
                                     1002000);
  if (!status) {
    return 3;
  }
  webrtc_qos::EncodedVideoFrame frame;
  return moved_jitter.HasFrame() && moved_jitter.PopFrame(&frame) &&
                 frame.keyframe
             ? 0
             : 4;
}
EOF

cat > "${WORK_DIR}/prototype_role.cc" <<'EOF'
#include "webrtc_qos/sender_qos_googcc_bridge.h"
#include "webrtc_qos/video_jitter_bridge.h"

int main() {
  webrtc_qos::TransportIds ids{1, 1, 1, 0x12345678, 2};
  webrtc_qos::SenderQosControllerConfig qos_config;
  qos_config.ids = ids;
  auto qos = webrtc_qos::CreateGoogCcSenderQosController(qos_config, 1000000);
  auto jitter = webrtc_qos::CreateWebRtcVideoJitterPlayer(
      webrtc_qos::VideoJitterPlayerConfig{ids.sender_ssrc});
  auto moved_qos = std::move(qos);
  auto moved_jitter = std::move(jitter);
  return moved_qos.GetTargetRates(1000000).googcc_target_bps > 0 &&
                 !moved_jitter.HasFrame()
             ? 0
             : 1;
}
EOF

cat > "${WORK_DIR}/ffmpeg_encoder_link.cc" <<'EOF'
#include "webrtc_qos/ffmpeg_h264_encoder.h"

int main() {
  webrtc_qos::FfmpegH264Encoder encoder;
  webrtc_qos::FfmpegH264EncoderConfig config;
  config.width = 320;
  config.height = 180;
  config.fps = 30;
  config.bitrate_bps = 800000;
  return static_cast<int>(config.width + config.height) > 0 ? 0 : 1;
}
EOF

cat > "${WORK_DIR}/ffmpeg_decoder_link.cc" <<'EOF'
#include "webrtc_qos/ffmpeg_h264_decoder.h"

int main() {
  webrtc_qos::FfmpegH264Decoder decoder;
  auto stats = decoder.GetStats();
  return stats.decoded_frames == 0 && stats.decode_errors == 0 ? 0 : 1;
}
EOF

cmake -S "${WORK_DIR}" -B "${WORK_DIR}/build" \
  -DCMAKE_PREFIX_PATH="${PREFIX}" >/dev/null
cmake --build "${WORK_DIR}/build" -j2 >/dev/null
"${WORK_DIR}/build/consumer"
"${WORK_DIR}/build/server_role"
"${WORK_DIR}/build/push_role"
"${WORK_DIR}/build/play_role"
"${WORK_DIR}/build/prototype_role"
if [[ -x "${WORK_DIR}/build/ffmpeg_encoder_link" ]]; then
  "${WORK_DIR}/build/ffmpeg_encoder_link"
fi
if [[ -x "${WORK_DIR}/build/ffmpeg_decoder_link" ]]; then
  "${WORK_DIR}/build/ffmpeg_decoder_link"
fi

echo "cmake package verification passed"
