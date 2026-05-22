#include "runtime_logger.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <filesystem>
#include <iomanip>
#include <iostream>
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

RuntimeLogger::RuntimeLogger(RuntimeLogConfig config, std::string role)
    : config_(config), role_(std::move(role)) {
  if (!config_.file.enabled || config_.file.directory.empty()) {
    return;
  }
  std::error_code error;
  std::filesystem::create_directories(config_.file.directory, error);
  if (error) {
    return;
  }

  std::ostringstream prefix;
  prefix << config_.file.directory << "/" << BaseName(config_.file) << "."
         << role_ << "." << static_cast<long long>(getpid()) << "."
         << TimestampForPath() << "-" << WallClockNowUs() << "-"
         << NextLoggerInstance();
  path_prefix_ = prefix.str();
  RotateIfNeededLocked();
}

RuntimeLogger::~RuntimeLogger() {
  Flush();
}

void RuntimeLogger::Info(const char* event, const TransportIds& ids) {
  Log(LogLevel::kInfo, event, ids, nullptr);
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
  std::lock_guard<std::mutex> lock(mutex_);
  if (file_.is_open()) {
    file_.flush();
  }
}

void RuntimeLogger::Log(LogLevel level,
                        const char* event,
                        const TransportIds& ids,
                        const Status* status) {
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
    line << "\n";
  }

  const std::string text = line.str();
  std::lock_guard<std::mutex> lock(mutex_);
  RotateIfNeededLocked();
  if (file_.is_open()) {
    file_ << text;
    current_file_bytes_ += text.size();
  }
  if (config_.file.also_stderr) {
    std::cerr << text;
  }
}

void RuntimeLogger::RotateIfNeededLocked() {
  if (path_prefix_.empty()) {
    return;
  }
  const uint64_t max_file_bytes =
      config_.file.max_file_bytes == 0 ? 64 * 1024 * 1024
                                       : config_.file.max_file_bytes;
  if (file_.is_open() && current_file_bytes_ < max_file_bytes) {
    return;
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
}

bool RuntimeLogger::ShouldLog(LogLevel level) const {
  if (!config_.file.enabled && !config_.file.also_stderr) {
    return false;
  }
  return level >= config_.min_level && config_.min_level != LogLevel::kOff;
}

}  // namespace webrtc_qos
