#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/root/webrtc_qos_sdk/dist/linux-x86_64}"
WORK_DIR="${WORK_DIR:-/tmp/webrtc_qos_facade_matrix.$$}"
OUTPUT_DIR="${OUTPUT_DIR:-/root/webrtc_qos_sdk/artifacts/webrtc_first_facade_matrix}"
FRAMES="${FRAMES:-36}"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

cat > "${WORK_DIR}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(webrtc_first_facade_matrix LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(WebRtcQosSdk REQUIRED CONFIG)

foreach(target IN ITEMS
  WebRtcQosSdk::role_push
  WebRtcQosSdk::role_play
  WebRtcQosSdk::role_server)
  if(NOT TARGET "${target}")
    message(FATAL_ERROR "missing required facade role: ${target}")
  endif()
endforeach()

add_executable(webrtc_first_facade_matrix main.cc)
target_link_libraries(webrtc_first_facade_matrix PRIVATE
  WebRtcQosSdk::role_push
  WebRtcQosSdk::role_play
  WebRtcQosSdk::role_server)
EOF

cat > "${WORK_DIR}/main.cc" <<'EOF'
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "webrtc_qos/rate_cap.h"
#include "webrtc_qos/rtcp_adapter.h"
#include "webrtc_qos/rtp_packet_adapter.h"
#include "webrtc_qos/server_qos_router.h"
#include "webrtc_qos/video_play_client.h"
#include "webrtc_qos/video_push_client.h"

namespace {

struct Packet {
  webrtc_qos::TransportPacketKind kind = webrtc_qos::TransportPacketKind::kRtp;
  std::vector<uint8_t> bytes;
  bool retransmission = false;
  bool padding = false;
  int64_t time_us = 0;
};

struct Scenario {
  std::string name;
  int frames = 36;
  int bad_start = -1;
  int bad_end = -1;
  bool drop_dead_zone = false;
  bool periodic_single_loss = false;
  bool inject_rate_cap = false;
  double min_playable_ratio = 0.95;
  bool expect_nack = false;
  bool expect_retransmission = false;
  bool expect_low_rate_in_bad_window = false;
  bool expect_recovery_after_bad_window = false;
  bool expect_final_low = false;
  bool multi_receiver_rate_cap = false;
  double max_bad_send_rps = 0.0;
  double max_bad_rtp_pps = 0.0;
  uint32_t max_bad_target_bps = 0;
  double min_recovery_send_rps = 0.0;
  double min_recovery_rtp_pps = 0.0;
  uint32_t min_recovery_target_bps = 0;
};

struct Metrics {
  std::string scenario;
  int ticks = 0;
  int frames_pushed = 0;
  int decoded_frames = 0;
  int pushed_bad_ticks = 0;
  int total_bad_ticks = 0;
  int pushed_recovery_ticks = 0;
  int total_recovery_ticks = 0;
  int rtp_sent = 0;
  int bad_rtp_sent = 0;
  int recovery_rtp_sent = 0;
  int rtp_to_server = 0;
  int rtp_to_play = 0;
  int rtp_dropped_downlink = 0;
  int rtcp_twcc = 0;
  int rtcp_rr = 0;
  int rtcp_nack = 0;
  int rtcp_pli = 0;
  int retransmissions = 0;
  uint32_t selected_receiver_id = 0;
  uint16_t rate_cap_reason = 0;
  uint32_t bad_selected_receiver_id = 0;
  uint16_t bad_rate_cap_reason = 0;
  bool multi_receiver_worst_cap_seen = false;
  uint32_t min_target_bps = UINT32_MAX;
  uint32_t final_target_bps = 0;
  uint32_t min_encoder_fps = UINT32_MAX;
  uint32_t final_encoder_fps = 0;
  uint32_t min_bad_target_bps = UINT32_MAX;
  uint32_t max_bad_target_bps = 0;
  uint32_t max_recovery_target_bps = 0;
  uint32_t min_bad_encoder_fps = UINT32_MAX;
  uint32_t max_bad_encoder_fps = 0;
  uint32_t max_recovery_encoder_fps = 0;
  uint32_t max_rtt_ms = 0;
};

Packet CopyPacket(const webrtc_qos::TransportPacketView& view) {
  Packet packet;
  packet.kind = view.metadata.kind;
  packet.retransmission = view.metadata.retransmission;
  packet.padding = view.metadata.padding;
  packet.time_us = view.metadata.send_time_us;
  packet.bytes.assign(view.bytes, view.bytes + view.size);
  return packet;
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

bool ParseRtpSeq(const std::vector<uint8_t>& bytes,
                 const webrtc_qos::SessionConfig& session,
                 uint16_t* seq) {
  webrtc_qos::RtpPacketAdapterConfig config;
  config.payload_type = session.h264.payload_type;
  config.transport_sequence_extension_id = session.twcc.extension_id;
  config.enable_transport_sequence_extension = true;
  webrtc_qos::RtpPacketAdapterParsedPacket parsed;
  if (!webrtc_qos::ParseRtpPacket(bytes.data(), bytes.size(), config,
                                  &parsed)) {
    return false;
  }
  *seq = parsed.sequence_number;
  return true;
}

bool InBadWindow(const Scenario& scenario, int frame_index) {
  return frame_index >= scenario.bad_start && frame_index <= scenario.bad_end;
}

bool InRecoveryWindow(const Scenario& scenario, int frame_index) {
  return scenario.bad_end >= 0 && frame_index > scenario.bad_end;
}

double TickRate(int count, int ticks) {
  return ticks <= 0 ? 0.0 : static_cast<double>(count) * 30.0 / ticks;
}

constexpr double kMaxWeakSendRps = 15.0;
constexpr double kMaxWeakRtpPps = 45.0;

bool ShouldDropDownlink(const Scenario& scenario,
                        int frame_index,
                        uint16_t rtp_sequence_number,
                        bool retransmission) {
  if (retransmission) {
    return false;
  }
  if (scenario.drop_dead_zone && InBadWindow(scenario, frame_index)) {
    return true;
  }
  if (scenario.periodic_single_loss && InBadWindow(scenario, frame_index)) {
    return rtp_sequence_number % 9 == 2;
  }
  return false;
}

void CountRtcpToSender(const Packet& packet, Metrics* metrics) {
  webrtc_qos::RtcpAdapterParsedPacket parsed;
  if (!webrtc_qos::ParseRtcpPacket(packet.bytes.data(), packet.bytes.size(),
                                   &parsed)) {
    return;
  }
  if (parsed.type == webrtc_qos::RtcpAdapterPacketType::kTransportFeedback) {
    ++metrics->rtcp_twcc;
  } else if (parsed.type == webrtc_qos::RtcpAdapterPacketType::kReceiverReport) {
    ++metrics->rtcp_rr;
  }
}

void CountRtcpFromPlay(const Packet& packet, Metrics* metrics) {
  webrtc_qos::RtcpAdapterParsedPacket parsed;
  if (!webrtc_qos::ParseRtcpPacket(packet.bytes.data(), packet.bytes.size(),
                                   &parsed)) {
    return;
  }
  if (parsed.type == webrtc_qos::RtcpAdapterPacketType::kNack) {
    ++metrics->rtcp_nack;
  } else if (parsed.type == webrtc_qos::RtcpAdapterPacketType::kPli) {
    ++metrics->rtcp_pli;
  }
}

Metrics RunScenario(const Scenario& scenario) {
  Metrics metrics;
  metrics.scenario = scenario.name;

  webrtc_qos::SessionConfig session;
  session.ids.session_id = 1;
  session.ids.stream_id = 1;
  session.ids.transport_id = 1;
  session.ids.sender_ssrc = 0x12345678;
  session.ids.receiver_id = 0x2222;
  session.start_bitrate_bps = 1200000;
  session.min_bitrate_bps = 300000;
  session.max_bitrate_bps = 2500000;

  std::vector<Packet> push_output;
  std::vector<Packet> play_output;
  std::vector<Packet> server_to_sender;
  std::vector<Packet> server_to_receiver;
  size_t push_output_index = 0;
  size_t play_output_index = 0;
  size_t server_to_sender_index = 0;
  size_t server_to_receiver_index = 0;

  webrtc_qos::VideoPushClientConfig push_config;
  push_config.session = session;
  push_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        push_output.push_back(CopyPacket(packet));
        return webrtc_qos::Status::Ok();
      };

  webrtc_qos::VideoPlayClientConfig play_config;
  play_config.session = session;
  play_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        play_output.push_back(CopyPacket(packet));
        return webrtc_qos::Status::Ok();
      };
  play_config.decoded_access_unit_output =
      [&](const webrtc_qos::AnnexBAccessUnitView& access_unit) {
        if (access_unit.bytes == nullptr || access_unit.size == 0) {
          return webrtc_qos::Status::Error(
              webrtc_qos::StatusCode::kInternalError, "empty decoded AU");
        }
        ++metrics.decoded_frames;
        return webrtc_qos::Status::Ok();
      };

  webrtc_qos::ServerQosRouterConfig server_config;
  server_config.session = session;
  server_config.sender_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        server_to_sender.push_back(CopyPacket(packet));
        return webrtc_qos::Status::Ok();
      };
  server_config.receiver_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        server_to_receiver.push_back(CopyPacket(packet));
        return webrtc_qos::Status::Ok();
      };

  std::unique_ptr<webrtc_qos::VideoPushClient> push =
      webrtc_qos::CreateVideoPushClient(push_config);
  std::unique_ptr<webrtc_qos::VideoPlayClient> play =
      webrtc_qos::CreateVideoPlayClient(play_config);
  std::unique_ptr<webrtc_qos::ServerQosRouter> server =
      webrtc_qos::CreateServerQosRouter(server_config);
  if (!push || !play || !server || !push->Start() || !play->Start() ||
      !server->Start()) {
    std::cerr << "failed to start facade roles\n";
    std::exit(2);
  }

  auto drain_server_to_sender = [&](int64_t now_us) {
    while (server_to_sender_index < server_to_sender.size()) {
      const Packet& packet = server_to_sender[server_to_sender_index++];
      if (packet.kind == webrtc_qos::TransportPacketKind::kRtcp) {
        CountRtcpToSender(packet, &metrics);
        if (!push->OnTransportFeedback(packet.bytes.data(), packet.bytes.size(),
                                       now_us)) {
          std::cerr << "push rejected server RTCP\n";
          std::exit(3);
        }
      }
    }
  };

  auto drain_play_output = [&](int64_t now_us) {
    while (play_output_index < play_output.size()) {
      const Packet& packet = play_output[play_output_index++];
      if (packet.kind != webrtc_qos::TransportPacketKind::kRtcp) {
        continue;
      }
      CountRtcpFromPlay(packet, &metrics);
      if (!server->OnReceiverRtcp(session.ids.receiver_id, packet.bytes.data(),
                                  packet.bytes.size(), now_us)) {
        std::cerr << "server rejected play RTCP\n";
        std::exit(4);
      }
    }
  };

  auto drain_server_to_receiver = [&](int frame_index, int64_t now_us) {
    while (server_to_receiver_index < server_to_receiver.size()) {
      const Packet& packet = server_to_receiver[server_to_receiver_index++];
      if (packet.kind == webrtc_qos::TransportPacketKind::kRtcp) {
        (void)play->OnRtcpPacket(packet.bytes.data(), packet.bytes.size(),
                                 now_us);
        continue;
      }
      uint16_t seq = 0;
      if (!ParseRtpSeq(packet.bytes, session, &seq)) {
        std::cerr << "failed to parse relayed RTP\n";
        std::exit(5);
      }
      if (ShouldDropDownlink(scenario, frame_index, seq,
                             packet.retransmission)) {
        ++metrics.rtp_dropped_downlink;
        continue;
      }
      if (packet.retransmission) {
        ++metrics.retransmissions;
      }
      ++metrics.rtp_to_play;
      if (!play->OnRtpPacket(packet.bytes.data(), packet.bytes.size(), now_us)) {
        std::cerr << "play rejected RTP\n";
        std::exit(6);
      }
    }
  };

  auto pump = [&](int frame_index, int64_t now_us) {
    for (int guard = 0; guard < 64; ++guard) {
      const size_t a = push_output_index + play_output_index +
                       server_to_sender_index + server_to_receiver_index;
      drain_server_to_sender(now_us);
      drain_server_to_receiver(frame_index, now_us);
      drain_play_output(now_us);
      drain_server_to_sender(now_us);
      drain_server_to_receiver(frame_index, now_us);
      const size_t b = push_output_index + play_output_index +
                       server_to_sender_index + server_to_receiver_index;
      if (a == b) {
        break;
      }
    }
    if (!play->Process(now_us)) {
      std::cerr << "play process failed\n";
      std::exit(7);
    }
  };

  auto drain_push_output = [&](int frame_index, int64_t now_us) {
    while (push_output_index < push_output.size()) {
      const Packet& packet = push_output[push_output_index++];
      if (packet.kind == webrtc_qos::TransportPacketKind::kRtp) {
        ++metrics.rtp_sent;
        if (InBadWindow(scenario, frame_index)) {
          ++metrics.bad_rtp_sent;
        }
        if (InRecoveryWindow(scenario, frame_index)) {
          ++metrics.recovery_rtp_sent;
        }
        ++metrics.rtp_to_server;
        if (!server->OnSenderRtp(packet.bytes.data(), packet.bytes.size(),
                                 now_us)) {
          std::cerr << "server rejected sender RTP\n";
          std::exit(7);
        }
      } else if (packet.kind == webrtc_qos::TransportPacketKind::kRtcp) {
        if (!server->OnSenderRtcp(packet.bytes.data(), packet.bytes.size(),
                                  now_us)) {
          std::cerr << "server rejected sender RTCP\n";
          std::exit(8);
        }
      }
      pump(frame_index, now_us);
    }
  };

  for (int frame = 0; frame < scenario.frames; ++frame) {
    ++metrics.ticks;
    const int64_t now_us = 1000000 + static_cast<int64_t>(frame) * 33333;
    const bool in_bad_window = InBadWindow(scenario, frame);
    const bool in_recovery_window = InRecoveryWindow(scenario, frame);
    auto process_status = push->Process(now_us);
    if (!process_status) {
      std::cerr << "push process failed\n";
      std::exit(12);
    }
    drain_push_output(frame, now_us);
    pump(frame, now_us);
    if (in_bad_window) {
      ++metrics.total_bad_ticks;
    }
    if (in_recovery_window) {
      ++metrics.total_recovery_ticks;
    }

    if (scenario.inject_rate_cap) {
      webrtc_qos::DownlinkQuality quality;
      quality.ids = session.ids;
      quality.report_seq = frame + 1;
      quality.report_time_us = static_cast<uint64_t>(now_us);
      if (in_bad_window) {
        quality.fraction_lost_q8 = 192;
        quality.video_drop_frames = 1;
      }
      if (!server->OnDownlinkQuality(quality)) {
        std::cerr << "server rejected downlink quality\n";
        std::exit(9);
      }
      if (scenario.multi_receiver_rate_cap) {
        webrtc_qos::DownlinkQuality healthy_quality;
        healthy_quality.ids = session.ids;
        healthy_quality.ids.receiver_id = session.ids.receiver_id + 1;
        healthy_quality.report_seq = frame + 1;
        healthy_quality.report_time_us = static_cast<uint64_t>(now_us);
        if (!server->OnDownlinkQuality(healthy_quality)) {
          std::cerr << "server rejected healthy receiver quality\n";
          std::exit(14);
        }
      }
      const auto cap = server->CurrentSenderRateCap(now_us);
      if (!push->OnSenderRateCap(cap)) {
        std::cerr << "push rejected sender rate cap\n";
        std::exit(10);
      }
      metrics.rate_cap_reason = cap.reason_code;
      if (scenario.multi_receiver_rate_cap && in_bad_window) {
        metrics.bad_selected_receiver_id = cap.ids.receiver_id;
        metrics.bad_rate_cap_reason = cap.reason_code;
        metrics.multi_receiver_worst_cap_seen =
            cap.ids.receiver_id == session.ids.receiver_id &&
            cap.reason_code ==
                static_cast<uint16_t>(webrtc_qos::RateCapReason::kWorstReceiver);
      }
    }

    const auto adaptation = push->GetEncoderAdaptation(now_us);
    metrics.min_encoder_fps =
        std::min(metrics.min_encoder_fps, adaptation.max_fps);
    metrics.final_encoder_fps = adaptation.max_fps;
    const auto tick_snapshot = push->GetQosSnapshot(now_us);
    metrics.min_target_bps = std::min(
        metrics.min_target_bps, tick_snapshot.sender_rates.final_target_bps);
    metrics.final_target_bps = tick_snapshot.sender_rates.final_target_bps;
    metrics.max_rtt_ms =
        std::max(metrics.max_rtt_ms, tick_snapshot.sender_rates.rtt_ms);
    const auto server_snapshot = server->GetQosSnapshot(now_us);
    metrics.selected_receiver_id =
        server_snapshot.downlink_quality.ids.receiver_id;
    if (in_bad_window) {
      metrics.min_bad_target_bps =
          std::min(metrics.min_bad_target_bps,
                   tick_snapshot.sender_rates.final_target_bps);
      metrics.max_bad_target_bps =
          std::max(metrics.max_bad_target_bps,
                   tick_snapshot.sender_rates.final_target_bps);
      metrics.min_bad_encoder_fps =
          std::min(metrics.min_bad_encoder_fps, adaptation.max_fps);
      metrics.max_bad_encoder_fps =
          std::max(metrics.max_bad_encoder_fps, adaptation.max_fps);
    }
    if (in_recovery_window) {
      metrics.max_recovery_target_bps =
          std::max(metrics.max_recovery_target_bps,
                   tick_snapshot.sender_rates.final_target_bps);
      metrics.max_recovery_encoder_fps =
          std::max(metrics.max_recovery_encoder_fps, adaptation.max_fps);
    }
    const int fps_interval =
        adaptation.max_fps >= 25
            ? 1
            : (adaptation.max_fps >= 15 ? 2
                                        : (adaptation.max_fps >= 10 ? 3 : 6));
    if (frame % fps_interval != 0) {
      continue;
    }
    if (in_bad_window) {
      ++metrics.pushed_bad_ticks;
    }
    if (in_recovery_window) {
      ++metrics.pushed_recovery_ticks;
    }

    const std::vector<uint8_t> au =
        MakeAccessUnit(static_cast<uint8_t>(frame & 0xff));
    webrtc_qos::AnnexBAccessUnitView view;
    view.bytes = au.data();
    view.size = au.size();
    view.capture_time_us = now_us;
    view.keyframe = true;
    if (!push->PushAnnexBAccessUnit(view)) {
      std::cerr << "push rejected AU\n";
      std::exit(11);
    }
    ++metrics.frames_pushed;
    process_status = push->Process(now_us + 1000);
    if (!process_status) {
      std::cerr << "push process after AU failed\n";
      std::exit(13);
    }
    drain_push_output(frame, now_us + 1000);
    pump(frame, now_us + 2000);

    const auto snapshot = push->GetQosSnapshot(now_us + 3000);
    metrics.min_target_bps =
        std::min(metrics.min_target_bps, snapshot.sender_rates.final_target_bps);
    metrics.final_target_bps = snapshot.sender_rates.final_target_bps;
    metrics.max_rtt_ms =
        std::max(metrics.max_rtt_ms, snapshot.sender_rates.rtt_ms);
  }

  pump(scenario.frames, 1000000 + static_cast<int64_t>(scenario.frames) *
                                       33333 + 1000000);
  const int64_t final_time_us =
      1000000 + static_cast<int64_t>(scenario.frames) * 33333 + 1000000;
  if (scenario.inject_rate_cap) {
    webrtc_qos::DownlinkQuality final_quality;
    final_quality.ids = session.ids;
    final_quality.report_seq = static_cast<uint32_t>(scenario.frames + 1);
    final_quality.report_time_us = static_cast<uint64_t>(final_time_us);
    if (scenario.expect_final_low) {
      final_quality.fraction_lost_q8 = 192;
      final_quality.video_drop_frames = 1;
      final_quality.recv_bitrate_bps = session.min_bitrate_bps;
    }
    if (!server->OnDownlinkQuality(final_quality)) {
      std::cerr << "server rejected final downlink quality\n";
      std::exit(12);
    }
    const auto final_cap = server->CurrentSenderRateCap(final_time_us);
    if (!push->OnSenderRateCap(final_cap)) {
      std::cerr << "push rejected final sender rate cap\n";
      std::exit(13);
    }
  }
  const auto snapshot = push->GetQosSnapshot(final_time_us);
  metrics.final_target_bps = snapshot.sender_rates.final_target_bps;
  metrics.max_rtt_ms = std::max(metrics.max_rtt_ms,
                                snapshot.sender_rates.rtt_ms);
  if (metrics.min_target_bps == UINT32_MAX) {
    metrics.min_target_bps = 0;
  }
  if (metrics.min_encoder_fps == UINT32_MAX) {
    metrics.min_encoder_fps = 0;
  }
  if (metrics.min_bad_target_bps == UINT32_MAX) {
    metrics.min_bad_target_bps = 0;
  }
  if (metrics.min_bad_encoder_fps == UINT32_MAX) {
    metrics.min_bad_encoder_fps = 0;
  }
  return metrics;
}

bool CheckScenario(const Scenario& scenario, const Metrics& metrics) {
  const double playable_ratio =
      metrics.frames_pushed == 0
          ? 0.0
          : static_cast<double>(metrics.decoded_frames) / metrics.frames_pushed;
  bool ok = playable_ratio >= scenario.min_playable_ratio;
  if (scenario.expect_nack) {
    ok = ok && metrics.rtcp_nack > 0;
  }
  if (scenario.expect_retransmission) {
    ok = ok && metrics.retransmissions > 0;
  }
  if (scenario.expect_low_rate_in_bad_window ||
      scenario.expect_recovery_after_bad_window || scenario.expect_final_low) {
    const double bad_send_rps =
        TickRate(metrics.pushed_bad_ticks, metrics.total_bad_ticks);
    const double bad_rtp_pps =
        TickRate(metrics.bad_rtp_sent, metrics.total_bad_ticks);
    const double recovery_send_rps =
        TickRate(metrics.pushed_recovery_ticks, metrics.total_recovery_ticks);
    const double recovery_rtp_pps =
        TickRate(metrics.recovery_rtp_sent, metrics.total_recovery_ticks);
    if (scenario.expect_low_rate_in_bad_window) {
      ok = ok && metrics.total_bad_ticks > 0 &&
           metrics.min_encoder_fps <= 10 &&
           metrics.min_bad_encoder_fps > 0 &&
           metrics.min_bad_encoder_fps <= 10 &&
           metrics.pushed_bad_ticks * 2 <=
               std::max(1, metrics.total_bad_ticks);
      if (scenario.max_bad_send_rps > 0.0) {
        ok = ok && bad_send_rps <= scenario.max_bad_send_rps;
      }
      if (scenario.max_bad_rtp_pps > 0.0) {
        ok = ok && bad_rtp_pps <= scenario.max_bad_rtp_pps;
      }
      if (scenario.max_bad_target_bps > 0) {
        ok = ok && metrics.min_bad_target_bps > 0 &&
             metrics.max_bad_target_bps > 0 &&
             metrics.min_bad_target_bps <= scenario.max_bad_target_bps &&
             metrics.max_bad_target_bps <= scenario.max_bad_target_bps;
      }
      ok = ok && metrics.max_bad_encoder_fps > 0 &&
           metrics.max_bad_encoder_fps <= 10;
      if (scenario.multi_receiver_rate_cap) {
        ok = ok && metrics.multi_receiver_worst_cap_seen;
      }
    }
    if (scenario.expect_recovery_after_bad_window) {
      ok = ok && metrics.total_recovery_ticks > 0 &&
           metrics.final_target_bps >= 1000000 &&
           metrics.final_encoder_fps >= 25 &&
           metrics.pushed_recovery_ticks * 3 >=
               std::max(1, metrics.total_recovery_ticks * 2);
      if (scenario.min_recovery_send_rps > 0.0) {
        ok = ok && recovery_send_rps >= scenario.min_recovery_send_rps;
      }
      if (scenario.min_recovery_rtp_pps > 0.0) {
        ok = ok && recovery_rtp_pps >= scenario.min_recovery_rtp_pps;
      }
      if (scenario.min_recovery_target_bps > 0) {
        ok = ok && metrics.max_recovery_target_bps >=
                         scenario.min_recovery_target_bps;
      }
    }
    if (scenario.expect_final_low) {
      ok = ok && metrics.final_encoder_fps <= 10;
      if (scenario.max_bad_target_bps > 0) {
        ok = ok && metrics.final_target_bps <= scenario.max_bad_target_bps;
      }
    }
  }
  return ok;
}

void WriteCsv(const std::string& path,
              const std::vector<Scenario>& scenarios,
              const std::vector<Metrics>& results) {
  std::ofstream out(path);
  out << "scenario,ticks,frames_pushed,decoded_frames,playable_ratio,"
         "bad_send_ratio,recovery_send_ratio,rtp_sent,rtp_to_server,"
         "rtp_to_play,rtp_dropped_downlink,rtcp_twcc,rtcp_rr,rtcp_nack,"
         "rtcp_pli,retransmissions,selected_receiver_id,rate_cap_reason,"
         "bad_selected_receiver_id,bad_rate_cap_reason,"
         "min_target_bps,final_target_bps,"
         "min_encoder_fps,final_encoder_fps,bad_send_rps,bad_rtp_pps,"
         "recovery_send_rps,recovery_rtp_pps,min_bad_target_bps,"
         "max_bad_target_bps,max_recovery_target_bps,min_bad_encoder_fps,"
         "max_bad_encoder_fps,max_recovery_encoder_fps,max_rtt_ms,pass\n";
  for (size_t i = 0; i < results.size(); ++i) {
    const Metrics& m = results[i];
    const double playable_ratio =
        m.frames_pushed == 0
            ? 0.0
            : static_cast<double>(m.decoded_frames) / m.frames_pushed;
    const double bad_send_ratio =
        m.total_bad_ticks == 0
            ? 0.0
            : static_cast<double>(m.pushed_bad_ticks) / m.total_bad_ticks;
    const double recovery_send_ratio =
        m.total_recovery_ticks == 0
            ? 0.0
            : static_cast<double>(m.pushed_recovery_ticks) /
                  m.total_recovery_ticks;
    const double bad_send_rps =
        TickRate(m.pushed_bad_ticks, m.total_bad_ticks);
    const double bad_rtp_pps = TickRate(m.bad_rtp_sent, m.total_bad_ticks);
    const double recovery_send_rps =
        TickRate(m.pushed_recovery_ticks, m.total_recovery_ticks);
    const double recovery_rtp_pps =
        TickRate(m.recovery_rtp_sent, m.total_recovery_ticks);
    out << m.scenario << ',' << m.ticks << ',' << m.frames_pushed << ','
        << m.decoded_frames << ',' << playable_ratio << ','
        << bad_send_ratio << ',' << recovery_send_ratio << ',' << m.rtp_sent
        << ','
        << m.rtp_to_server << ',' << m.rtp_to_play << ','
        << m.rtp_dropped_downlink << ',' << m.rtcp_twcc << ','
        << m.rtcp_rr << ',' << m.rtcp_nack << ',' << m.rtcp_pli << ','
        << m.retransmissions << ',' << m.selected_receiver_id << ','
        << m.rate_cap_reason << ',' << m.bad_selected_receiver_id << ','
        << m.bad_rate_cap_reason << ',' << m.min_target_bps << ','
        << m.final_target_bps << ',' << m.min_encoder_fps << ','
        << m.final_encoder_fps << ',' << bad_send_rps << ','
        << bad_rtp_pps << ',' << recovery_send_rps << ','
        << recovery_rtp_pps << ',' << m.min_bad_target_bps << ','
        << m.max_bad_target_bps << ',' << m.max_recovery_target_bps << ','
        << m.min_bad_encoder_fps << ',' << m.max_bad_encoder_fps << ','
        << m.max_recovery_encoder_fps << ',' << m.max_rtt_ms << ','
        << (CheckScenario(scenarios[i], m) ? "true" : "false") << '\n';
  }
}

}  // namespace

int main(int argc, char** argv) {
  const int frames = argc >= 2 ? std::max(1, std::stoi(argv[1])) : 36;
  const std::string csv_path =
      argc >= 3 ? argv[2] : "webrtc_first_facade_matrix.csv";
  std::vector<Scenario> scenarios = {
      Scenario{"good_static", frames, -1, -1, false, false, false, 1.0,
               false, false, false, false, false, false, 0.0, 0.0, 0, 0.0,
               0.0, 0},
      Scenario{"burst_loss_recover", frames, 4, std::max(4, frames / 2),
               false, true, false, 0.85, true, true, false, false, false,
               false, 0.0, 0.0, 0, 0.0, 0.0, 0},
      Scenario{"bandwidth_cliff_low_rps_recover", frames, frames / 4,
               frames / 2, false, false, true, 1.0, false, false, true,
               true, false, false, 15.0, 45.0, 600000, 25.0, 75.0, 1000000},
      Scenario{"weak_network_low_rps_low_bitrate", frames, frames / 4,
               frames * 3 / 4, false, false, true, 1.0, false, false, true,
               true, false, false, 15.0, 45.0, 600000, 25.0, 75.0, 1000000},
      Scenario{"multi_receiver_worst_cap_recover", frames, frames / 4,
               frames / 2, false, false, true, 1.0, false, false, true,
               true, false, true, 15.0, 45.0, 600000, 25.0, 75.0, 1000000},
      Scenario{"walking_dead_zone_recover", frames, frames / 4, frames / 2,
               true, false, true, 0.65, true, true, true, true, false, false,
               15.0, 45.0, 600000, 25.0, 75.0, 1000000},
      Scenario{"sustained_low_bandwidth_low_rps", frames, frames / 4,
               frames - 1, false, false, true, 1.0, false, false, true,
               false, true, false, 15.0, 45.0, 600000, 0.0, 0.0, 0},
      Scenario{"weak_start_low_bandwidth_low_rps", frames, 0, frames - 1,
               false, false, true, 1.0, false, false, true, false, true,
               false, kMaxWeakSendRps, kMaxWeakRtpPps, 600000, 0.0, 0.0, 0},
  };

  std::vector<Metrics> results;
  bool ok = true;
  for (const auto& scenario : scenarios) {
    Metrics metrics = RunScenario(scenario);
    ok = CheckScenario(scenario, metrics) && ok;
    const double playable_ratio =
        metrics.frames_pushed == 0
            ? 0.0
            : static_cast<double>(metrics.decoded_frames) /
                  metrics.frames_pushed;
    const double bad_send_ratio =
        metrics.total_bad_ticks == 0
            ? 0.0
            : static_cast<double>(metrics.pushed_bad_ticks) /
                  metrics.total_bad_ticks;
    const double recovery_send_ratio =
        metrics.total_recovery_ticks == 0
            ? 0.0
            : static_cast<double>(metrics.pushed_recovery_ticks) /
                  metrics.total_recovery_ticks;
    const double bad_send_rps =
        TickRate(metrics.pushed_bad_ticks, metrics.total_bad_ticks);
    const double bad_rtp_pps =
        TickRate(metrics.bad_rtp_sent, metrics.total_bad_ticks);
    const double recovery_send_rps =
        TickRate(metrics.pushed_recovery_ticks, metrics.total_recovery_ticks);
    const double recovery_rtp_pps =
        TickRate(metrics.recovery_rtp_sent, metrics.total_recovery_ticks);
    std::cout << scenario.name << " frames=" << metrics.frames_pushed
              << " decoded=" << metrics.decoded_frames
              << " playable_ratio=" << playable_ratio
              << " bad_send_ratio=" << bad_send_ratio
              << " recovery_send_ratio=" << recovery_send_ratio
              << " bad_send_rps=" << bad_send_rps
              << " bad_rtp_pps=" << bad_rtp_pps
              << " recovery_send_rps=" << recovery_send_rps
              << " recovery_rtp_pps=" << recovery_rtp_pps
              << " dropped=" << metrics.rtp_dropped_downlink
              << " nack=" << metrics.rtcp_nack
              << " rtx=" << metrics.retransmissions
              << " twcc=" << metrics.rtcp_twcc
              << " rr=" << metrics.rtcp_rr
              << " selected_receiver=" << metrics.selected_receiver_id
              << " rate_cap_reason=" << metrics.rate_cap_reason
              << " bad_selected_receiver=" << metrics.bad_selected_receiver_id
              << " bad_rate_cap_reason=" << metrics.bad_rate_cap_reason
              << " min_target=" << metrics.min_target_bps
              << " final_target=" << metrics.final_target_bps
              << " bad_min_target=" << metrics.min_bad_target_bps
              << " bad_max_target=" << metrics.max_bad_target_bps
              << " recovery_max_target=" << metrics.max_recovery_target_bps
              << " min_fps=" << metrics.min_encoder_fps
              << " final_fps=" << metrics.final_encoder_fps
              << " bad_min_fps=" << metrics.min_bad_encoder_fps
              << " bad_max_fps=" << metrics.max_bad_encoder_fps
              << " recovery_max_fps=" << metrics.max_recovery_encoder_fps
              << " rtt=" << metrics.max_rtt_ms
              << " pass=" << (CheckScenario(scenario, metrics) ? "true"
                                                                : "false")
              << "\n";
    results.push_back(std::move(metrics));
  }
  WriteCsv(csv_path, scenarios, results);
  return ok ? 0 : 1;
}
EOF

cmake -S "${WORK_DIR}" -B "${WORK_DIR}/build" \
  -DCMAKE_PREFIX_PATH="${PREFIX}" >/dev/null
cmake --build "${WORK_DIR}/build" -j2 >/dev/null

CSV_PATH="${OUTPUT_DIR}/webrtc_first_facade_matrix.csv"
LOG_PATH="${OUTPUT_DIR}/webrtc_first_facade_matrix.log"
"${WORK_DIR}/build/webrtc_first_facade_matrix" "${FRAMES}" "${CSV_PATH}" \
  | tee "${LOG_PATH}"

echo "wrote ${CSV_PATH}"
