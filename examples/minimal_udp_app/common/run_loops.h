#pragma once

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <set>
#include <string>
#include <time.h>
#include <vector>

#include "codec/synthetic_h264_source.h"
#include "common/options.h"
#include "common/session.h"
#include "common/udp_socket.h"
#include "common/wire_packet.h"
#include "webrtc_qos/server_qos_router.h"
#include "webrtc_qos/video_play_client.h"
#include "webrtc_qos/video_push_client.h"

namespace minimal_udp {

struct SampleMetrics {
  int pushed_frames = 0;
  int decoded_frames = 0;
  int sender_rtp = 0;
  int sender_rtcp = 0;
  int receiver_rtcp = 0;
  int downlink_dropped = 0;
  int retransmissions = 0;
  int sender_rate_caps = 0;
  int bad_ticks = 0;
  int bad_pushed_frames = 0;
  int recovery_ticks = 0;
  int recovery_pushed_frames = 0;
  std::set<uint32_t> decoded_track_ids;
  uint32_t min_bad_target_bps = UINT32_MAX;
  uint32_t max_recovery_target_bps = 0;
  uint32_t min_bad_fps = UINT32_MAX;
  uint32_t max_recovery_fps = 0;
  uint32_t final_target_bps = 0;
  uint32_t final_fps = 0;
};

inline const char* StatusCodeName(webrtc_qos::StatusCode code) {
  switch (code) {
    case webrtc_qos::StatusCode::kOk:
      return "ok";
    case webrtc_qos::StatusCode::kInvalidArgument:
      return "invalid_argument";
    case webrtc_qos::StatusCode::kUnsupported:
      return "unsupported";
    case webrtc_qos::StatusCode::kMalformedPacket:
      return "malformed_packet";
    case webrtc_qos::StatusCode::kQueueFull:
      return "queue_full";
    case webrtc_qos::StatusCode::kInternalError:
      return "internal_error";
  }
  return "unknown";
}

inline void RequireStatus(const webrtc_qos::Status& status,
                          const char* operation) {
  if (status) {
    return;
  }
  std::cerr << operation << " failed: code="
            << StatusCodeName(status.code) << " reason=" << status.message
            << " full_error=role_log_when_log_dir_is_enabled\n";
  std::exit(2);
}

inline bool SendDownlinkQuality(UdpSocket* endpoint,
                                const sockaddr_in& server_addr,
                                const webrtc_qos::DownlinkQuality& quality,
                                int64_t now_us) {
  WirePacket wire;
  wire.kind = WireKind::kDownlinkQuality;
  wire.time_us = now_us;
  wire.payload = EncodeDownlinkQuality(quality);
  return endpoint->SendTo(server_addr, EncodeWirePacket(wire));
}

inline bool SendSenderRateCap(UdpSocket* endpoint,
                              const sockaddr_in& sender_addr,
                              const webrtc_qos::SenderRateCap& cap,
                              int64_t now_us) {
  WirePacket wire;
  wire.kind = WireKind::kSenderRateCap;
  wire.time_us = now_us;
  wire.payload = EncodeSenderRateCap(cap);
  return endpoint->SendTo(sender_addr, EncodeWirePacket(wire));
}

inline bool CheckSelftestMetrics(const SampleMetrics& metrics,
                                 size_t track_total) {
  const double playable_ratio =
      metrics.pushed_frames == 0
          ? 0.0
          : static_cast<double>(metrics.decoded_frames) /
                metrics.pushed_frames;
  const uint32_t max_bad_fps = track_total > 1 ? 15u : 10u;
  const double max_bad_send_rps = track_total > 1 ? 30.0 : 15.0;
  const double min_recovery_send_rps = track_total > 1 ? 50.0 : 25.0;
  return playable_ratio >= 0.85 && metrics.sender_rtp > 0 &&
         metrics.decoded_track_ids.size() == track_total &&
         metrics.sender_rtcp > 0 && metrics.receiver_rtcp > 0 &&
         metrics.sender_rate_caps > 0 && metrics.downlink_dropped > 0 &&
         metrics.retransmissions > 0 && metrics.min_bad_target_bps > 0 &&
         metrics.min_bad_target_bps <= 600000 &&
         metrics.min_bad_fps <= max_bad_fps &&
         TickRate(metrics.bad_pushed_frames, metrics.bad_ticks) <=
             max_bad_send_rps &&
         metrics.max_recovery_target_bps >= 1000000 &&
         metrics.max_recovery_fps >= 25 &&
         TickRate(metrics.recovery_pushed_frames, metrics.recovery_ticks) >=
             min_recovery_send_rps;
}

inline int RunSender(uint16_t local_port,
                     const sockaddr_in& server_addr,
                     const CommonOptions& options) {
  UdpSocket udp;
  if (!udp.Bind(local_port)) {
    std::cerr << "failed to bind sender UDP port\n";
    return 2;
  }

  SampleMetrics metrics;
  const webrtc_qos::SessionConfig session =
      MakeSession("minimal_udp_sender", options.tracks);
  webrtc_qos::VideoPushClientConfig push_config;
  push_config.session = session;
  push_config.logging = MakeLogConfig(options);
  push_config.metrics = MakeMetricsConfig(options.metrics_dir);
  push_config.alerts = MakeAlertConfig(options.alerts_dir);
  push_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtp) {
          ++metrics.sender_rtp;
        } else {
          ++metrics.sender_rtcp;
        }
        return udp.SendTo(server_addr, EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "sender UDP send failed");
      };

  std::unique_ptr<webrtc_qos::VideoPushClient> push =
      webrtc_qos::CreateVideoPushClient(push_config);
  if (!push) {
    std::cerr << "failed to create sender facade\n";
    return 3;
  }
  RequireStatus(push->Start(), "sender start");

  auto pump_feedback = [&](int64_t now_us) {
    bool progressed = false;
    std::vector<uint8_t> datagram;
    sockaddr_in from {};
    while (udp.Recv(&datagram, &from)) {
      WirePacket wire;
      if (!DecodeWirePacket(datagram, &wire)) {
        continue;
      }
      if (wire.kind == WireKind::kRtcp) {
        RequireStatus(push->OnTransportFeedback(wire.payload.data(),
                                                wire.payload.size(), now_us),
                      "sender RTCP feedback");
        progressed = true;
      } else if (wire.kind == WireKind::kSenderRateCap) {
        webrtc_qos::SenderRateCap cap;
        if (DecodeSenderRateCap(wire.payload, session.ids, &cap)) {
          ++metrics.sender_rate_caps;
          RequireStatus(push->OnSenderRateCap(cap), "sender rate cap");
          progressed = true;
        }
      }
    }
    return progressed;
  };

  for (int frame = 0; frame < options.frames; ++frame) {
    const int64_t now_us = 1000000 + static_cast<int64_t>(frame) * 33333;
    RequireStatus(push->Process(now_us), "sender process");
    for (int guard = 0; guard < 32 && pump_feedback(now_us); ++guard) {
    }
    const auto adaptation = push->GetEncoderAdaptation(now_us);
    const auto snapshot = push->GetQosSnapshot(now_us);
    metrics.final_target_bps = snapshot.sender_rates.final_target_bps;
    metrics.final_fps = adaptation.max_fps;
    for (size_t track_index = 0; track_index < session.video_tracks.size();
         ++track_index) {
      const auto& track = session.video_tracks[track_index];
      webrtc_qos::EncoderAdaptation track_adaptation;
      if (!push->GetTrackEncoderAdaptation(track.ids.track_id, now_us,
                                           &track_adaptation)) {
        continue;
      }
      if (frame % FpsInterval(track_adaptation.max_fps) != 0) {
        continue;
      }
      const std::vector<uint8_t> au = MakeIdrAccessUnit(
          static_cast<uint8_t>((frame + track_index * 67) & 0xff));
      webrtc_qos::AnnexBAccessUnitView view;
      view.bytes = au.data();
      view.size = au.size();
      view.capture_time_us = now_us;
      view.keyframe = true;
      view.ids = track.ids;
      RequireStatus(push->PushAnnexBAccessUnit(view), "sender push AU");
      ++metrics.pushed_frames;
      const int64_t post_push_time_us =
          now_us + 1000 + static_cast<int64_t>(track_index) * 1000;
      RequireStatus(push->Process(post_push_time_us),
                    "sender process after AU");
      for (int guard = 0; guard < 32 && pump_feedback(post_push_time_us);
           ++guard) {
      }
    }
  }

  const int64_t final_time_us =
      1000000 + static_cast<int64_t>(options.frames) * 33333 + 1000000;
  RequireStatus(push->Process(final_time_us), "sender final process");
  for (int guard = 0; guard < 64 && pump_feedback(final_time_us); ++guard) {
  }
  push->Stop();

  std::cout << "minimal_udp_sender backend=webrtc_first_facade"
            << " transport=udp"
            << " peer_connection=false"
            << " tracks=" << session.video_tracks.size()
            << " local=" << EndpointToString(udp.local_addr())
            << " server=" << EndpointToString(server_addr)
            << " pushed=" << metrics.pushed_frames
            << " sender_rtp=" << metrics.sender_rtp
            << " sender_rtcp=" << metrics.sender_rtcp
            << " sender_rate_caps=" << metrics.sender_rate_caps
            << " final_target=" << metrics.final_target_bps
            << " final_fps=" << metrics.final_fps
            << "\n";
  return metrics.pushed_frames > 0 && metrics.sender_rtp > 0 ? 0 : 1;
}

inline int RunServer(uint16_t local_port,
                     const sockaddr_in& sender_addr,
                     const sockaddr_in& receiver_addr,
                     const CommonOptions& options) {
  UdpSocket udp;
  if (!udp.Bind(local_port)) {
    std::cerr << "failed to bind server UDP port\n";
    return 2;
  }

  SampleMetrics metrics;
  const webrtc_qos::SessionConfig session =
      MakeSession("minimal_udp_server", options.tracks);
  webrtc_qos::ServerQosRouterConfig server_config;
  server_config.session = session;
  server_config.logging = MakeLogConfig(options);
  server_config.metrics = MakeMetricsConfig(options.metrics_dir);
  server_config.alerts = MakeAlertConfig(options.alerts_dir);
  server_config.sender_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        return udp.SendTo(sender_addr, EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "server sender-output UDP send failed");
      };
  server_config.receiver_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        return udp.SendTo(receiver_addr, EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "server receiver-output UDP send failed");
      };

  std::unique_ptr<webrtc_qos::ServerQosRouter> server =
      webrtc_qos::CreateServerQosRouter(server_config);
  if (!server) {
    std::cerr << "failed to create server facade\n";
    return 3;
  }
  RequireStatus(server->Start(), "server start");

  for (int frame = 0; frame < options.frames; ++frame) {
    const int64_t now_us = 1000000 + static_cast<int64_t>(frame) * 33333;
    std::vector<uint8_t> datagram;
    sockaddr_in from {};
    while (udp.Recv(&datagram, &from)) {
      WirePacket wire;
      if (!DecodeWirePacket(datagram, &wire)) {
        continue;
      }
      if (SameAddress(from, sender_addr)) {
        if (wire.kind == WireKind::kRtp) {
          ++metrics.sender_rtp;
          RequireStatus(server->OnSenderRtp(wire.payload.data(),
                                            wire.payload.size(), now_us),
                        "server sender RTP");
        } else if (wire.kind == WireKind::kRtcp) {
          ++metrics.sender_rtcp;
          RequireStatus(server->OnSenderRtcp(wire.payload.data(),
                                             wire.payload.size(), now_us),
                        "server sender RTCP");
        }
      } else if (SameAddress(from, receiver_addr)) {
        if (wire.kind == WireKind::kRtcp) {
          ++metrics.receiver_rtcp;
          RequireStatus(server->OnReceiverRtcp(session.ids.receiver_id,
                                              wire.payload.data(),
                                              wire.payload.size(), now_us),
                        "server receiver RTCP");
        } else if (wire.kind == WireKind::kDownlinkQuality) {
          webrtc_qos::DownlinkQuality quality;
          if (DecodeDownlinkQuality(wire.payload, session.ids, &quality)) {
            RequireStatus(server->OnDownlinkQuality(quality),
                          "server downlink quality");
            const auto cap = server->CurrentSenderRateCap(now_us);
            if (!SendSenderRateCap(&udp, sender_addr, cap, now_us)) {
              std::cerr << "server sender cap UDP send failed\n";
              return 4;
            }
            ++metrics.sender_rate_caps;
          }
        }
      }
    }
  }
  const auto snapshot =
      server->GetQosSnapshot(1000000 +
                             static_cast<int64_t>(options.frames) * 33333);
  server->Stop();
  std::cout << "minimal_udp_server backend=webrtc_first_facade"
            << " transport=udp"
            << " peer_connection=false"
            << " tracks=" << session.video_tracks.size()
            << " local=" << EndpointToString(udp.local_addr())
            << " sender=" << EndpointToString(sender_addr)
            << " receiver=" << EndpointToString(receiver_addr)
            << " sender_rtp=" << metrics.sender_rtp
            << " sender_rtcp=" << metrics.sender_rtcp
            << " receiver_rtcp=" << metrics.receiver_rtcp
            << " sender_rate_caps=" << metrics.sender_rate_caps
            << " retransmission=" << snapshot.retransmission_count
            << "\n";
  return 0;
}

inline int RunReceiver(uint16_t local_port,
                       const sockaddr_in& server_addr,
                       const CommonOptions& options) {
  UdpSocket udp;
  if (!udp.Bind(local_port)) {
    std::cerr << "failed to bind receiver UDP port\n";
    return 2;
  }

  SampleMetrics metrics;
  const webrtc_qos::SessionConfig session =
      MakeSession("minimal_udp_receiver", options.tracks);
  webrtc_qos::VideoPlayClientConfig play_config;
  play_config.session = session;
  play_config.logging = MakeLogConfig(options);
  play_config.metrics = MakeMetricsConfig(options.metrics_dir);
  play_config.alerts = MakeAlertConfig(options.alerts_dir);
  play_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        ++metrics.receiver_rtcp;
        return udp.SendTo(server_addr, EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "receiver UDP send failed");
      };
  play_config.decoded_access_unit_output =
      [&](const webrtc_qos::AnnexBAccessUnitView& access_unit) {
        if (access_unit.bytes == nullptr || access_unit.size == 0) {
          return webrtc_qos::Status::Error(
              webrtc_qos::StatusCode::kInternalError, "empty decoded AU");
        }
        ++metrics.decoded_frames;
        metrics.decoded_track_ids.insert(access_unit.ids.track_id);
        return webrtc_qos::Status::Ok();
      };

  std::unique_ptr<webrtc_qos::VideoPlayClient> play =
      webrtc_qos::CreateVideoPlayClient(play_config);
  if (!play) {
    std::cerr << "failed to create receiver facade\n";
    return 3;
  }
  RequireStatus(play->Start(), "receiver start");

  for (int frame = 0; frame < options.frames; ++frame) {
    const int64_t now_us = 1000000 + static_cast<int64_t>(frame) * 33333;
    webrtc_qos::DownlinkQuality quality;
    quality.ids = session.ids;
    quality.report_seq = static_cast<uint32_t>(frame + 1);
    quality.report_time_us = static_cast<uint64_t>(now_us);
    if (InBadWindow(frame, options.frames)) {
      quality.fraction_lost_q8 = 192;
      quality.video_drop_frames = 1;
      quality.recv_bitrate_bps = session.min_bitrate_bps;
    }
    if (!SendDownlinkQuality(&udp, server_addr, quality, now_us)) {
      std::cerr << "receiver downlink quality UDP send failed\n";
      return 4;
    }

    std::vector<uint8_t> datagram;
    sockaddr_in from {};
    while (udp.Recv(&datagram, &from)) {
      WirePacket wire;
      if (!DecodeWirePacket(datagram, &wire)) {
        continue;
      }
      if (wire.kind == WireKind::kRtcp) {
        RequireStatus(play->OnRtcpPacket(wire.payload.data(),
                                         wire.payload.size(), now_us),
                      "receiver RTCP");
      } else if (wire.kind == WireKind::kRtp) {
        const bool retransmission = (wire.flags & kRetransmissionFlag) != 0;
        if (InBadWindow(frame, options.frames) && !retransmission) {
          ++metrics.downlink_dropped;
          continue;
        }
        if (retransmission) {
          ++metrics.retransmissions;
        }
        RequireStatus(play->OnRtpPacket(wire.payload.data(),
                                        wire.payload.size(), now_us),
                      "receiver RTP");
      }
    }
    RequireStatus(play->Process(now_us), "receiver process");
  }
  play->Stop();
  std::cout << "minimal_udp_receiver backend=webrtc_first_facade"
            << " transport=udp"
            << " peer_connection=false"
            << " tracks=" << session.video_tracks.size()
            << " local=" << EndpointToString(udp.local_addr())
            << " server=" << EndpointToString(server_addr)
            << " decoded=" << metrics.decoded_frames
            << " decoded_tracks=" << metrics.decoded_track_ids.size()
            << " receiver_rtcp=" << metrics.receiver_rtcp
            << " dropped=" << metrics.downlink_dropped
            << " retransmission=" << metrics.retransmissions
            << "\n";
  return 0;
}

inline int RunSelftest(const CommonOptions& options) {
  UdpSocket sender_udp;
  UdpSocket server_udp;
  UdpSocket receiver_udp;
  if (!sender_udp.Bind(0) || !server_udp.Bind(0) || !receiver_udp.Bind(0)) {
    std::cerr << "failed to bind UDP loopback sockets\n";
    return 2;
  }

  SampleMetrics metrics;
  const webrtc_qos::SessionConfig session =
      MakeSession("minimal_udp_selftest", options.tracks);

  webrtc_qos::VideoPushClientConfig push_config;
  push_config.session = session;
  push_config.logging = MakeLogConfig(options);
  push_config.metrics = MakeMetricsConfig(options.metrics_dir);
  push_config.alerts = MakeAlertConfig(options.alerts_dir);
  push_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtp) {
          ++metrics.sender_rtp;
        } else {
          ++metrics.sender_rtcp;
        }
        return sender_udp.SendTo(server_udp.local_addr(),
                                 EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "sender UDP send failed");
      };

  webrtc_qos::VideoPlayClientConfig play_config;
  play_config.session = session;
  play_config.logging = MakeLogConfig(options);
  play_config.metrics = MakeMetricsConfig(options.metrics_dir);
  play_config.alerts = MakeAlertConfig(options.alerts_dir);
  play_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        ++metrics.receiver_rtcp;
        return receiver_udp.SendTo(server_udp.local_addr(),
                                   EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "receiver UDP send failed");
      };
  play_config.decoded_access_unit_output =
      [&](const webrtc_qos::AnnexBAccessUnitView& access_unit) {
        if (access_unit.bytes == nullptr || access_unit.size == 0) {
          return webrtc_qos::Status::Error(
              webrtc_qos::StatusCode::kInternalError, "empty decoded AU");
        }
        ++metrics.decoded_frames;
        metrics.decoded_track_ids.insert(access_unit.ids.track_id);
        return webrtc_qos::Status::Ok();
      };

  webrtc_qos::ServerQosRouterConfig server_config;
  server_config.session = session;
  server_config.logging = MakeLogConfig(options);
  server_config.metrics = MakeMetricsConfig(options.metrics_dir);
  server_config.alerts = MakeAlertConfig(options.alerts_dir);
  server_config.sender_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        return server_udp.SendTo(sender_udp.local_addr(),
                                 EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "server sender-output UDP send failed");
      };
  server_config.receiver_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        return server_udp.SendTo(receiver_udp.local_addr(),
                                 EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "server receiver-output UDP send failed");
      };

  std::unique_ptr<webrtc_qos::VideoPushClient> push =
      webrtc_qos::CreateVideoPushClient(push_config);
  std::unique_ptr<webrtc_qos::VideoPlayClient> play =
      webrtc_qos::CreateVideoPlayClient(play_config);
  std::unique_ptr<webrtc_qos::ServerQosRouter> server =
      webrtc_qos::CreateServerQosRouter(server_config);
  if (!push || !play || !server) {
    std::cerr << "failed to create role facades\n";
    return 3;
  }
  RequireStatus(push->Start(), "push start");
  RequireStatus(play->Start(), "play start");
  RequireStatus(server->Start(), "server start");

  auto pump_sender = [&](int64_t now_us) {
    bool progressed = false;
    std::vector<uint8_t> datagram;
    sockaddr_in from {};
    while (sender_udp.Recv(&datagram, &from)) {
      WirePacket wire;
      if (!DecodeWirePacket(datagram, &wire)) {
        continue;
      }
      if (wire.kind == WireKind::kRtcp) {
        RequireStatus(push->OnTransportFeedback(wire.payload.data(),
                                                wire.payload.size(), now_us),
                      "push UDP RTCP feedback");
        progressed = true;
      } else if (wire.kind == WireKind::kSenderRateCap) {
        webrtc_qos::SenderRateCap cap;
        if (DecodeSenderRateCap(wire.payload, session.ids, &cap)) {
          ++metrics.sender_rate_caps;
          RequireStatus(push->OnSenderRateCap(cap), "push UDP sender cap");
          progressed = true;
        }
      }
    }
    return progressed;
  };

  auto pump_receiver = [&](int frame, int64_t now_us) {
    bool progressed = false;
    std::vector<uint8_t> datagram;
    sockaddr_in from {};
    while (receiver_udp.Recv(&datagram, &from)) {
      WirePacket wire;
      if (!DecodeWirePacket(datagram, &wire)) {
        continue;
      }
      if (wire.kind == WireKind::kRtcp) {
        RequireStatus(play->OnRtcpPacket(wire.payload.data(),
                                         wire.payload.size(), now_us),
                      "play UDP RTCP");
        progressed = true;
      } else if (wire.kind == WireKind::kRtp) {
        const bool retransmission = (wire.flags & kRetransmissionFlag) != 0;
        if (InBadWindow(frame, options.frames) && !retransmission) {
          ++metrics.downlink_dropped;
          progressed = true;
          continue;
        }
        if (retransmission) {
          ++metrics.retransmissions;
        }
        RequireStatus(play->OnRtpPacket(wire.payload.data(),
                                        wire.payload.size(), now_us),
                      "play UDP RTP");
        progressed = true;
      }
    }
    return progressed;
  };

  auto pump_server = [&](int64_t now_us) {
    bool progressed = false;
    std::vector<uint8_t> datagram;
    sockaddr_in from {};
    while (server_udp.Recv(&datagram, &from)) {
      WirePacket wire;
      if (!DecodeWirePacket(datagram, &wire)) {
        continue;
      }
      if (SameAddress(from, sender_udp.local_addr())) {
        if (wire.kind == WireKind::kRtp) {
          RequireStatus(server->OnSenderRtp(wire.payload.data(),
                                            wire.payload.size(), now_us),
                        "server UDP sender RTP");
          progressed = true;
        } else if (wire.kind == WireKind::kRtcp) {
          RequireStatus(server->OnSenderRtcp(wire.payload.data(),
                                             wire.payload.size(), now_us),
                        "server UDP sender RTCP");
          progressed = true;
        }
      } else if (SameAddress(from, receiver_udp.local_addr())) {
        if (wire.kind == WireKind::kRtcp) {
          RequireStatus(server->OnReceiverRtcp(session.ids.receiver_id,
                                              wire.payload.data(),
                                              wire.payload.size(), now_us),
                        "server UDP receiver RTCP");
          progressed = true;
        } else if (wire.kind == WireKind::kDownlinkQuality) {
          webrtc_qos::DownlinkQuality quality;
          if (DecodeDownlinkQuality(wire.payload, session.ids, &quality)) {
            RequireStatus(server->OnDownlinkQuality(quality),
                          "server UDP downlink quality");
            RequireStatus(push->OnSenderRateCap(
                              server->CurrentSenderRateCap(now_us)),
                          "local cap mirror");
            if (!SendSenderRateCap(&server_udp, sender_udp.local_addr(),
                                   server->CurrentSenderRateCap(now_us),
                                   now_us)) {
              std::cerr << "server UDP sender cap send failed\n";
              std::exit(4);
            }
            progressed = true;
          }
        }
      }
    }
    return progressed;
  };

  auto pump_all = [&](int frame, int64_t now_us) {
    int idle_polls = 0;
    for (int guard = 0; guard < 128; ++guard) {
      const bool server_progressed = pump_server(now_us);
      const bool sender_progressed = pump_sender(now_us);
      const bool receiver_progressed = pump_receiver(frame, now_us);
      const bool progressed =
          server_progressed || sender_progressed || receiver_progressed;
      if (!progressed) {
        if (++idle_polls <= 4) {
          const timespec wait_time {0, 1000000};
          nanosleep(&wait_time, nullptr);
          continue;
        }
        break;
      }
      idle_polls = 0;
    }
    RequireStatus(play->Process(now_us), "play UDP process");
  };

  for (int frame = 0; frame < options.frames; ++frame) {
    const int64_t now_us = 1000000 + static_cast<int64_t>(frame) * 33333;
    RequireStatus(push->Process(now_us), "push process");
    pump_all(frame, now_us);

    webrtc_qos::DownlinkQuality quality;
    quality.ids = session.ids;
    quality.report_seq = static_cast<uint32_t>(frame + 1);
    quality.report_time_us = static_cast<uint64_t>(now_us);
    if (InBadWindow(frame, options.frames)) {
      quality.fraction_lost_q8 = 192;
      quality.video_drop_frames = 1;
      quality.recv_bitrate_bps = session.min_bitrate_bps;
    }
    if (!SendDownlinkQuality(&receiver_udp, server_udp.local_addr(), quality,
                             now_us)) {
      std::cerr << "receiver UDP downlink quality send failed\n";
      return 4;
    }
    pump_all(frame, now_us);

    const auto adaptation = push->GetEncoderAdaptation(now_us);
    const auto snapshot = push->GetQosSnapshot(now_us);
    metrics.final_target_bps = snapshot.sender_rates.final_target_bps;
    metrics.final_fps = adaptation.max_fps;
    if (InBadWindow(frame, options.frames)) {
      ++metrics.bad_ticks;
      metrics.min_bad_target_bps =
          std::min(metrics.min_bad_target_bps,
                   snapshot.sender_rates.final_target_bps);
      metrics.min_bad_fps = std::min(metrics.min_bad_fps, adaptation.max_fps);
    }
    if (InRecoveryWindow(frame, options.frames)) {
      ++metrics.recovery_ticks;
      metrics.max_recovery_target_bps =
          std::max(metrics.max_recovery_target_bps,
                   snapshot.sender_rates.final_target_bps);
      metrics.max_recovery_fps =
          std::max(metrics.max_recovery_fps, adaptation.max_fps);
    }
    for (size_t track_index = 0; track_index < session.video_tracks.size();
         ++track_index) {
      const auto& track = session.video_tracks[track_index];
      webrtc_qos::EncoderAdaptation track_adaptation;
      if (!push->GetTrackEncoderAdaptation(track.ids.track_id, now_us,
                                           &track_adaptation)) {
        continue;
      }
      if (frame % FpsInterval(track_adaptation.max_fps) != 0) {
        continue;
      }
      if (InBadWindow(frame, options.frames)) {
        ++metrics.bad_pushed_frames;
      }
      if (InRecoveryWindow(frame, options.frames)) {
        ++metrics.recovery_pushed_frames;
      }
      const std::vector<uint8_t> au = MakeIdrAccessUnit(
          static_cast<uint8_t>((frame + track_index * 67) & 0xff));
      webrtc_qos::AnnexBAccessUnitView view;
      view.bytes = au.data();
      view.size = au.size();
      view.capture_time_us = now_us;
      view.keyframe = true;
      view.ids = track.ids;
      RequireStatus(push->PushAnnexBAccessUnit(view), "push UDP AU");
      ++metrics.pushed_frames;
      const int64_t post_push_time_us =
          now_us + 1000 + static_cast<int64_t>(track_index) * 1000;
      RequireStatus(push->Process(post_push_time_us), "push process after AU");
      pump_all(frame, post_push_time_us + 1000);
    }
  }

  const int64_t final_time_us =
      1000000 + static_cast<int64_t>(options.frames) * 33333 + 1000000;
  RequireStatus(push->OnSenderRateCap(server->CurrentSenderRateCap(final_time_us)),
                "final push UDP sender cap");
  RequireStatus(push->Process(final_time_us), "final push process");
  pump_all(options.frames, final_time_us);
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

  push->Stop();
  play->Stop();
  server->Stop();

  const double playable_ratio =
      metrics.pushed_frames == 0
          ? 0.0
          : static_cast<double>(metrics.decoded_frames) /
                metrics.pushed_frames;
  const bool pass = CheckSelftestMetrics(metrics, session.video_tracks.size());
  std::cout << "minimal_udp_selftest"
            << " backend=webrtc_first_facade"
            << " transport=udp"
            << " peer_connection=false"
            << " tracks=" << session.video_tracks.size()
            << " sender_port=" << sender_udp.port()
            << " server_port=" << server_udp.port()
            << " receiver_port=" << receiver_udp.port()
            << " pushed=" << metrics.pushed_frames
            << " decoded=" << metrics.decoded_frames
            << " decoded_tracks=" << metrics.decoded_track_ids.size()
            << " playable_ratio=" << playable_ratio
            << " sender_rtp=" << metrics.sender_rtp
            << " sender_rtcp=" << metrics.sender_rtcp
            << " receiver_rtcp=" << metrics.receiver_rtcp
            << " dropped=" << metrics.downlink_dropped
            << " retransmission=" << metrics.retransmissions
            << " sender_rate_caps=" << metrics.sender_rate_caps
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
            << " pass=" << (pass ? "true" : "false")
            << "\n";
  return pass ? 0 : 1;
}

}  // namespace minimal_udp
