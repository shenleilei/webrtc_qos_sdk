#pragma once

#include <cstdint>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>

#include "webrtc_qos/runtime_logging.h"
#include "webrtc_qos/status.h"
#include "webrtc_qos/types.h"

namespace webrtc_qos {

class RuntimeLogger {
 public:
  RuntimeLogger() = default;
  RuntimeLogger(RuntimeLogConfig config, std::string role);
  ~RuntimeLogger();

  RuntimeLogger(const RuntimeLogger&) = delete;
  RuntimeLogger& operator=(const RuntimeLogger&) = delete;

  void Info(const char* event, const TransportIds& ids);
  void Warn(const char* event, const TransportIds& ids, const Status& status);
  void Error(const char* event, const TransportIds& ids, const Status& status);
  void Flush();

 private:
  void Log(LogLevel level,
           const char* event,
           const TransportIds& ids,
           const Status* status);
  void RotateIfNeededLocked();
  bool ShouldLog(LogLevel level) const;

  RuntimeLogConfig config_;
  std::string role_;
  std::string path_prefix_;
  uint32_t file_index_ = 0;
  uint64_t current_file_bytes_ = 0;
  std::ofstream file_;
  std::mutex mutex_;
};

std::string StatusCodeName(StatusCode code);

}  // namespace webrtc_qos
