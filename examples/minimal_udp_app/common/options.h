#pragma once

#include <algorithm>
#include <cstdint>
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
  uint64_t log_max_file_bytes = 1024 * 1024;
  uint32_t log_max_files = 4;
  uint32_t log_max_queue_records = 4096;
  uint64_t metrics_max_file_bytes = 1024 * 1024;
  uint32_t metrics_max_files = 4;
  uint64_t alerts_max_file_bytes = 1024 * 1024;
  uint32_t alerts_max_files = 4;
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
    if (arg == "--log-max-file-bytes") {
      if (i + 1 >= argc) {
        std::cerr << "--log-max-file-bytes requires a value\n";
        return false;
      }
      options->log_max_file_bytes =
          static_cast<uint64_t>(std::strtoull(argv[++i], nullptr, 10));
      continue;
    }
    if (arg == "--log-max-files") {
      if (i + 1 >= argc) {
        std::cerr << "--log-max-files requires a value\n";
        return false;
      }
      options->log_max_files =
          static_cast<uint32_t>(std::max(1, std::atoi(argv[++i])));
      continue;
    }
    if (arg == "--log-max-queue-records") {
      if (i + 1 >= argc) {
        std::cerr << "--log-max-queue-records requires a value\n";
        return false;
      }
      options->log_max_queue_records =
          static_cast<uint32_t>(std::max(1, std::atoi(argv[++i])));
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
    if (arg == "--metrics-max-file-bytes") {
      if (i + 1 >= argc) {
        std::cerr << "--metrics-max-file-bytes requires a value\n";
        return false;
      }
      options->metrics_max_file_bytes =
          static_cast<uint64_t>(std::strtoull(argv[++i], nullptr, 10));
      continue;
    }
    if (arg == "--metrics-max-files") {
      if (i + 1 >= argc) {
        std::cerr << "--metrics-max-files requires a value\n";
        return false;
      }
      options->metrics_max_files =
          static_cast<uint32_t>(std::max(1, std::atoi(argv[++i])));
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
    if (arg == "--alerts-max-file-bytes") {
      if (i + 1 >= argc) {
        std::cerr << "--alerts-max-file-bytes requires a value\n";
        return false;
      }
      options->alerts_max_file_bytes =
          static_cast<uint64_t>(std::strtoull(argv[++i], nullptr, 10));
      continue;
    }
    if (arg == "--alerts-max-files") {
      if (i + 1 >= argc) {
        std::cerr << "--alerts-max-files requires a value\n";
        return false;
      }
      options->alerts_max_files =
          static_cast<uint32_t>(std::max(1, std::atoi(argv[++i])));
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
    const CommonOptions& options) {
  webrtc_qos::RuntimeLogConfig config;
  if (!options.log_dir.empty()) {
    config.file.enabled = true;
    config.file.directory = options.log_dir;
    config.file.basename = "minimal_udp";
    config.file.json_lines = true;
    config.file.also_stderr = false;
    config.file.max_file_bytes = options.log_max_file_bytes;
    config.file.max_files = options.log_max_files;
    config.max_queue_records = options.log_max_queue_records;
  }
  return config;
}

inline webrtc_qos::RuntimeMetricsConfig MakeMetricsConfig(
    const CommonOptions& options) {
  webrtc_qos::RuntimeMetricsConfig config;
  if (!options.metrics_dir.empty()) {
    config.file.enabled = true;
    config.file.directory = options.metrics_dir;
    config.file.basename = "minimal_udp_metrics";
    config.file.max_file_bytes = options.metrics_max_file_bytes;
    config.file.max_files = options.metrics_max_files;
    config.interval_ms = 100;
    config.include_track_snapshots = true;
  }
  return config;
}

inline webrtc_qos::RuntimeAlertConfig MakeAlertConfig(
    const CommonOptions& options) {
  webrtc_qos::RuntimeAlertConfig config;
  if (!options.alerts_dir.empty()) {
    config.file.enabled = true;
    config.file.directory = options.alerts_dir;
    config.file.basename = "minimal_udp_alerts";
    config.file.max_file_bytes = options.alerts_max_file_bytes;
    config.file.max_files = options.alerts_max_files;
    config.suppress_repeated_alerts_ms = 0;
    config.high_loss_fraction_q8 = 128;
    config.video_drop_frames_threshold = 1;
    config.low_target_bps = 700000;
    config.low_encoder_fps = 20;
  }
  return config;
}

}  // namespace minimal_udp
