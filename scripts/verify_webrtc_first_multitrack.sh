#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/root/webrtc_qos_sdk/dist/linux-x86_64}"
WORK_DIR="${WORK_DIR:-/tmp/webrtc_qos_multitrack.$$}"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

cat > "${WORK_DIR}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(webrtc_qos_multitrack LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(WebRtcQosSdk REQUIRED CONFIG)

add_executable(verify_multitrack main.cc)
target_link_libraries(verify_multitrack PRIVATE
  WebRtcQosSdk::role_push
  WebRtcQosSdk::role_play
  WebRtcQosSdk::role_server)
EOF

cat > "${WORK_DIR}/main.cc" <<'EOF'
#include <cstdint>
#include <iostream>
#include <memory>
#include <utility>
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

struct Packet {
  std::vector<uint8_t> bytes;
  webrtc_qos::TransportPacketMetadata metadata;
};

}  // namespace

int main() {
  webrtc_qos::SessionConfig session;
  session.ids.session_id = 1;
  session.ids.stream_id = 10;
  session.ids.transport_id = 1;
  session.ids.receiver_id = 9;
  session.ids.source_id = 77;
  session.rtcp.receiver_feedback_ssrc = 0x90000009u;
  session.rtcp.server_feedback_ssrc = 0x70000009u;

  webrtc_qos::VideoTrackConfig track_a;
  track_a.ids = session.ids;
  track_a.ids.track_id = 101;
  track_a.ids.sender_ssrc = 0x11111111u;
  track_a.base_track = true;
  track_a.weight = 70;

  webrtc_qos::VideoTrackConfig track_b = track_a;
  track_b.ids.track_id = 202;
  track_b.ids.sender_ssrc = 0x22222222u;
  track_b.base_track = false;
  track_b.weight = 30;

  session.ids.sender_ssrc = track_a.ids.sender_ssrc;
  session.video_tracks = {track_a, track_b};

  std::vector<Packet> push_packets;
  webrtc_qos::VideoPushClientConfig push_config;
  push_config.session = session;
  push_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        push_packets.push_back(
            Packet{{packet.bytes, packet.bytes + packet.size}, packet.metadata});
        return webrtc_qos::Status::Ok();
      };

  std::vector<Packet> play_rtcp_packets;
  std::vector<webrtc_qos::TransportIds> decoded_ids;
  webrtc_qos::VideoPlayClientConfig play_config;
  play_config.session = session;
  play_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtcp) {
          play_rtcp_packets.push_back(
              Packet{{packet.bytes, packet.bytes + packet.size},
                     packet.metadata});
        }
        return webrtc_qos::Status::Ok();
      };
  play_config.decoded_access_unit_output =
      [&](const webrtc_qos::AnnexBAccessUnitView& access_unit) {
        decoded_ids.push_back(access_unit.ids);
        return webrtc_qos::Status::Ok();
      };

  std::vector<Packet> server_to_sender;
  std::vector<Packet> server_to_receiver;
  webrtc_qos::ServerQosRouterConfig server_config;
  server_config.session = session;
  server_config.sender_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        server_to_sender.push_back(
            Packet{{packet.bytes, packet.bytes + packet.size}, packet.metadata});
        return webrtc_qos::Status::Ok();
      };
  server_config.receiver_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        server_to_receiver.push_back(
            Packet{{packet.bytes, packet.bytes + packet.size}, packet.metadata});
        return webrtc_qos::Status::Ok();
      };

  auto push = webrtc_qos::CreateVideoPushClient(push_config);
  auto play = webrtc_qos::CreateVideoPlayClient(play_config);
  auto server = webrtc_qos::CreateServerQosRouter(server_config);
  if (!push || !play || !server || !push->Start() || !play->Start() ||
      !server->Start()) {
    return 1;
  }

  const auto au = MakeAccessUnit();
  webrtc_qos::AnnexBAccessUnitView track_a_au;
  track_a_au.bytes = au.data();
  track_a_au.size = au.size();
  track_a_au.capture_time_us = 1000000;
  track_a_au.keyframe = true;
  track_a_au.ids = track_a.ids;
  if (!push->PushAnnexBAccessUnit(track_a_au) || !push->Process(1001000)) {
    return 2;
  }

  webrtc_qos::AnnexBAccessUnitView track_b_au = track_a_au;
  track_b_au.capture_time_us = 1033333;
  track_b_au.ids = track_b.ids;
  if (!push->PushAnnexBAccessUnit(track_b_au) || !push->Process(1034333)) {
    return 3;
  }

  bool saw_track_a_rtp = false;
  bool saw_track_b_rtp = false;
  for (const auto& packet : push_packets) {
    if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtp) {
      if (packet.metadata.ids.track_id == track_a.ids.track_id &&
          packet.metadata.ids.sender_ssrc == track_a.ids.sender_ssrc) {
        saw_track_a_rtp = true;
      }
      if (packet.metadata.ids.track_id == track_b.ids.track_id &&
          packet.metadata.ids.sender_ssrc == track_b.ids.sender_ssrc) {
        saw_track_b_rtp = true;
      }
      if (!server->OnSenderRtp(packet.bytes.data(), packet.bytes.size(),
                               packet.metadata.send_time_us)) {
        return 4;
      }
    } else if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtcp) {
      if (!server->OnSenderRtcp(packet.bytes.data(), packet.bytes.size(),
                                packet.metadata.send_time_us)) {
        return 5;
      }
    }
  }
  if (!saw_track_a_rtp || !saw_track_b_rtp) {
    return 6;
  }

  for (const auto& packet : server_to_receiver) {
    if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtp) {
      if (!play->OnRtpPacket(packet.bytes.data(), packet.bytes.size(),
                             packet.metadata.send_time_us)) {
        return 7;
      }
    } else if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtcp) {
      if (!play->OnRtcpPacket(packet.bytes.data(), packet.bytes.size(),
                              packet.metadata.send_time_us)) {
        return 8;
      }
    }
  }
  if (!play->Process(1200000)) {
    return 9;
  }
  if (decoded_ids.size() != 2) {
    return 10;
  }
  bool decoded_track_a = false;
  bool decoded_track_b = false;
  for (const auto& ids : decoded_ids) {
    if (ids.track_id == track_a.ids.track_id &&
        ids.sender_ssrc == track_a.ids.sender_ssrc) {
      decoded_track_a = true;
    }
    if (ids.track_id == track_b.ids.track_id &&
        ids.sender_ssrc == track_b.ids.sender_ssrc) {
      decoded_track_b = true;
    }
  }
  if (!decoded_track_a || !decoded_track_b) {
    return 11;
  }

  webrtc_qos::EncoderAdaptation track_a_adaptation;
  webrtc_qos::EncoderAdaptation track_b_adaptation;
  if (!push->GetTrackEncoderAdaptation(track_a.ids.track_id, 1300000,
                                       &track_a_adaptation) ||
      !push->GetTrackEncoderAdaptation(track_b.ids.track_id, 1300000,
                                       &track_b_adaptation)) {
    return 12;
  }
  const auto source_snapshot = push->GetQosSnapshot(1300000);
  if (track_a_adaptation.target_bitrate_bps <=
      track_b_adaptation.target_bitrate_bps) {
    return 13;
  }
  if (static_cast<uint64_t>(track_a_adaptation.target_bitrate_bps) +
          track_b_adaptation.target_bitrate_bps >
      static_cast<uint64_t>(source_snapshot.sender_rates.final_target_bps) + 1) {
    std::cerr << "uncapped allocation overflow track_a="
              << track_a_adaptation.target_bitrate_bps
              << " track_b=" << track_b_adaptation.target_bitrate_bps
              << " source="
              << source_snapshot.sender_rates.final_target_bps << "\n";
    return 24;
  }

  std::vector<uint8_t> pli_bytes;
  webrtc_qos::RtcpAdapterPli pli;
  pli.sender_ssrc = session.rtcp.receiver_feedback_ssrc;
  pli.media_ssrc = track_b.ids.sender_ssrc;
  if (!webrtc_qos::BuildRtcpPli(pli, &pli_bytes) ||
      !push->OnTransportFeedback(pli_bytes.data(), pli_bytes.size(), 1400000)) {
    return 14;
  }
  if (!push->GetTrackEncoderAdaptation(track_b.ids.track_id, 1400000,
                                       &track_b_adaptation) ||
      !track_b_adaptation.request_keyframe) {
    return 15;
  }
  if (!push->GetTrackEncoderAdaptation(track_a.ids.track_id, 1400000,
                                       &track_a_adaptation)) {
    return 16;
  }
  if (track_a_adaptation.request_keyframe) {
    return 17;
  }

  std::vector<uint8_t> sender_nack_bytes;
  webrtc_qos::RtcpAdapterNack sender_nack;
  sender_nack.sender_ssrc = session.rtcp.receiver_feedback_ssrc;
  sender_nack.media_ssrc = track_b.ids.sender_ssrc;
  sender_nack.packet_ids.push_back(1);
  const size_t push_packets_before_retransmission = push_packets.size();
  if (!webrtc_qos::BuildRtcpNack(sender_nack, &sender_nack_bytes) ||
      !push->OnTransportFeedback(sender_nack_bytes.data(),
                                 sender_nack_bytes.size(), 1450000)) {
    return 18;
  }
  bool saw_track_b_retransmission = false;
  bool saw_track_a_retransmission = false;
  for (int i = 0; i < 50; ++i) {
    if (!push->Process(1455000 + static_cast<int64_t>(i) * 5000)) {
      return 19;
    }
    for (size_t packet_index = push_packets_before_retransmission;
         packet_index < push_packets.size(); ++packet_index) {
      if (!push_packets[packet_index].metadata.retransmission) {
        continue;
      }
      if (push_packets[packet_index].metadata.ids.sender_ssrc ==
          track_b.ids.sender_ssrc) {
        saw_track_b_retransmission = true;
      }
      if (push_packets[packet_index].metadata.ids.sender_ssrc ==
          track_a.ids.sender_ssrc) {
        saw_track_a_retransmission = true;
      }
    }
    if (saw_track_b_retransmission) {
      break;
    }
  }
  if (!saw_track_b_retransmission || saw_track_a_retransmission) {
    return 20;
  }

  webrtc_qos::SenderRateCap low_cap =
      webrtc_qos::UnlimitedSenderRateCap(session.ids, 1, 1455000);
  low_cap.cap_bps = 600000;
  low_cap.receive_time_us = 1455000;
  if (!push->OnSenderRateCap(low_cap)) {
    return 25;
  }
  if (!push->GetTrackEncoderAdaptation(track_a.ids.track_id, 1460000,
                                       &track_a_adaptation) ||
      !push->GetTrackEncoderAdaptation(track_b.ids.track_id, 1460000,
                                       &track_b_adaptation)) {
    return 26;
  }
  const auto capped_source_snapshot = push->GetQosSnapshot(1460000);
  if (track_a_adaptation.target_bitrate_bps <=
          track_b_adaptation.target_bitrate_bps ||
      track_a_adaptation.max_fps < track_b_adaptation.max_fps ||
      static_cast<uint64_t>(track_a_adaptation.target_bitrate_bps) +
              track_b_adaptation.target_bitrate_bps >
          static_cast<uint64_t>(
              capped_source_snapshot.sender_rates.final_target_bps) + 1) {
    std::cerr << "capped allocation invalid track_a_bps="
              << track_a_adaptation.target_bitrate_bps
              << " track_b_bps=" << track_b_adaptation.target_bitrate_bps
              << " track_a_fps=" << track_a_adaptation.max_fps
              << " track_b_fps=" << track_b_adaptation.max_fps
              << " track_a_weight=" << track_a.weight
              << " track_b_weight=" << track_b.weight
              << " track_a_base=" << track_a.base_track
              << " track_b_base=" << track_b.base_track
              << " source_bps="
              << capped_source_snapshot.sender_rates.final_target_bps << "\n";
    return 27;
  }

  webrtc_qos::QosSnapshot track_a_play_snapshot;
  webrtc_qos::QosSnapshot track_b_play_snapshot;
  if (!play->GetTrackQosSnapshot(track_a.ids.track_id, 1500000,
                                 &track_a_play_snapshot) ||
      !play->GetTrackQosSnapshot(track_b.ids.track_id, 1500000,
                                 &track_b_play_snapshot)) {
    return 21;
  }
  webrtc_qos::QosSnapshot track_a_push_snapshot;
  webrtc_qos::QosSnapshot track_b_push_snapshot;
  if (!push->GetTrackQosSnapshot(track_a.ids.track_id, 1500000,
                                 &track_a_push_snapshot) ||
      !push->GetTrackQosSnapshot(track_b.ids.track_id, 1500000,
                                 &track_b_push_snapshot)) {
    return 22;
  }
  return (track_a_play_snapshot.ids.track_id == track_a.ids.track_id &&
          track_b_play_snapshot.ids.track_id == track_b.ids.track_id &&
          track_b_push_snapshot.pli_count > track_a_push_snapshot.pli_count &&
          track_b_push_snapshot.retransmission_count >
              track_a_push_snapshot.retransmission_count)
             ? 0
             : 23;
}
EOF

cmake -S "${WORK_DIR}" -B "${WORK_DIR}/build" \
  -DCMAKE_PREFIX_PATH="${PREFIX}" >/dev/null
cmake --build "${WORK_DIR}/build" -j2 >/dev/null
"${WORK_DIR}/build/verify_multitrack"

echo "webrtc_first_multitrack passed prefix=${PREFIX}"
