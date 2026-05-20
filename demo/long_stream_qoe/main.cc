#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "webrtc_qos/ffmpeg_h264_encoder.h"
#include "webrtc_qos/retransmission_cache.h"
#include "webrtc_qos/sender_pacer.h"
#include "webrtc_qos/sender_qos_controller.h"
#include "webrtc_qos/video_receiver.h"
#include "webrtc_qos/video_sender.h"

namespace {

struct Phase {
  std::string name;
  int64_t start_us = 0;
  int64_t end_us = 0;
  uint32_t feedback_bps = 0;
  double feedback_loss = 0.0;
  uint32_t rtt_ms = 0;
  uint32_t downlink_capacity_bps = 0;
  uint32_t downlink_jitter_ms = 0;
  uint16_t downlink_drop_every = 0;
};

struct PhaseMetrics {
  std::string name;
  int64_t duration_us = 0;
  uint32_t encoded_frames = 0;
  uint32_t receiver_frames = 0;
  uint32_t keyframes = 0;
  uint64_t sent_bytes = 0;
};

struct ScheduledPacket {
  webrtc_qos::RtpPacket packet;
  int64_t delivery_us = 0;
  bool retransmission = false;
};

struct Summary {
  std::string strategy;
  bool ok = true;
  int64_t degrade_time_ms = -1;
  int64_t recovery_time_ms = -1;
  uint32_t freeze_count = 0;
  int64_t max_freeze_ms = 0;
  uint32_t network_drops = 0;
  uint32_t duplicate_frames = 0;
  uint32_t encoded_frames = 0;
  uint32_t receiver_frames = 0;
  uint32_t keyframes = 0;
  uint64_t sent_bytes = 0;
};

const Phase& FindPhase(const std::vector<Phase>& phases, int64_t now_us) {
  for (const Phase& phase : phases) {
    if (now_us >= phase.start_us && now_us < phase.end_us) {
      return phase;
    }
  }
  return phases.back();
}

size_t FindPhaseIndex(const std::vector<Phase>& phases, int64_t now_us) {
  for (size_t i = 0; i < phases.size(); ++i) {
    if (now_us >= phases[i].start_us && now_us < phases[i].end_us) {
      return i;
    }
  }
  return phases.size() - 1;
}

uint16_t NextSeq(uint16_t* seq) {
  const uint16_t out = *seq;
  *seq = static_cast<uint16_t>(*seq + 1);
  return out;
}

webrtc_qos::UplinkTransportFeedback BuildFeedback(
    const webrtc_qos::TransportIds& ids,
    uint16_t* transport_seq,
    int64_t now_us,
    uint32_t ack_bps,
    double loss_fraction) {
  webrtc_qos::UplinkTransportFeedback feedback;
  feedback.ids = ids;
  feedback.reference_time_us = now_us;
  feedback.feedback_seq = static_cast<uint16_t>(now_us / 100000);

  constexpr size_t kPackets = 30;
  const size_t lost_packets =
      static_cast<size_t>(loss_fraction * static_cast<double>(kPackets) + 0.5);
  const size_t acked_packets = kPackets - lost_packets;
  const size_t packet_size = 1000;
  const int64_t span_us =
      ack_bps > 0
          ? static_cast<int64_t>((acked_packets * packet_size * 8.0 * 1000000.0) /
                                 static_cast<double>(ack_bps))
          : 1000000;
  const int64_t step_us =
      acked_packets > 1 ? span_us / static_cast<int64_t>(acked_packets - 1)
                        : span_us;
  int64_t receive_time_us = now_us;
  for (size_t i = 0; i < kPackets; ++i) {
    const uint16_t seq = NextSeq(transport_seq);
    webrtc_qos::PacketFeedback packet;
    packet.transport_sequence_number = seq;
    packet.send_time_us = now_us - 100000 + static_cast<int64_t>(i) * 3000;
    packet.packet_size = packet_size;
    if (i < lost_packets) {
      packet.receive_time_us = -1;
    } else {
      packet.receive_time_us = receive_time_us;
      receive_time_us += step_us;
    }
    feedback.packets.push_back(packet);
  }
  return feedback;
}

void FillI420Frame(uint32_t width,
                   uint32_t height,
                   int frame_index,
                   std::vector<uint8_t>* y,
                   std::vector<uint8_t>* u,
                   std::vector<uint8_t>* v) {
  y->resize(width * height);
  u->resize(width * height / 4);
  v->resize(width * height / 4);
  for (uint32_t row = 0; row < height; ++row) {
    for (uint32_t col = 0; col < width; ++col) {
      const uint32_t gradient =
          48 + (col * 96 / std::max<uint32_t>(1, width)) +
          (row * 48 / std::max<uint32_t>(1, height));
      (*y)[row * width + col] = static_cast<uint8_t>(gradient);
    }
  }
  const uint32_t square = std::max<uint32_t>(8, width / 8);
  const uint32_t x0 =
      static_cast<uint32_t>((frame_index * 3) % std::max<uint32_t>(1, width - square));
  const uint32_t y0 =
      static_cast<uint32_t>((frame_index * 2) % std::max<uint32_t>(1, height - square));
  for (uint32_t row = y0; row < y0 + square && row < height; ++row) {
    for (uint32_t col = x0; col < x0 + square && col < width; ++col) {
      (*y)[row * width + col] = 210;
    }
  }
  std::fill(u->begin(), u->end(),
            static_cast<uint8_t>(96 + (frame_index % 8)));
  std::fill(v->begin(), v->end(),
            static_cast<uint8_t>(150 - (frame_index % 8)));
}

void WriteSummary(const std::string& path,
                  const Summary& summary,
                  const std::vector<PhaseMetrics>& phases) {
  if (path.empty()) {
    return;
  }
  std::ofstream out(path);
  out << "{\n";
  out << "  \"strategy\": \"" << summary.strategy << "\",\n";
  out << "  \"ok\": " << (summary.ok ? "true" : "false") << ",\n";
  out << "  \"degrade_time_ms\": " << summary.degrade_time_ms << ",\n";
  out << "  \"recovery_time_ms\": " << summary.recovery_time_ms << ",\n";
  out << "  \"freeze_count\": " << summary.freeze_count << ",\n";
  out << "  \"max_freeze_ms\": " << summary.max_freeze_ms << ",\n";
  out << "  \"network_drops\": " << summary.network_drops << ",\n";
  out << "  \"duplicate_frames\": " << summary.duplicate_frames << ",\n";
  out << "  \"encoded_frames\": " << summary.encoded_frames << ",\n";
  out << "  \"receiver_frames\": " << summary.receiver_frames << ",\n";
  out << "  \"keyframes\": " << summary.keyframes << ",\n";
  out << "  \"sent_bytes\": " << summary.sent_bytes << ",\n";
  out << "  \"phases\": [\n";
  for (size_t i = 0; i < phases.size(); ++i) {
    const PhaseMetrics& phase = phases[i];
    const double seconds = phase.duration_us / 1000000.0;
    const double encode_fps =
        seconds > 0 ? phase.encoded_frames / seconds : 0.0;
    const double receiver_fps =
        seconds > 0 ? phase.receiver_frames / seconds : 0.0;
    const double send_bps =
        seconds > 0 ? static_cast<double>(phase.sent_bytes * 8) / seconds : 0.0;
    out << "    {\"name\": \"" << phase.name << "\", "
        << "\"encoded_frames\": " << phase.encoded_frames << ", "
        << "\"receiver_frames\": " << phase.receiver_frames << ", "
        << "\"keyframes\": " << phase.keyframes << ", "
        << "\"encode_fps\": " << encode_fps << ", "
        << "\"receiver_fps\": " << receiver_fps << ", "
        << "\"send_bps\": " << static_cast<uint64_t>(send_bps) << "}";
    out << (i + 1 == phases.size() ? "\n" : ",\n");
  }
  out << "  ]\n";
  out << "}\n";
}

bool Expect(bool condition, const std::string& message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    return false;
  }
  return condition;
}

}  // namespace

int main(int argc, char** argv) {
  using namespace webrtc_qos;

  std::string summary_path;
  std::string strategy = "adaptive";
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    const std::string prefix = "--summary=";
    if (arg.rfind(prefix, 0) == 0) {
      summary_path = arg.substr(prefix.size());
      continue;
    }
    const std::string strategy_prefix = "--strategy=";
    if (arg.rfind(strategy_prefix, 0) == 0) {
      strategy = arg.substr(strategy_prefix.size());
    }
  }
  if (strategy != "adaptive" && strategy != "balanced" &&
      strategy != "fixed" && strategy != "bitrate_only") {
    std::cerr << "unsupported strategy: " << strategy << "\n";
    return 1;
  }
  const bool enforce_thresholds = strategy == "adaptive";

  const std::vector<Phase> phases = {
      {"good", 0, 3000000, 10000000, 0.0, 20, 4000000, 5, 0},
      {"outage", 3000000, 7000000, 80000, 0.45, 1000, 240000, 180, 0},
      {"poor", 7000000, 10000000, 120000, 0.25, 650, 220000, 90, 0},
      {"good_again", 10000000, 15000000, 10000000, 0.0, 40, 4000000, 5, 0},
  };
  std::vector<PhaseMetrics> phase_metrics;
  for (const Phase& phase : phases) {
    phase_metrics.push_back(PhaseMetrics{phase.name,
                                         phase.end_us - phase.start_us});
  }

  TransportIds ids{1, 1, 1, 0x12345678, 2};
  SenderQosControllerConfig qos_config;
  qos_config.ids = ids;
  qos_config.start_bitrate_bps = 1200000;
  qos_config.min_bitrate_bps = 80000;
  qos_config.max_bitrate_bps = 2500000;
  SenderQosController qos(qos_config);

  FfmpegH264EncoderConfig encoder_config;
  encoder_config.width = 320;
  encoder_config.height = 180;
  encoder_config.fps = 30;
  encoder_config.bitrate_bps = 1200000;
  encoder_config.gop_size = 30;
  FfmpegH264Encoder encoder;
  Status status = encoder.Open(encoder_config);
  if (!status) {
    std::cerr << "encoder open failed: " << status.message << "\n";
    return 1;
  }

  int64_t now_us = 0;
  uint16_t feedback_transport_seq = 1;
  uint16_t retransmission_transport_seq = 50000;
  RetransmissionCache cache;
  std::vector<ScheduledPacket> downlink;
  bool force_keyframe_next = true;
  int64_t last_frame_out_us = -1;
  Summary summary;
  summary.strategy = strategy;
  int64_t link_available_us = 0;
  int64_t last_keyframe_encode_us = -10000000;
  std::set<uint32_t> rendered_timestamps;

  auto schedule_downlink = [&](const RtpPacket& packet,
                               int64_t send_time_us,
                               bool retransmission) {
    const Phase& phase = FindPhase(phases, send_time_us);
    if (!retransmission && phase.downlink_drop_every > 0 &&
        packet.sequence_number % phase.downlink_drop_every == 0) {
      ++summary.network_drops;
      return;
    }
    const size_t bytes = packet.payload.size() + 20;
    const uint32_t capacity_bps =
        std::max<uint32_t>(1, phase.downlink_capacity_bps);
    const int64_t tx_start_us = std::max(send_time_us, link_available_us);
    const int64_t queue_delay_us = tx_start_us - send_time_us;
    const int64_t serialize_us =
        static_cast<int64_t>((bytes * 8.0 * 1000000.0) /
                             static_cast<double>(capacity_bps));
    link_available_us = tx_start_us + std::max<int64_t>(1, serialize_us);
    if (!retransmission && queue_delay_us > 800000) {
      ++summary.network_drops;
      return;
    }
    int64_t jitter_us = 0;
    if (phase.downlink_jitter_ms > 0) {
      const int sign = packet.sequence_number % 2 == 0 ? 1 : -1;
      jitter_us = sign * static_cast<int64_t>(phase.downlink_jitter_ms) * 500;
    }
    const int64_t base_delay_us =
        static_cast<int64_t>(phase.rtt_ms) * 1000 / 2;
    ScheduledPacket scheduled;
    scheduled.packet = packet;
    scheduled.delivery_us =
        link_available_us + std::max<int64_t>(0, base_delay_us + jitter_us);
    scheduled.retransmission = retransmission;
    downlink.push_back(std::move(scheduled));
  };

  SenderPacer pacer(
      SenderPacerConfig{1200000, kPacerTickMs, kPacerMaxQueueMs,
                        kPacerMaxQueueBytes},
      [&](const RtpPacket& packet) {
        const size_t bytes = packet.payload.size() + 20;
        Status sent_status =
            qos.OnPacketSent(packet.transport_sequence_number, bytes, now_us);
        if (!sent_status) {
          return sent_status;
        }
        const size_t phase_index = FindPhaseIndex(phases, now_us);
        phase_metrics[phase_index].sent_bytes += bytes;
        summary.sent_bytes += bytes;
        cache.Store(packet, now_us);
        schedule_downlink(packet, now_us, false);
        return Status::Ok();
      });
  VideoSender sender(VideoSenderConfig{ids}, &pacer);

  VideoReceiver receiver(
      VideoReceiverConfig{ids},
      VideoReceiverCallbacks{
          [&](const EncodedVideoFrame& frame) {
            if (!rendered_timestamps.insert(frame.rtp_timestamp).second) {
              ++summary.duplicate_frames;
              return;
            }
            const size_t phase_index = FindPhaseIndex(phases, now_us);
            ++phase_metrics[phase_index].receiver_frames;
            ++summary.receiver_frames;
            if (frame.keyframe) {
              ++phase_metrics[phase_index].keyframes;
              ++summary.keyframes;
            }
            if (last_frame_out_us >= 0) {
              const int64_t gap_ms = (now_us - last_frame_out_us) / 1000;
              if (gap_ms > 1000) {
                ++summary.freeze_count;
                summary.max_freeze_ms = std::max(summary.max_freeze_ms, gap_ms);
              }
            }
            last_frame_out_us = now_us;
          },
          nullptr,
          [&](const RecoveryRequest& request) {
            if (request.type == RecoveryRequest::Type::kPli) {
              if (now_us - last_keyframe_encode_us >= 2000000) {
                force_keyframe_next = true;
              }
              return;
            }
            if (request.type != RecoveryRequest::Type::kNack) {
              return;
            }
            for (uint16_t sequence : request.missing_rtp_sequence_numbers) {
              std::optional<RtpPacket> retransmission =
                  cache.Find(sequence, retransmission_transport_seq++);
              if (retransmission.has_value()) {
                schedule_downlink(*retransmission, now_us, true);
              }
            }
          }});

  int64_t next_feedback_us = 0;
  int64_t next_encode_us = 0;
  uint32_t applied_bitrate_bps = encoder_config.bitrate_bps;
  uint32_t applied_fps = encoder_config.fps;
  int frame_index = 0;
  std::vector<uint8_t> y;
  std::vector<uint8_t> u;
  std::vector<uint8_t> v;
  std::vector<uint8_t> annexb;

  constexpr int64_t kTickUs = 5000;
  constexpr int64_t kEndUs = 15000000;
  for (now_us = 0; now_us <= kEndUs; now_us += kTickUs) {
    const Phase& phase = FindPhase(phases, now_us);
    if (now_us >= next_feedback_us) {
      UplinkTransportFeedback feedback =
          BuildFeedback(ids, &feedback_transport_seq, now_us,
                        phase.feedback_bps, phase.feedback_loss);
      status = qos.OnUplinkTransportFeedback(feedback);
      if (!status) {
        std::cerr << "feedback failed: " << status.message << "\n";
        return 2;
      }
      RtcpReceiverReport rr;
      rr.sender_ssrc = ids.sender_ssrc;
      rr.rtt_ms = phase.rtt_ms;
      rr.receive_time_us = now_us;
      status = qos.OnRtcpReceiverReport(rr);
      if (!status) {
        std::cerr << "RR failed: " << status.message << "\n";
        return 3;
      }
      next_feedback_us += 100000;
    }

    EncoderAdaptation adaptation = qos.GetEncoderAdaptation(now_us);
    if (strategy == "fixed") {
      adaptation.target_bitrate_bps = 1200000;
      adaptation.max_fps = 30;
      adaptation.request_keyframe = false;
    } else if (strategy == "bitrate_only") {
      adaptation.max_fps = 30;
    } else if (strategy == "balanced") {
      adaptation.max_fps = std::max<uint32_t>(10, adaptation.max_fps);
    }
    if (now_us >= phases[1].start_us && summary.degrade_time_ms < 0 &&
        adaptation.target_bitrate_bps <= 200000 && adaptation.max_fps <= 5) {
      summary.degrade_time_ms = (now_us - phases[1].start_us) / 1000;
    }
    if (now_us >= phases[3].start_us && summary.recovery_time_ms < 0 &&
        adaptation.target_bitrate_bps >= 2000000 && adaptation.max_fps == 30) {
      summary.recovery_time_ms = (now_us - phases[3].start_us) / 1000;
    }
    if (adaptation.target_bitrate_bps != applied_bitrate_bps ||
        adaptation.max_fps != applied_fps) {
      applied_bitrate_bps = adaptation.target_bitrate_bps;
      applied_fps = std::max<uint32_t>(1, adaptation.max_fps);
      status = encoder.SetRates(applied_bitrate_bps, applied_fps);
      if (!status) {
        std::cerr << "set rates failed: " << status.message << "\n";
        return 4;
      }
      pacer.SetTargetBitrate(applied_bitrate_bps);
      force_keyframe_next = true;
    }

    while (now_us >= next_encode_us) {
      FillI420Frame(encoder_config.width, encoder_config.height, frame_index,
                    &y, &u, &v);
      const bool keyframe_needed = force_keyframe_next ||
                                   adaptation.request_keyframe ||
                                   frame_index == 0;
      const bool force_keyframe =
          keyframe_needed && now_us - last_keyframe_encode_us >= 2000000;
      status = encoder.EncodeI420(y.data(), encoder_config.width, u.data(),
                                  encoder_config.width / 2, v.data(),
                                  encoder_config.width / 2, force_keyframe,
                                  &annexb);
      if (!status) {
        std::cerr << "encode failed: " << status.message << "\n";
        return 5;
      }
      if (force_keyframe) {
        force_keyframe_next = false;
        last_keyframe_encode_us = now_us;
      }
      status = sender.SendAnnexBAccessUnit(annexb.data(), annexb.size(), now_us);
      if (!status && status.code != StatusCode::kQueueFull) {
        std::cerr << "send AU failed: " << status.message << "\n";
        return 6;
      }
      const size_t phase_index = FindPhaseIndex(phases, now_us);
      ++phase_metrics[phase_index].encoded_frames;
      ++summary.encoded_frames;
      ++frame_index;
      next_encode_us =
          now_us + 1000000 / static_cast<int64_t>(std::max<uint32_t>(1, applied_fps));
      break;
    }

    status = pacer.Tick(now_us);
    if (!status) {
      std::cerr << "pacer failed: " << status.message << "\n";
      return 7;
    }

    for (size_t i = 0; i < downlink.size();) {
      if (downlink[i].delivery_us > now_us) {
        ++i;
        continue;
      }
      RtpPacket packet = downlink[i].packet;
      packet.receive_time_us = now_us;
      downlink.erase(downlink.begin() + static_cast<long>(i));
      status = receiver.OnRtpPacket(packet, now_us);
      if (!status && status.code != StatusCode::kMalformedPacket) {
        std::cerr << "receiver failed: " << status.message << "\n";
        return 8;
      }
    }
  }

  for (int flush = 0; flush < 300; ++flush) {
    now_us += kTickUs;
    status = pacer.Tick(now_us);
    if (!status) {
      std::cerr << "flush pacer failed: " << status.message << "\n";
      return 9;
    }
    for (size_t i = 0; i < downlink.size();) {
      if (downlink[i].delivery_us > now_us) {
        ++i;
        continue;
      }
      RtpPacket packet = downlink[i].packet;
      packet.receive_time_us = now_us;
      downlink.erase(downlink.begin() + static_cast<long>(i));
      receiver.OnRtpPacket(packet, now_us);
    }
  }

  bool ok = true;
  auto fps = [](const PhaseMetrics& phase, uint32_t frames) {
    return phase.duration_us > 0
               ? frames / (phase.duration_us / 1000000.0)
               : 0.0;
  };
  const double good_encode_fps = fps(phase_metrics[0], phase_metrics[0].encoded_frames);
  const double outage_encode_fps =
      fps(phase_metrics[1], phase_metrics[1].encoded_frames);
  const double recovered_encode_fps =
      fps(phase_metrics[3], phase_metrics[3].encoded_frames);
  const double good_receiver_fps =
      fps(phase_metrics[0], phase_metrics[0].receiver_frames);
  const double recovered_receiver_fps =
      fps(phase_metrics[3], phase_metrics[3].receiver_frames);

  if (enforce_thresholds) {
    ok &= Expect(summary.degrade_time_ms >= 0 &&
                     summary.degrade_time_ms <= 1000,
                 "degrade time <= 1000ms");
    ok &= Expect(summary.recovery_time_ms >= 0 &&
                     summary.recovery_time_ms <= 1500,
                 "recovery time <= 1500ms");
    ok &= Expect(good_encode_fps >= 20.0, "good encode fps >= 20");
    ok &= Expect(outage_encode_fps >= 3.0 && outage_encode_fps <= 10.0,
                 "outage encode fps in [3,10]");
    ok &= Expect(recovered_encode_fps >= 20.0,
                 "recovered encode fps >= 20");
    ok &= Expect(good_receiver_fps >= 15.0, "good receiver fps >= 15");
    ok &= Expect(recovered_receiver_fps >= 15.0,
                 "recovered receiver fps >= 15");
    ok &= Expect(summary.freeze_count <= 3, "freeze count <= 3");
    ok &= Expect(summary.max_freeze_ms <= 2000, "max freeze <= 2000ms");
    ok &= Expect(summary.receiver_frames > 0, "receiver frames > 0");
  }
  summary.ok = ok;

  WriteSummary(summary_path, summary, phase_metrics);

  std::cout << "long_stream_qoe strategy=" << strategy
            << " degrade_ms=" << summary.degrade_time_ms
            << " recovery_ms=" << summary.recovery_time_ms
            << " freeze_count=" << summary.freeze_count
            << " max_freeze_ms=" << summary.max_freeze_ms
            << " network_drops=" << summary.network_drops
            << " duplicate_frames=" << summary.duplicate_frames
            << " encoded_frames=" << summary.encoded_frames
            << " receiver_frames=" << summary.receiver_frames
            << " keyframes=" << summary.keyframes
            << " sent_bytes=" << summary.sent_bytes << "\n";
  for (const PhaseMetrics& phase : phase_metrics) {
    const double seconds = phase.duration_us / 1000000.0;
    const double encode_fps =
        seconds > 0 ? phase.encoded_frames / seconds : 0.0;
    const double receiver_fps =
        seconds > 0 ? phase.receiver_frames / seconds : 0.0;
    const uint64_t send_bps =
        seconds > 0
            ? static_cast<uint64_t>((phase.sent_bytes * 8) / seconds)
            : 0;
    std::cout << "long_stream_qoe phase=" << phase.name
              << " encode_fps=" << encode_fps
              << " receiver_fps=" << receiver_fps
              << " send_bps=" << send_bps
              << " encoded_frames=" << phase.encoded_frames
              << " receiver_frames=" << phase.receiver_frames
              << " keyframes=" << phase.keyframes << "\n";
  }
  std::cout << (ok ? "long_stream_qoe_demo passed\n"
                   : "long_stream_qoe_demo failed\n");
  return ok ? 0 : 1;
}
