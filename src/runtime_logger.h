#pragma once

#include <cstdint>
#include <condition_variable>
#include <deque>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>

#include "webrtc_qos/runtime_logging.h"
#include "webrtc_qos/runtime_alerts.h"
#include "webrtc_qos/runtime_metrics.h"
#include "webrtc_qos/session_config.h"
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
  void Info(const char* event,
            const TransportIds& ids,
            const std::string& extra_json_fields);
  void Warn(const char* event, const TransportIds& ids, const Status& status);
  void Error(const char* event, const TransportIds& ids, const Status& status);
  void Flush();
  const Status& InitializationStatus() const { return init_status_; }

 private:
  struct QueuedLogRecord {
    LogLevel level = LogLevel::kInfo;
    bool preserve = false;
    std::string text;
  };

  void Log(LogLevel level,
           const char* event,
           const TransportIds& ids,
           const Status* status,
           const std::string* extra_json_fields = nullptr);
  void WorkerLoop();
  void WriteRecordLocked(const QueuedLogRecord& record);
  bool RotateIfNeededLocked();
  bool ShouldLog(LogLevel level) const;
  uint32_t MaxQueueRecords() const;
  bool IsAsyncEnabled() const;

  RuntimeLogConfig config_;
  Status init_status_ = Status::Ok();
  std::string role_;
  std::string path_prefix_;
  uint32_t file_index_ = 0;
  uint64_t current_file_bytes_ = 0;
  std::ofstream file_;
  std::deque<QueuedLogRecord> queue_;
  std::thread worker_;
  std::mutex mutex_;
  std::condition_variable queue_cv_;
  std::condition_variable flush_cv_;
  bool stopping_ = false;
  bool worker_active_ = false;
  uint64_t pending_dropped_log_count_ = 0;
};

std::string StatusCodeName(StatusCode code);
std::string RuntimeConfigDumpFields(const SessionConfig& session,
                                    const RuntimeLogConfig& logging,
                                    const RuntimeMetricsConfig& metrics,
                                    const RuntimeAlertConfig& alerts,
                                    size_t resolved_track_count);

}  // namespace webrtc_qos
