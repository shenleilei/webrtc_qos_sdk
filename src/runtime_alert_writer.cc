#include "runtime_alert_writer.h"

#include <atomic>
#include <chrono>
#include <ctime>
#include <filesystem>
#include <iomanip>
#include <sstream>
#include <string>
#include <utility>

#include <unistd.h>

namespace webrtc_qos {
namespace {

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

uint64_t NextAlertInstance() {
  static std::atomic<uint64_t> counter {0};
  return counter.fetch_add(1, std::memory_order_relaxed);
}

std::string BaseName(const FileAlertsConfig& config) {
  if (!config.basename.empty()) {
    return config.basename;
  }
  return "webrtc_qos_alerts";
}

const char* SeverityName(AlertSeverity severity) {
  switch (severity) {
    case AlertSeverity::kInfo:
      return "INFO";
    case AlertSeverity::kWarn:
      return "WARN";
    case AlertSeverity::kError:
      return "ERROR";
  }
  return "UNKNOWN";
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

int64_t AlertTimeUs(int64_t now_us) {
  return now_us > 0 ? now_us : WallClockNowUs();
}

}  // namespace

RuntimeAlertWriter::RuntimeAlertWriter(RuntimeAlertConfig config,
                                       std::string role)
    : config_(std::move(config)), role_(std::move(role)) {
  if (!config_.file.enabled) {
    return;
  }
  if (config_.file.directory.empty()) {
    init_status_ = Status::Error(StatusCode::kInvalidArgument,
                                 "runtime alerts directory is required");
    return;
  }
  std::error_code error;
  std::filesystem::create_directories(config_.file.directory, error);
  if (error) {
    init_status_ = Status::Error(StatusCode::kInternalError,
                                 "runtime alerts directory is not writable");
    return;
  }

  std::ostringstream prefix;
  prefix << config_.file.directory << "/" << BaseName(config_.file) << "."
         << role_ << "." << static_cast<long long>(getpid()) << "."
         << TimestampForPath() << "-" << WallClockNowUs() << "-"
         << NextAlertInstance();
  path_prefix_ = prefix.str();
  if (!RotateIfNeededLocked()) {
    init_status_ =
        Status::Error(StatusCode::kInternalError,
                      "runtime alerts file could not be opened");
    path_prefix_.clear();
  }
}

RuntimeAlertWriter::~RuntimeAlertWriter() {
  Flush();
}

void RuntimeAlertWriter::Warn(const char* rule,
                              const char* category,
                              const TransportIds& ids,
                              int64_t now_us,
                              double value,
                              double threshold) {
  Write(AlertSeverity::kWarn, rule, category, ids, now_us, value, threshold,
        nullptr);
}

void RuntimeAlertWriter::Error(const char* rule,
                               const char* category,
                               const TransportIds& ids,
                               int64_t now_us,
                               const Status& status) {
  Write(AlertSeverity::kError, rule, category, ids, now_us, 0, 0, &status);
}

void RuntimeAlertWriter::Flush() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (file_.is_open()) {
    file_.flush();
  }
}

void RuntimeAlertWriter::Write(AlertSeverity severity,
                               const char* rule,
                               const char* category,
                               const TransportIds& ids,
                               int64_t now_us,
                               double value,
                               double threshold,
                               const Status* status) {
  if (!config_.file.enabled || path_prefix_.empty()) {
    return;
  }
  const int64_t alert_time_us = AlertTimeUs(now_us);
  std::lock_guard<std::mutex> lock(mutex_);
  if (SuppressedLocked(rule, ids, alert_time_us)) {
    return;
  }

  std::ostringstream line;
  line << "{\"ts_us\":" << alert_time_us
       << ",\"severity\":\"" << SeverityName(severity) << "\""
       << ",\"role\":\"" << EscapeJson(role_) << "\""
       << ",\"rule\":\"" << EscapeJson(rule == nullptr ? "" : rule) << "\""
       << ",\"category\":\""
       << EscapeJson(category == nullptr ? "" : category) << "\""
       << ",\"session_id\":" << ids.session_id
       << ",\"stream_id\":" << ids.stream_id
       << ",\"transport_id\":" << ids.transport_id
       << ",\"source_id\":" << ids.source_id
       << ",\"track_id\":" << ids.track_id
       << ",\"sender_ssrc\":" << ids.sender_ssrc
       << ",\"receiver_id\":" << ids.receiver_id;
  if (status != nullptr) {
    line << ",\"status_code\":\"" << StatusCodeName(status->code)
         << "\",\"reason\":\"" << EscapeJson(status->message) << "\"";
  } else {
    line << ",\"value\":" << value << ",\"threshold\":" << threshold;
  }
  line << "}\n";

  const std::string text = line.str();
  RotateIfNeededLocked();
  if (file_.is_open()) {
    file_ << text;
    current_file_bytes_ += text.size();
  }
}

bool RuntimeAlertWriter::SuppressedLocked(const char* rule,
                                          const TransportIds& ids,
                                          int64_t now_us) {
  const int64_t suppress_us =
      static_cast<int64_t>(config_.suppress_repeated_alerts_ms) * 1000;
  if (suppress_us <= 0) {
    return false;
  }
  std::ostringstream key;
  key << (rule == nullptr ? "" : rule) << ":" << ids.session_id << ":"
      << ids.stream_id << ":" << ids.source_id << ":" << ids.track_id << ":"
      << ids.sender_ssrc << ":" << ids.receiver_id;
  auto found = last_alert_time_us_.find(key.str());
  if (found != last_alert_time_us_.end() && now_us - found->second < suppress_us) {
    return true;
  }
  last_alert_time_us_[key.str()] = now_us;
  return false;
}

bool RuntimeAlertWriter::RotateIfNeededLocked() {
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
  const uint32_t max_files =
      config_.file.max_files == 0 ? 1 : config_.file.max_files;
  if (file_index_ >= max_files) {
    file_index_ = 0;
  }
  std::ostringstream path;
  path << path_prefix_ << "." << file_index_ << ".jsonl";
  ++file_index_;
  current_file_bytes_ = 0;
  file_.open(path.str(), std::ios::out | std::ios::trunc);
  return file_.is_open();
}

}  // namespace webrtc_qos
