#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/root/webrtc_qos_sdk/dist/linux-x86_64}"
WORK_DIR="${WORK_DIR:-/tmp/webrtc_qos_multitrack_matrix.$$}"
OUTPUT_DIR="${OUTPUT_DIR:-/root/webrtc_qos_sdk/artifacts/webrtc_first_multitrack_matrix}"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

cat > "${WORK_DIR}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(webrtc_qos_multitrack_matrix LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(WebRtcQosSdk REQUIRED CONFIG)

add_executable(webrtc_first_multitrack_matrix main.cc)
target_link_libraries(webrtc_first_multitrack_matrix PRIVATE
  WebRtcQosSdk::role_push
  WebRtcQosSdk::role_play
  WebRtcQosSdk::role_server)
EOF

cat > "${WORK_DIR}/main.cc" <<'EOF'
#include <cstdint>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "webrtc_qos/rtcp_adapter.h"
#include "webrtc_qos/server_qos_router.h"
#include "webrtc_qos/video_play_client.h"
#include "webrtc_qos/video_push_client.h"

namespace {

struct ScenarioResult {
  std::string name;
  uint32_t decoded_track_count = 0;
  uint32_t track_a_target_bps = 0;
  uint32_t track_b_target_bps = 0;
  uint32_t source_target_bps = 0;
  uint32_t track_a_fps = 0;
  uint32_t track_b_fps = 0;
  uint32_t track_a_retransmissions = 0;
  uint32_t track_b_retransmissions = 0;
  uint32_t track_a_pli = 0;
  uint32_t track_b_pli = 0;
  bool pass = false;
};

void AppendStartCodeAndNalu(const uint8_t* nalu,
                            size_t nalu_size,
                            std::vector<uint8_t>* out) {
  out->push_back(0x00);
  out->push_back(0x00);
  out->push_back(0x00);
  out->push_back(0x01);
  out->insert(out->end(), nalu, nalu + nalu_size);
}

std::vector<uint8_t> MakeAccessUnit(uint8_t frame_id) {
  const uint8_t sps[] = {0x67, 0x42, 0xc0, 0x15, 0x8c, 0x68, 0x14, 0x19,
                         0x79, 0xe0, 0x1e, 0x11, 0x08, 0xd4, 0x00, 0x04};
  const uint8_t pps[] = {0x68, 0xce, 0x3c, 0x80, 0x00, 0x2e};
  const uint8_t idr[] = {0x65, 0xb8, 0x00, 0x04, 0x08, 0x79,
                         0x31, 0x40, frame_id, 0x42, 0xae, 0x4d};
  std::vector<uint8_t> au;
  AppendStartCodeAndNalu(sps, sizeof(sps), &au);
  AppendStartCodeAndNalu(pps, sizeof(pps), &au);
  AppendStartCodeAndNalu(idr, sizeof(idr), &au);
  return au;
}

struct Packet {
  std::vector<uint8_t> bytes;
  webrtc_qos::TransportPacketMetadata metadata;
};

struct Runtime {
  webrtc_qos::SessionConfig session;
  webrtc_qos::VideoTrackConfig track_a;
  webrtc_qos::VideoTrackConfig track_b;
  std::vector<Packet> push_packets;
  std::vector<Packet> play_rtcp_packets;
  std::vector<Packet> server_to_sender;
  std::vector<Packet> server_to_receiver;
  std::vector<webrtc_qos::TransportIds> decoded_ids;
  std::unique_ptr<webrtc_qos::VideoPushClient> push;
  std::unique_ptr<webrtc_qos::VideoPlayClient> play;
  std::unique_ptr<webrtc_qos::ServerQosRouter> server;
};

Packet CopyPacket(const webrtc_qos::TransportPacketView& packet) {
  return Packet{{packet.bytes, packet.bytes + packet.size}, packet.metadata};
}

bool BuildRuntime(Runtime* runtime) {
  runtime->session.ids.session_id = 1;
  runtime->session.ids.stream_id = 10;
  runtime->session.ids.transport_id = 1;
  runtime->session.ids.receiver_id = 9;
  runtime->session.ids.source_id = 77;
  runtime->session.rtcp.receiver_feedback_ssrc = 0x90000009u;
  runtime->session.rtcp.server_feedback_ssrc = 0x70000009u;

  runtime->track_a.ids = runtime->session.ids;
  runtime->track_a.ids.track_id = 101;
  runtime->track_a.ids.sender_ssrc = 0x11111111u;
  runtime->track_a.base_track = true;
  runtime->track_a.weight = 70;

  runtime->track_b = runtime->track_a;
  runtime->track_b.ids.track_id = 202;
  runtime->track_b.ids.sender_ssrc = 0x22222222u;
  runtime->track_b.base_track = false;
  runtime->track_b.weight = 30;

  runtime->session.ids.sender_ssrc = runtime->track_a.ids.sender_ssrc;
  runtime->session.video_tracks = {runtime->track_a, runtime->track_b};

  webrtc_qos::VideoPushClientConfig push_config;
  push_config.session = runtime->session;
  push_config.transport_output =
      [runtime](const webrtc_qos::TransportPacketView& packet) {
        runtime->push_packets.push_back(CopyPacket(packet));
        return webrtc_qos::Status::Ok();
      };

  webrtc_qos::VideoPlayClientConfig play_config;
  play_config.session = runtime->session;
  play_config.transport_output =
      [runtime](const webrtc_qos::TransportPacketView& packet) {
        if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtcp) {
          runtime->play_rtcp_packets.push_back(CopyPacket(packet));
        }
        return webrtc_qos::Status::Ok();
      };
  play_config.decoded_access_unit_output =
      [runtime](const webrtc_qos::AnnexBAccessUnitView& access_unit) {
        runtime->decoded_ids.push_back(access_unit.ids);
        return webrtc_qos::Status::Ok();
      };

  webrtc_qos::ServerQosRouterConfig server_config;
  server_config.session = runtime->session;
  server_config.sender_output =
      [runtime](const webrtc_qos::TransportPacketView& packet) {
        runtime->server_to_sender.push_back(CopyPacket(packet));
        return webrtc_qos::Status::Ok();
      };
  server_config.receiver_output =
      [runtime](const webrtc_qos::TransportPacketView& packet) {
        runtime->server_to_receiver.push_back(CopyPacket(packet));
        return webrtc_qos::Status::Ok();
      };

  runtime->push = webrtc_qos::CreateVideoPushClient(push_config);
  runtime->play = webrtc_qos::CreateVideoPlayClient(play_config);
  runtime->server = webrtc_qos::CreateServerQosRouter(server_config);
  return runtime->push && runtime->play && runtime->server &&
         static_cast<bool>(runtime->push->Start()) &&
         static_cast<bool>(runtime->play->Start()) &&
         static_cast<bool>(runtime->server->Start());
}

bool PushAndRoute(Runtime* runtime, const webrtc_qos::AnnexBAccessUnitView& au,
                  int64_t process_time_us) {
  if (!runtime->push->PushAnnexBAccessUnit(au) ||
      !runtime->push->Process(process_time_us)) {
    return false;
  }

  for (const auto& packet : runtime->push_packets) {
    if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtp) {
      if (!runtime->server->OnSenderRtp(packet.bytes.data(), packet.bytes.size(),
                                        packet.metadata.send_time_us)) {
        return false;
      }
    } else if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtcp) {
      if (!runtime->server->OnSenderRtcp(packet.bytes.data(),
                                         packet.bytes.size(),
                                         packet.metadata.send_time_us)) {
        return false;
      }
    }
  }

  for (const auto& packet : runtime->server_to_receiver) {
    if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtp) {
      if (!runtime->play->OnRtpPacket(packet.bytes.data(), packet.bytes.size(),
                                      packet.metadata.send_time_us)) {
        return false;
      }
    } else if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtcp) {
      if (!runtime->play->OnRtcpPacket(packet.bytes.data(), packet.bytes.size(),
                                       packet.metadata.send_time_us)) {
        return false;
      }
    }
  }

  runtime->push_packets.clear();
  runtime->server_to_receiver.clear();
  return static_cast<bool>(runtime->play->Process(process_time_us + 1000));
}

ScenarioResult RunScenario(const std::string& name) {
  Runtime runtime;
  ScenarioResult result;
  result.name = name;
  result.pass = BuildRuntime(&runtime);
  if (!result.pass) {
    return result;
  }

  const auto au = MakeAccessUnit(1);
  webrtc_qos::AnnexBAccessUnitView track_a_au;
  track_a_au.bytes = au.data();
  track_a_au.size = au.size();
  track_a_au.capture_time_us = 1000000;
  track_a_au.keyframe = true;
  track_a_au.ids = runtime.track_a.ids;
  result.pass = PushAndRoute(&runtime, track_a_au, 1001000);
  if (!result.pass) {
    return result;
  }

  webrtc_qos::AnnexBAccessUnitView track_b_au = track_a_au;
  track_b_au.capture_time_us = 1033333;
  track_b_au.ids = runtime.track_b.ids;
  result.pass = PushAndRoute(&runtime, track_b_au, 1034333);
  if (!result.pass) {
    return result;
  }

  result.decoded_track_count =
      static_cast<uint32_t>(runtime.decoded_ids.size());

  webrtc_qos::EncoderAdaptation track_a_adaptation;
  webrtc_qos::EncoderAdaptation track_b_adaptation;
  result.pass =
      runtime.push->GetTrackEncoderAdaptation(runtime.track_a.ids.track_id,
                                              1300000, &track_a_adaptation) &&
      runtime.push->GetTrackEncoderAdaptation(runtime.track_b.ids.track_id,
                                              1300000, &track_b_adaptation);
  if (!result.pass) {
    return result;
  }
  result.track_a_target_bps = track_a_adaptation.target_bitrate_bps;
  result.track_b_target_bps = track_b_adaptation.target_bitrate_bps;
  result.track_a_fps = track_a_adaptation.max_fps;
  result.track_b_fps = track_b_adaptation.max_fps;
  result.source_target_bps =
      runtime.push->GetQosSnapshot(1300000).sender_rates.final_target_bps;

  if (name == "feedback_isolation" || name == "source_cap_allocation") {
    std::vector<uint8_t> pli_bytes;
    webrtc_qos::RtcpAdapterPli pli;
    pli.sender_ssrc = runtime.session.rtcp.receiver_feedback_ssrc;
    pli.media_ssrc = runtime.track_b.ids.sender_ssrc;
    result.pass = webrtc_qos::BuildRtcpPli(pli, &pli_bytes) &&
                  static_cast<bool>(runtime.push->OnTransportFeedback(
                      pli_bytes.data(), pli_bytes.size(), 1400000));
    if (!result.pass) {
      return result;
    }

    result.pass =
        runtime.push->GetTrackEncoderAdaptation(runtime.track_a.ids.track_id,
                                                1400000, &track_a_adaptation) &&
        runtime.push->GetTrackEncoderAdaptation(runtime.track_b.ids.track_id,
                                                1400000, &track_b_adaptation);
    if (!result.pass) {
      return result;
    }

    std::vector<uint8_t> sender_nack_bytes;
    webrtc_qos::RtcpAdapterNack sender_nack;
    sender_nack.sender_ssrc = runtime.session.rtcp.receiver_feedback_ssrc;
    sender_nack.media_ssrc = runtime.track_b.ids.sender_ssrc;
    sender_nack.packet_ids.push_back(1);
    const size_t before_retransmission = runtime.push_packets.size();
    result.pass = webrtc_qos::BuildRtcpNack(sender_nack, &sender_nack_bytes) &&
                  static_cast<bool>(runtime.push->OnTransportFeedback(
                      sender_nack_bytes.data(), sender_nack_bytes.size(),
                      1450000));
    if (!result.pass) {
      return result;
    }
    for (int i = 0; i < 50; ++i) {
      if (!runtime.push->Process(1455000 + static_cast<int64_t>(i) * 5000)) {
        result.pass = false;
        return result;
      }
    }
    webrtc_qos::QosSnapshot track_a_push_snapshot;
    webrtc_qos::QosSnapshot track_b_push_snapshot;
    result.pass =
        runtime.push->GetTrackQosSnapshot(runtime.track_a.ids.track_id, 1500000,
                                          &track_a_push_snapshot) &&
        runtime.push->GetTrackQosSnapshot(runtime.track_b.ids.track_id, 1500000,
                                          &track_b_push_snapshot);
    if (!result.pass) {
      return result;
    }
    result.track_a_retransmissions = track_a_push_snapshot.retransmission_count;
    result.track_b_retransmissions = track_b_push_snapshot.retransmission_count;
    result.track_a_pli = track_a_push_snapshot.pli_count;
    result.track_b_pli = track_b_push_snapshot.pli_count;

    const bool feedback_isolated =
        track_b_adaptation.request_keyframe &&
        !track_a_adaptation.request_keyframe &&
        result.track_b_retransmissions > result.track_a_retransmissions &&
        result.track_b_pli > result.track_a_pli;
    result.pass = feedback_isolated;
    if (!result.pass || name != "source_cap_allocation") {
      return result;
    }
  }

  webrtc_qos::SenderRateCap low_cap =
      webrtc_qos::UnlimitedSenderRateCap(runtime.session.ids, 1, 1455000);
  low_cap.cap_bps = 600000;
  low_cap.receive_time_us = 1455000;
  result.pass = static_cast<bool>(runtime.push->OnSenderRateCap(low_cap));
  if (!result.pass) {
    return result;
  }

  result.pass =
      runtime.push->GetTrackEncoderAdaptation(runtime.track_a.ids.track_id,
                                              1460000, &track_a_adaptation) &&
      runtime.push->GetTrackEncoderAdaptation(runtime.track_b.ids.track_id,
                                              1460000, &track_b_adaptation);
  if (!result.pass) {
    return result;
  }
  result.track_a_target_bps = track_a_adaptation.target_bitrate_bps;
  result.track_b_target_bps = track_b_adaptation.target_bitrate_bps;
  result.track_a_fps = track_a_adaptation.max_fps;
  result.track_b_fps = track_b_adaptation.max_fps;
  result.source_target_bps =
      runtime.push->GetQosSnapshot(1460000).sender_rates.final_target_bps;

  result.pass =
      result.track_a_target_bps > result.track_b_target_bps &&
      result.track_a_fps >= result.track_b_fps &&
      static_cast<uint64_t>(result.track_a_target_bps) +
              result.track_b_target_bps <=
          static_cast<uint64_t>(result.source_target_bps) + 1;
  return result;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string output_dir = argc >= 2 ? argv[1] : ".";
  const std::string csv_path = output_dir + "/webrtc_first_multitrack_matrix.csv";

  std::vector<ScenarioResult> results;
  results.push_back(RunScenario("baseline_dual_track"));
  results.push_back(RunScenario("feedback_isolation"));
  results.push_back(RunScenario("source_cap_allocation"));

  std::ofstream csv(csv_path, std::ios::trunc);
  csv << "scenario,decoded_track_count,track_a_target_bps,track_b_target_bps,"
         "source_target_bps,track_a_fps,track_b_fps,track_a_retransmissions,"
         "track_b_retransmissions,track_a_pli,track_b_pli,pass\n";
  bool all_pass = true;
  for (const auto& result : results) {
    csv << result.name << ',' << result.decoded_track_count << ','
        << result.track_a_target_bps << ',' << result.track_b_target_bps << ','
        << result.source_target_bps << ',' << result.track_a_fps << ','
        << result.track_b_fps << ',' << result.track_a_retransmissions << ','
        << result.track_b_retransmissions << ',' << result.track_a_pli << ','
        << result.track_b_pli << ',' << (result.pass ? "true" : "false")
        << '\n';
    std::cout << "multitrack scenario=" << result.name
              << " decoded_tracks=" << result.decoded_track_count
              << " track_a_bps=" << result.track_a_target_bps
              << " track_b_bps=" << result.track_b_target_bps
              << " source_bps=" << result.source_target_bps
              << " track_a_fps=" << result.track_a_fps
              << " track_b_fps=" << result.track_b_fps
              << " track_a_rtx=" << result.track_a_retransmissions
              << " track_b_rtx=" << result.track_b_retransmissions
              << " track_a_pli=" << result.track_a_pli
              << " track_b_pli=" << result.track_b_pli
              << " pass=" << (result.pass ? "true" : "false") << '\n';
    all_pass = all_pass && result.pass;
  }
  std::cout << "wrote " << csv_path << '\n';
  return all_pass ? 0 : 1;
}
EOF

cmake -S "${WORK_DIR}" -B "${WORK_DIR}/build" \
  -DCMAKE_PREFIX_PATH="${PREFIX}" >/dev/null
cmake --build "${WORK_DIR}/build" -j2 >/dev/null
"${WORK_DIR}/build/webrtc_first_multitrack_matrix" "${OUTPUT_DIR}"

echo "webrtc_first_multitrack_matrix passed output_dir=${OUTPUT_DIR}"
