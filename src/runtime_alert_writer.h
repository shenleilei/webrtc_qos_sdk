#pragma once

#include <cstdint>
#include <fstream>
#include <map>
#include <mutex>
#include <string>

#include "webrtc_qos/runtime_alerts.h"
#include "webrtc_qos/status.h"
#include "webrtc_qos/types.h"

namespace webrtc_qos {

class RuntimeAlertWriter {
 public:
  RuntimeAlertWriter() = default;
  RuntimeAlertWriter(RuntimeAlertConfig config, std::string role);
  ~RuntimeAlertWriter();

  RuntimeAlertWriter(const RuntimeAlertWriter&) = delete;
  RuntimeAlertWriter& operator=(const RuntimeAlertWriter&) = delete;

  void Warn(const char* rule,
            const char* category,
            const TransportIds& ids,
            int64_t now_us,
            double value,
            double threshold);
  void Error(const char* rule,
             const char* category,
             const TransportIds& ids,
             int64_t now_us,
             const Status& status);
  void Flush();

  const RuntimeAlertConfig& config() const { return config_; }

 private:
  void Write(AlertSeverity severity,
             const char* rule,
             const char* category,
             const TransportIds& ids,
             int64_t now_us,
             double value,
             double threshold,
             const Status* status);
  bool SuppressedLocked(const char* rule,
                        const TransportIds& ids,
                        int64_t now_us);
  void RotateIfNeededLocked();

  RuntimeAlertConfig config_;
  std::string role_;
  std::string path_prefix_;
  uint32_t file_index_ = 0;
  uint64_t current_file_bytes_ = 0;
  std::ofstream file_;
  std::map<std::string, int64_t> last_alert_time_us_;
  std::mutex mutex_;
};

}  // namespace webrtc_qos
