#include <algorithm>
#include <cstdlib>
#include <cstdint>
#include <cmath>
#include <fstream>
#include <iostream>
#include <limits>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

#include "webrtc_qos/ffmpeg_h264_decoder.h"
#include "webrtc_qos/ffmpeg_h264_encoder.h"
#include "webrtc_qos/receiver_qos_observer.h"
#include "webrtc_qos/retransmission_cache.h"
#include "webrtc_qos/sender_pacer.h"
#include "webrtc_qos/sender_qos_controller.h"
#include "webrtc_qos/video_jitter_player.h"
#include "webrtc_qos/video_sender.h"

#ifdef WEBRTC_QOS_ENABLE_WEBRTC_BACKEND
#include "webrtc_qos/sender_qos_googcc_bridge.h"
#include "webrtc_qos/video_jitter_bridge.h"
#endif

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
  uint32_t decoded_frames = 0;
  uint32_t decode_errors = 0;
  uint32_t quality_samples = 0;
  double psnr_min = std::numeric_limits<double>::infinity();
  double psnr_sum = 0.0;
  uint32_t network_drops = 0;
  uint64_t sent_bytes = 0;
  uint32_t adaptation_samples = 0;
  uint32_t target_bps_min = std::numeric_limits<uint32_t>::max();
  uint32_t target_bps_max = 0;
  uint32_t target_bps_last = 0;
  uint64_t target_bps_sum = 0;
  uint32_t fps_min = std::numeric_limits<uint32_t>::max();
  uint32_t fps_max = 0;
  uint32_t fps_last = 0;
  uint64_t fps_sum = 0;
  int64_t adaptation_response_time_ms = -1;
};

struct ScheduledPacket {
  webrtc_qos::RtpPacket packet;
  int64_t delivery_us = 0;
  bool retransmission = false;
};

struct Summary {
  std::string scenario;
  std::string backend;
  std::string strategy;
  uint32_t network_seed = 0;
  bool ok = true;
  int64_t degrade_time_ms = -1;
  int64_t recovery_time_ms = -1;
  uint32_t freeze_count = 0;
  int64_t max_freeze_ms = 0;
  uint32_t network_drops = 0;
  uint32_t duplicate_frames = 0;
  uint32_t encoded_frames = 0;
  uint32_t receiver_frames = 0;
  uint32_t decoded_frames = 0;
  uint32_t decode_errors = 0;
  uint32_t quality_samples = 0;
  double psnr_min = std::numeric_limits<double>::infinity();
  double psnr_sum = 0.0;
  uint32_t keyframes = 0;
  uint32_t probe_packets = 0;
  uint64_t sent_bytes = 0;
};

struct I420Frame {
  uint32_t width = 0;
  uint32_t height = 0;
  std::vector<uint8_t> y;
  std::vector<uint8_t> u;
  std::vector<uint8_t> v;
};

bool IsSupportedScenario(const std::string& scenario) {
  return scenario == "walking_dead_zone" ||
         scenario == "jitter_loss_oscillation" ||
         scenario == "bandwidth_staircase" ||
         scenario == "rtt_jitter_spike_recover" ||
         scenario == "loss_burst_recover";
}

std::vector<Phase> BuildScenario(const std::string& scenario) {
  if (scenario == "walking_dead_zone") {
    return {
        {"good", 0, 3000000, 10000000, 0.0, 20, 4000000, 5, 0},
        {"outage", 3000000, 7000000, 80000, 0.45, 1000, 240000, 180, 0},
        {"poor", 7000000, 10000000, 120000, 0.25, 650, 220000, 90, 0},
        {"good_again", 10000000, 15000000, 10000000, 0.0, 40, 4000000, 5, 0},
    };
  }
  if (scenario == "jitter_loss_oscillation") {
    return {
        {"good", 0, 3000000, 10000000, 0.0, 25, 4000000, 5, 0},
        {"outage", 3000000, 7000000, 450000, 0.18, 220, 500000, 260, 29},
        {"poor", 7000000, 10000000, 700000, 0.08, 160, 700000, 180, 41},
        {"good_again", 10000000, 15000000, 10000000, 0.0, 35, 4000000, 5, 0},
    };
  }
  if (scenario == "rtt_jitter_spike_recover") {
    return {
        {"good", 0, 3000000, 8000000, 0.0, 35, 4000000, 5, 0},
        {"outage", 3000000, 7000000, 700000, 0.08, 900, 800000, 320, 0},
        {"poor", 7000000, 10000000, 500000, 0.04, 420, 650000, 180, 0},
        {"good_again", 10000000, 15000000, 8000000, 0.0, 45, 4000000, 5, 0},
    };
  }
  if (scenario == "loss_burst_recover") {
    return {
        {"good", 0, 3000000, 6000000, 0.0, 25, 4000000, 5, 0},
        {"outage", 3000000, 7000000, 500000, 0.60, 220, 560000, 140, 17},
        {"poor", 7000000, 10000000, 650000, 0.15, 160, 700000, 90, 29},
        {"good_again", 10000000, 15000000, 6000000, 0.0, 35, 4000000, 5, 0},
    };
  }
  return {
      {"good", 0, 3000000, 10000000, 0.0, 20, 4000000, 5, 0},
      {"outage", 3000000, 7000000, 600000, 0.08, 260, 650000, 60, 0},
      {"poor", 7000000, 10000000, 180000, 0.28, 750, 260000, 120, 0},
      {"good_again", 10000000, 15000000, 10000000, 0.0, 40, 4000000, 5, 0},
  };
}

bool MeetsPhaseAdaptationTarget(const std::string& scenario,
                                const std::string& phase,
                                const webrtc_qos::EncoderAdaptation& adaptation) {
  struct Target {
    uint32_t bps = 0;
    uint32_t fps = 0;
    bool minimum = false;
  };

  Target target;
  if (scenario == "walking_dead_zone") {
    if (phase == "outage") {
      target = Target{250000, 8, false};
    } else if (phase == "poor") {
      target = Target{350000, 12, false};
    } else if (phase == "good_again") {
      target = Target{1800000, 24, true};
    }
  } else if (scenario == "jitter_loss_oscillation") {
    if (phase == "outage") {
      target = Target{350000, 12, false};
    } else if (phase == "poor") {
      target = Target{450000, 12, false};
    } else if (phase == "good_again") {
      target = Target{1800000, 24, true};
    }
  } else if (scenario == "bandwidth_staircase") {
    if (phase == "outage") {
      target = Target{450000, 15, false};
    } else if (phase == "poor") {
      target = Target{300000, 12, false};
    } else if (phase == "good_again") {
      target = Target{1800000, 24, true};
    }
  } else if (scenario == "rtt_jitter_spike_recover") {
    if (phase == "outage") {
      target = Target{500000, 12, false};
    } else if (phase == "poor") {
      target = Target{450000, 12, false};
    } else if (phase == "good_again") {
      target = Target{1800000, 24, true};
    }
  } else if (scenario == "loss_burst_recover") {
    if (phase == "outage") {
      target = Target{350000, 15, false};
    } else if (phase == "poor") {
      target = Target{450000, 12, false};
    } else if (phase == "good_again") {
      target = Target{1800000, 24, true};
    }
  }

  if (target.bps == 0 || target.fps == 0) {
    return false;
  }
  if (target.minimum) {
    return adaptation.target_bitrate_bps >= target.bps &&
           adaptation.max_fps >= target.fps;
  }
  return adaptation.target_bitrate_bps <= target.bps &&
         adaptation.max_fps <= target.fps;
}

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

uint32_t MixSeed(uint32_t seed, uint32_t a, uint32_t b) {
  uint32_t x = seed ^ (a * 0x9e3779b9u) ^ (b * 0x85ebca6bu);
  x ^= x >> 16;
  x *= 0x7feb352du;
  x ^= x >> 15;
  x *= 0x846ca68bu;
  x ^= x >> 16;
  return x;
}

webrtc_qos::UplinkTransportFeedback BuildFeedback(
    const webrtc_qos::TransportIds& ids,
    std::vector<webrtc_qos::PacketFeedback>* pending_packets,
    int64_t now_us,
    uint16_t feedback_seq,
    uint32_t ack_bps,
    double loss_fraction,
    uint32_t network_seed) {
  webrtc_qos::UplinkTransportFeedback feedback;
  feedback.ids = ids;
  feedback.reference_time_us = now_us;
  feedback.feedback_seq = feedback_seq;
  if (!pending_packets || pending_packets->empty()) {
    return feedback;
  }

  std::vector<webrtc_qos::PacketFeedback> due;
  due.reserve(pending_packets->size());
  auto it = pending_packets->begin();
  while (it != pending_packets->end()) {
    if (it->send_time_us <= now_us - 20000) {
      due.push_back(*it);
      it = pending_packets->erase(it);
    } else {
      ++it;
    }
  }
  if (due.empty()) {
    return feedback;
  }

  std::vector<bool> lost_flags(due.size(), false);
  const uint32_t loss_threshold =
      static_cast<uint32_t>(std::max(0.0, std::min(1.0, loss_fraction)) *
                            1000.0 + 0.5);
  size_t acked_packets = 0;
  size_t acked_bytes = 0;
  for (size_t i = 0; i < due.size(); ++i) {
    const uint32_t hash =
        network_seed == 0
            ? static_cast<uint32_t>((i + 1) * 1103515245u +
                                    feedback_seq * 2654435761u)
            : MixSeed(network_seed, static_cast<uint32_t>(i + 1),
                      feedback_seq);
    lost_flags[i] = loss_threshold > 0 && (hash % 1000u) < loss_threshold;
    if (!lost_flags[i]) {
      ++acked_packets;
      acked_bytes += due[i].packet_size;
    }
  }
  const int64_t span_us =
      ack_bps > 0
          ? static_cast<int64_t>((acked_bytes * 8.0 * 1000000.0) /
                                 static_cast<double>(ack_bps))
          : 1000000;
  const int64_t step_us =
      acked_packets > 1 ? span_us / static_cast<int64_t>(acked_packets - 1)
                        : span_us;
  int64_t receive_time_us = now_us - span_us;
  for (size_t i = 0; i < due.size(); ++i) {
    webrtc_qos::PacketFeedback packet = due[i];
    if (lost_flags[i]) {
      packet.receive_time_us = -1;
    } else {
      packet.receive_time_us = std::max(packet.send_time_us, receive_time_us);
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

double ComputePlaneSse(const uint8_t* reference,
                       const uint8_t* decoded,
                       size_t size) {
  double sse = 0.0;
  for (size_t i = 0; i < size; ++i) {
    const int diff = static_cast<int>(reference[i]) - static_cast<int>(decoded[i]);
    sse += static_cast<double>(diff * diff);
  }
  return sse;
}

double ComputeI420Psnr(const I420Frame& reference,
                       const webrtc_qos::DecodedVideoFrame& decoded) {
  if (reference.width != decoded.width || reference.height != decoded.height ||
      reference.y.empty() || reference.u.empty() || reference.v.empty() ||
      decoded.y_plane.empty() || decoded.u_plane.empty() ||
      decoded.v_plane.empty()) {
    return 0.0;
  }
  const size_t y_size = static_cast<size_t>(reference.width) * reference.height;
  const size_t uv_size = static_cast<size_t>(reference.width / 2) *
                         (reference.height / 2);
  if (reference.y.size() != y_size || reference.u.size() != uv_size ||
      reference.v.size() != uv_size || decoded.y_plane.size() != y_size ||
      decoded.u_plane.size() != uv_size || decoded.v_plane.size() != uv_size) {
    return 0.0;
  }
  const double sse =
      ComputePlaneSse(reference.y.data(), decoded.y_plane.data(), y_size) +
      ComputePlaneSse(reference.u.data(), decoded.u_plane.data(), uv_size) +
      ComputePlaneSse(reference.v.data(), decoded.v_plane.data(), uv_size);
  const double samples = static_cast<double>(y_size + 2 * uv_size);
  if (sse <= 0.0) {
    return 99.0;
  }
  const double mse = sse / samples;
  return 10.0 * std::log10((255.0 * 255.0) / mse);
}

double AveragePsnr(double sum, uint32_t samples) {
  return samples > 0 ? sum / static_cast<double>(samples) : 0.0;
}

void WriteSummary(const std::string& path,
                  const Summary& summary,
                  const std::vector<PhaseMetrics>& phases) {
  if (path.empty()) {
    return;
  }
  std::ofstream out(path);
  out << "{\n";
  out << "  \"scenario\": \"" << summary.scenario << "\",\n";
  out << "  \"backend\": \"" << summary.backend << "\",\n";
  out << "  \"strategy\": \"" << summary.strategy << "\",\n";
  out << "  \"network_seed\": " << summary.network_seed << ",\n";
  out << "  \"ok\": " << (summary.ok ? "true" : "false") << ",\n";
  out << "  \"degrade_time_ms\": " << summary.degrade_time_ms << ",\n";
  out << "  \"recovery_time_ms\": " << summary.recovery_time_ms << ",\n";
  out << "  \"freeze_count\": " << summary.freeze_count << ",\n";
  out << "  \"max_freeze_ms\": " << summary.max_freeze_ms << ",\n";
  out << "  \"network_drops\": " << summary.network_drops << ",\n";
  out << "  \"duplicate_frames\": " << summary.duplicate_frames << ",\n";
  out << "  \"encoded_frames\": " << summary.encoded_frames << ",\n";
  out << "  \"receiver_frames\": " << summary.receiver_frames << ",\n";
  out << "  \"decoded_frames\": " << summary.decoded_frames << ",\n";
  out << "  \"decode_errors\": " << summary.decode_errors << ",\n";
  out << "  \"quality_samples\": " << summary.quality_samples << ",\n";
  out << "  \"psnr_min\": "
      << (summary.quality_samples > 0 ? summary.psnr_min : 0.0) << ",\n";
  out << "  \"psnr_avg\": "
      << AveragePsnr(summary.psnr_sum, summary.quality_samples) << ",\n";
  out << "  \"keyframes\": " << summary.keyframes << ",\n";
  out << "  \"probe_packets\": " << summary.probe_packets << ",\n";
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
    const uint32_t target_bps_min =
        phase.adaptation_samples > 0 ? phase.target_bps_min : 0;
    const double target_bps_avg =
        phase.adaptation_samples > 0
            ? static_cast<double>(phase.target_bps_sum) /
                  static_cast<double>(phase.adaptation_samples)
            : 0.0;
    const uint32_t fps_min =
        phase.adaptation_samples > 0 ? phase.fps_min : 0;
    const double fps_avg =
        phase.adaptation_samples > 0
            ? static_cast<double>(phase.fps_sum) /
                  static_cast<double>(phase.adaptation_samples)
            : 0.0;
    out << "    {\"name\": \"" << phase.name << "\", "
        << "\"encoded_frames\": " << phase.encoded_frames << ", "
        << "\"receiver_frames\": " << phase.receiver_frames << ", "
        << "\"decoded_frames\": " << phase.decoded_frames << ", "
        << "\"decode_errors\": " << phase.decode_errors << ", "
        << "\"quality_samples\": " << phase.quality_samples << ", "
        << "\"psnr_min\": "
        << (phase.quality_samples > 0 ? phase.psnr_min : 0.0) << ", "
        << "\"psnr_avg\": "
        << AveragePsnr(phase.psnr_sum, phase.quality_samples) << ", "
        << "\"keyframes\": " << phase.keyframes << ", "
        << "\"network_drops\": " << phase.network_drops << ", "
        << "\"encode_fps\": " << encode_fps << ", "
        << "\"receiver_fps\": " << receiver_fps << ", "
        << "\"send_bps\": " << static_cast<uint64_t>(send_bps) << ", "
        << "\"target_bps_min\": " << target_bps_min << ", "
        << "\"target_bps_avg\": " << static_cast<uint64_t>(target_bps_avg)
        << ", "
        << "\"target_bps_max\": " << phase.target_bps_max << ", "
        << "\"target_bps_last\": " << phase.target_bps_last << ", "
        << "\"fps_min\": " << fps_min << ", "
        << "\"fps_avg\": " << fps_avg << ", "
        << "\"fps_max\": " << phase.fps_max << ", "
        << "\"fps_last\": " << phase.fps_last << ", "
        << "\"adaptation_response_time_ms\": "
        << phase.adaptation_response_time_ms << "}";
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
  std::string backend = "lightweight";
  std::string strategy = "adaptive";
  std::string scenario = "walking_dead_zone";
  uint32_t network_seed = 0;
  const bool trace_rates = std::getenv("WEBRTC_QOS_TRACE_RATES") != nullptr;
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
      continue;
    }
    const std::string backend_prefix = "--backend=";
    if (arg.rfind(backend_prefix, 0) == 0) {
      backend = arg.substr(backend_prefix.size());
      continue;
    }
    const std::string scenario_prefix = "--scenario=";
    if (arg.rfind(scenario_prefix, 0) == 0) {
      scenario = arg.substr(scenario_prefix.size());
      continue;
    }
    const std::string seed_prefix = "--network-seed=";
    if (arg.rfind(seed_prefix, 0) == 0) {
      network_seed =
          static_cast<uint32_t>(std::stoul(arg.substr(seed_prefix.size())));
    }
  }
  if (strategy != "adaptive" && strategy != "balanced" &&
      strategy != "fixed" && strategy != "bitrate_only") {
    std::cerr << "unsupported strategy: " << strategy << "\n";
    return 1;
  }
  if (backend != "lightweight" && backend != "webrtc") {
    std::cerr << "unsupported backend: " << backend << "\n";
    return 1;
  }
  if (!IsSupportedScenario(scenario)) {
    std::cerr << "unsupported scenario: " << scenario << "\n";
    return 1;
  }
#ifndef WEBRTC_QOS_ENABLE_WEBRTC_BACKEND
  if (backend == "webrtc") {
    std::cerr << "webrtc backend support was not compiled in\n";
    return 1;
  }
#endif
  const bool enforce_thresholds =
      scenario == "walking_dead_zone" && backend == "lightweight" &&
      strategy == "adaptive";
  const bool enforce_decode_thresholds = backend == "webrtc";

  const std::vector<Phase> phases = BuildScenario(scenario);
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
  std::unique_ptr<SenderQosBackend> qos_backend;
#ifdef WEBRTC_QOS_ENABLE_WEBRTC_BACKEND
  if (backend == "webrtc") {
    qos_backend = CreateGoogCcSenderQosBackend(qos_config, 0);
  }
#endif
  SenderQosController qos(qos_config, std::move(qos_backend));

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
  uint16_t feedback_seq = 1;
  uint16_t retransmission_transport_seq = 50000;
  uint16_t probe_transport_seq = 60000;
  RetransmissionCache cache;
  std::vector<PacketFeedback> pending_uplink_feedback;
  std::vector<ScheduledPacket> downlink;
  bool force_keyframe_next = true;
  bool route_recovered = false;
  int64_t last_frame_out_us = -1;
  Summary summary;
  summary.scenario = scenario;
  summary.backend = backend;
  summary.strategy = strategy;
  summary.network_seed = network_seed;
  int64_t link_available_us = 0;
  int64_t last_keyframe_encode_us = -10000000;
  std::set<uint32_t> rendered_timestamps;
  std::unordered_map<uint32_t, I420Frame> source_frames;

  auto schedule_downlink = [&](const RtpPacket& packet,
                               int64_t send_time_us,
                               bool retransmission) {
    const Phase& phase = FindPhase(phases, send_time_us);
    if (!retransmission && phase.downlink_drop_every > 0) {
      const bool should_drop =
          network_seed == 0
              ? packet.sequence_number % phase.downlink_drop_every == 0
              : (static_cast<uint32_t>(packet.sequence_number) +
                 network_seed) %
                        phase.downlink_drop_every ==
                    0;
      if (should_drop) {
        ++phase_metrics[FindPhaseIndex(phases, send_time_us)].network_drops;
        ++summary.network_drops;
        return;
      }
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
      ++phase_metrics[FindPhaseIndex(phases, send_time_us)].network_drops;
      ++summary.network_drops;
      return;
    }
    int64_t jitter_us = 0;
    if (phase.downlink_jitter_ms > 0) {
      const int sign =
          network_seed == 0
              ? (packet.sequence_number % 2 == 0 ? 1 : -1)
              : ((MixSeed(network_seed, packet.sequence_number,
                          packet.timestamp) &
                  1u) == 0
                     ? 1
                     : -1);
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
        pending_uplink_feedback.push_back(PacketFeedback{
            packet.transport_sequence_number,
            now_us,
            -1,
            bytes,
        });
        const size_t phase_index = FindPhaseIndex(phases, now_us);
        phase_metrics[phase_index].sent_bytes += bytes;
        summary.sent_bytes += bytes;
        cache.Store(packet, now_us);
        schedule_downlink(packet, now_us, false);
        return Status::Ok();
      });
  VideoSender sender(VideoSenderConfig{ids}, &pacer);

  auto send_probe_cluster = [&](const ProbeCluster& cluster) -> Status {
    if (cluster.target_bitrate_bps == 0 || cluster.min_probe_count == 0 ||
        cluster.min_probe_bytes == 0) {
      return Status::Ok();
    }
    const size_t probe_packet_size = 1200;
    size_t sent_bytes = 0;
    int64_t send_time_us = now_us;
    const int64_t delta_us =
        cluster.min_probe_delta_us > 0
            ? cluster.min_probe_delta_us
            : std::max<int64_t>(
                  1,
                  static_cast<int64_t>(
                      (probe_packet_size * 8.0 * 1000000.0) /
                      static_cast<double>(cluster.target_bitrate_bps)));
    const size_t capped_min_probe_bytes =
        std::min<size_t>(cluster.min_probe_bytes, 12000);
    for (uint32_t i = 0;
         i < cluster.min_probe_count || sent_bytes < capped_min_probe_bytes;
         ++i) {
      if (i > 0) {
        send_time_us += delta_us;
      }
      const uint16_t sequence = probe_transport_seq++;
      Status probe_status =
          qos.OnProbePacketSent(sequence, probe_packet_size, send_time_us,
                                cluster);
      if (!probe_status) {
        return probe_status;
      }
      pending_uplink_feedback.push_back(PacketFeedback{
          sequence,
          send_time_us,
          -1,
          probe_packet_size,
      });
      sent_bytes += probe_packet_size;
      ++summary.probe_packets;
    }
    return Status::Ok();
  };

  ReceiverQosObserver receiver_observer(ReceiverQosObserverConfig{ids, 200});
  std::unique_ptr<VideoJitterBackend> jitter_backend;
#ifdef WEBRTC_QOS_ENABLE_WEBRTC_BACKEND
  if (backend == "webrtc") {
    jitter_backend =
        CreateWebRtcVideoJitterBackend(VideoJitterPlayerConfig{ids.sender_ssrc});
  }
#endif
  VideoJitterPlayer jitter(VideoJitterPlayerConfig{ids.sender_ssrc},
                           std::move(jitter_backend));
  FfmpegH264Decoder decoder;
  status = decoder.Open();
  if (!status) {
    std::cerr << "decoder open failed: " << status.message << "\n";
    return 1;
  }

  auto handle_recovery_request = [&](const RecoveryRequest& request) {
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
  };

  auto handle_frame = [&](const EncodedVideoFrame& frame) {
    if (!rendered_timestamps.insert(frame.rtp_timestamp).second) {
      ++summary.duplicate_frames;
      return;
    }
    const size_t phase_index = FindPhaseIndex(phases, now_us);
    std::vector<DecodedVideoFrame> decoded_frames;
    Status decode_status =
        decoder.DecodeAnnexB(frame.annexb_access_unit.data(),
                             frame.annexb_access_unit.size(),
                             frame.rtp_timestamp, &decoded_frames);
    if (!decode_status) {
      std::cerr << "long_stream_qoe decode_error"
                << " timestamp=" << frame.rtp_timestamp
                << " bytes=" << frame.annexb_access_unit.size()
                << " keyframe=" << (frame.keyframe ? 1 : 0)
                << " status=" << decode_status.message
                << " decoded_outputs=" << decoded_frames.size() << "\n";
      ++phase_metrics[phase_index].decode_errors;
      ++summary.decode_errors;
      return;
    }
    if (decoded_frames.empty()) {
      return;
    }
    phase_metrics[phase_index].decoded_frames +=
        static_cast<uint32_t>(decoded_frames.size());
    summary.decoded_frames += static_cast<uint32_t>(decoded_frames.size());
    for (const DecodedVideoFrame& decoded_frame : decoded_frames) {
      const uint32_t decoded_rtp_timestamp =
          decoded_frame.pts >= 0
              ? static_cast<uint32_t>(decoded_frame.pts)
              : frame.rtp_timestamp;
      auto source_it = source_frames.find(decoded_rtp_timestamp);
      if (source_it != source_frames.end()) {
        const double psnr = ComputeI420Psnr(source_it->second, decoded_frame);
        if (psnr > 0.0) {
          ++phase_metrics[phase_index].quality_samples;
          phase_metrics[phase_index].psnr_sum += psnr;
          phase_metrics[phase_index].psnr_min =
              std::min(phase_metrics[phase_index].psnr_min, psnr);
          ++summary.quality_samples;
          summary.psnr_sum += psnr;
          summary.psnr_min = std::min(summary.psnr_min, psnr);
        }
        source_frames.erase(source_it);
      }
    }
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
  };

  auto receive_packet = [&](const RtpPacket& packet) -> Status {
    receiver_observer.OnRtpPacketReceived(packet, now_us);
    Status insert_status = jitter.InsertPacket(packet, now_us);
    if (!insert_status) {
      RecoveryRequest request;
      request.type = RecoveryRequest::Type::kPli;
      request.sender_ssrc = ids.sender_ssrc;
      request.reason = insert_status.message;
      handle_recovery_request(request);
      return insert_status;
    }
    while (jitter.HasFrame()) {
      EncodedVideoFrame frame;
      Status pop_status = jitter.PopFrame(&frame);
      if (!pop_status) {
        return pop_status;
      }
      receiver_observer.OnFrameDecoded(frame.rtp_timestamp);
      handle_frame(frame);
    }
    std::vector<uint16_t> missing =
        receiver_observer.TakeMissingSequenceNumbers();
    if (!missing.empty()) {
      RecoveryRequest request;
      request.type = RecoveryRequest::Type::kNack;
      request.sender_ssrc = ids.sender_ssrc;
      request.missing_rtp_sequence_numbers = std::move(missing);
      request.reason = "missing RTP sequence numbers";
      handle_recovery_request(request);
    }
    return Status::Ok();
  };

  int64_t next_feedback_us = 0;
  int64_t next_process_us = 0;
  int64_t next_trace_us = 0;
  int64_t next_encode_us = 0;
  uint32_t applied_bitrate_bps = encoder_config.bitrate_bps;
  uint32_t applied_pacing_bps = encoder_config.bitrate_bps;
  uint32_t applied_fps = encoder_config.fps;
  int frame_index = 0;
  std::vector<uint8_t> y;
  std::vector<uint8_t> u;
  std::vector<uint8_t> v;
  std::vector<uint8_t> annexb;

  constexpr int64_t kTickUs = 5000;
  constexpr int64_t kEndUs = 15000000;
  constexpr uint32_t kRecoveredRouteStartBps = 2000000;
  for (now_us = 0; now_us <= kEndUs; now_us += kTickUs) {
    const Phase& phase = FindPhase(phases, now_us);
    if (!route_recovered && now_us >= phases[3].start_us) {
      // In C/S mode the server can declare the uplink route healthy again.
      // Bootstrap GoogCC from a known-good production target instead of waiting
      // for a slow AIMD climb from the conservative startup rate.
      status = qos.OnNetworkRouteChange(kRecoveredRouteStartBps, now_us);
      if (!status) {
        std::cerr << "route change failed: " << status.message << "\n";
        return 2;
      }
      SenderRateCap cap;
      cap.ids = ids;
      cap.cap_bps = kUnlimitedRateCapBps;
      cap.receive_time_us = now_us;
      status = qos.OnSenderRateCap(cap);
      if (!status) {
        std::cerr << "route cap reset failed: " << status.message << "\n";
        return 2;
      }
      pending_uplink_feedback.clear();
      applied_pacing_bps = kRecoveredRouteStartBps;
      pacer.SetTargetBitrate(applied_pacing_bps);
      force_keyframe_next = true;
      route_recovered = true;
    }
    if (now_us >= next_process_us) {
      status = qos.OnProcessInterval(now_us);
      if (!status) {
        std::cerr << "process interval failed: " << status.message << "\n";
        return 2;
      }
      std::vector<ProbeCluster> probe_clusters = qos.TakeProbeClusters();
      for (const auto& cluster : probe_clusters) {
        status = send_probe_cluster(cluster);
        if (!status) {
          std::cerr << "probe failed: " << status.message << "\n";
          return 2;
        }
      }
      next_process_us += 25000;
    }
    if (now_us >= next_feedback_us) {
      UplinkTransportFeedback feedback =
          BuildFeedback(ids, &pending_uplink_feedback, now_us, feedback_seq++,
                        phase.feedback_bps, phase.feedback_loss,
                        network_seed);
      if (!feedback.packets.empty()) {
        status = qos.OnUplinkTransportFeedback(feedback);
        if (!status) {
          std::cerr << "feedback failed: " << status.message << "\n";
          return 2;
        }
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
      SenderRateCap cap;
      cap.ids = ids;
      cap.cap_bps =
          phase.downlink_capacity_bps < 1000000
              ? std::max<uint32_t>(
                    qos_config.min_bitrate_bps,
                    static_cast<uint32_t>(phase.downlink_capacity_bps * 0.60))
              : kUnlimitedRateCapBps;
      cap.expire_ms = 300;
      cap.receive_time_us = now_us;
      status = qos.OnSenderRateCap(cap);
      if (!status) {
        std::cerr << "rate cap failed: " << status.message << "\n";
        return 3;
      }
      next_feedback_us += 100000;
    }

    EncoderAdaptation adaptation = qos.GetEncoderAdaptation(now_us);
    TargetRates target_rates = qos.GetTargetRates(now_us);
    if (strategy == "fixed") {
      adaptation.target_bitrate_bps = 1200000;
      target_rates.pacing_bps = 1200000;
      adaptation.max_fps = 30;
      adaptation.request_keyframe = false;
    } else if (strategy == "bitrate_only") {
      adaptation.max_fps = 30;
    } else if (strategy == "balanced") {
      adaptation.max_fps = std::max<uint32_t>(10, adaptation.max_fps);
    }
    {
      PhaseMetrics& metrics = phase_metrics[FindPhaseIndex(phases, now_us)];
      ++metrics.adaptation_samples;
      metrics.target_bps_min =
          std::min(metrics.target_bps_min, adaptation.target_bitrate_bps);
      metrics.target_bps_max =
          std::max(metrics.target_bps_max, adaptation.target_bitrate_bps);
      metrics.target_bps_last = adaptation.target_bitrate_bps;
      metrics.target_bps_sum += adaptation.target_bitrate_bps;
      metrics.fps_min = std::min(metrics.fps_min, adaptation.max_fps);
      metrics.fps_max = std::max(metrics.fps_max, adaptation.max_fps);
      metrics.fps_last = adaptation.max_fps;
      metrics.fps_sum += adaptation.max_fps;
      if (metrics.adaptation_response_time_ms < 0 &&
          MeetsPhaseAdaptationTarget(scenario, phase.name, adaptation)) {
        metrics.adaptation_response_time_ms =
            (now_us - phase.start_us) / 1000;
      }
    }
    if (now_us >= phases[1].start_us && summary.degrade_time_ms < 0 &&
        adaptation.target_bitrate_bps <= 200000 && adaptation.max_fps <= 5) {
      summary.degrade_time_ms = (now_us - phases[1].start_us) / 1000;
    }
    if (now_us >= phases[3].start_us && summary.recovery_time_ms < 0 &&
        adaptation.target_bitrate_bps >= 2000000 && adaptation.max_fps == 30) {
      summary.recovery_time_ms = (now_us - phases[3].start_us) / 1000;
    }
    if (trace_rates && now_us >= next_trace_us) {
      std::cerr << "trace_rates backend=" << backend
                << " strategy=" << strategy
                << " phase=" << phase.name
                << " now_ms=" << now_us / 1000
                << " target_bps=" << target_rates.final_target_bps
                << " googcc_bps=" << target_rates.googcc_target_bps
                << " pacing_bps=" << target_rates.pacing_bps
                << " fps=" << adaptation.max_fps
                << " loss=" << target_rates.loss_fraction
                << " rtt_ms=" << target_rates.rtt_ms << "\n";
      next_trace_us += 100000;
    }
    if (target_rates.pacing_bps != applied_pacing_bps) {
      applied_pacing_bps = target_rates.pacing_bps;
      pacer.SetTargetBitrate(applied_pacing_bps);
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
      if (target_rates.pacing_bps == 0) {
        applied_pacing_bps = applied_bitrate_bps;
        pacer.SetTargetBitrate(applied_pacing_bps);
      }
      force_keyframe_next = true;
    }

    while (now_us >= next_encode_us) {
      const uint32_t rtp_timestamp =
          kVideoClockRateHz + static_cast<uint32_t>(frame_index) *
                                  (kVideoClockRateHz / 30);
      FillI420Frame(encoder_config.width, encoder_config.height, frame_index,
                    &y, &u, &v);
      I420Frame source_frame;
      source_frame.width = encoder_config.width;
      source_frame.height = encoder_config.height;
      source_frame.y = y;
      source_frame.u = u;
      source_frame.v = v;
      source_frames[rtp_timestamp] = std::move(source_frame);
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
      status = receive_packet(packet);
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
      receive_packet(packet);
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
  if (enforce_decode_thresholds) {
    ok &= Expect(summary.decode_errors == 0, "decode errors == 0");
    ok &= Expect(summary.decoded_frames >= summary.receiver_frames,
                 "decoded frames >= receiver frames");
    ok &= Expect(summary.quality_samples >= summary.receiver_frames,
                 "quality samples >= receiver frames");
  }
  summary.ok = ok;

  WriteSummary(summary_path, summary, phase_metrics);

  std::cout << "long_stream_qoe backend=" << backend
            << " scenario=" << scenario
            << " strategy=" << strategy
            << " network_seed=" << network_seed
            << " degrade_ms=" << summary.degrade_time_ms
            << " recovery_ms=" << summary.recovery_time_ms
            << " freeze_count=" << summary.freeze_count
            << " max_freeze_ms=" << summary.max_freeze_ms
            << " network_drops=" << summary.network_drops
            << " duplicate_frames=" << summary.duplicate_frames
            << " encoded_frames=" << summary.encoded_frames
            << " receiver_frames=" << summary.receiver_frames
            << " decoded_frames=" << summary.decoded_frames
            << " decode_errors=" << summary.decode_errors
            << " quality_samples=" << summary.quality_samples
            << " psnr_avg=" << AveragePsnr(summary.psnr_sum,
                                           summary.quality_samples)
            << " psnr_min="
            << (summary.quality_samples > 0 ? summary.psnr_min : 0.0)
            << " keyframes=" << summary.keyframes
            << " probe_packets=" << summary.probe_packets
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
              << " decoded_frames=" << phase.decoded_frames
              << " decode_errors=" << phase.decode_errors
              << " quality_samples=" << phase.quality_samples
              << " psnr_avg=" << AveragePsnr(phase.psnr_sum,
                                             phase.quality_samples)
              << " psnr_min="
              << (phase.quality_samples > 0 ? phase.psnr_min : 0.0)
              << " keyframes=" << phase.keyframes
              << " network_drops=" << phase.network_drops
              << " target_bps_min="
              << (phase.adaptation_samples > 0 ? phase.target_bps_min : 0)
              << " target_bps_max=" << phase.target_bps_max
              << " target_bps_last=" << phase.target_bps_last
              << " fps_min="
              << (phase.adaptation_samples > 0 ? phase.fps_min : 0)
              << " fps_max=" << phase.fps_max
              << " fps_last=" << phase.fps_last
              << " adaptation_response_ms="
              << phase.adaptation_response_time_ms << "\n";
  }
  std::cout << (ok ? "long_stream_qoe_demo passed\n"
                   : "long_stream_qoe_demo failed\n");
  return ok ? 0 : 1;
}
