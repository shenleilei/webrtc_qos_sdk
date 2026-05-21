#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/root/output}"
WORK_DIR="${WORK_DIR:-/tmp/webrtc_qos_cmake_consumer.$$}"

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
  WebRtcQosSdk::transport_packet_history)

if(TARGET WebRtcQosSdk::role_push)
  add_executable(push_role push_role.cc)
  target_link_libraries(push_role PRIVATE WebRtcQosSdk::role_push)
endif()

if(TARGET WebRtcQosSdk::role_play)
  add_executable(play_role play_role.cc)
  target_link_libraries(play_role PRIVATE WebRtcQosSdk::role_play)
endif()

if(TARGET WebRtcQosSdk::role_server)
  add_executable(server_role server_role.cc)
  target_link_libraries(server_role PRIVATE WebRtcQosSdk::role_server)
  add_executable(server_role_runtime server_role_runtime.cc)
  target_link_libraries(server_role_runtime PRIVATE WebRtcQosSdk::role_server)
endif()

if(TARGET WebRtcQosSdk::webrtc_rtp_rtcp)
  add_executable(rtp_packet_adapter_link rtp_packet_adapter_link.cc)
  target_link_libraries(rtp_packet_adapter_link PRIVATE
    WebRtcQosSdk::webrtc_rtp_rtcp)
endif()

if(TARGET WebRtcQosSdk::webrtc_qos_facade_video)
  add_executable(video_facade_runtime video_facade_runtime.cc)
  target_link_libraries(video_facade_runtime PRIVATE
    WebRtcQosSdk::role_push
    WebRtcQosSdk::role_play
    WebRtcQosSdk::role_server)
endif()

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

#include "webrtc_qos/control_messages.h"
#include "webrtc_qos/production_transport_adapter.h"
#include "webrtc_qos/qos_metrics.h"
#include "webrtc_qos/rate_cap.h"
#include "webrtc_qos/server_qos_router.h"
#include "webrtc_qos/transport_packet_history.h"
#include "webrtc_qos/video_play_client.h"
#include "webrtc_qos/video_push_client.h"
#include "webrtc_qos/server_qos_router.h"
#include "webrtc_qos/rtcp_adapter.h"

int main() {
  webrtc_qos::TransportIds ids{1, 1, 1, 0x12345678, 2};
  webrtc_qos::TransportPacketHistory history({1000, 3000, 8});
  const std::vector<uint8_t> rtp = {0x80, 0x60, 0x00, 0x07};
  history.Store({1, ids.sender_ssrc, 7}, rtp.data(), rtp.size(), 1000000,
                false);
  auto found = history.Find({1, ids.sender_ssrc, 7});
  if (!found || found->rtp_bytes != rtp) {
    return 1;
  }

  webrtc_qos::SessionConfig session;
  session.ids = ids;
  webrtc_qos::VideoPushClientConfig push_config;
  push_config.session = session;
  webrtc_qos::VideoPlayClientConfig play_config;
  play_config.session = session;
  webrtc_qos::ServerQosRouterConfig server_config;
  server_config.session = session;
  webrtc_qos::ControlMessageHeader header;
  header.type = webrtc_qos::ControlMessageType::kSenderRateCapV1;
  auto cap = webrtc_qos::UnlimitedSenderRateCap(ids, 1, 1000000);
  return webrtc_qos::IsUnlimitedRateCap(cap) && header.version == 1 ? 0 : 2;
}
EOF

cat > "${WORK_DIR}/rtp_packet_adapter_link.cc" <<'EOF'
#include <vector>

#include "webrtc_qos/rtp_packet_adapter.h"
#include "webrtc_qos/types.h"

int main() {
  const std::vector<uint8_t> payload = {0x65, 0x88, 0x99, 0xaa};
  std::vector<uint8_t> rtp_bytes;
  webrtc_qos::RtpPacketAdapterConfig rtp_config;
  rtp_config.payload_type = webrtc_qos::kH264PayloadType;
  rtp_config.transport_sequence_extension_id =
      webrtc_qos::kTransportWideCcExtensionId;
  webrtc_qos::RtpPacketAdapterBuildInput rtp_input;
  rtp_input.payload_type = webrtc_qos::kH264PayloadType;
  rtp_input.marker = true;
  rtp_input.sequence_number = 7;
  rtp_input.timestamp = 90000;
  rtp_input.ssrc = 0x12345678;
  rtp_input.transport_sequence_number = 77;
  rtp_input.payload = payload.data();
  rtp_input.payload_size = payload.size();
  if (!webrtc_qos::BuildRtpPacket(rtp_input, rtp_config, &rtp_bytes)) {
    return 3;
  }
  webrtc_qos::RtpPacketAdapterParsedPacket parsed;
  if (!webrtc_qos::ParseRtpPacket(rtp_bytes.data(), rtp_bytes.size(),
                                  rtp_config, &parsed)) {
    return 4;
  }
  if (parsed.payload != payload || !parsed.transport_sequence_number ||
      *parsed.transport_sequence_number != 77) {
    return 5;
  }
  return parsed.ssrc == 0x12345678 && parsed.sequence_number == 7 ? 0 : 6;
}
EOF

cat > "${WORK_DIR}/push_role.cc" <<'EOF'
#include <memory>

#include "webrtc_qos/video_push_client.h"

int main() {
  webrtc_qos::VideoPushClientConfig config;
  config.session.ids.session_id = 1;
  config.session.ids.stream_id = 1;
  config.session.ids.transport_id = 1;
  config.session.ids.sender_ssrc = 0x12345678;
  config.transport_output =
      [](const webrtc_qos::TransportPacketView&) {
        return webrtc_qos::Status::Ok();
      };
  std::unique_ptr<webrtc_qos::VideoPushClient> client =
      webrtc_qos::CreateVideoPushClient(config);
  if (!client || !client->Start() ||
      !client->OnNetworkRouteChange(900000, 300000, 900000, 1000) ||
      !client->Stop()) {
    return 1;
  }
  return 0;
}
EOF

cat > "${WORK_DIR}/play_role.cc" <<'EOF'
#include <memory>

#include "webrtc_qos/video_play_client.h"

int main() {
  webrtc_qos::VideoPlayClientConfig config;
  config.session.ids.session_id = 1;
  config.session.ids.stream_id = 1;
  config.session.ids.transport_id = 1;
  config.session.ids.sender_ssrc = 0x12345678;
  config.transport_output =
      [](const webrtc_qos::TransportPacketView&) {
        return webrtc_qos::Status::Ok();
      };
  config.decoded_access_unit_output =
      [](const webrtc_qos::AnnexBAccessUnitView&) {
        return webrtc_qos::Status::Ok();
      };
  std::unique_ptr<webrtc_qos::VideoPlayClient> client =
      webrtc_qos::CreateVideoPlayClient(config);
  if (!client || !client->Start() || !client->Stop()) {
    return 1;
  }
  return 0;
}
EOF

cat > "${WORK_DIR}/server_role.cc" <<'EOF'
#include <memory>

#include "webrtc_qos/server_qos_router.h"

int main() {
  webrtc_qos::ServerQosRouterConfig config;
  config.session.ids.session_id = 1;
  config.session.ids.stream_id = 1;
  config.session.ids.transport_id = 1;
  config.session.ids.sender_ssrc = 0x12345678;
  config.sender_output =
      [](const webrtc_qos::TransportPacketView&) {
        return webrtc_qos::Status::Ok();
      };
  config.receiver_output =
      [](const webrtc_qos::TransportPacketView&) {
        return webrtc_qos::Status::Ok();
      };
  std::unique_ptr<webrtc_qos::ServerQosRouter> router =
      webrtc_qos::CreateServerQosRouter(config);
  if (!router || !router->Start() || !router->Stop()) {
    return 1;
  }
  return 0;
}
EOF

cat > "${WORK_DIR}/server_role_runtime.cc" <<'EOF'
#include <memory>
#include <vector>

#include "webrtc_qos/server_qos_router.h"

int main() {
  webrtc_qos::SessionConfig session;
  session.ids.session_id = 1;
  session.ids.stream_id = 1;
  session.ids.transport_id = 1;
  session.ids.sender_ssrc = 0x12345678;
  session.ids.receiver_id = 9;

  uint32_t sender_packets = 0;
  uint32_t receiver_packets = 0;
  webrtc_qos::ServerQosRouterConfig config;
  config.session = session;
  config.sender_output = [&](const webrtc_qos::TransportPacketView& packet) {
    return packet.bytes != nullptr || packet.size == 0
               ? (++sender_packets, webrtc_qos::Status::Ok())
               : webrtc_qos::Status::Error(
                     webrtc_qos::StatusCode::kInternalError,
                     "invalid sender packet");
  };
  config.receiver_output = [&](const webrtc_qos::TransportPacketView& packet) {
    return packet.bytes != nullptr || packet.size == 0
               ? (++receiver_packets, webrtc_qos::Status::Ok())
               : webrtc_qos::Status::Error(
                     webrtc_qos::StatusCode::kInternalError,
                     "invalid receiver packet");
  };

  std::unique_ptr<webrtc_qos::ServerQosRouter> router =
      webrtc_qos::CreateServerQosRouter(config);
  if (!router || !router->Start()) {
    return 1;
  }

  webrtc_qos::DownlinkQuality quality;
  quality.ids = session.ids;
  quality.report_time_us = 1000000;
  quality.fraction_lost_q8 = 32;
  if (!router->OnDownlinkQuality(quality)) {
    return 2;
  }
  const auto cap = router->CurrentSenderRateCap(1000000);
  if (cap.cap_bps == 0 || cap.expire_ms == 0) {
    return 3;
  }
  const auto snapshot = router->GetQosSnapshot(1000000);
  if (snapshot.sender_rates.sender_rate_cap_bps != cap.cap_bps) {
    return 4;
  }

  webrtc_qos::DownlinkQuality good_receiver_quality;
  good_receiver_quality.ids = session.ids;
  good_receiver_quality.ids.receiver_id = 10;
  good_receiver_quality.report_time_us = 1100000;
  if (!router->OnDownlinkQuality(good_receiver_quality)) {
    return 7;
  }
  const auto mixed_cap = router->CurrentSenderRateCap(1100000);
  if (mixed_cap.cap_bps != cap.cap_bps ||
      mixed_cap.reason_code !=
          static_cast<uint16_t>(webrtc_qos::RateCapReason::kWorstReceiver)) {
    return 8;
  }

  webrtc_qos::DownlinkQuality bad_receiver_quality;
  bad_receiver_quality.ids = session.ids;
  bad_receiver_quality.ids.receiver_id = 11;
  bad_receiver_quality.report_time_us = 1200000;
  bad_receiver_quality.fraction_lost_q8 = 64;
  bad_receiver_quality.video_drop_frames = 2;
  if (!router->OnDownlinkQuality(bad_receiver_quality)) {
    return 9;
  }
  const auto worst_cap = router->CurrentSenderRateCap(1200000);
  const auto worst_snapshot = router->GetQosSnapshot(1200000);
  if (worst_cap.cap_bps != cap.cap_bps ||
      worst_snapshot.downlink_quality.ids.receiver_id != 11) {
    return 10;
  }

  const auto expired_cap = router->CurrentSenderRateCap(2300001);
  if (!webrtc_qos::IsUnlimitedRateCap(expired_cap)) {
    return 11;
  }
  if (!router->Stop()) {
    return 12;
  }
  return sender_packets == 0 && receiver_packets == 0 ? 0 : 13;
}
EOF

cat > "${WORK_DIR}/video_facade_runtime.cc" <<'EOF'
#include <cstdint>
#include <memory>
#include <vector>

#include "webrtc_qos/rtcp_adapter.h"
#include "webrtc_qos/server_qos_router.h"
#include "webrtc_qos/video_play_client.h"
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
  session.ids.receiver_id = 9;

  std::vector<std::vector<uint8_t>> rtp_packets;
  std::vector<std::vector<uint8_t>> push_rtcp_packets;
  webrtc_qos::VideoPushClientConfig push_config;
  push_config.session = session;
  push_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtp) {
          rtp_packets.emplace_back(packet.bytes, packet.bytes + packet.size);
        } else if (packet.metadata.kind ==
                   webrtc_qos::TransportPacketKind::kRtcp) {
          push_rtcp_packets.emplace_back(packet.bytes, packet.bytes +
                                                   packet.size);
        }
        return webrtc_qos::Status::Ok();
      };

  uint32_t decoded_frames = 0;
  std::vector<std::vector<uint8_t>> play_rtcp_packets;
  webrtc_qos::VideoPlayClientConfig play_config;
  play_config.session = session;
  play_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtcp) {
          play_rtcp_packets.emplace_back(packet.bytes, packet.bytes +
                                                   packet.size);
        }
        return webrtc_qos::Status::Ok();
      };
  play_config.decoded_access_unit_output =
      [&](const webrtc_qos::AnnexBAccessUnitView& access_unit) {
        if (access_unit.bytes == nullptr || access_unit.size == 0 ||
            !access_unit.keyframe) {
          return webrtc_qos::Status::Error(
              webrtc_qos::StatusCode::kInternalError,
              "invalid decoded access unit");
        }
        ++decoded_frames;
        return webrtc_qos::Status::Ok();
      };

  std::unique_ptr<webrtc_qos::VideoPushClient> push =
      webrtc_qos::CreateVideoPushClient(push_config);
  std::unique_ptr<webrtc_qos::VideoPlayClient> play =
      webrtc_qos::CreateVideoPlayClient(play_config);
  if (!push || !play || !push->Start() || !play->Start()) {
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
  if (!push->Process(1001000)) {
    return 31;
  }
  if (rtp_packets.empty()) {
    return 3;
  }
  if (push_rtcp_packets.empty()) {
    return 19;
  }
  int64_t receive_time_us = 1100000;
  for (const auto& packet : rtp_packets) {
    if (!play->OnRtpPacket(packet.data(), packet.size(), receive_time_us)) {
      return 4;
    }
    receive_time_us += 5000;
  }
  if (decoded_frames != 1) {
    return 5;
  }
  auto snapshot = play->GetQosSnapshot(2000000);
  if (snapshot.nack_count != 0 || snapshot.pli_count != 0 ||
      snapshot.dropped_frames != 0) {
    return 6;
  }

  std::vector<std::vector<uint8_t>> server_to_sender;
  std::vector<webrtc_qos::TransportPacketView> server_to_receiver_views;
  std::vector<std::vector<uint8_t>> server_to_receiver_bytes;
  webrtc_qos::ServerQosRouterConfig server_config;
  server_config.session = session;
  server_config.sender_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        server_to_sender.emplace_back(packet.bytes, packet.bytes + packet.size);
        return webrtc_qos::Status::Ok();
      };
  server_config.receiver_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        server_to_receiver_views.push_back(packet);
        server_to_receiver_bytes.emplace_back(packet.bytes,
                                              packet.bytes + packet.size);
        return webrtc_qos::Status::Ok();
      };
  std::unique_ptr<webrtc_qos::ServerQosRouter> server =
      webrtc_qos::CreateServerQosRouter(server_config);
  if (!server || !server->Start()) {
    return 7;
  }
  int64_t server_receive_time_us = 1200000;
  for (const auto& packet : rtp_packets) {
    if (!server->OnSenderRtp(packet.data(), packet.size(),
                             server_receive_time_us)) {
      return 8;
    }
    server_receive_time_us += 50000;
  }
  if (server_to_receiver_views.empty()) {
    return 8;
  }
  if (server_to_receiver_views[0].metadata.kind !=
          webrtc_qos::TransportPacketKind::kRtp ||
      server_to_receiver_views[0].metadata.retransmission ||
      server_to_sender.empty()) {
    return 9;
  }
  bool saw_twcc = false;
  for (const auto& packet : server_to_sender) {
    webrtc_qos::RtcpAdapterParsedPacket parsed;
    if (webrtc_qos::ParseRtcpPacket(packet.data(), packet.size(), &parsed) &&
        parsed.type == webrtc_qos::RtcpAdapterPacketType::kTransportFeedback) {
      saw_twcc = true;
      if (!push->OnTransportFeedback(packet.data(), packet.size(), 1500000)) {
        return 10;
      }
    }
  }
  if (!saw_twcc) {
    return 11;
  }
  auto push_snapshot = push->GetQosSnapshot(1600000);
  if (push_snapshot.sender_rates.googcc_target_bps == 0 ||
      push_snapshot.sender_rates.pacing_bps == 0 ||
      push_snapshot.sender_rates.final_target_bps == 0) {
    return 12;
  }
  server_to_sender.clear();

  if (!server->OnSenderRtcp(push_rtcp_packets[0].data(),
                            push_rtcp_packets[0].size(), 2200000)) {
    return 20;
  }
  bool saw_rr = false;
  for (const auto& packet : server_to_sender) {
    webrtc_qos::RtcpAdapterParsedPacket parsed;
    if (webrtc_qos::ParseRtcpPacket(packet.data(), packet.size(), &parsed) &&
        parsed.type == webrtc_qos::RtcpAdapterPacketType::kReceiverReport) {
      saw_rr = true;
      if (!push->OnTransportFeedback(packet.data(), packet.size(), 2300000)) {
        return 21;
      }
    }
  }
  if (!saw_rr) {
    return 22;
  }
  push_snapshot = push->GetQosSnapshot(2400000);
  if (push_snapshot.sender_rates.rtt_ms == 0) {
    return 23;
  }
  server_to_sender.clear();
  const size_t receiver_outputs_before_nack = server_to_receiver_views.size();

  if (rtp_packets.size() < 3) {
    return 24;
  }
  play_rtcp_packets.clear();
  std::unique_ptr<webrtc_qos::VideoPlayClient> nack_play =
      webrtc_qos::CreateVideoPlayClient(play_config);
  if (!nack_play || !nack_play->Start()) {
    return 25;
  }
  if (!nack_play->OnRtpPacket(rtp_packets[0].data(), rtp_packets[0].size(),
                              3000000)) {
    return 26;
  }
  if (!nack_play->OnRtpPacket(rtp_packets[2].data(), rtp_packets[2].size(),
                              3010000)) {
    return 27;
  }
  bool saw_play_nack = false;
  for (const auto& packet : play_rtcp_packets) {
    webrtc_qos::RtcpAdapterParsedPacket parsed;
    if (webrtc_qos::ParseRtcpPacket(packet.data(), packet.size(), &parsed) &&
        parsed.type == webrtc_qos::RtcpAdapterPacketType::kNack &&
        !parsed.nack.packet_ids.empty() && parsed.nack.packet_ids[0] == 2) {
      saw_play_nack = true;
      if (!server->OnReceiverRtcp(session.ids.receiver_id, packet.data(),
                                  packet.size(), 3020000)) {
        return 28;
      }
    }
  }
  if (!saw_play_nack) {
    return 29;
  }
  if (server_to_receiver_views.size() != receiver_outputs_before_nack + 1 ||
      !server_to_receiver_views.back().metadata.retransmission ||
      !server_to_sender.empty()) {
    return 30;
  }

  const size_t receiver_outputs_before_manual_nack =
      server_to_receiver_views.size();

  webrtc_qos::RtcpAdapterNack nack;
  nack.sender_ssrc = 0x99999999;
  nack.media_ssrc = session.ids.sender_ssrc;
  nack.packet_ids.push_back(1);
  std::vector<uint8_t> nack_bytes;
  if (!webrtc_qos::BuildRtcpNack(nack, &nack_bytes)) {
    return 13;
  }
  if (!server->OnReceiverRtcp(session.ids.receiver_id, nack_bytes.data(),
                              nack_bytes.size(), 1300000)) {
    return 14;
  }
  if (server_to_receiver_views.size() !=
          receiver_outputs_before_manual_nack + 1 ||
      !server_to_receiver_views.back().metadata.retransmission ||
      !server_to_sender.empty()) {
    return 15;
  }

  nack.packet_ids.clear();
  nack.packet_ids.push_back(777);
  if (!webrtc_qos::BuildRtcpNack(nack, &nack_bytes)) {
    return 16;
  }
  if (!server->OnReceiverRtcp(session.ids.receiver_id, nack_bytes.data(),
                              nack_bytes.size(), 1400000)) {
    return 17;
  }
  return server_to_sender.size() == 1 ? 0 : 18;
}
EOF

cat > "${WORK_DIR}/ffmpeg_encoder_link.cc" <<'EOF'
#include "webrtc_qos/ffmpeg_h264_encoder.h"

int main() {
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
if [[ -x "${WORK_DIR}/build/push_role" ]]; then
  "${WORK_DIR}/build/push_role"
fi
if [[ -x "${WORK_DIR}/build/play_role" ]]; then
  "${WORK_DIR}/build/play_role"
fi
if [[ -x "${WORK_DIR}/build/server_role" ]]; then
  "${WORK_DIR}/build/server_role"
fi
if [[ -x "${WORK_DIR}/build/server_role_runtime" ]]; then
  "${WORK_DIR}/build/server_role_runtime"
fi
if [[ -x "${WORK_DIR}/build/rtp_packet_adapter_link" ]]; then
  "${WORK_DIR}/build/rtp_packet_adapter_link"
fi
if [[ -x "${WORK_DIR}/build/video_facade_runtime" ]]; then
  "${WORK_DIR}/build/video_facade_runtime"
fi
if [[ -x "${WORK_DIR}/build/ffmpeg_encoder_link" ]]; then
  "${WORK_DIR}/build/ffmpeg_encoder_link"
fi
if [[ -x "${WORK_DIR}/build/ffmpeg_decoder_link" ]]; then
  "${WORK_DIR}/build/ffmpeg_decoder_link"
fi

echo "CMake package verification passed prefix=${PREFIX}"
