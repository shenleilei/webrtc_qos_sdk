#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <utility>
#include <vector>

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

struct Metrics {
  int ticks = 0;
  int pushed_frames = 0;
  int decoded_frames = 0;
  int downlink_dropped = 0;
  int sender_rtp = 0;
  int sender_rtcp = 0;
  int receiver_rtcp = 0;
  int retransmissions = 0;
  int bad_ticks = 0;
  int bad_pushed_frames = 0;
  int recovery_ticks = 0;
  int recovery_pushed_frames = 0;
  uint32_t min_bad_target_bps = UINT32_MAX;
  uint32_t max_recovery_target_bps = 0;
  uint32_t min_bad_fps = UINT32_MAX;
  uint32_t max_recovery_fps = 0;
  uint32_t final_target_bps = 0;
  uint32_t final_fps = 0;
};

struct Scenario {
  std::string name;
  int frames = 36;
  int bad_start = -1;
  int bad_end = -1;
  bool inject_rate_cap = false;
  bool drop_downlink_in_bad_window = false;
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

std::vector<uint8_t> MakeIdrAccessUnit(uint8_t frame_id) {
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

bool InBadWindow(const Scenario& scenario, int frame) {
  return frame >= scenario.bad_start && frame <= scenario.bad_end;
}

bool InRecoveryWindow(const Scenario& scenario, int frame) {
  return scenario.bad_end >= 0 && frame > scenario.bad_end;
}

double TickRate(int count, int ticks) {
  return ticks <= 0 ? 0.0 : static_cast<double>(count) * 30.0 / ticks;
}

void RequireStatus(const webrtc_qos::Status& status, const char* operation) {
  if (status) {
    return;
  }
  std::cerr << operation << " failed: " << status.message << "\n";
  std::exit(2);
}

int FpsInterval(uint32_t fps) {
  if (fps >= 25) {
    return 1;
  }
  if (fps >= 15) {
    return 2;
  }
  return fps >= 10 ? 3 : 6;
}

Metrics RunScenario(const Scenario& scenario) {
  Metrics metrics;
  metrics.ticks = scenario.frames;

  webrtc_qos::SessionConfig session;
  session.ids.session_id = 1;
  session.ids.stream_id = 1;
  session.ids.transport_id = 1;
  session.ids.sender_ssrc = 0x12345678;
  session.ids.receiver_id = 0x2222;
  session.start_bitrate_bps = 1200000;
  session.min_bitrate_bps = 300000;
  session.max_bitrate_bps = 2500000;
  session.debug_name = scenario.name;

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
  if (!push || !play || !server) {
    std::cerr << "failed to create facade roles\n";
    std::exit(2);
  }
  RequireStatus(push->Start(), "push start");
  RequireStatus(play->Start(), "play start");
  RequireStatus(server->Start(), "server start");

  auto drain_server_to_sender = [&](int64_t now_us) {
    while (server_to_sender_index < server_to_sender.size()) {
      const Packet& packet = server_to_sender[server_to_sender_index++];
      if (packet.kind == webrtc_qos::TransportPacketKind::kRtcp) {
        RequireStatus(push->OnTransportFeedback(packet.bytes.data(),
                                                packet.bytes.size(), now_us),
                      "push RTCP feedback");
      }
    }
  };

  auto drain_play_output = [&](int64_t now_us) {
    while (play_output_index < play_output.size()) {
      const Packet& packet = play_output[play_output_index++];
      if (packet.kind != webrtc_qos::TransportPacketKind::kRtcp) {
        continue;
      }
      ++metrics.receiver_rtcp;
      RequireStatus(server->OnReceiverRtcp(session.ids.receiver_id,
                                           packet.bytes.data(),
                                           packet.bytes.size(), now_us),
                    "server receiver RTCP");
    }
  };

  auto drain_server_to_receiver = [&](int frame, int64_t now_us) {
    while (server_to_receiver_index < server_to_receiver.size()) {
      const Packet& packet = server_to_receiver[server_to_receiver_index++];
      if (packet.kind == webrtc_qos::TransportPacketKind::kRtcp) {
        RequireStatus(play->OnRtcpPacket(packet.bytes.data(),
                                         packet.bytes.size(), now_us),
                      "play RTCP");
        continue;
      }
      if (scenario.drop_downlink_in_bad_window && InBadWindow(scenario, frame) &&
          !packet.retransmission) {
        ++metrics.downlink_dropped;
        continue;
      }
      if (packet.retransmission) {
        ++metrics.retransmissions;
      }
      RequireStatus(play->OnRtpPacket(packet.bytes.data(), packet.bytes.size(),
                                      now_us),
                    "play RTP");
    }
  };

  auto pump = [&](int frame, int64_t now_us) {
    for (int guard = 0; guard < 64; ++guard) {
      const size_t before = server_to_sender_index + server_to_receiver_index +
                            play_output_index + push_output_index;
      drain_server_to_sender(now_us);
      drain_server_to_receiver(frame, now_us);
      drain_play_output(now_us);
      drain_server_to_sender(now_us);
      drain_server_to_receiver(frame, now_us);
      const size_t after = server_to_sender_index + server_to_receiver_index +
                           play_output_index + push_output_index;
      if (before == after) {
        break;
      }
    }
  };

  auto drain_push_output = [&](int frame, int64_t now_us) {
    while (push_output_index < push_output.size()) {
      const Packet& packet = push_output[push_output_index++];
      if (packet.kind == webrtc_qos::TransportPacketKind::kRtp) {
        ++metrics.sender_rtp;
        RequireStatus(server->OnSenderRtp(packet.bytes.data(),
                                          packet.bytes.size(), now_us),
                      "server sender RTP");
      } else if (packet.kind == webrtc_qos::TransportPacketKind::kRtcp) {
        ++metrics.sender_rtcp;
        RequireStatus(server->OnSenderRtcp(packet.bytes.data(),
                                           packet.bytes.size(), now_us),
                      "server sender RTCP");
      }
      pump(frame, now_us);
    }
  };

  for (int frame = 0; frame < scenario.frames; ++frame) {
    const int64_t now_us = 1000000 + static_cast<int64_t>(frame) * 33333;
    const bool bad = InBadWindow(scenario, frame);
    const bool recovery = InRecoveryWindow(scenario, frame);

    RequireStatus(push->Process(now_us), "push process");
    drain_push_output(frame, now_us);
    pump(frame, now_us);

    if (scenario.inject_rate_cap) {
      webrtc_qos::DownlinkQuality quality;
      quality.ids = session.ids;
      quality.report_seq = static_cast<uint32_t>(frame + 1);
      quality.report_time_us = static_cast<uint64_t>(now_us);
      if (bad) {
        quality.fraction_lost_q8 = 192;
        quality.video_drop_frames = 1;
      }
      RequireStatus(server->OnDownlinkQuality(quality),
                    "server downlink quality");
      RequireStatus(push->OnSenderRateCap(server->CurrentSenderRateCap(now_us)),
                    "push sender rate cap");
    }

    const auto adaptation = push->GetEncoderAdaptation(now_us);
    const auto snapshot = push->GetQosSnapshot(now_us);
    metrics.final_target_bps = snapshot.sender_rates.final_target_bps;
    metrics.final_fps = adaptation.max_fps;

    if (bad) {
      ++metrics.bad_ticks;
      metrics.min_bad_target_bps =
          std::min(metrics.min_bad_target_bps,
                   snapshot.sender_rates.final_target_bps);
      metrics.min_bad_fps = std::min(metrics.min_bad_fps, adaptation.max_fps);
    }
    if (recovery) {
      ++metrics.recovery_ticks;
      metrics.max_recovery_target_bps =
          std::max(metrics.max_recovery_target_bps,
                   snapshot.sender_rates.final_target_bps);
      metrics.max_recovery_fps =
          std::max(metrics.max_recovery_fps, adaptation.max_fps);
    }

    if (frame % FpsInterval(adaptation.max_fps) != 0) {
      continue;
    }

    if (bad) {
      ++metrics.bad_pushed_frames;
    }
    if (recovery) {
      ++metrics.recovery_pushed_frames;
    }

    const std::vector<uint8_t> au =
        MakeIdrAccessUnit(static_cast<uint8_t>(frame & 0xff));
    webrtc_qos::AnnexBAccessUnitView view;
    view.bytes = au.data();
    view.size = au.size();
    view.capture_time_us = now_us;
    view.keyframe = true;
    RequireStatus(push->PushAnnexBAccessUnit(view), "push AU");
    ++metrics.pushed_frames;

    RequireStatus(push->Process(now_us + 1000), "push process after AU");
    drain_push_output(frame, now_us + 1000);
    pump(frame, now_us + 2000);
  }

  const int64_t final_time_us =
      1000000 + static_cast<int64_t>(scenario.frames) * 33333 + 1000000;
  RequireStatus(push->Process(final_time_us), "final push process");
  drain_push_output(scenario.frames, final_time_us);
  pump(scenario.frames, final_time_us);

  const auto server_snapshot = server->GetQosSnapshot(final_time_us);
  metrics.retransmissions =
      std::max<int>(metrics.retransmissions,
                    static_cast<int>(server_snapshot.retransmission_count));
  if (metrics.min_bad_target_bps == UINT32_MAX) {
    metrics.min_bad_target_bps = 0;
  }
  if (metrics.min_bad_fps == UINT32_MAX) {
    metrics.min_bad_fps = 0;
  }
  return metrics;
}

bool CheckScenario(const Scenario& scenario, const Metrics& metrics) {
  const double playable_ratio =
      metrics.pushed_frames == 0
          ? 0.0
          : static_cast<double>(metrics.decoded_frames) /
                metrics.pushed_frames;
  if (playable_ratio < 0.85) {
    return false;
  }
  if (!scenario.inject_rate_cap) {
    return metrics.final_target_bps >= 1000000 && metrics.final_fps >= 25;
  }

  const double bad_send_rps =
      TickRate(metrics.bad_pushed_frames, metrics.bad_ticks);
  const double recovery_send_rps =
      TickRate(metrics.recovery_pushed_frames, metrics.recovery_ticks);
  return metrics.downlink_dropped > 0 && metrics.receiver_rtcp > 0 &&
         metrics.retransmissions > 0 && metrics.min_bad_target_bps > 0 &&
         metrics.min_bad_target_bps <= 600000 && metrics.min_bad_fps <= 10 &&
         bad_send_rps <= 15.0 && metrics.max_recovery_target_bps >= 1000000 &&
         metrics.max_recovery_fps >= 25 && recovery_send_rps >= 25.0;
}

void PrintScenario(const Scenario& scenario, const Metrics& metrics) {
  const double playable_ratio =
      metrics.pushed_frames == 0
          ? 0.0
          : static_cast<double>(metrics.decoded_frames) /
                metrics.pushed_frames;
  std::cout << scenario.name << " pushed=" << metrics.pushed_frames
            << " decoded=" << metrics.decoded_frames
            << " playable_ratio=" << playable_ratio
            << " dropped=" << metrics.downlink_dropped
            << " receiver_rtcp=" << metrics.receiver_rtcp
            << " rtx=" << metrics.retransmissions
            << " bad_send_rps="
            << TickRate(metrics.bad_pushed_frames, metrics.bad_ticks)
            << " recovery_send_rps="
            << TickRate(metrics.recovery_pushed_frames,
                        metrics.recovery_ticks)
            << " min_bad_target=" << metrics.min_bad_target_bps
            << " max_recovery_target=" << metrics.max_recovery_target_bps
            << " min_bad_fps=" << metrics.min_bad_fps
            << " max_recovery_fps=" << metrics.max_recovery_fps
            << " final_target=" << metrics.final_target_bps
            << " final_fps=" << metrics.final_fps
            << " pass=" << (CheckScenario(scenario, metrics) ? "true"
                                                              : "false")
            << "\n";
}

}  // namespace

int main(int argc, char** argv) {
  const int frames = argc >= 2 ? std::max(12, std::atoi(argv[1])) : 36;
  const std::vector<Scenario> scenarios = {
      Scenario{"good_static", frames, -1, -1, false, false},
      Scenario{"walking_dead_zone_recover", frames, frames / 4, frames / 2,
               true, true},
  };

  bool ok = true;
  std::cout << "backend=webrtc_first_facade"
            << " transport=custom_bytes"
            << " peer_connection=false"
            << "\n";
  for (const auto& scenario : scenarios) {
    const Metrics metrics = RunScenario(scenario);
    PrintScenario(scenario, metrics);
    ok = CheckScenario(scenario, metrics) && ok;
  }
  return ok ? 0 : 1;
}
