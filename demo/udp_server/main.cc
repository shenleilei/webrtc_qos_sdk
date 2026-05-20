#include <cstdlib>
#include <deque>
#include <iostream>
#include <map>
#include <string>
#include <vector>

#include "demo/udp_common.h"
#include "webrtc_qos/retransmission_cache.h"
#include "webrtc_qos/rtcp_packets.h"
#include "webrtc_qos/rtp_packet.h"
#include "webrtc_qos/transport_feedback.h"

namespace {

void Usage(const char* argv0) {
  std::cerr << "usage: " << argv0
            << " <listen_port> <receiver_ip> <receiver_port>"
            << " [--drop-rtp-seq=N] [--drop-rtp-seqs=A,B]"
            << " [--reorder-rtp-seq=N] [--reorder-rtp-seqs=A,B]"
            << " [--reorder-delay-ms=N] [--delay-ms=N]"
            << " [--jitter-ms=N] [--jitter-every-n=N]\n";
}

bool SameEndpoint(const sockaddr_in& a, const sockaddr_in& b) {
  return a.sin_family == b.sin_family && a.sin_port == b.sin_port &&
         a.sin_addr.s_addr == b.sin_addr.s_addr;
}

uint32_t CompactNtp(uint64_t ntp_timestamp) {
  return static_cast<uint32_t>((ntp_timestamp >> 16) & 0xffffffffu);
}

bool FlushDelayedIfReady(int fd,
                         const sockaddr_in& receiver,
                         const webrtc_qos::demo::DemoEnvelopeHeader& header,
                         int64_t now_us,
                         std::deque<webrtc_qos::demo::DelayedPacket>* delayed,
                         size_t* rtp_forwarded) {
  if (!delayed || delayed->empty() ||
      delayed->front().release_time_us > now_us) {
    return false;
  }
  if (!webrtc_qos::demo::SendEnvelope(fd, receiver, header,
                                      delayed->front().payload)) {
    std::cerr << "udp_server: flush delayed RTP failed\n";
    std::exit(1);
  }
  if (!delayed->front().counted_forwarded && rtp_forwarded) {
    ++(*rtp_forwarded);
  }
  delayed->pop_front();
  return true;
}

void FlushAllReady(int fd,
                   const sockaddr_in& receiver,
                   const webrtc_qos::demo::DemoEnvelopeHeader& header,
                   int64_t now_us,
                   std::deque<webrtc_qos::demo::DelayedPacket>* delayed,
                   size_t* rtp_forwarded) {
  while (FlushDelayedIfReady(fd, receiver, header, now_us, delayed,
                             rtp_forwarded)) {
  }
}

void EnqueueDelayed(std::deque<webrtc_qos::demo::DelayedPacket>* delayed,
                    webrtc_qos::demo::DelayedPacket packet) {
  if (!delayed) {
    return;
  }
  auto it = delayed->begin();
  while (it != delayed->end() && it->release_time_us <= packet.release_time_us) {
    ++it;
  }
  delayed->insert(it, std::move(packet));
}

bool SendSenderRateCapOnce(int fd,
                           const sockaddr_in& sender,
                           const webrtc_qos::TransportIds& ids,
                           size_t* rate_caps_sent) {
  if (!rate_caps_sent || *rate_caps_sent > 0) {
    return false;
  }
  webrtc_qos::SenderRateCap cap;
  cap.ids = ids;
  cap.controller_seq = 1;
  cap.cap_bps = 1000000;
  cap.expire_ms = 500;
  cap.reason_code = 1;
  if (webrtc_qos::demo::SendEnvelope(
          fd, sender,
          webrtc_qos::demo::MakeEnvelopeHeader(
              webrtc_qos::demo::EnvelopeType::kSenderRateCap, ids),
          webrtc_qos::SerializeSenderRateCap(cap))) {
    ++(*rate_caps_sent);
    return true;
  }
  return false;
}

}  // namespace

int main(int argc, char** argv) {
  using namespace webrtc_qos;
  using namespace webrtc_qos::demo;

  if (argc < 4) {
    Usage(argv[0]);
    return 2;
  }

  const uint16_t listen_port = static_cast<uint16_t>(std::atoi(argv[1]));
  const std::string receiver_ip = argv[2];
  const uint16_t receiver_port = static_cast<uint16_t>(std::atoi(argv[3]));
  NetworkSimulationConfig netem;
  for (int i = 4; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg.rfind("--", 0) != 0) {
      netem.drop_rtp_seqs = {
          static_cast<uint16_t>(std::atoi(arg.c_str()))};
      continue;
    }
    uint16_t single_value = 0;
    if (ParseUint16Option(arg, "--drop-rtp-seq=", &single_value)) {
      netem.drop_rtp_seqs = {single_value};
      continue;
    }
    if (ParseUint16Option(arg, "--reorder-rtp-seq=", &single_value)) {
      netem.reorder_rtp_seqs = {single_value};
      continue;
    }
    if (ParseUint16ListOption(arg, "--drop-rtp-seqs=",
                              &netem.drop_rtp_seqs) ||
        ParseUint16ListOption(arg, "--reorder-rtp-seqs=",
                              &netem.reorder_rtp_seqs) ||
        ParseUint32Option(arg, "--delay-ms=", &netem.delay_ms) ||
        ParseUint32Option(arg, "--reorder-delay-ms=",
                          &netem.reorder_delay_ms) ||
        ParseUint32Option(arg, "--jitter-ms=", &netem.jitter_ms) ||
        ParseUint16Option(arg, "--jitter-every-n=", &netem.jitter_every_n)) {
      continue;
    }
    Usage(argv[0]);
    return 2;
  }

  int fd = CreateUdpSocket(listen_port);
  sockaddr_in receiver = MakeIpv4Address(receiver_ip, receiver_port);
  sockaddr_in sender{};
  bool sender_known = false;
  TransportIds ids = DemoTransportIds();

  RetransmissionCache downlink_cache;
  std::map<uint16_t, PacketFeedback> uplink_feedback;
  std::deque<DelayedPacket> delayed_packets;
  size_t rtp_in = 0;
  size_t rtp_forwarded = 0;
  size_t dropped = 0;
  size_t reordered = 0;
  size_t delayed = 0;
  size_t jittered = 0;
  size_t retransmitted = 0;
  size_t rr_sent = 0;
  size_t rate_caps_sent = 0;
  size_t pli_forwarded = 0;
  uint16_t feedback_seq = 1;
  int64_t synthetic_arrival_us = 2000000;
  bool bye_from_sender = false;
  bool bye_from_receiver = false;

  const int64_t deadline_us = NowUs() + 15000000;
  while (NowUs() < deadline_us && !(bye_from_sender && bye_from_receiver)) {
    FlushAllReady(fd, receiver, MakeEnvelopeHeader(EnvelopeType::kRtp, ids),
                  NowUs(), &delayed_packets, &rtp_forwarded);

    DemoEnvelopeHeader header;
    std::vector<uint8_t> payload;
    sockaddr_in from{};
    if (!ReceiveEnvelope(fd, 20, &header, &payload, &from)) {
      continue;
    }

    if (header.session_id != ids.session_id || header.stream_id != ids.stream_id) {
      continue;
    }

    if (header.type == EnvelopeType::kRtp) {
      RtpPacket packet;
      Status status = ParseRtpPacket(payload.data(), payload.size(), &packet);
      if (!status) {
        std::cerr << "udp_server: parse RTP failed: " << status.message
                  << "\n";
        return 1;
      }
      sender = from;
      sender_known = true;
      ids.sender_ssrc = packet.ssrc;
      ++rtp_in;
      synthetic_arrival_us += 3000;
      uplink_feedback[packet.transport_sequence_number] = PacketFeedback{
          packet.transport_sequence_number,
          packet.capture_time_us,
          synthetic_arrival_us,
          packet.payload.size() + 20,
      };

      UplinkTransportFeedback feedback;
      feedback.ids.sender_ssrc = packet.ssrc;
      feedback.ids.receiver_id = 9001;
      feedback.ids.session_id = ids.session_id;
      feedback.ids.stream_id = ids.stream_id;
      feedback.ids.transport_id = ids.transport_id;
      feedback.feedback_seq = feedback_seq++;
      feedback.reference_time_us = uplink_feedback.begin()->second.receive_time_us;
      for (const auto& [unused, item] : uplink_feedback) {
        (void)unused;
        feedback.packets.push_back(item);
      }
      const std::vector<uint8_t> encoded_feedback =
          SerializeRtcpTransportFeedback(feedback);
      SendEnvelope(fd, sender, MakeEnvelopeHeader(EnvelopeType::kUplinkTwcc, ids),
                   encoded_feedback);

      if (ContainsUint16(netem.drop_rtp_seqs, packet.sequence_number)) {
        downlink_cache.Store(packet, NowUs());
        ++dropped;
        continue;
      }

      downlink_cache.Store(packet, NowUs());
      const std::vector<uint8_t> encoded = SerializeRtpPacket(packet);

      if (ContainsUint16(netem.reorder_rtp_seqs, packet.sequence_number)) {
        EnqueueDelayed(&delayed_packets,
                       DelayedPacket{
                           encoded,
                           NowUs() +
                               static_cast<int64_t>(netem.reorder_delay_ms) *
                                   1000,
                           false});
        ++reordered;
        continue;
      }

      if (netem.jitter_ms > 0 && netem.jitter_every_n > 0 &&
          packet.sequence_number % netem.jitter_every_n == 0) {
        EnqueueDelayed(&delayed_packets,
                       DelayedPacket{
                           encoded,
                           NowUs() +
                               static_cast<int64_t>(netem.jitter_ms) * 1000,
                           false});
        ++jittered;
        continue;
      }

      const uint16_t first_drop =
          netem.drop_rtp_seqs.empty() ? 0 : netem.drop_rtp_seqs.front();
      if (netem.delay_ms > 0 && delayed_packets.empty() &&
          packet.sequence_number > first_drop) {
        EnqueueDelayed(&delayed_packets, DelayedPacket{
            encoded, NowUs() + static_cast<int64_t>(netem.delay_ms) * 1000,
            false});
        ++delayed;
        continue;
      }

      if (!SendEnvelope(fd, receiver, MakeEnvelopeHeader(EnvelopeType::kRtp, ids),
                        encoded)) {
        std::cerr << "udp_server: forward RTP failed\n";
        return 1;
      }
      ++rtp_forwarded;
    } else if (header.type == EnvelopeType::kRtcpSr) {
      if (!sender_known) {
        sender = from;
        sender_known = true;
      }
      RtcpSenderReport sr;
      Status status =
          ParseRtcpSenderReport(payload.data(), payload.size(), &sr);
      if (!status) {
        std::cerr << "udp_server: parse SR failed: " << status.message << "\n";
        return 1;
      }
      RtcpReceiverReport rr;
      rr.sender_ssrc = sr.sender_ssrc;
      rr.last_sender_report = CompactNtp(sr.ntp_timestamp);
      rr.delay_since_last_sender_report = 0x00010000;
      if (!SendEnvelope(fd, sender, MakeEnvelopeHeader(EnvelopeType::kRtcpRr, ids),
                        SerializeRtcpReceiverReport(rr))) {
        std::cerr << "udp_server: send RR failed\n";
        return 1;
      }
      ++rr_sent;
    } else if (header.type == EnvelopeType::kNack) {
      if (!sender_known) {
        continue;
      }
      RtcpNack nack;
      Status status = ParseRtcpNack(payload.data(), payload.size(), &nack);
      if (!status) {
        std::cerr << "udp_server: parse NACK failed: " << status.message
                  << "\n";
        return 1;
      }
      uint16_t twcc = 5000;
      for (uint16_t seq : nack.lost_rtp_sequence_numbers) {
        std::optional<RtpPacket> packet = downlink_cache.Find(seq, twcc++);
        if (!packet) {
          continue;
        }
        const std::vector<uint8_t> encoded = SerializeRtpPacket(*packet);
        if (!SendEnvelope(fd, receiver, MakeEnvelopeHeader(EnvelopeType::kRtp, ids),
                          encoded)) {
          std::cerr << "udp_server: retransmit RTP failed\n";
          return 1;
        }
        ++retransmitted;
      }
      SendSenderRateCapOnce(fd, sender, ids, &rate_caps_sent);
    } else if (header.type == EnvelopeType::kPli) {
      if (!sender_known) {
        continue;
      }
      RtcpPli pli;
      Status status = ParseRtcpPli(payload.data(), payload.size(), &pli);
      if (!status) {
        std::cerr << "udp_server: parse PLI failed: " << status.message
                  << "\n";
        return 1;
      }
      if (!SendEnvelope(fd, sender, MakeEnvelopeHeader(EnvelopeType::kPli, ids),
                        SerializeRtcpPli(pli))) {
        std::cerr << "udp_server: forward PLI failed\n";
        return 1;
      }
      ++pli_forwarded;
    } else if (header.type == EnvelopeType::kDownlinkQuality) {
      DownlinkQuality report;
      Status status = ParseDownlinkQuality(payload.data(), payload.size(),
                                           &report);
      if (!status) {
        std::cerr << "udp_server: parse quality failed: " << status.message
                  << "\n";
        return 1;
      }
      std::cout << "udp_server quality loss_q8=" << report.fraction_lost_q8
                << " jitter=" << report.video_jitter_frames << "\n";
      if (sender_known && report.fraction_lost_q8 > 0) {
        SendSenderRateCapOnce(fd, sender, ids, &rate_caps_sent);
      }
    } else if (header.type == EnvelopeType::kBye) {
      if (sender_known && SameEndpoint(from, sender)) {
        bye_from_sender = true;
        SendEnvelope(fd, receiver, MakeEnvelopeHeader(EnvelopeType::kBye, ids),
                     {});
      } else {
        bye_from_receiver = true;
      }
    }
  }

  FlushAllReady(fd, receiver, MakeEnvelopeHeader(EnvelopeType::kRtp, ids),
                NowUs() + 10000000, &delayed_packets, &rtp_forwarded);

  if (sender_known && !uplink_feedback.empty()) {
    UplinkTransportFeedback feedback;
    feedback.ids.sender_ssrc = 0x12345678;
    feedback.ids.receiver_id = 9001;
    feedback.ids.session_id = ids.session_id;
    feedback.ids.stream_id = ids.stream_id;
    feedback.ids.transport_id = ids.transport_id;
    feedback.feedback_seq = 1;
    feedback.reference_time_us = uplink_feedback.begin()->second.receive_time_us;
    for (const auto& [unused, packet] : uplink_feedback) {
      (void)unused;
      feedback.packets.push_back(packet);
    }
    const std::vector<uint8_t> encoded = SerializeRtcpTransportFeedback(feedback);
    SendEnvelope(fd, sender, MakeEnvelopeHeader(EnvelopeType::kUplinkTwcc, ids),
                 encoded);
  }
  SendEnvelope(fd, receiver, MakeEnvelopeHeader(EnvelopeType::kBye, ids), {});

  std::cout << "udp_server rtp_in=" << rtp_in
            << " forwarded=" << rtp_forwarded
            << " dropped=" << dropped
            << " reordered=" << reordered
            << " delayed=" << delayed
            << " jittered=" << jittered
            << " retransmitted=" << retransmitted
            << " rr_sent=" << rr_sent
            << " rate_caps=" << rate_caps_sent
            << " pli_forwarded=" << pli_forwarded << "\n";
  close(fd);
  return rtp_in >= 7 && dropped >= 1 && retransmitted >= 1 && rr_sent >= 1 &&
                 pli_forwarded >= 1
             ? 0
             : 1;
}
