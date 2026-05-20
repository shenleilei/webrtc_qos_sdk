#include <cstdlib>
#include <iostream>
#include <vector>

#include "demo/udp_common.h"
#include "webrtc_qos/rtcp_packets.h"
#include "webrtc_qos/rtp_packet.h"
#include "webrtc_qos/sender_qos_googcc_bridge.h"
#include "webrtc_qos/sender_pacer.h"
#include "webrtc_qos/transport_feedback.h"
#include "webrtc_qos/video_sender.h"

namespace {

void Usage(const char* argv0) {
  std::cerr << "usage: " << argv0
            << " <local_port> <server_ip> <server_port>\n";
}

uint32_t CompactNtp(uint64_t ntp_timestamp) {
  return static_cast<uint32_t>((ntp_timestamp >> 16) & 0xffffffffu);
}

}  // namespace

int main(int argc, char** argv) {
  using namespace webrtc_qos;
  using namespace webrtc_qos::demo;

  if (argc != 4) {
    Usage(argv[0]);
    return 2;
  }

  const uint16_t local_port = static_cast<uint16_t>(std::atoi(argv[1]));
  const std::string server_ip = argv[2];
  const uint16_t server_port = static_cast<uint16_t>(std::atoi(argv[3]));

  int fd = CreateUdpSocket(local_port);
  sockaddr_in server = MakeIpv4Address(server_ip, server_port);

  TransportIds ids = DemoTransportIds();

  SenderQosControllerConfig qos_config;
  qos_config.ids = ids;
  qos_config.start_bitrate_bps = 1200000;
  qos_config.min_bitrate_bps = 300000;
  qos_config.max_bitrate_bps = 2500000;
  SenderQosController qos =
      CreateGoogCcSenderQosController(qos_config, 1000000);
  qos.OnProcessInterval(1000000);

  std::vector<PacketFeedback> pending_feedback_seed;
  int64_t current_send_time_us = 1000000;
  SenderPacer pacer(
      SenderPacerConfig{},
      [&](const RtpPacket& packet) {
        const std::vector<uint8_t> encoded = SerializeRtpPacket(packet);
        if (!SendEnvelope(fd, server,
                          MakeEnvelopeHeader(EnvelopeType::kRtp, ids),
                          encoded)) {
          return Status::Error(StatusCode::kInternalError, "send RTP failed");
        }
        qos.OnPacketSent(packet.transport_sequence_number,
                         packet.payload.size() + 20,
                         current_send_time_us);
        pending_feedback_seed.push_back(PacketFeedback{
            packet.transport_sequence_number,
            current_send_time_us,
            -1,
            packet.payload.size() + 20,
        });
        return Status::Ok();
      });

  VideoSender sender(VideoSenderConfig{ids}, &pacer);
  const auto idr = SyntheticIdrAu();
  const auto large_idr = SyntheticLargeIdrAu();
  Status status = sender.SendAnnexBAccessUnit(idr.data(), idr.size(), NowUs());
  if (!status) {
    std::cerr << "udp_sender: send IDR failed: " << status.message << "\n";
    return 1;
  }
  status = sender.SendAnnexBAccessUnit(large_idr.data(), large_idr.size(),
                                       NowUs() + 33000);
  if (!status) {
    std::cerr << "udp_sender: send large IDR failed: " << status.message
              << "\n";
    return 1;
  }

  for (int i = 0; i < 80; ++i) {
    current_send_time_us = 1000000 + static_cast<int64_t>(i) * 5000;
    if (i % 5 == 0) {
      qos.OnProcessInterval(current_send_time_us);
    }
    status = pacer.Tick(current_send_time_us);
    if (!status) {
      std::cerr << "udp_sender: pacer failed: " << status.message << "\n";
      return 1;
    }
    usleep(5000);
  }

  RtcpSenderReport sr;
  sr.sender_ssrc = ids.sender_ssrc;
  sr.ntp_timestamp = (static_cast<uint64_t>(3) << 32);
  sr.rtp_timestamp = 93000;
  sr.packet_count = static_cast<uint32_t>(pacer.GetStats().sent_packets);
  sr.octet_count = static_cast<uint32_t>(pending_feedback_seed.size() * 1200);
  SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kRtcpSr, ids),
               SerializeRtcpSenderReport(sr));

  size_t feedback_packets = 0;
  size_t rr_packets = 0;
  size_t rate_caps = 0;
  size_t pli_received = 0;
  size_t idr_resends = 0;
  const int64_t feedback_deadline_us = NowUs() + 3000000;
  int64_t core_feedback_grace_deadline_us = 0;
  while (NowUs() < feedback_deadline_us) {
    DemoEnvelopeHeader header;
    std::vector<uint8_t> payload;
    sockaddr_in from{};
    if (!ReceiveEnvelope(fd, 100, &header, &payload, &from)) {
      continue;
    }
    if (header.type == EnvelopeType::kUplinkTwcc) {
      UplinkTransportFeedback feedback;
      status =
          ParseRtcpTransportFeedback(payload.data(), payload.size(), &feedback);
      if (!status) {
        std::cerr << "udp_sender: parse TWCC failed: " << status.message
                  << "\n";
        return 1;
      }
      feedback.ids.session_id = header.session_id;
      feedback.ids.stream_id = header.stream_id;
      feedback.ids.transport_id = ids.transport_id;
      for (auto& packet : feedback.packets) {
        for (const auto& seed : pending_feedback_seed) {
          if (seed.transport_sequence_number ==
              packet.transport_sequence_number) {
            packet.send_time_us = seed.send_time_us;
            packet.packet_size = seed.packet_size;
            break;
          }
        }
      }
      qos.OnUplinkTransportFeedback(feedback);
      qos.OnProcessInterval(NowUs());
      ++feedback_packets;
    } else if (header.type == EnvelopeType::kRtcpRr) {
      RtcpReceiverReport rr;
      status = ParseRtcpReceiverReport(payload.data(), payload.size(), &rr);
      if (!status) {
        std::cerr << "udp_sender: parse RR failed: " << status.message << "\n";
        return 1;
      }
      const uint32_t lsr = CompactNtp(sr.ntp_timestamp);
      if (rr.last_sender_report == lsr) {
        rr.rtt_ms = 24;
      }
      rr.receive_time_us = NowUs();
      qos.OnRtcpReceiverReport(rr);
      qos.OnProcessInterval(rr.receive_time_us);
      ++rr_packets;
    } else if (header.type == EnvelopeType::kSenderRateCap) {
      SenderRateCap cap;
      status = ParseSenderRateCap(payload.data(), payload.size(), &cap);
      if (!status) {
        std::cerr << "udp_sender: parse rate cap failed: " << status.message
                  << "\n";
        return 1;
      }
      cap.receive_time_us = NowUs();
      qos.OnSenderRateCap(cap);
      ++rate_caps;
    } else if (header.type == EnvelopeType::kPli) {
      RtcpPli pli;
      status = ParseRtcpPli(payload.data(), payload.size(), &pli);
      if (!status) {
        std::cerr << "udp_sender: parse PLI failed: " << status.message
                  << "\n";
        return 1;
      }
      ++pli_received;
      status = sender.SendAnnexBAccessUnit(idr.data(), idr.size(), NowUs());
      if (!status) {
        std::cerr << "udp_sender: resend IDR failed: " << status.message
                  << "\n";
        return 1;
      }
      for (int i = 0; i < 20; ++i) {
        current_send_time_us += 5000;
        status = pacer.Tick(current_send_time_us);
        if (!status) {
          std::cerr << "udp_sender: pacer failed after PLI: "
                    << status.message << "\n";
          return 1;
        }
        usleep(1000);
      }
      ++idr_resends;
    }
    if (feedback_packets > 0 && rr_packets > 0 && pli_received > 0 &&
        core_feedback_grace_deadline_us == 0) {
      core_feedback_grace_deadline_us = NowUs() + 800000;
    }
    if (feedback_packets > 0 && rr_packets > 0 && pli_received > 0 &&
        (rate_caps > 0 || NowUs() >= core_feedback_grace_deadline_us)) {
      break;
    }
  }

  SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kBye, ids), {});
  const TargetRates rates = qos.GetTargetRates(3005000);
  const SenderPacerStats pacer_stats = pacer.GetStats();
  std::cout << "udp_sender sent=" << pacer_stats.sent_packets
            << " feedback=" << feedback_packets
            << " rr=" << rr_packets
            << " rate_caps=" << rate_caps
            << " pli_received=" << pli_received
            << " idr_resends=" << idr_resends
            << " googcc_target_bps=" << rates.googcc_target_bps
            << " final_target_bps=" << rates.final_target_bps
            << " rtt_ms=" << rates.rtt_ms << "\n";
  close(fd);
  return pacer_stats.sent_packets >= 7 && feedback_packets >= 1 &&
                 rr_packets >= 1 && rate_caps >= 1 && pli_received >= 1 &&
                 idr_resends >= 1
             ? 0
             : 1;
}
