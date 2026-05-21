#include <cstdlib>
#include <algorithm>
#include <deque>
#include <iostream>
#include <limits>
#include <map>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

#include "demo/qoe_common.h"
#include "demo/udp_common.h"
#include "webrtc_qos/ffmpeg_h264_decoder.h"
#include "webrtc_qos/receiver_qos_observer.h"
#include "webrtc_qos/rtcp_packets.h"
#include "webrtc_qos/rtp_packet.h"
#include "webrtc_qos/transport_feedback.h"
#include "webrtc_qos/video_jitter_player.h"

namespace {

void Usage(const char* argv0) {
  std::cerr << "usage: " << argv0
            << " <local_port> <server_ip> <server_port>"
            << " [--width=N] [--height=N] [--content=motion|low_motion|detail_motion]"
            << " [--expect-frames=N] [--direct-feedback]"
            << " [--rate-cap-bps=N] [--rate-cap-at-packet=N]"
            << " [--drop-every=N] [--delay-ms=N] [--jitter-ms=N]"
            << " [--jitter-every-n=N] [--network-seed=N]"
            << " [--profile=none|walking_dead_zone|bandwidth_cliff_recover|jitter_loss_recover]"
            << " [--max-frame-gap-ms=N] [--min-psnr-avg=N]\n";
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

struct DirectNetemPhase {
  uint32_t start_ms = 0;
  uint32_t cap_bps = webrtc_qos::kUnlimitedRateCapBps;
  uint32_t drop_every = 0;
  uint32_t delay_ms = 0;
  uint32_t jitter_ms = 0;
  uint32_t jitter_every_n = 0;
};

struct DirectDelayedPacket {
  webrtc_qos::RtpPacket packet;
  int64_t release_time_us = 0;
};

uint32_t MediaTimeMs(const webrtc_qos::RtpPacket& packet) {
  constexpr uint32_t kBaseRtpTimestamp = 90000;
  const uint32_t delta = packet.timestamp >= kBaseRtpTimestamp
                             ? packet.timestamp - kBaseRtpTimestamp
                             : packet.timestamp;
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

bool MatchesEvery(uint32_t interval,
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

std::vector<DirectNetemPhase> BuildDirectProfile(const std::string& profile,
                                                 uint32_t drop_every,
                                                 uint32_t delay_ms,
                                                 uint32_t jitter_ms,
                                                 uint32_t jitter_every_n) {
  if (profile == "none" || profile.empty()) {
    return {DirectNetemPhase{0, webrtc_qos::kUnlimitedRateCapBps, drop_every,
                             delay_ms, jitter_ms, jitter_every_n}};
  }
  if (profile == "walking_dead_zone") {
    return {
        DirectNetemPhase{0, webrtc_qos::kUnlimitedRateCapBps, 0, 0, 0, 0},
        DirectNetemPhase{1200, 90000, 3, 700, 350, 5},
        DirectNetemPhase{2600, 180000, 7, 350, 160, 4},
        DirectNetemPhase{4200, webrtc_qos::kUnlimitedRateCapBps, 0, 0, 0, 0},
    };
  }
  if (profile == "bandwidth_cliff_recover") {
    return {
        DirectNetemPhase{0, webrtc_qos::kUnlimitedRateCapBps, 0, 0, 0, 0},
        DirectNetemPhase{1500, 180000, 0, 180, 80, 5},
        DirectNetemPhase{3200, 500000, 0, 120, 50, 6},
        DirectNetemPhase{4800, webrtc_qos::kUnlimitedRateCapBps, 0, 0, 0, 0},
    };
  }
  if (profile == "jitter_loss_recover") {
    return {
        DirectNetemPhase{0, webrtc_qos::kUnlimitedRateCapBps, 0, 0, 0, 0},
        DirectNetemPhase{1400, 500000, 11, 220, 220, 3},
        DirectNetemPhase{3800, webrtc_qos::kUnlimitedRateCapBps, 0, 0, 0, 0},
    };
  }
  std::cerr << "unknown profile: " << profile << "\n";
  std::exit(2);
}

const DirectNetemPhase& SelectDirectPhase(
    const std::vector<DirectNetemPhase>& phases,
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

void EnqueueDelayed(std::deque<DirectDelayedPacket>* delayed,
                    DirectDelayedPacket packet) {
  auto it = delayed->begin();
  while (it != delayed->end() && it->release_time_us <= packet.release_time_us) {
    ++it;
  }
  delayed->insert(it, std::move(packet));
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
  uint32_t width = 320;
  uint32_t height = 180;
  uint32_t expected_frames = 60;
  bool direct_feedback = false;
  uint32_t rate_cap_bps = kUnlimitedRateCapBps;
  uint32_t rate_cap_at_packet = 0;
  uint32_t drop_every = 0;
  uint32_t delay_ms = 0;
  uint32_t jitter_ms = 0;
  uint32_t jitter_every_n = 0;
  uint32_t network_seed = 0;
  uint32_t max_frame_gap_ms_limit = 1000;
  uint32_t min_psnr_avg = 25;
  std::string profile = "none";
  std::string content = "motion";
  for (int i = 4; i < argc; ++i) {
    const std::string arg = argv[i];
    if (ParseUint32Arg(arg, "--width=", &width) ||
        ParseUint32Arg(arg, "--height=", &height) ||
        ParseUint32Arg(arg, "--expect-frames=", &expected_frames)) {
      continue;
    }
    const std::string content_prefix = "--content=";
    if (arg.rfind(content_prefix, 0) == 0) {
      content = arg.substr(content_prefix.size());
      continue;
    }
    if (arg == "--direct-feedback") {
      direct_feedback = true;
      continue;
    }
    if (ParseUint32Arg(arg, "--rate-cap-bps=", &rate_cap_bps) ||
        ParseUint32Arg(arg, "--rate-cap-at-packet=", &rate_cap_at_packet) ||
        ParseUint32Arg(arg, "--drop-every=", &drop_every) ||
        ParseUint32Arg(arg, "--delay-ms=", &delay_ms) ||
        ParseUint32Arg(arg, "--jitter-ms=", &jitter_ms) ||
        ParseUint32Arg(arg, "--jitter-every-n=", &jitter_every_n) ||
        ParseUint32Arg(arg, "--network-seed=", &network_seed) ||
        ParseUint32Arg(arg, "--max-frame-gap-ms=", &max_frame_gap_ms_limit) ||
        ParseUint32Arg(arg, "--min-psnr-avg=", &min_psnr_avg)) {
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
  const std::vector<DirectNetemPhase> phases =
      BuildDirectProfile(profile, drop_every, delay_ms, jitter_ms,
                         jitter_every_n);

  const int fd = CreateUdpSocket(local_port);
  const sockaddr_in server = MakeIpv4Address(server_ip, server_port);
  const TransportIds ids = DemoTransportIds();
  ReceiverQosObserver observer(ReceiverQosObserverConfig{ids, 200});
  observer.SetDownlinkRttMs(12);
  VideoJitterPlayer jitter(VideoJitterPlayerConfig{ids.sender_ssrc});
  FfmpegH264Decoder decoder;
  Status status = decoder.Open();
  if (!status) {
    std::cerr << "udp_long_receiver: decoder open failed: " << status.message
              << "\n";
    return 1;
  }

  uint64_t rtp_packets = 0;
  uint64_t nack_sent = 0;
  uint64_t completed_frames = 0;
  uint64_t decoded_frames = 0;
  uint64_t decode_errors = 0;
  uint64_t quality_samples = 0;
  uint64_t downlink_reports = 0;
  double psnr_sum = 0.0;
  double psnr_min = std::numeric_limits<double>::infinity();
  std::map<uint16_t, PacketFeedback> uplink_feedback;
  uint16_t feedback_seq = 1;
  uint32_t cap_seq = 1;
  bool limited_cap_sent = false;
  bool unlimited_cap_sent = false;
  bool have_direct_feedback_seq = false;
  uint16_t next_direct_feedback_seq = 0;
  uint64_t direct_twcc_sent = 0;
  uint64_t direct_rr_sent = 0;
  uint64_t direct_rate_caps = 0;
  uint64_t direct_dropped = 0;
  uint64_t direct_delayed = 0;
  uint64_t direct_jittered = 0;
  uint64_t direct_released = 0;
  uint64_t direct_impaired_packets = 0;
  uint64_t direct_phase_changes = 0;
  uint64_t direct_phase_packets = 0;
  uint32_t direct_min_cap_bps = std::numeric_limits<uint32_t>::max();
  uint32_t direct_max_limited_cap_bps = 0;
  uint32_t direct_last_cap_bps = kUnlimitedRateCapBps;
  uint32_t direct_last_sent_cap_bps = 0;
  uint32_t direct_last_cap_media_ms = 0;
  size_t direct_last_phase_index = std::numeric_limits<size_t>::max();
  std::set<uint16_t> direct_dropped_once;
  std::deque<DirectDelayedPacket> delayed_packets;
  const auto send_direct_twcc = [&](int64_t now_us) {
    if (!direct_feedback || uplink_feedback.empty()) {
      return;
    }
    UplinkTransportFeedback feedback;
    feedback.ids = ids;
    feedback.feedback_seq = feedback_seq++;
    feedback.reference_time_us = uplink_feedback.begin()->second.receive_time_us;
    for (const auto& [unused, item] : uplink_feedback) {
      (void)unused;
      feedback.packets.push_back(item);
    }
    SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kUplinkTwcc, ids),
                 SerializeRtcpTransportFeedback(feedback));
    ++direct_twcc_sent;
    uplink_feedback.clear();
    (void)now_us;
  };
  const auto send_direct_rate_cap = [&](uint32_t cap_bps,
                                        uint16_t reason_code) {
    if (!direct_feedback) {
      return;
    }
    SenderRateCap cap;
    cap.ids = ids;
    cap.controller_seq = cap_seq++;
    cap.cap_bps = cap_bps;
    cap.expire_ms = cap_bps == kUnlimitedRateCapBps ? 0 : 500;
    cap.reason_code = reason_code;
    SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kSenderRateCap, ids),
                 SerializeSenderRateCap(cap));
    ++direct_rate_caps;
  };
  int64_t last_frame_time_us = -1;
  int64_t max_completion_gap_ms = 0;
  int64_t last_frame_media_ms = -1;
  int64_t max_frame_gap_ms = 0;
  int64_t max_frame_gap_from_ms = 0;
  int64_t max_frame_gap_to_ms = 0;
  const auto process_rtp_packet = [&](const RtpPacket& input_packet,
                                      bool from_delay_queue) -> Status {
    RtpPacket packet = input_packet;
    ++rtp_packets;
    const int64_t now_us = NowUs();
    if (from_delay_queue) {
      ++direct_released;
    }
    if (direct_feedback && profile != "none" && !from_delay_queue &&
        packet.transport_sequence_number < 50000) {
      size_t phase_index = 0;
      const uint32_t media_ms = MediaTimeMs(packet);
      const DirectNetemPhase& phase =
          SelectDirectPhase(phases, media_ms, &phase_index);
      if (phase_index != direct_last_phase_index) {
        direct_last_phase_index = phase_index;
        ++direct_phase_changes;
      }
      ++direct_phase_packets;
      const bool impaired =
          phase.drop_every > 0 || phase.delay_ms > 0 ||
          (phase.jitter_ms > 0 && phase.jitter_every_n > 0) ||
          phase.cap_bps != kUnlimitedRateCapBps;
      if (impaired) {
        ++direct_impaired_packets;
      }
      const bool should_send_phase_cap =
          phase.cap_bps != direct_last_sent_cap_bps ||
          (phase.cap_bps != kUnlimitedRateCapBps &&
           media_ms >= direct_last_cap_media_ms + 300);
      if (should_send_phase_cap) {
        send_direct_rate_cap(phase.cap_bps, 20);
        direct_last_sent_cap_bps = phase.cap_bps;
        direct_last_cap_bps = phase.cap_bps;
        direct_last_cap_media_ms = media_ms;
        if (phase.cap_bps != kUnlimitedRateCapBps) {
          direct_min_cap_bps = std::min(direct_min_cap_bps, phase.cap_bps);
          direct_max_limited_cap_bps =
              std::max(direct_max_limited_cap_bps, phase.cap_bps);
        }
      }
      if (MatchesEvery(phase.drop_every, packet, network_seed, 0x51f15eedu) &&
          direct_dropped_once.insert(packet.sequence_number).second) {
        ++direct_dropped;
        return Status::Ok();
      }
      if (phase.jitter_ms > 0 &&
          MatchesEvery(phase.jitter_every_n, packet, network_seed, 0x7177e2u)) {
        EnqueueDelayed(&delayed_packets,
                       DirectDelayedPacket{
                           packet,
                           now_us + static_cast<int64_t>(phase.jitter_ms) * 1000,
                       });
        ++direct_jittered;
        return Status::Ok();
      }
      if (phase.delay_ms > 0) {
        EnqueueDelayed(&delayed_packets,
                       DirectDelayedPacket{
                           packet,
                           now_us + static_cast<int64_t>(phase.delay_ms) * 1000,
                       });
        ++direct_delayed;
        return Status::Ok();
      }
    }
    const bool should_direct_drop =
        direct_feedback && !from_delay_queue && profile == "none" &&
        drop_every > 0 && packet.transport_sequence_number < 50000 &&
        packet.sequence_number % drop_every == 0 &&
        direct_dropped_once.insert(packet.sequence_number).second;
    if (should_direct_drop) {
      ++direct_dropped;
      return Status::Ok();
    }
    if (direct_feedback) {
      if (packet.transport_sequence_number >= 50000) {
        send_direct_twcc(now_us);
        UplinkTransportFeedback feedback;
        feedback.ids = ids;
        feedback.feedback_seq = feedback_seq++;
        feedback.reference_time_us = now_us;
        feedback.packets.push_back(PacketFeedback{
            packet.transport_sequence_number,
            packet.capture_time_us,
            now_us,
            packet.payload.size() + 20,
        });
        SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kUplinkTwcc, ids),
                     SerializeRtcpTransportFeedback(feedback));
        ++direct_twcc_sent;
      } else {
        if (!have_direct_feedback_seq) {
          next_direct_feedback_seq = packet.transport_sequence_number;
          have_direct_feedback_seq = true;
        }
        while (next_direct_feedback_seq != packet.transport_sequence_number) {
          uplink_feedback[next_direct_feedback_seq] = PacketFeedback{
              next_direct_feedback_seq,
              packet.capture_time_us,
              -1,
              0,
          };
          ++next_direct_feedback_seq;
        }
        ++next_direct_feedback_seq;
        uplink_feedback[packet.transport_sequence_number] = PacketFeedback{
            packet.transport_sequence_number,
            packet.capture_time_us,
            now_us,
            packet.payload.size() + 20,
        };
        if (uplink_feedback.size() >= 8) {
          send_direct_twcc(now_us);
        }
      }
      if (profile == "none" && rate_cap_at_packet > 0 && !limited_cap_sent &&
          rtp_packets >= rate_cap_at_packet && rate_cap_bps > 0 &&
          rate_cap_bps != kUnlimitedRateCapBps) {
        send_direct_rate_cap(rate_cap_bps, 10);
        limited_cap_sent = true;
      }
      if (profile == "none" && limited_cap_sent && !unlimited_cap_sent &&
          rtp_packets >= rate_cap_at_packet + 120) {
        send_direct_rate_cap(kUnlimitedRateCapBps, 11);
        unlimited_cap_sent = true;
      }
    }
    observer.OnRtpPacketReceived(packet, now_us);
    Status status = jitter.InsertPacket(packet, now_us);
    if (!status) {
      return status;
    }
    while (jitter.HasFrame()) {
      EncodedVideoFrame frame;
      status = jitter.PopFrame(&frame);
      if (!status) {
        return status;
      }
      observer.OnFrameDecoded(frame.rtp_timestamp);
      ++completed_frames;
      if (last_frame_time_us >= 0) {
        max_completion_gap_ms =
            std::max<int64_t>(max_completion_gap_ms,
                              (now_us - last_frame_time_us) / 1000);
      }
      last_frame_time_us = now_us;
      const int64_t frame_media_ms =
          frame.rtp_timestamp >= 90000
              ? static_cast<int64_t>(frame.rtp_timestamp - 90000) / 90
              : static_cast<int64_t>(frame.rtp_timestamp) / 90;
      if (last_frame_media_ms >= 0) {
        const int64_t frame_gap_ms = frame_media_ms - last_frame_media_ms;
        if (frame_gap_ms > max_frame_gap_ms) {
          max_frame_gap_ms = frame_gap_ms;
          max_frame_gap_from_ms = last_frame_media_ms;
          max_frame_gap_to_ms = frame_media_ms;
        }
      }
      last_frame_media_ms = frame_media_ms;
      std::vector<DecodedVideoFrame> decoded;
      status = decoder.DecodeAnnexB(frame.annexb_access_unit.data(),
                                    frame.annexb_access_unit.size(),
                                    frame.rtp_timestamp, &decoded);
      if (!status) {
        ++decode_errors;
        continue;
      }
      decoded_frames += decoded.size();
      for (const DecodedVideoFrame& out : decoded) {
        const int64_t pts = out.pts >= 0 ? out.pts : frame.rtp_timestamp;
        const int64_t timestamp_delta =
            pts >= 90000 ? pts - 90000 : static_cast<int64_t>(pts);
        const int frame_index =
            static_cast<int>((timestamp_delta + 1500) / 3000);
        I420Frame reference = MakeI420Frame(width, height, content, frame_index);
        const double psnr = ComputeI420Psnr(reference, out);
        if (psnr > 0.0) {
          psnr_sum += psnr;
          psnr_min = std::min(psnr_min, psnr);
          ++quality_samples;
        }
      }
    }
    std::vector<uint16_t> missing = observer.TakeMissingSequenceNumbers();
    if (!missing.empty()) {
      RtcpNack nack;
      nack.sender_ssrc = ids.receiver_id;
      nack.media_ssrc = ids.sender_ssrc;
      nack.lost_rtp_sequence_numbers = std::move(missing);
      SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kNack, ids),
                   SerializeRtcpNack(nack));
      ++nack_sent;
    }
    if (observer.ShouldReport(now_us)) {
      DownlinkQuality report = observer.BuildReport(now_us);
      const VideoJitterStats stats = jitter.GetStats();
      report.video_jitter_frames = stats.jitter_frames;
      report.video_decodable_queue_depth = stats.decodable_queue_depth;
      report.video_drop_frames = static_cast<uint16_t>(
          std::min<uint32_t>(stats.dropped_frames, 0xffff));
      SendEnvelope(fd, server,
                   MakeEnvelopeHeader(EnvelopeType::kDownlinkQuality, ids),
                   SerializeDownlinkQuality(report));
      ++downlink_reports;
    }
    return Status::Ok();
  };
  bool bye = false;
  bool sender_bye_seen = false;
  const int64_t start_us = NowUs();
  const int64_t deadline_us = start_us + 20000000;
  while (NowUs() < deadline_us && !bye) {
    const int64_t loop_now_us = NowUs();
    while (!delayed_packets.empty() &&
           delayed_packets.front().release_time_us <= loop_now_us) {
      RtpPacket delayed_packet = delayed_packets.front().packet;
      delayed_packets.pop_front();
      status = process_rtp_packet(delayed_packet, true);
      if (!status) {
        std::cerr << "udp_long_receiver: delayed RTP failed: "
                  << status.message << "\n";
        return 1;
      }
    }
    if (sender_bye_seen && delayed_packets.empty()) {
      bye = true;
      break;
    }
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
      status = ParseRtpPacket(payload.data(), payload.size(), &packet);
      if (!status) {
        std::cerr << "udp_long_receiver: parse RTP failed: " << status.message
                  << "\n";
        return 1;
      }
      status = process_rtp_packet(packet, false);
      if (!status) {
        std::cerr << "udp_long_receiver: process RTP failed: " << status.message
                  << "\n";
        return 1;
      }
    } else if (header.type == EnvelopeType::kBye) {
      sender_bye_seen = true;
      bye = delayed_packets.empty();
    } else if (header.type == EnvelopeType::kRtcpSr && direct_feedback) {
      RtcpSenderReport sr;
      status = ParseRtcpSenderReport(payload.data(), payload.size(), &sr);
      if (!status) {
        std::cerr << "udp_long_receiver: parse SR failed: " << status.message
                  << "\n";
        return 1;
      }
      RtcpReceiverReport rr;
      rr.sender_ssrc = sr.sender_ssrc;
      rr.last_sender_report =
          static_cast<uint32_t>((sr.ntp_timestamp >> 16) & 0xffffffffu);
      rr.delay_since_last_sender_report = 0x00010000;
      SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kRtcpRr, ids),
                   SerializeRtcpReceiverReport(rr));
      ++direct_rr_sent;
    }
  }
  while (!delayed_packets.empty()) {
    RtpPacket delayed_packet = delayed_packets.front().packet;
    delayed_packets.pop_front();
    status = process_rtp_packet(delayed_packet, true);
    if (!status) {
      std::cerr << "udp_long_receiver: final delayed RTP failed: "
                << status.message << "\n";
      return 1;
    }
  }
  send_direct_twcc(NowUs());
  DownlinkQuality final_report = observer.BuildReport(NowUs());
  const VideoJitterStats final_stats = jitter.GetStats();
  final_report.video_jitter_frames = final_stats.jitter_frames;
  final_report.video_decodable_queue_depth = final_stats.decodable_queue_depth;
  final_report.video_drop_frames = static_cast<uint16_t>(
      std::min<uint32_t>(final_stats.dropped_frames, 0xffff));
  SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kDownlinkQuality, ids),
               SerializeDownlinkQuality(final_report));
  ++downlink_reports;
  SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kBye, ids), {});
  const double psnr_avg =
      quality_samples > 0 ? psnr_sum / static_cast<double>(quality_samples) : 0.0;
  const double safe_psnr_min = quality_samples > 0 ? psnr_min : 0.0;
  if (direct_min_cap_bps == std::numeric_limits<uint32_t>::max()) {
    direct_min_cap_bps = kUnlimitedRateCapBps;
  }
  std::cout << "udp_long_receiver rtp=" << rtp_packets
            << " completed_frames=" << completed_frames
            << " decoded_frames=" << decoded_frames
            << " decode_errors=" << decode_errors
            << " quality_samples=" << quality_samples
            << " psnr_avg=" << psnr_avg
            << " psnr_min=" << safe_psnr_min
            << " max_completion_gap_ms=" << max_completion_gap_ms
            << " max_frame_gap_ms=" << max_frame_gap_ms
            << " max_frame_gap_from_ms=" << max_frame_gap_from_ms
            << " max_frame_gap_to_ms=" << max_frame_gap_to_ms
            << " nack_sent=" << nack_sent
            << " downlink_reports=" << downlink_reports
            << " direct_twcc_sent=" << direct_twcc_sent
            << " direct_rr_sent=" << direct_rr_sent
            << " direct_rate_caps=" << direct_rate_caps
            << " direct_dropped=" << direct_dropped
            << " direct_delayed=" << direct_delayed
            << " direct_jittered=" << direct_jittered
            << " direct_released=" << direct_released
            << " direct_profile=" << profile
            << " direct_network_seed=" << network_seed
            << " direct_phase_changes=" << direct_phase_changes
            << " direct_phase_packets=" << direct_phase_packets
            << " direct_impaired_packets=" << direct_impaired_packets
            << " direct_min_cap_bps=" << direct_min_cap_bps
            << " direct_max_limited_cap_bps=" << direct_max_limited_cap_bps
            << " direct_last_cap_bps=" << direct_last_cap_bps << "\n";
  close(fd);
  return completed_frames >= expected_frames && decoded_frames >= expected_frames &&
                 decode_errors == 0 && quality_samples >= expected_frames &&
                 psnr_avg >= static_cast<double>(min_psnr_avg) &&
                 max_frame_gap_ms <= static_cast<int64_t>(max_frame_gap_ms_limit)
             ? 0
             : 1;
}
