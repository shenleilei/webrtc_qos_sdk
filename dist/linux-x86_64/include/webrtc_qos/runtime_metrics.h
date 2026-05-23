#pragma once

#include <cstdint>
#include <string>

namespace webrtc_qos {

struct FileMetricsConfig {
  bool enabled = false;
  std::string directory;
  std::string basename = "webrtc_qos_metrics";
  uint64_t max_file_bytes = 64 * 1024 * 1024;
  uint32_t max_files = 5;
};

struct RuntimeMetricsConfig {
  FileMetricsConfig file;
  uint32_t interval_ms = 1000;
  bool include_track_snapshots = true;
};

}  // namespace webrtc_qos
