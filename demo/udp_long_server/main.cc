#include <cstdlib>
#include <algorithm>
#include <deque>
#include <iostream>
#include <map>
#include <limits>
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
            << " [--drop-every=N] [--delay-ms=N] [--jitter-ms=N]"
            << " [--jitter-every-n=N]"
            << " [--network-seed=N]"
            << " [--profile=none|walking_dead_zone|bandwidth_cliff_recover|jitter_loss_recover]\n";
}

struct NetemPhase {
  uint32_t start_ms = 0;
  uint32_t cap_bps = webrtc_qos::kUnlimitedRateCapBps;
  uint16_t drop_every = 0;
  uint32_t delay_ms = 0;
  uint32_t jitter_ms = 0;
  uint16_t jitter_every_n = 0;
};

uint32_t MediaTimeMs(const webrtc_qos::RtpPacket& packet) {
  const uint32_t base = 90000;
  const uint32_t delta =
      packet.timestamp >= base ? packet.timestamp - base : packet.timestamp;
  return delta / 90;
}

uint32_t MixSeed(uint32_t seed, uint32_t a, uint32_t b) {
  uint32_t x = seed ^ (a * 0x9e3779b9u) ^ (b * 0x85ebca6bu);
  x ^= x >> 16;
  x *= 0x7feb352du;
  x ^= x >> 15;
  x *= 0x846ca68bu;
  x ^= x >> 16;
  return x;
}

bool MatchesEvery(uint16_t interval,
                  const webrtc_qos::RtpPacket& packet,
                  uint32_t network_seed,
                  uint32_t salt) {
  if (interval == 0) {
    return false;
  }
  if (network_seed == 0) {
    return packet.sequence_number % interval == 0;
  }
  return MixSeed(network_seed ^ salt, packet.sequence_number,
                 packet.timestamp) %
             interval ==
         0;
}

std::vector<NetemPhase> BuildProfile(const std::string& profile,
                                     uint16_t drop_every,
                                     uint32_t delay_ms,
                                     uint32_t jitter_ms,
                                     uint16_t jitter_every_n) {
  if (profile == "none" || profile.empty()) {
    return {NetemPhase{0, webrtc_qos::kUnlimitedRateCapBps, drop_every,
                       delay_ms, jitter_ms, jitter_every_n}};
  }
  if (profile == "walking_dead_zone") {
    return {
        NetemPhase{0, webrtc_qos::kUnlimitedRateCapBps, 0, 0, 0, 0},
        NetemPhase{1200, 90000, 3, 700, 350, 5},
        NetemPhase{2600, 180000, 7, 350, 160, 4},
        NetemPhase{4200, webrtc_qos::kUnlimitedRateCapBps, 0, 0, 0, 0},
    };
  }
  if (profile == "bandwidth_cliff_recover") {
    return {
        NetemPhase{0, webrtc_qos::kUnlimitedRateCapBps, 0, 0, 0, 0},
        NetemPhase{1500, 180000, 0, 180, 80, 5},
        NetemPhase{3200, 500000, 0, 120, 50, 6},
        NetemPhase{4800, webrtc_qos::kUnlimitedRateCapBps, 0, 0, 0, 0},
    };
  }
  if (profile == "jitter_loss_recover") {
    return {
        NetemPhase{0, webrtc_qos::kUnlimitedRateCapBps, 0, 0, 0, 0},
        NetemPhase{1400, 500000, 11, 220, 220, 3},
        NetemPhase{3800, webrtc_qos::kUnlimitedRateCapBps, 0, 0, 0, 0},
    };
  }
  std::cerr << "unknown profile: " << profile << "\n";
  std::exit(2);
}

const NetemPhase& SelectPhase(const std::vector<NetemPhase>& phases,
                              uint32_t media_ms,
                              size_t* phase_index) {
  size_t selected = 0;
  for (size_t i = 0; i < phases.size(); ++i) {
    if (media_ms >= phases[i].start_ms) {
      selected = i;
    }
  }
  if (phase_index) {
    *phase_index = selected;
  }
  return phases[selected];
}

void EnqueueDelayed(std::deque<webrtc_qos::demo::DelayedPacket>* delayed,
                    webrtc_qos::demo::DelayedPacket packet) {
  auto it = delayed->begin();
  while (it != delayed->end() && it->release_time_us <= packet.release_time_us) {
    ++it;
  }
  delayed->insert(it, std::move(packet));
}

bool FlushReady(int fd,
                const sockaddr_in& receiver,
                const webrtc_qos::demo::DemoEnvelopeHeader& header,
                int64_t now_us,
                std::deque<webrtc_qos::demo::DelayedPacket>* delayed,
                uint64_t* forwarded) {
  if (delayed->empty() || delayed->front().release_time_us > now_us) {
    return false;
  }
  if (!webrtc_qos::demo::SendEnvelope(fd, receiver, header,
                                      delayed->front().payload)) {
    std::cerr << "udp_long_server: delayed send failed\n";
    std::exit(1);
  }
  ++(*forwarded);
  delayed->pop_front();
  return true;
}

void FlushAllReady(int fd,
                   const sockaddr_in& receiver,
                   const webrtc_qos::demo::DemoEnvelopeHeader& header,
                   int64_t now_us,
                   std::deque<webrtc_qos::demo::DelayedPacket>* delayed,
                   uint64_t* forwarded) {
  while (FlushReady(fd, receiver, header, now_us, delayed, forwarded)) {
  }
}

uint32_t CompactNtp(uint64_t ntp_timestamp) {
  return static_cast<uint32_t>((ntp_timestamp >> 16) & 0xffffffffu);
}

bool SendSenderRateCap(int fd,
                       const sockaddr_in& sender,
                       const webrtc_qos::TransportIds& ids,
                       uint32_t cap_bps,
                       uint32_t controller_seq,
                       uint16_t reason_code) {
  webrtc_qos::SenderRateCap cap;
  cap.ids = ids;
  cap.controller_seq = controller_seq;
  cap.cap_bps = cap_bps;
  cap.expire_ms = 500;
  cap.reason_code = reason_code;
  return webrtc_qos::demo::SendEnvelope(
      fd, sender,
      webrtc_qos::demo::MakeEnvelopeHeader(
          webrtc_qos::demo::EnvelopeType::kSenderRateCap, ids),
      webrtc_qos::SerializeSenderRateCap(cap));
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
  uint16_t drop_every = 0;
  uint32_t delay_ms = 0;
  uint32_t jitter_ms = 0;
  uint16_t jitter_every_n = 0;
  uint32_t network_seed = 0;
  std::string profile = "none";
  for (int i = 4; i < argc; ++i) {
    const std::string arg = argv[i];
    if (ParseUint16Option(arg, "--drop-every=", &drop_every) ||
        ParseUint32Option(arg, "--delay-ms=", &delay_ms) ||
        ParseUint32Option(arg, "--jitter-ms=", &jitter_ms) ||
        ParseUint16Option(arg, "--jitter-every-n=", &jitter_every_n) ||
        ParseUint32Option(arg, "--network-seed=", &network_seed)) {
      continue;
    }
    const std::string profile_prefix = "--profile=";
    if (arg.rfind(profile_prefix, 0) == 0) {
      profile = arg.substr(profile_prefix.size());
      continue;
    }
    Usage(argv[0]);
    return 2;
  }
  const std::vector<NetemPhase> phases =
      BuildProfile(profile, drop_every, delay_ms, jitter_ms, jitter_every_n);

  const int fd = CreateUdpSocket(listen_port);
  const sockaddr_in receiver = MakeIpv4Address(receiver_ip, receiver_port);
  const TransportIds ids = DemoTransportIds();
  RetransmissionCache cache;
  std::map<uint16_t, PacketFeedback> uplink_feedback;
  std::deque<DelayedPacket> delayed;
  sockaddr_in sender{};
  bool sender_known = false;
  uint64_t rtp_in = 0;
  uint64_t forwarded = 0;
  uint64_t dropped = 0;
  uint64_t retransmitted = 0;
  uint64_t twcc_sent = 0;
  uint64_t rr_sent = 0;
  uint64_t quality_reports = 0;
  uint64_t rate_caps = 0;
  uint64_t phase_changes = 0;
  uint64_t phase_packets = 0;
  uint64_t impaired_packets = 0;
  uint32_t min_cap_bps = std::numeric_limits<uint32_t>::max();
  uint32_t max_limited_cap_bps = 0;
  uint32_t last_cap_bps = kUnlimitedRateCapBps;
  size_t last_phase_index = std::numeric_limits<size_t>::max();
  uint32_t last_sent_cap_bps = 0;
  uint32_t last_cap_media_ms = 0;
  uint16_t feedback_seq = 1;
  uint32_t cap_seq = 1;
  bool bye = false;
  const int64_t deadline_us = NowUs() + 20000000;
  while (NowUs() < deadline_us && !bye) {
    FlushAllReady(fd, receiver, MakeEnvelopeHeader(EnvelopeType::kRtp, ids),
                  NowUs(), &delayed, &forwarded);
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
        std::cerr << "udp_long_server: parse RTP failed: " << status.message
                  << "\n";
        return 1;
      }
      sender = from;
      sender_known = true;
      ++rtp_in;
      size_t phase_index = 0;
      const uint32_t media_ms = MediaTimeMs(packet);
      const NetemPhase& phase = SelectPhase(phases, media_ms, &phase_index);
      if (phase_index != last_phase_index) {
        last_phase_index = phase_index;
        ++phase_changes;
      }
      ++phase_packets;
      const bool impaired = phase.drop_every > 0 || phase.delay_ms > 0 ||
                            (phase.jitter_ms > 0 && phase.jitter_every_n > 0) ||
                            phase.cap_bps != kUnlimitedRateCapBps;
      if (impaired) {
        ++impaired_packets;
      }
      const bool should_send_cap =
          phase.cap_bps != last_sent_cap_bps ||
          (phase.cap_bps != kUnlimitedRateCapBps &&
           media_ms >= last_cap_media_ms + 300);
      if (should_send_cap) {
        if (SendSenderRateCap(fd, sender, ids, phase.cap_bps, cap_seq++, 3)) {
          ++rate_caps;
          last_sent_cap_bps = phase.cap_bps;
          last_cap_bps = phase.cap_bps;
          last_cap_media_ms = media_ms;
          if (phase.cap_bps != kUnlimitedRateCapBps) {
            min_cap_bps = std::min(min_cap_bps, phase.cap_bps);
            max_limited_cap_bps = std::max(max_limited_cap_bps, phase.cap_bps);
          }
        }
      }
      cache.Store(packet, NowUs());
      uplink_feedback[packet.transport_sequence_number] = PacketFeedback{
          packet.transport_sequence_number,
          packet.capture_time_us,
          NowUs(),
          packet.payload.size() + 20,
      };
      UplinkTransportFeedback feedback;
      feedback.ids = ids;
      feedback.feedback_seq = feedback_seq++;
      feedback.reference_time_us = uplink_feedback.begin()->second.receive_time_us;
      for (const auto& [unused, item] : uplink_feedback) {
        (void)unused;
        feedback.packets.push_back(item);
      }
      SendEnvelope(fd, sender, MakeEnvelopeHeader(EnvelopeType::kUplinkTwcc, ids),
                   SerializeRtcpTransportFeedback(feedback));
      ++twcc_sent;
      if (MatchesEvery(phase.drop_every, packet, network_seed, 0x51f15eedu)) {
        ++dropped;
        continue;
      }
      const std::vector<uint8_t> encoded = SerializeRtpPacket(packet);
      if (phase.jitter_ms > 0 &&
          MatchesEvery(phase.jitter_every_n, packet, network_seed,
                       0x7177e2u)) {
        EnqueueDelayed(&delayed,
                       DelayedPacket{
                           encoded,
                           NowUs() + static_cast<int64_t>(phase.jitter_ms) * 1000,
                           false});
        continue;
      }
      if (phase.delay_ms > 0) {
        EnqueueDelayed(&delayed,
                       DelayedPacket{
                           encoded,
                           NowUs() + static_cast<int64_t>(phase.delay_ms) * 1000,
                           false});
        continue;
      }
      if (!SendEnvelope(fd, receiver, MakeEnvelopeHeader(EnvelopeType::kRtp, ids),
                        encoded)) {
        std::cerr << "udp_long_server: forward RTP failed\n";
        return 1;
      }
      ++forwarded;
    } else if (header.type == EnvelopeType::kNack) {
      RtcpNack nack;
      Status status = ParseRtcpNack(payload.data(), payload.size(), &nack);
      if (!status) {
        std::cerr << "udp_long_server: parse NACK failed: " << status.message
                  << "\n";
        return 1;
      }
      uint16_t twcc = 50000;
      for (uint16_t seq : nack.lost_rtp_sequence_numbers) {
        std::optional<RtpPacket> packet = cache.Find(seq, twcc++);
        if (!packet) {
          continue;
        }
        if (!SendEnvelope(fd, receiver, MakeEnvelopeHeader(EnvelopeType::kRtp, ids),
                          SerializeRtpPacket(*packet))) {
          std::cerr << "udp_long_server: retransmit RTP failed\n";
          return 1;
        }
        ++retransmitted;
      }
      if (sender_known && rate_caps == 0) {
        if (SendSenderRateCap(fd, sender, ids, 800000, cap_seq++, 1)) {
          ++rate_caps;
        }
      }
    } else if (header.type == EnvelopeType::kRtcpSr) {
      sender = from;
      sender_known = true;
      RtcpSenderReport sr;
      Status status =
          ParseRtcpSenderReport(payload.data(), payload.size(), &sr);
      if (!status) {
        std::cerr << "udp_long_server: parse SR failed: " << status.message
                  << "\n";
        return 1;
      }
      RtcpReceiverReport rr;
      rr.sender_ssrc = sr.sender_ssrc;
      rr.last_sender_report = CompactNtp(sr.ntp_timestamp);
      rr.delay_since_last_sender_report = 0x00010000;
      if (!SendEnvelope(fd, sender, MakeEnvelopeHeader(EnvelopeType::kRtcpRr, ids),
                        SerializeRtcpReceiverReport(rr))) {
        std::cerr << "udp_long_server: send RR failed\n";
        return 1;
      }
      ++rr_sent;
    } else if (header.type == EnvelopeType::kDownlinkQuality) {
      DownlinkQuality report;
      Status status = ParseDownlinkQuality(payload.data(), payload.size(),
                                           &report);
      if (!status) {
        std::cerr << "udp_long_server: parse quality failed: " << status.message
                  << "\n";
        return 1;
      }
      ++quality_reports;
      if (sender_known && report.fraction_lost_q8 > 0 && rate_caps == 0) {
        if (SendSenderRateCap(fd, sender, ids, 800000, cap_seq++, 2)) {
          ++rate_caps;
        }
      }
    } else if (header.type == EnvelopeType::kBye) {
      bye = true;
    }
  }
  FlushAllReady(fd, receiver, MakeEnvelopeHeader(EnvelopeType::kRtp, ids),
                NowUs() + 10000000, &delayed, &forwarded);
  SendEnvelope(fd, receiver, MakeEnvelopeHeader(EnvelopeType::kBye, ids), {});
  if (min_cap_bps == std::numeric_limits<uint32_t>::max()) {
    min_cap_bps = kUnlimitedRateCapBps;
  }
  std::cout << "udp_long_server rtp_in=" << rtp_in
            << " forwarded=" << forwarded
            << " dropped=" << dropped
            << " retransmitted=" << retransmitted
            << " twcc_sent=" << twcc_sent
            << " rr_sent=" << rr_sent
            << " quality_reports=" << quality_reports
            << " rate_caps=" << rate_caps
            << " profile=" << profile
            << " network_seed=" << network_seed
            << " phase_changes=" << phase_changes
            << " phase_packets=" << phase_packets
            << " impaired_packets=" << impaired_packets
            << " min_cap_bps=" << min_cap_bps
            << " max_limited_cap_bps=" << max_limited_cap_bps
            << " last_cap_bps=" << last_cap_bps << "\n";
  close(fd);
  return rtp_in > 0 && forwarded > 0 && twcc_sent > 0 && rr_sent > 0 ? 0 : 1;
}
