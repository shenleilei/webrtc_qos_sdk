#include "runtime_metrics_writer.h"

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

uint64_t NextMetricsInstance() {
  static std::atomic<uint64_t> counter {0};
  return counter.fetch_add(1, std::memory_order_relaxed);
}

std::string BaseName(const FileMetricsConfig& config) {
  if (!config.basename.empty()) {
    return config.basename;
  }
  return "webrtc_qos_metrics";
}

uint64_t SafeTimeUs(uint64_t report_time_us) {
  return report_time_us == 0 ? static_cast<uint64_t>(WallClockNowUs())
                             : report_time_us;
}

uint32_t AdaptationTargetBps(const EncoderAdaptation* adaptation) {
  return adaptation == nullptr ? 0 : adaptation->target_bitrate_bps;
}

uint32_t AdaptationFps(const EncoderAdaptation* adaptation) {
  return adaptation == nullptr ? 0 : adaptation->max_fps;
}

bool AdaptationKeyframe(const EncoderAdaptation* adaptation) {
  return adaptation != nullptr && adaptation->request_keyframe;
}

}  // namespace

RuntimeMetricsWriter::RuntimeMetricsWriter(RuntimeMetricsConfig config,
                                           std::string role)
    : config_(std::move(config)), role_(std::move(role)) {
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
         << NextMetricsInstance();
  path_prefix_ = prefix.str();
  RotateIfNeededLocked();
}

RuntimeMetricsWriter::~RuntimeMetricsWriter() {
  Flush();
}

bool RuntimeMetricsWriter::ShouldWrite(int64_t now_us) const {
  if (!config_.file.enabled || path_prefix_.empty()) {
    return false;
  }
  const int64_t interval_us =
      static_cast<int64_t>(config_.interval_ms == 0 ? 1000
                                                   : config_.interval_ms) *
      1000;
  std::lock_guard<std::mutex> lock(mutex_);
  if (next_write_time_us_ != 0 && now_us < next_write_time_us_) {
    return false;
  }
  next_write_time_us_ = now_us + interval_us;
  return true;
}

void RuntimeMetricsWriter::WriteSession(
    const QosSnapshot& snapshot,
    const EncoderAdaptation* adaptation) {
  Write("session", snapshot, adaptation);
}

void RuntimeMetricsWriter::WriteTrack(
    const QosSnapshot& snapshot,
    const EncoderAdaptation* adaptation) {
  Write("track", snapshot, adaptation);
}

void RuntimeMetricsWriter::Flush() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (file_.is_open()) {
    file_.flush();
  }
}

void RuntimeMetricsWriter::Write(const char* scope,
                                 const QosSnapshot& snapshot,
                                 const EncoderAdaptation* adaptation) {
  if (!config_.file.enabled || path_prefix_.empty()) {
    return;
  }

  const TransportIds& ids = snapshot.ids;
  const DownlinkQuality& quality = snapshot.downlink_quality;
  const TargetRates& rates = snapshot.sender_rates;
  std::ostringstream line;
  line << "{\"ts_us\":" << SafeTimeUs(snapshot.report_time_us)
       << ",\"role\":\"" << role_ << "\""
       << ",\"scope\":\"" << scope << "\""
       << ",\"session_id\":" << ids.session_id
       << ",\"stream_id\":" << ids.stream_id
       << ",\"transport_id\":" << ids.transport_id
       << ",\"source_id\":" << ids.source_id
       << ",\"track_id\":" << ids.track_id
       << ",\"sender_ssrc\":" << ids.sender_ssrc
       << ",\"receiver_id\":" << ids.receiver_id
       << ",\"googcc_target_bps\":" << rates.googcc_target_bps
       << ",\"pacing_bps\":" << rates.pacing_bps
       << ",\"sender_rate_cap_bps\":" << rates.sender_rate_cap_bps
       << ",\"final_target_bps\":" << rates.final_target_bps
       << ",\"rtt_ms\":" << rates.rtt_ms
       << ",\"loss_fraction\":" << rates.loss_fraction
       << ",\"adaptation_target_bps\":" << AdaptationTargetBps(adaptation)
       << ",\"adaptation_max_fps\":" << AdaptationFps(adaptation)
       << ",\"request_keyframe\":"
       << (AdaptationKeyframe(adaptation) ? "true" : "false")
       << ",\"downlink_fraction_lost_q8\":" << quality.fraction_lost_q8
       << ",\"downlink_recv_bitrate_bps\":" << quality.recv_bitrate_bps
       << ",\"downlink_video_drop_frames\":" << quality.video_drop_frames
       << ",\"nack_count\":" << snapshot.nack_count
       << ",\"pli_count\":" << snapshot.pli_count
       << ",\"retransmission_count\":" << snapshot.retransmission_count
       << ",\"dropped_retransmission_packets\":"
       << snapshot.dropped_retransmission_packets
       << ",\"unsupported_rtcp_packet_count\":"
       << snapshot.unsupported_rtcp_packet_count
       << ",\"dropped_frames\":" << snapshot.dropped_frames
       << ",\"jitter_buffer_delay_ms\":" << snapshot.jitter_buffer_delay_ms
       << ",\"emitted_probe_packets\":" << snapshot.emitted_probe_packets
       << ",\"emitted_probe_bytes\":" << snapshot.emitted_probe_bytes
       << ",\"emitted_padding_packets\":" << snapshot.emitted_padding_packets
       << ",\"emitted_padding_bytes\":" << snapshot.emitted_padding_bytes
       << ",\"last_probe_cluster_id\":" << snapshot.last_probe_cluster_id
       << ",\"process_tick_count\":" << snapshot.process_tick_count
       << ",\"process_tick_gap_us\":" << snapshot.process_tick_gap_us
       << ",\"max_process_tick_gap_us\":" << snapshot.max_process_tick_gap_us
       << ",\"rtp_output_gap_us\":" << snapshot.rtp_output_gap_us
       << ",\"max_rtp_output_gap_us\":" << snapshot.max_rtp_output_gap_us
       << ",\"rtp_input_gap_us\":" << snapshot.rtp_input_gap_us
       << ",\"max_rtp_input_gap_us\":" << snapshot.max_rtp_input_gap_us
       << "}\n";

  const std::string text = line.str();
  std::lock_guard<std::mutex> lock(mutex_);
  RotateIfNeededLocked();
  if (file_.is_open()) {
    file_ << text;
    current_file_bytes_ += text.size();
  }
}

void RuntimeMetricsWriter::RotateIfNeededLocked() {
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
}

}  // namespace webrtc_qos
