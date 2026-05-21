#include <cstdlib>
#include <iostream>
#include <unordered_map>
#include <string>
#include <vector>

#include "demo/qoe_common.h"
#include "demo/udp_common.h"
#include "webrtc_qos/ffmpeg_h264_encoder.h"
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

uint64_t DemoNtpFromUs(int64_t time_us) {
  const uint64_t seconds = static_cast<uint64_t>(time_us / 1000000);
  const uint64_t fraction =
      (static_cast<uint64_t>(time_us % 1000000) << 32) / 1000000;
  return (seconds << 32) | fraction;
}

uint32_t CompactNtp(uint64_t ntp_timestamp) {
  return static_cast<uint32_t>((ntp_timestamp >> 16) & 0xffffffffu);
}

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
  uint64_t twcc_feedback = 0;
  uint64_t rr_feedback = 0;
  uint64_t rate_caps = 0;
  std::unordered_map<uint16_t, PacketFeedback> sent_packet_feedback;
  int64_t pacer_time_us = 0;
  SenderPacer pacer(
      SenderPacerConfig{bitrate_bps, kPacerTickMs, kPacerMaxQueueMs,
                        kPacerMaxQueueBytes},
      [&](const RtpPacket& packet) {
        const std::vector<uint8_t> encoded = SerializeRtpPacket(packet);
        if (!SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kRtp, ids),
                          encoded)) {
          return Status::Error(StatusCode::kInternalError,
                               "send RTP envelope failed");
        }
        ++sent_packets;
        sent_bytes += encoded.size();
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
  config.gop_size = 30;
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
      ++rate_caps;
    }
    const TargetRates rates = qos.GetTargetRates(pacer_time_us);
    pacer.SetTargetBitrate(rates.pacing_bps);
    return Status::Ok();
  };

  for (uint32_t i = 0; i < frame_count; ++i) {
    const int64_t capture_time_us =
        static_cast<int64_t>(i) * 1000000 / static_cast<int64_t>(config.fps);
    FillI420Frame(width, height, content, static_cast<int>(i), &y, &u, &v);
    const bool force_keyframe = (i % 30) == 0;
    status = encoder.EncodeI420(y.data(), width, u.data(), width / 2, v.data(),
                                width / 2, force_keyframe, &annexb);
    if (!status) {
      std::cerr << "udp_long_sender: encode failed: " << status.message << "\n";
      return 1;
    }
    status = sender.SendAnnexBAccessUnit(annexb.data(), annexb.size(),
                                         capture_time_us);
    if (!status && status.code != StatusCode::kQueueFull) {
      std::cerr << "udp_long_sender: send AU failed: " << status.message << "\n";
      return 1;
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
      pacer.SetTargetBitrate(qos.GetTargetRates(pacer_time_us).pacing_bps);
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
    pacer.SetTargetBitrate(qos.GetTargetRates(pacer_time_us).pacing_bps);
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
  std::cout << "udp_long_sender frames=" << frame_count
            << " sent_packets=" << sent_packets
            << " sent_bytes=" << sent_bytes
            << " pacer_drops=" << pacer.GetStats().dropped_packets
            << " twcc_feedback=" << twcc_feedback
            << " rr=" << rr_feedback
            << " rate_caps=" << rate_caps
            << " final_target_bps=" << rates.final_target_bps
            << " pacing_bps=" << rates.pacing_bps
            << " rtt_ms=" << rates.rtt_ms << "\n";
  close(fd);
  return sent_packets > frame_count && twcc_feedback > 0 && rr_feedback > 0
             ? 0
             : 1;
}
