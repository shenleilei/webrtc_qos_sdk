#pragma once

#include <cstdint>
#include <string>

namespace webrtc_qos {

enum class AlertSeverity {
  kInfo = 1,
  kWarn = 2,
  kError = 3,
};

struct FileAlertsConfig {
  bool enabled = false;
  std::string directory;
  std::string basename = "webrtc_qos_alerts";
  uint64_t max_file_bytes = 64 * 1024 * 1024;
  uint32_t max_files = 5;
};

struct RuntimeAlertConfig {
  FileAlertsConfig file;
  uint32_t suppress_repeated_alerts_ms = 1000;

  bool alert_on_qos_degradation = true;
  bool alert_on_recovery_events = true;
  bool alert_on_malformed_packet = true;
  bool alert_on_transport_failure = true;
  bool alert_on_media_failure = true;

  uint16_t high_loss_fraction_q8 = 128;
  uint16_t video_drop_frames_threshold = 1;
  uint32_t low_target_bps = 700000;
  uint32_t low_encoder_fps = 20;
};

}  // namespace webrtc_qos
