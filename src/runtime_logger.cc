#include "runtime_logger.h"

#include <atomic>
#include <chrono>
#include <algorithm>
#include <cstdio>
#include <ctime>
#include <filesystem>
#include <iomanip>
#include <sstream>
#include <string>

#include <unistd.h>

namespace webrtc_qos {
namespace {

const char* LogLevelName(LogLevel level) {
  switch (level) {
    case LogLevel::kTrace:
      return "TRACE";
    case LogLevel::kDebug:
      return "DEBUG";
    case LogLevel::kInfo:
      return "INFO";
    case LogLevel::kWarn:
      return "WARN";
    case LogLevel::kError:
      return "ERROR";
    case LogLevel::kOff:
      return "OFF";
  }
  return "UNKNOWN";
}

int64_t WallClockNowUs() {
  const auto now = std::chrono::system_clock::now().time_since_epoch();
  return std::chrono::duration_cast<std::chrono::microseconds>(now).count();
}

std::string TimestampForPath() {
  const std::time_t now = std::time(nullptr);
  std::tm tm {};
  localtime_r(&now, &tm);
  std::ostringstream out;
  out << std::put_time(&tm, "%Y%m%d-%H%M%S");
  return out.str();
}

uint64_t NextLoggerInstance() {
  static std::atomic<uint64_t> counter {0};
  return counter.fetch_add(1, std::memory_order_relaxed);
}

std::string EscapeJson(const std::string& value) {
  std::string out;
  out.reserve(value.size() + 8);
  for (char ch : value) {
    switch (ch) {
      case '\\':
        out += "\\\\";
        break;
      case '"':
        out += "\\\"";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        out += ch;
        break;
    }
  }
  return out;
}

std::string BaseName(const FileLogConfig& config) {
  if (!config.basename.empty()) {
    return config.basename;
  }
  return "webrtc_qos";
}

void AddDroppedLogCount(std::string* text,
                        uint64_t dropped_log_count,
                        bool json_lines) {
  if (text == nullptr || dropped_log_count == 0) {
    return;
  }
  if (json_lines) {
    const std::string field =
        ",\"dropped_log_count\":" + std::to_string(dropped_log_count);
    const size_t insert_pos =
        text->size() >= 2 && (*text)[text->size() - 2] == '}'
            ? text->size() - 2
            : text->size();
    text->insert(insert_pos, field);
    return;
  }
  const std::string field =
      " dropped_log_count=" + std::to_string(dropped_log_count);
  const size_t insert_pos =
      !text->empty() && text->back() == '\n' ? text->size() - 1 : text->size();
  text->insert(insert_pos, field);
}

}  // namespace

std::string StatusCodeName(StatusCode code) {
  switch (code) {
    case StatusCode::kOk:
      return "ok";
    case StatusCode::kInvalidArgument:
      return "invalid_argument";
    case StatusCode::kUnsupported:
      return "unsupported";
    case StatusCode::kMalformedPacket:
      return "malformed_packet";
    case StatusCode::kQueueFull:
      return "queue_full";
    case StatusCode::kInternalError:
      return "internal_error";
  }
  return "unknown";
}

std::string RuntimeConfigDumpFields(const SessionConfig& session,
                                    const RuntimeLogConfig& logging,
                                    const RuntimeMetricsConfig& metrics,
                                    const RuntimeAlertConfig& alerts,
                                    size_t resolved_track_count) {
  std::ostringstream fields;
  fields << "\"schema_version\":1"
         << ",\"transport\":\"udp\""
         << ",\"peer_connection\":false"
         << ",\"resolved_track_count\":" << resolved_track_count
         << ",\"start_bitrate_bps\":" << session.start_bitrate_bps
         << ",\"min_bitrate_bps\":" << session.min_bitrate_bps
         << ",\"max_bitrate_bps\":" << session.max_bitrate_bps
         << ",\"twcc_extension_id\":"
         << static_cast<uint32_t>(session.twcc.extension_id)
         << ",\"rtcp_sr_rr_interval_ms\":"
         << session.rtcp.sr_rr_interval_ms
         << ",\"logging_enabled\":"
         << (logging.file.enabled ? "true" : "false")
         << ",\"log_json_lines\":"
         << (logging.file.json_lines ? "true" : "false")
         << ",\"log_max_file_bytes\":" << logging.file.max_file_bytes
         << ",\"log_max_files\":" << logging.file.max_files
         << ",\"log_max_queue_records\":"
         << logging.max_queue_records
         << ",\"metrics_enabled\":"
         << (metrics.file.enabled ? "true" : "false")
         << ",\"metrics_interval_ms\":" << metrics.interval_ms
         << ",\"metrics_include_track_snapshots\":"
         << (metrics.include_track_snapshots ? "true" : "false")
         << ",\"alerts_enabled\":"
         << (alerts.file.enabled ? "true" : "false")
         << ",\"alerts_high_loss_fraction_q8\":"
         << alerts.high_loss_fraction_q8
         << ",\"alerts_low_target_bps\":" << alerts.low_target_bps
         << ",\"alerts_low_encoder_fps\":" << alerts.low_encoder_fps
         << ",\"alerts_max_process_tick_gap_ms\":"
         << alerts.max_process_tick_gap_ms
         << ",\"alerts_max_rtp_output_gap_ms\":"
         << alerts.max_rtp_output_gap_ms
         << ",\"alerts_max_rtp_input_gap_ms\":"
         << alerts.max_rtp_input_gap_ms
         << ",\"alerts_media_flow_gap_enabled\":"
         << (alerts.alert_on_media_flow_gap ? "true" : "false")
         << ",\"alerts_consecutive_transport_failures_threshold\":"
         << alerts.consecutive_transport_failures_threshold
         << ",\"redaction_media_bytes\":\"omitted\""
         << ",\"redaction_runtime_paths\":\"omitted\"";
  return fields.str();
}

RuntimeLogger::RuntimeLogger(RuntimeLogConfig config, std::string role)
    : config_(config), role_(std::move(role)) {
  if (!config_.file.enabled) {
    return;
  }
  if (config_.file.directory.empty()) {
    init_status_ = Status::Error(StatusCode::kInvalidArgument,
                                 "runtime log directory is required");
    return;
  }
  std::error_code error;
  std::filesystem::create_directories(config_.file.directory, error);
  if (error) {
    init_status_ = Status::Error(StatusCode::kInternalError,
                                 "runtime log directory is not writable");
    return;
  }

  std::ostringstream prefix;
  prefix << config_.file.directory << "/" << BaseName(config_.file) << "."
         << role_ << "." << static_cast<long long>(getpid()) << "."
         << TimestampForPath() << "-" << WallClockNowUs() << "-"
         << NextLoggerInstance();
  path_prefix_ = prefix.str();
  if (!RotateIfNeededLocked()) {
    init_status_ =
        Status::Error(StatusCode::kInternalError,
                      "runtime log file could not be opened");
    path_prefix_.clear();
    return;
  }
  if (IsAsyncEnabled()) {
    worker_ = std::thread(&RuntimeLogger::WorkerLoop, this);
  }
}

RuntimeLogger::~RuntimeLogger() {
  Flush();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  queue_cv_.notify_all();
  if (worker_.joinable()) {
    worker_.join();
  }
  Flush();
}

void RuntimeLogger::Info(const char* event, const TransportIds& ids) {
  Log(LogLevel::kInfo, event, ids, nullptr);
}

void RuntimeLogger::Info(const char* event,
                         const TransportIds& ids,
                         const std::string& extra_json_fields) {
  Log(LogLevel::kInfo, event, ids, nullptr, &extra_json_fields);
}

void RuntimeLogger::Warn(const char* event,
                         const TransportIds& ids,
                         const Status& status) {
  Log(LogLevel::kWarn, event, ids, &status);
}

void RuntimeLogger::Error(const char* event,
                          const TransportIds& ids,
                          const Status& status) {
  Log(LogLevel::kError, event, ids, &status);
}

void RuntimeLogger::Flush() {
  std::unique_lock<std::mutex> lock(mutex_);
  flush_cv_.wait(lock, [this] {
    return queue_.empty() && !worker_active_;
  });
  if (file_.is_open()) {
    file_.flush();
  }
}

void RuntimeLogger::Log(LogLevel level,
                        const char* event,
                        const TransportIds& ids,
                        const Status* status,
                        const std::string* extra_json_fields) {
  if (!ShouldLog(level)) {
    return;
  }
  std::ostringstream line;
  if (config_.file.json_lines) {
    line << "{\"ts_us\":" << WallClockNowUs() << ",\"level\":\""
         << LogLevelName(level) << "\",\"role\":\"" << EscapeJson(role_)
         << "\",\"event\":\"" << EscapeJson(event == nullptr ? "" : event)
         << "\",\"session_id\":" << ids.session_id
         << ",\"stream_id\":" << ids.stream_id
         << ",\"transport_id\":" << ids.transport_id
         << ",\"source_id\":" << ids.source_id
         << ",\"track_id\":" << ids.track_id
         << ",\"sender_ssrc\":" << ids.sender_ssrc
         << ",\"receiver_id\":" << ids.receiver_id;
    if (status != nullptr) {
      line << ",\"status_code\":\"" << StatusCodeName(status->code)
           << "\",\"reason\":\"" << EscapeJson(status->message) << "\"";
    }
    if (extra_json_fields != nullptr && !extra_json_fields->empty()) {
      line << "," << *extra_json_fields;
    }
    line << "}\n";
  } else {
    line << WallClockNowUs() << " " << LogLevelName(level) << " " << role_
         << " event=" << (event == nullptr ? "" : event)
         << " session_id=" << ids.session_id << " stream_id=" << ids.stream_id
         << " transport_id=" << ids.transport_id
         << " source_id=" << ids.source_id << " track_id=" << ids.track_id
         << " sender_ssrc=" << ids.sender_ssrc
         << " receiver_id=" << ids.receiver_id;
    if (status != nullptr) {
      line << " status_code=" << StatusCodeName(status->code)
           << " reason=" << status->message;
    }
    if (extra_json_fields != nullptr && !extra_json_fields->empty()) {
      line << " extra_json_fields={" << *extra_json_fields << "}";
    }
    line << "\n";
  }

  const std::string text = line.str();
  QueuedLogRecord record;
  record.level = level;
  record.preserve = level >= LogLevel::kWarn ||
                    (event != nullptr && std::string(event) == "stop");
  record.text = text;

  std::unique_lock<std::mutex> lock(mutex_);
  if (IsAsyncEnabled()) {
    const uint32_t max_queue_records = MaxQueueRecords();
    if (queue_.size() >= max_queue_records) {
      if (!record.preserve) {
        ++pending_dropped_log_count_;
        return;
      }
      while (queue_.size() >= max_queue_records) {
        auto low_priority = std::find_if(queue_.begin(), queue_.end(),
                                         [](const QueuedLogRecord& queued) {
                                           return !queued.preserve;
                                         });
        if (low_priority == queue_.end()) {
          flush_cv_.wait(lock, [this, max_queue_records] {
            return queue_.size() < max_queue_records;
          });
          continue;
        }
        queue_.erase(low_priority);
        ++pending_dropped_log_count_;
      }
    }
    if (pending_dropped_log_count_ > 0) {
      AddDroppedLogCount(&record.text, pending_dropped_log_count_,
                         config_.file.json_lines);
      pending_dropped_log_count_ = 0;
    }
    queue_.push_back(std::move(record));
    lock.unlock();
    queue_cv_.notify_one();
  } else {
    WriteRecordLocked(record);
  }
}

void RuntimeLogger::WorkerLoop() {
  for (;;) {
    QueuedLogRecord record;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      queue_cv_.wait(lock, [this] {
        return stopping_ || !queue_.empty();
      });
      if (queue_.empty() && stopping_) {
        flush_cv_.notify_all();
        return;
      }
      record = std::move(queue_.front());
      queue_.pop_front();
      worker_active_ = true;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      WriteRecordLocked(record);
      worker_active_ = false;
      flush_cv_.notify_all();
    }
  }
}

void RuntimeLogger::WriteRecordLocked(const QueuedLogRecord& record) {
  RotateIfNeededLocked();
  if (file_.is_open()) {
    file_ << record.text;
    current_file_bytes_ += record.text.size();
  }
}

bool RuntimeLogger::RotateIfNeededLocked() {
  if (path_prefix_.empty()) {
    return false;
  }
  const uint64_t max_file_bytes =
      config_.file.max_file_bytes == 0 ? 64 * 1024 * 1024
                                       : config_.file.max_file_bytes;
  if (file_.is_open() && current_file_bytes_ < max_file_bytes) {
    return true;
  }
  if (file_.is_open()) {
    file_.flush();
    file_.close();
  }
  const uint32_t max_files = config_.file.max_files == 0 ? 1 : config_.file.max_files;
  if (file_index_ >= max_files) {
    file_index_ = 0;
  }
  std::ostringstream path;
  path << path_prefix_ << "." << file_index_ << ".log";
  ++file_index_;
  current_file_bytes_ = 0;
  file_.open(path.str(), std::ios::out | std::ios::trunc);
  return file_.is_open();
}

bool RuntimeLogger::ShouldLog(LogLevel level) const {
  const bool can_write_file = config_.file.enabled && !path_prefix_.empty();
  if (!can_write_file) {
    return false;
  }
  return level >= config_.min_level && config_.min_level != LogLevel::kOff;
}

uint32_t RuntimeLogger::MaxQueueRecords() const {
  return config_.max_queue_records == 0 ? 1 : config_.max_queue_records;
}

bool RuntimeLogger::IsAsyncEnabled() const {
  return config_.file.enabled && !path_prefix_.empty();
}

}  // namespace webrtc_qos
