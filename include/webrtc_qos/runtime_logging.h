#pragma once

#include <cstdint>
#include <string>

namespace webrtc_qos {

enum class LogLevel {
  kTrace = 0,
  kDebug = 1,
  kInfo = 2,
  kWarn = 3,
  kError = 4,
  kOff = 5,
};

struct FileLogConfig {
  bool enabled = false;
  std::string directory;
  std::string basename = "webrtc_qos";
  uint64_t max_file_bytes = 64 * 1024 * 1024;
  uint32_t max_files = 5;
  bool json_lines = true;
  bool also_stderr = false;
};

struct RuntimeLogConfig {
  LogLevel min_level = LogLevel::kInfo;
  FileLogConfig file;
  uint32_t max_queue_records = 4096;
};

}  // namespace webrtc_qos
