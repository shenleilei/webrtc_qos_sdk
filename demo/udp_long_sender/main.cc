#include <cstdlib>
#include <algorithm>
#include <iostream>
#include <limits>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "demo/qoe_common.h"
#include "demo/udp_common.h"
#include "webrtc_qos/ffmpeg_h264_encoder.h"
#include "webrtc_qos/retransmission_cache.h"
#include "webrtc_qos/rtcp_packets.h"
#include "webrtc_qos/rtp_packet.h"
#include "webrtc_qos/sender_pacer.h"
#include "webrtc_qos/sender_qos_controller.h"
#include "webrtc_qos/transport_feedback.h"
#include "webrtc_qos/video_sender.h"

namespace {

void Usage(const char* argv0) {
  std::cerr << "usage: " << argv0
            << " <local_port> <server_ip> <server_port>"
            << " [--frames=N] [--width=N] [--height=N]"
            << " [--bitrate=N] [--content=motion|low_motion|detail_motion]\n";
}

bool ParseUint32Arg(const std::string& arg,
                    const std::string& prefix,
                    uint32_t* value) {
  if (arg.rfind(prefix, 0) != 0 || !value) {
    return false;
  }
  *value = static_cast<uint32_t>(std::strtoul(arg.c_str() + prefix.size(),
                                             nullptr, 10));
  return true;
}

bool ShouldApplyEncoderRates(uint32_t target_bitrate_bps,
                             uint32_t target_fps,
                             uint32_t applied_bitrate_bps,
                             uint32_t applied_fps) {
  if (target_fps != applied_fps) {
    return true;
  }
  const uint32_t diff =
      target_bitrate_bps > applied_bitrate_bps
          ? target_bitrate_bps - applied_bitrate_bps
          : applied_bitrate_bps - target_bitrate_bps;
  return diff >= std::max<uint32_t>(30000, applied_bitrate_bps / 10);
}

uint64_t DemoNtpFromUs(int64_t time_us) {
  const uint64_t seconds = static_cast<uint64_t>(time_us / 1000000);
  const uint64_t fraction =
      (static_cast<uint64_t>(time_us % 1000000) << 32) / 1000000;
  return (seconds << 32) | fraction;
}

uint32_t CompactNtp(uint64_t ntp_timestamp) {
  return static_cast<uint32_t>((ntp_timestamp >> 16) & 0xffffffffu);
}

constexpr uint32_t kHealthyPeriodicKeyframeBps = 800000;
constexpr uint32_t kPeriodicKeyframeSourceFrames = 90;
constexpr int64_t kNormalKeyframeIntervalUs = 2000000;
constexpr int64_t kPacerRecoveryKeyframeIntervalUs = 750000;

}  // namespace

int main(int argc, char** argv) {
  using namespace webrtc_qos;
  using namespace webrtc_qos::demo;

  if (argc < 4) {
    Usage(argv[0]);
    return 2;
  }

  const uint16_t local_port = static_cast<uint16_t>(std::atoi(argv[1]));
  const std::string server_ip = argv[2];
  const uint16_t server_port = static_cast<uint16_t>(std::atoi(argv[3]));
  uint32_t frame_count = 90;
  uint32_t width = 320;
  uint32_t height = 180;
  uint32_t bitrate_bps = 1200000;
  std::string content = "motion";
  for (int i = 4; i < argc; ++i) {
    const std::string arg = argv[i];
    if (ParseUint32Arg(arg, "--frames=", &frame_count) ||
        ParseUint32Arg(arg, "--width=", &width) ||
        ParseUint32Arg(arg, "--height=", &height) ||
        ParseUint32Arg(arg, "--bitrate=", &bitrate_bps)) {
      continue;
    }
    const std::string content_prefix = "--content=";
    if (arg.rfind(content_prefix, 0) == 0) {
      content = arg.substr(content_prefix.size());
      continue;
    }
    Usage(argv[0]);
    return 2;
  }
  if (width == 0 || height == 0 || width % 2 != 0 || height % 2 != 0 ||
      frame_count == 0 || bitrate_bps == 0) {
    Usage(argv[0]);
    return 2;
  }

  const int fd = CreateUdpSocket(local_port);
  const sockaddr_in server = MakeIpv4Address(server_ip, server_port);
  const TransportIds ids = DemoTransportIds();

  SenderQosControllerConfig qos_config;
  qos_config.ids = ids;
  qos_config.start_bitrate_bps = bitrate_bps;
  qos_config.min_bitrate_bps = 80000;
  qos_config.max_bitrate_bps = std::max<uint32_t>(bitrate_bps, 2500000);
  SenderQosController qos(qos_config);

  uint64_t sent_packets = 0;
  uint64_t sent_bytes = 0;
  uint64_t encoded_frames = 0;
  uint64_t twcc_feedback = 0;
  uint64_t rr_feedback = 0;
  uint64_t rate_caps = 0;
  uint64_t nack_feedback = 0;
  uint64_t retransmitted_packets = 0;
  uint64_t enqueue_dropped_aus = 0;
  uint64_t source_frame_skips = 0;
  uint64_t encoder_reconfigs = 0;
  uint64_t forced_keyframes = 0;
  int64_t last_encoded_capture_time_us = -1;
  int64_t max_encode_gap_ms = 0;
  uint32_t adapt_target_min = std::numeric_limits<uint32_t>::max();
  uint32_t adapt_target_max = 0;
  uint32_t adapt_target_last = bitrate_bps;
  uint32_t adapt_fps_min = std::numeric_limits<uint32_t>::max();
  uint32_t adapt_fps_max = 0;
  uint32_t adapt_fps_last = 30;
  uint32_t applied_bitrate_bps = bitrate_bps;
  uint32_t applied_fps = 30;
  bool force_keyframe_next = true;
  int64_t last_keyframe_encode_us = -10000000;
  int64_t route_recovery_until_us = 0;
  uint32_t route_recovery_bps = 0;
  std::unordered_map<uint16_t, PacketFeedback> sent_packet_feedback;
  RetransmissionCache retransmission_cache;
  uint16_t retransmission_transport_sequence_number = 50000;
  int64_t pacer_time_us = 0;
  SenderPacer pacer(
      SenderPacerConfig{bitrate_bps, kPacerTickMs, kPacerMaxQueueMs,
                        kPacerMaxQueueBytes, 1400, false},
      [&](const RtpPacket& packet) {
        const std::vector<uint8_t> encoded = SerializeRtpPacket(packet);
        if (!SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kRtp, ids),
                          encoded)) {
          return Status::Error(StatusCode::kInternalError,
                               "send RTP envelope failed");
        }
        ++sent_packets;
        sent_bytes += encoded.size();
        retransmission_cache.Store(packet, pacer_time_us);
        retransmission_cache.Prune(pacer_time_us, qos.GetTargetRates(pacer_time_us).rtt_ms);
        sent_packet_feedback[packet.transport_sequence_number] =
            PacketFeedback{packet.transport_sequence_number, pacer_time_us, -1,
                           packet.payload.size() + 20};
        Status status = qos.OnPacketSent(packet.transport_sequence_number,
                                         packet.payload.size() + 20,
                                         pacer_time_us);
        if (!status) {
          return status;
        }
        return Status::Ok();
      });
  VideoSender sender(VideoSenderConfig{ids}, &pacer);

  FfmpegH264Encoder encoder;
  FfmpegH264EncoderConfig config;
  config.width = width;
  config.height = height;
  config.fps = 30;
  config.bitrate_bps = bitrate_bps;
  config.gop_size = kPeriodicKeyframeSourceFrames;
  Status status = encoder.Open(config);
  if (!status) {
    std::cerr << "udp_long_sender: encoder open failed: " << status.message
              << "\n";
    return 1;
  }

  std::vector<uint8_t> y;
  std::vector<uint8_t> u;
  std::vector<uint8_t> v;
  std::vector<uint8_t> annexb;
  uint64_t last_sr_ntp = 0;
  uint32_t last_sr_lsr = 0;
  const auto request_keyframe = [&](int64_t min_interval_us) {
    if (pacer_time_us - last_keyframe_encode_us >= min_interval_us) {
      force_keyframe_next = true;
    }
  };
  const auto apply_adaptation = [&]() -> Status {
    const TargetRates rates = qos.GetTargetRates(pacer_time_us);
    const bool in_route_recovery =
        route_recovery_until_us > 0 && pacer_time_us < route_recovery_until_us;
    const uint32_t effective_pacing_bps =
        in_route_recovery ? std::max(route_recovery_bps, rates.pacing_bps)
                          : rates.pacing_bps;
    pacer.SetTargetBitrate(effective_pacing_bps);
    EncoderAdaptation adaptation = qos.GetEncoderAdaptation(pacer_time_us);
    if (in_route_recovery) {
      adaptation.target_bitrate_bps =
          std::max(route_recovery_bps, adaptation.target_bitrate_bps);
      adaptation.max_fps = 30;
    }
    adaptation.target_bitrate_bps =
        std::max<uint32_t>(qos_config.min_bitrate_bps,
                           adaptation.target_bitrate_bps);
    adaptation.max_fps =
        std::max<uint32_t>(1, std::min<uint32_t>(30, adaptation.max_fps));
    adapt_target_min = std::min(adapt_target_min,
                                adaptation.target_bitrate_bps);
    adapt_target_max = std::max(adapt_target_max,
                                adaptation.target_bitrate_bps);
    adapt_target_last = adaptation.target_bitrate_bps;
    adapt_fps_min = std::min(adapt_fps_min, adaptation.max_fps);
    adapt_fps_max = std::max(adapt_fps_max, adaptation.max_fps);
    adapt_fps_last = adaptation.max_fps;
    if (!ShouldApplyEncoderRates(adaptation.target_bitrate_bps,
                                 adaptation.max_fps, applied_bitrate_bps,
                                 applied_fps)) {
      if (adaptation.request_keyframe) {
        request_keyframe(kNormalKeyframeIntervalUs);
      }
      return Status::Ok();
    }
    const bool bitrate_increased =
        adaptation.target_bitrate_bps > applied_bitrate_bps;
    applied_bitrate_bps = adaptation.target_bitrate_bps;
    applied_fps = adaptation.max_fps;
    Status status = encoder.SetRates(applied_bitrate_bps, applied_fps);
    if (!status) {
      return status;
    }
    ++encoder_reconfigs;
    if (bitrate_increased) {
      request_keyframe(kPacerRecoveryKeyframeIntervalUs);
    } else if (adaptation.request_keyframe) {
      request_keyframe(kNormalKeyframeIntervalUs);
    }
    return Status::Ok();
  };

  const auto poll_control = [&](int timeout_ms) -> Status {
    DemoEnvelopeHeader header;
    std::vector<uint8_t> payload;
    sockaddr_in from{};
    if (!ReceiveEnvelope(fd, timeout_ms, &header, &payload, &from)) {
      return Status::Ok();
    }
    if (header.session_id != ids.session_id ||
        header.stream_id != ids.stream_id) {
      return Status::Ok();
    }
    if (header.type == EnvelopeType::kUplinkTwcc) {
      UplinkTransportFeedback feedback;
      Status status =
          ParseRtcpTransportFeedback(payload.data(), payload.size(), &feedback);
      if (!status) {
        return status;
      }
      feedback.ids.session_id = ids.session_id;
      feedback.ids.stream_id = ids.stream_id;
      feedback.ids.transport_id = ids.transport_id;
      for (auto& packet : feedback.packets) {
        const auto it =
            sent_packet_feedback.find(packet.transport_sequence_number);
        if (it == sent_packet_feedback.end()) {
          continue;
        }
        packet.send_time_us = it->second.send_time_us;
        packet.packet_size = it->second.packet_size;
      }
      status = qos.OnUplinkTransportFeedback(feedback);
      if (!status) {
        return status;
      }
      ++twcc_feedback;
    } else if (header.type == EnvelopeType::kRtcpRr) {
      RtcpReceiverReport rr;
      Status status = ParseRtcpReceiverReport(payload.data(), payload.size(), &rr);
      if (!status) {
        return status;
      }
      if (rr.last_sender_report == last_sr_lsr && last_sr_lsr != 0) {
        rr.rtt_ms = 24;
      }
      rr.receive_time_us = NowUs();
      status = qos.OnRtcpReceiverReport(rr);
      if (!status) {
        return status;
      }
      ++rr_feedback;
    } else if (header.type == EnvelopeType::kSenderRateCap) {
      SenderRateCap cap;
      Status status = ParseSenderRateCap(payload.data(), payload.size(), &cap);
      if (!status) {
        return status;
      }
      cap.receive_time_us = pacer_time_us;
      status = qos.OnSenderRateCap(cap);
      if (!status) {
        return status;
      }
      if (cap.cap_bps == kUnlimitedRateCapBps) {
        route_recovery_bps = std::max<uint32_t>(bitrate_bps, 2500000);
        route_recovery_until_us = pacer_time_us + 2500000;
        request_keyframe(kPacerRecoveryKeyframeIntervalUs);
        status = qos.OnNetworkRouteChange(route_recovery_bps, pacer_time_us);
        if (!status) {
          return status;
        }
      }
      ++rate_caps;
    } else if (header.type == EnvelopeType::kNack) {
      RtcpNack nack;
      Status status = ParseRtcpNack(payload.data(), payload.size(), &nack);
      if (!status) {
        return status;
      }
      for (uint16_t seq : nack.lost_rtp_sequence_numbers) {
        std::optional<RtpPacket> packet =
            retransmission_cache.Find(seq, retransmission_transport_sequence_number++);
        if (!packet) {
          continue;
        }
        status = pacer.Enqueue(
            SendPacket{*packet, VideoFrameType::kUnknown, true, 0});
        if (!status) {
          return status;
        }
        ++retransmitted_packets;
      }
      ++nack_feedback;
    }
    return apply_adaptation();
  };

  uint32_t next_encode_source_index = 0;
  for (uint32_t i = 0; i < frame_count; ++i) {
    const int64_t capture_time_us =
        static_cast<int64_t>(i) * 1000000 / 30;
    status = apply_adaptation();
    if (!status) {
      std::cerr << "udp_long_sender: apply adaptation failed: "
                << status.message << "\n";
      return 1;
    }
    if (i >= next_encode_source_index) {
      FillI420Frame(width, height, content, static_cast<int>(i), &y, &u, &v);
      const TargetRates current_rates = qos.GetTargetRates(pacer_time_us);
      const bool healthy_periodic_keyframe =
          i > 0 && i % kPeriodicKeyframeSourceFrames == 0 &&
          current_rates.final_target_bps >= kHealthyPeriodicKeyframeBps &&
          applied_bitrate_bps >= kHealthyPeriodicKeyframeBps &&
          pacer_time_us - last_keyframe_encode_us >= kNormalKeyframeIntervalUs;
      const bool pacer_recovery_keyframe =
          pacer.GetStats().waiting_for_idr &&
          pacer_time_us - last_keyframe_encode_us >=
              kPacerRecoveryKeyframeIntervalUs;
      const bool keyframe_requested = encoded_frames == 0 || force_keyframe_next ||
                                      healthy_periodic_keyframe ||
                                      pacer_recovery_keyframe;
      const bool interval_ok =
          encoded_frames == 0 ||
          pacer_time_us - last_keyframe_encode_us >=
              (pacer_recovery_keyframe ? kPacerRecoveryKeyframeIntervalUs
                                       : kNormalKeyframeIntervalUs);
      const bool force_keyframe = keyframe_requested && interval_ok;
      status = encoder.EncodeI420(y.data(), width, u.data(), width / 2, v.data(),
                                  width / 2, force_keyframe, &annexb);
      if (!status) {
        std::cerr << "udp_long_sender: encode failed: " << status.message
                  << "\n";
        return 1;
      }
      if (force_keyframe) {
        force_keyframe_next = false;
        last_keyframe_encode_us = pacer_time_us;
        ++forced_keyframes;
      }
      if (last_encoded_capture_time_us >= 0) {
        max_encode_gap_ms =
            std::max<int64_t>(max_encode_gap_ms,
                              (capture_time_us - last_encoded_capture_time_us) /
                                  1000);
      }
      last_encoded_capture_time_us = capture_time_us;
      status = sender.SendAnnexBAccessUnit(annexb.data(), annexb.size(),
                                           capture_time_us);
      if (!status && status.code == StatusCode::kQueueFull) {
        ++enqueue_dropped_aus;
      }
      if (!status && status.code != StatusCode::kQueueFull) {
        std::cerr << "udp_long_sender: send AU failed: " << status.message
                  << "\n";
        return 1;
      }
      ++encoded_frames;
      const uint32_t source_frames_per_encode =
          std::max<uint32_t>(1, (30 + applied_fps - 1) / applied_fps);
      if (source_frames_per_encode > 1) {
        source_frame_skips += source_frames_per_encode - 1;
      }
      next_encode_source_index = i + source_frames_per_encode;
    }
    if (i == 0 || i % 30 == 0) {
      last_sr_ntp = DemoNtpFromUs(pacer_time_us);
      last_sr_lsr = CompactNtp(last_sr_ntp);
      RtcpSenderReport sr;
      sr.sender_ssrc = ids.sender_ssrc;
      sr.ntp_timestamp = last_sr_ntp;
      sr.rtp_timestamp = 90000 + static_cast<uint32_t>(
                                     (capture_time_us * kVideoClockRateHz) /
                                     1000000);
      sr.packet_count = static_cast<uint32_t>(sent_packets);
      sr.octet_count = static_cast<uint32_t>(sent_bytes);
      SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kRtcpSr, ids),
                   SerializeRtcpSenderReport(sr));
    }
    for (int tick = 0; tick < 7; ++tick) {
      pacer_time_us += 5000;
      status = qos.OnProcessInterval(pacer_time_us);
      if (!status) {
        std::cerr << "udp_long_sender: qos process failed: " << status.message
                  << "\n";
        return 1;
      }
      status = apply_adaptation();
      if (!status) {
        std::cerr << "udp_long_sender: tick adaptation failed: "
                  << status.message << "\n";
        return 1;
      }
      status = pacer.Tick(pacer_time_us);
      if (!status) {
        std::cerr << "udp_long_sender: pacer failed: " << status.message << "\n";
        return 1;
      }
      status = poll_control(0);
      if (!status) {
        std::cerr << "udp_long_sender: control failed: " << status.message
                  << "\n";
        return 1;
      }
      usleep(1000);
    }
  }
  for (int tick = 0; tick < 200; ++tick) {
    pacer_time_us += 5000;
    status = qos.OnProcessInterval(pacer_time_us);
    if (!status) {
      std::cerr << "udp_long_sender: flush qos failed: " << status.message
                << "\n";
      return 1;
    }
    status = apply_adaptation();
    if (!status) {
      std::cerr << "udp_long_sender: flush adaptation failed: "
                << status.message << "\n";
      return 1;
    }
    status = pacer.Tick(pacer_time_us);
    if (!status) {
      std::cerr << "udp_long_sender: flush pacer failed: " << status.message
                << "\n";
      return 1;
    }
    status = poll_control(0);
    if (!status) {
      std::cerr << "udp_long_sender: flush control failed: " << status.message
                << "\n";
      return 1;
    }
    usleep(1000);
  }
  for (int i = 0; i < 20; ++i) {
    status = poll_control(10);
    if (!status) {
      std::cerr << "udp_long_sender: final control failed: " << status.message
                << "\n";
      return 1;
    }
  }
  SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kBye, ids), {});
  const TargetRates rates = qos.GetTargetRates(pacer_time_us);
  if (adapt_target_min == std::numeric_limits<uint32_t>::max()) {
    adapt_target_min = adapt_target_last;
  }
  if (adapt_fps_min == std::numeric_limits<uint32_t>::max()) {
    adapt_fps_min = adapt_fps_last;
  }
  std::cout << "udp_long_sender frames=" << frame_count
            << " encoded_frames=" << encoded_frames
            << " sent_packets=" << sent_packets
            << " sent_bytes=" << sent_bytes
            << " pacer_drops=" << pacer.GetStats().dropped_packets
            << " pacer_drop_aus=" << pacer.GetStats().dropped_access_units
            << " forced_keyframes=" << forced_keyframes
            << " twcc_feedback=" << twcc_feedback
            << " rr=" << rr_feedback
            << " rate_caps=" << rate_caps
            << " final_target_bps=" << rates.final_target_bps
            << " pacing_bps=" << rates.pacing_bps
            << " rtt_ms=" << rates.rtt_ms
            << " adapt_target_min=" << adapt_target_min
            << " adapt_target_max=" << adapt_target_max
            << " adapt_target_last=" << adapt_target_last
            << " adapt_fps_min=" << adapt_fps_min
            << " adapt_fps_max=" << adapt_fps_max
            << " adapt_fps_last=" << adapt_fps_last
            << " encoder_reconfigs=" << encoder_reconfigs
            << " applied_bitrate_bps=" << applied_bitrate_bps
            << " applied_fps=" << applied_fps
            << " nack_feedback=" << nack_feedback
            << " retransmitted=" << retransmitted_packets
            << " max_encode_gap_ms=" << max_encode_gap_ms
            << " enqueue_dropped_aus=" << enqueue_dropped_aus
            << " source_frame_skips=" << source_frame_skips << "\n";
  close(fd);
  return sent_packets > encoded_frames && encoded_frames > 0 &&
                 twcc_feedback > 0 && rr_feedback > 0
             ? 0
             : 1;
}
