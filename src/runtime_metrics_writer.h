#pragma once

#include <cstdint>
#include <fstream>
#include <mutex>
#include <string>

#include "webrtc_qos/qos_metrics.h"
#include "webrtc_qos/runtime_metrics.h"
#include "webrtc_qos/status.h"
#include "webrtc_qos/types.h"

namespace webrtc_qos {

class RuntimeMetricsWriter {
 public:
  RuntimeMetricsWriter() = default;
  RuntimeMetricsWriter(RuntimeMetricsConfig config, std::string role);
  ~RuntimeMetricsWriter();

  RuntimeMetricsWriter(const RuntimeMetricsWriter&) = delete;
  RuntimeMetricsWriter& operator=(const RuntimeMetricsWriter&) = delete;

  bool ShouldWrite(int64_t now_us) const;
  bool include_track_snapshots() const {
    return config_.include_track_snapshots;
  }

  void WriteSession(const QosSnapshot& snapshot,
                    const EncoderAdaptation* adaptation = nullptr);
  void WriteTrack(const QosSnapshot& snapshot,
                  const EncoderAdaptation* adaptation = nullptr);
  void Flush();
  const Status& InitializationStatus() const { return init_status_; }

 private:
  void Write(const char* scope,
             const QosSnapshot& snapshot,
             const EncoderAdaptation* adaptation);
  bool RotateIfNeededLocked();

  RuntimeMetricsConfig config_;
  Status init_status_ = Status::Ok();
  std::string role_;
  std::string path_prefix_;
  uint32_t file_index_ = 0;
  uint64_t current_file_bytes_ = 0;
  mutable int64_t next_write_time_us_ = 0;
  std::ofstream file_;
  mutable std::mutex mutex_;
};

}  // namespace webrtc_qos
