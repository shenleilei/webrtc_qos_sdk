#pragma once

#include <cstdlib>
#include <iostream>
#include <string>

#include "webrtc_qos/runtime_alerts.h"
#include "webrtc_qos/runtime_logging.h"
#include "webrtc_qos/runtime_metrics.h"

namespace minimal_udp {

struct CommonOptions {
  int frames = 90;
  int tracks = 2;
  std::string log_dir;
  std::string metrics_dir;
  std::string alerts_dir;
};

inline bool ParseOptionalArgs(int argc,
                              char** argv,
                              int start_index,
                              CommonOptions* options) {
  for (int i = start_index; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--frames") {
      if (i + 1 >= argc) {
        std::cerr << "--frames requires a value\n";
        return false;
      }
      options->frames = std::max(1, std::atoi(argv[++i]));
      continue;
    }
    if (arg == "--tracks") {
      if (i + 1 >= argc) {
        std::cerr << "--tracks requires a value\n";
        return false;
      }
      options->tracks = std::atoi(argv[++i]) <= 1 ? 1 : 2;
      continue;
    }
    if (arg == "--log-dir") {
      if (i + 1 >= argc) {
        std::cerr << "--log-dir requires a directory\n";
        return false;
      }
      options->log_dir = argv[++i];
      continue;
    }
    if (arg == "--metrics-dir") {
      if (i + 1 >= argc) {
        std::cerr << "--metrics-dir requires a directory\n";
        return false;
      }
      options->metrics_dir = argv[++i];
      continue;
    }
    if (arg == "--alerts-dir") {
      if (i + 1 >= argc) {
        std::cerr << "--alerts-dir requires a directory\n";
        return false;
      }
      options->alerts_dir = argv[++i];
      continue;
    }
    char* end = nullptr;
    const long frames = std::strtol(arg.c_str(), &end, 10);
    if (end != nullptr && *end == '\0') {
      options->frames = std::max(1, static_cast<int>(frames));
      continue;
    }
    std::cerr << "unknown argument: " << arg << "\n";
    return false;
  }
  return true;
}

inline webrtc_qos::RuntimeLogConfig MakeLogConfig(
    const std::string& log_dir) {
  webrtc_qos::RuntimeLogConfig config;
  if (!log_dir.empty()) {
    config.file.enabled = true;
    config.file.directory = log_dir;
    config.file.basename = "minimal_udp";
    config.file.json_lines = true;
    config.file.also_stderr = false;
    config.file.max_file_bytes = 1024 * 1024;
    config.file.max_files = 4;
  }
  return config;
}

inline webrtc_qos::RuntimeMetricsConfig MakeMetricsConfig(
    const std::string& metrics_dir) {
  webrtc_qos::RuntimeMetricsConfig config;
  if (!metrics_dir.empty()) {
    config.file.enabled = true;
    config.file.directory = metrics_dir;
    config.file.basename = "minimal_udp_metrics";
    config.file.max_file_bytes = 1024 * 1024;
    config.file.max_files = 4;
    config.interval_ms = 100;
    config.include_track_snapshots = true;
  }
  return config;
}

inline webrtc_qos::RuntimeAlertConfig MakeAlertConfig(
    const std::string& alerts_dir) {
  webrtc_qos::RuntimeAlertConfig config;
  if (!alerts_dir.empty()) {
    config.file.enabled = true;
    config.file.directory = alerts_dir;
    config.file.basename = "minimal_udp_alerts";
    config.file.max_file_bytes = 1024 * 1024;
    config.file.max_files = 4;
    config.suppress_repeated_alerts_ms = 0;
    config.high_loss_fraction_q8 = 128;
    config.video_drop_frames_threshold = 1;
    config.low_target_bps = 700000;
    config.low_encoder_fps = 20;
  }
  return config;
}

}  // namespace minimal_udp
