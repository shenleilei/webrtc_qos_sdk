#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}"
BUILD_DIR="${BUILD_DIR:-/tmp/webrtc_qos_phase5_release_contract_build.$$}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/tmp/webrtc_qos_phase5_release_contract_install.$$}"
WORK_DIR="${WORK_DIR:-/tmp/webrtc_qos_phase5_release_contract_consumer.$$}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_phase5_release_contract_logs.$$}"
METRICS_DIR="${METRICS_DIR:-/tmp/webrtc_qos_phase5_release_contract_metrics.$$}"
ALERTS_DIR="${ALERTS_DIR:-/tmp/webrtc_qos_phase5_release_contract_alerts.$$}"

cleanup() {
  if [[ "${KEEP_WORK_DIR:-0}" != "1" ]]; then
    rm -rf "${BUILD_DIR}" "${INSTALL_PREFIX}" "${WORK_DIR}" \
      "${LOG_DIR}" "${METRICS_DIR}" "${ALERTS_DIR}"
  fi
}
trap cleanup EXIT

fail() {
  echo "phase5 release contract verification failed: $*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -s "${path}" ]] || fail "missing or empty file: ${path}"
}

rm -rf "${BUILD_DIR}" "${INSTALL_PREFIX}" "${WORK_DIR}" \
  "${LOG_DIR}" "${METRICS_DIR}" "${ALERTS_DIR}"
mkdir -p "${WORK_DIR}" "${LOG_DIR}" "${METRICS_DIR}" "${ALERTS_DIR}"

cmake -S "${SDK_ROOT}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DWEBRTC_QOS_ENABLE_WEBRTC_FACADE=ON \
  -DWEBRTC_QOS_WEBRTC_MODULE_PREFIX="${PREFIX}" >/dev/null
cmake --build "${BUILD_DIR}" -j2 >/dev/null
cmake --install "${BUILD_DIR}" --prefix "${INSTALL_PREFIX}" >/dev/null

public_headers=(
  control_messages.h
  production_transport_adapter.h
  qos_metrics.h
  rate_cap.h
  runtime_alerts.h
  runtime_logging.h
  runtime_metrics.h
  server_qos_router.h
  session_config.h
  status.h
  transport_io.h
  transport_packet_history.h
  transport_port.h
  types.h
  video_play_client.h
  video_push_client.h
)
webrtc_adapter_headers=(
  googcc_adapter.h
  h264_rtp_adapter.h
  nack_requester_adapter.h
  pacing_adapter.h
  rtcp_adapter.h
  rtp_packet_adapter.h
  video_jitter_adapter.h
)
archives=(
  libwebrtc_qos.a
  libwebrtc_qos_core.a
  libwebrtc_qos_transport.a
  libwebrtc_qos_transport_packet_history.a
  libwebrtc_qos_facade_video.a
  libwebrtc_qos_webrtc_googcc.a
  libwebrtc_qos_webrtc_pacing.a
  libwebrtc_qos_webrtc_rtp_rtcp.a
  libwebrtc_qos_webrtc_video_jitter.a
  libwebrtc_qos_webrtc_nack_requester.a
  libwebrtc_qos_role_push_bundle.a
  libwebrtc_qos_role_play_bundle.a
  libwebrtc_qos_role_server_bundle.a
)

for header in "${public_headers[@]}" "${webrtc_adapter_headers[@]}"; do
  require_file "${INSTALL_PREFIX}/include/webrtc_qos/${header}"
done
for archive in "${archives[@]}"; do
  require_file "${INSTALL_PREFIX}/lib/${archive}"
done
require_file "${INSTALL_PREFIX}/lib/cmake/WebRtcQosSdk/WebRtcQosSdkConfig.cmake"
require_file "${INSTALL_PREFIX}/lib/cmake/WebRtcQosSdk/WebRtcQosSdkTargets.cmake"

SDK_ROOT="${SDK_ROOT}" PREFIX="${INSTALL_PREFIX}" \
  "${SDK_ROOT}/scripts/verify_no_selfmade_media_stack.sh" >/dev/null

if find "${INSTALL_PREFIX}/include" "${INSTALL_PREFIX}/lib/cmake" -type f \
  \( -name '*.h' -o -name '*.cmake' \) -print0 |
  xargs -0 rg -n 'api/peer_connection|pc/peer_connection|PeerConnection|RTCPeerConnection'; then
  fail "release package exposes PeerConnection dependency"
fi

cat > "${WORK_DIR}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(phase5_release_contract_consumer LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(WebRtcQosSdk REQUIRED CONFIG)

set(REQUIRED_TARGETS
  WebRtcQosSdk::role_push
  WebRtcQosSdk::role_play
  WebRtcQosSdk::role_server
  WebRtcQosSdk::role_push_bundle
  WebRtcQosSdk::role_play_bundle
  WebRtcQosSdk::role_server_bundle
  WebRtcQosSdk::role_transport
  WebRtcQosSdk::transport_packet_history)
foreach(target_name IN LISTS REQUIRED_TARGETS)
  if(NOT TARGET "${target_name}")
    message(FATAL_ERROR "missing required release target: ${target_name}")
  endif()
endforeach()

add_executable(contract_role_targets contract.cc)
target_link_libraries(contract_role_targets PRIVATE
  WebRtcQosSdk::role_push
  WebRtcQosSdk::role_play
  WebRtcQosSdk::role_server)

add_executable(contract_role_bundles contract.cc)
target_link_libraries(contract_role_bundles PRIVATE
  WebRtcQosSdk::role_push_bundle
  WebRtcQosSdk::role_play_bundle
  WebRtcQosSdk::role_server_bundle)
EOF

cat > "${WORK_DIR}/contract.cc" <<'EOF'
#include <cstdint>
#include <iostream>
#include <memory>
#include <string>

#include "webrtc_qos/runtime_alerts.h"
#include "webrtc_qos/runtime_logging.h"
#include "webrtc_qos/runtime_metrics.h"
#include "webrtc_qos/server_qos_router.h"
#include "webrtc_qos/session_config.h"
#include "webrtc_qos/status.h"
#include "webrtc_qos/transport_io.h"
#include "webrtc_qos/video_play_client.h"
#include "webrtc_qos/video_push_client.h"

namespace {

webrtc_qos::SessionConfig MakeSession() {
  webrtc_qos::SessionConfig session;
  session.ids.session_id = 9001;
  session.ids.stream_id = 9002;
  session.ids.transport_id = 9003;
  session.ids.source_id = session.ids.stream_id;
  session.ids.track_id = 1;
  session.ids.sender_ssrc = 0x61234567u;
  session.ids.receiver_id = 9004;
  session.start_bitrate_bps = 1200000;
  session.min_bitrate_bps = 300000;
  session.max_bitrate_bps = 2500000;
  session.debug_name = "phase5_release_contract_consumer";
  return session;
}

webrtc_qos::RuntimeLogConfig MakeLogs(const std::string& dir) {
  webrtc_qos::RuntimeLogConfig config;
  config.file.enabled = true;
  config.file.directory = dir;
  config.file.basename = "phase5_release_contract";
  config.file.max_file_bytes = 1024 * 1024;
  config.file.max_files = 4;
  config.file.json_lines = true;
  config.max_queue_records = 4096;
  return config;
}

webrtc_qos::RuntimeMetricsConfig MakeMetrics(const std::string& dir) {
  webrtc_qos::RuntimeMetricsConfig config;
  config.file.enabled = true;
  config.file.directory = dir;
  config.file.basename = "phase5_release_contract_metrics";
  config.file.max_file_bytes = 1024 * 1024;
  config.file.max_files = 4;
  config.interval_ms = 1;
  config.include_track_snapshots = true;
  return config;
}

webrtc_qos::RuntimeAlertConfig MakeAlerts(const std::string& dir) {
  webrtc_qos::RuntimeAlertConfig config;
  config.file.enabled = true;
  config.file.directory = dir;
  config.file.basename = "phase5_release_contract_alerts";
  config.file.max_file_bytes = 1024 * 1024;
  config.file.max_files = 4;
  config.suppress_repeated_alerts_ms = 0;
  config.high_loss_fraction_q8 = 128;
  config.video_drop_frames_threshold = 1;
  config.low_target_bps = 700000;
  config.low_encoder_fps = 20;
  config.max_process_tick_gap_ms = 2000;
  config.max_rtp_output_gap_ms = 2000;
  config.max_rtp_input_gap_ms = 2000;
  config.consecutive_transport_failures_threshold = 3;
  return config;
}

webrtc_qos::TransportOutput OkTransport() {
  return [](const webrtc_qos::TransportPacketView&) {
    return webrtc_qos::Status::Ok();
  };
}

int Fail(const char* message) {
  std::cerr << message << "\n";
  return 1;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    return Fail("usage: contract <log_dir> <metrics_dir> <alerts_dir>");
  }

  const std::string log_dir = argv[1];
  const std::string metrics_dir = argv[2];
  const std::string alerts_dir = argv[3];
  const webrtc_qos::SessionConfig session = MakeSession();

  webrtc_qos::VideoPushClientConfig push_config;
  push_config.session = session;
  push_config.logging = MakeLogs(log_dir);
  push_config.metrics = MakeMetrics(metrics_dir);
  push_config.alerts = MakeAlerts(alerts_dir);
  push_config.transport_output = OkTransport();
  std::unique_ptr<webrtc_qos::VideoPushClient> push =
      webrtc_qos::CreateVideoPushClient(push_config);
  if (!push || !push->Start()) {
    return Fail("push start failed");
  }
  if (!push->Process(1000000)) {
    return Fail("push process failed");
  }
  if (!push->OnNetworkRouteChange(900000, 300000, 1200000, 1100000)) {
    return Fail("push route change failed");
  }
  webrtc_qos::EncoderAdaptation adaptation =
      push->GetEncoderAdaptation(1200000);
  if (adaptation.target_bitrate_bps == 0 || adaptation.max_fps == 0) {
    return Fail("push adaptation invalid");
  }
  if (!push->Stop()) {
    return Fail("push stop failed");
  }

  webrtc_qos::VideoPlayClientConfig play_config;
  play_config.session = session;
  play_config.logging = MakeLogs(log_dir);
  play_config.metrics = MakeMetrics(metrics_dir);
  play_config.alerts = MakeAlerts(alerts_dir);
  play_config.transport_output = OkTransport();
  play_config.decoded_access_unit_output =
      [](const webrtc_qos::AnnexBAccessUnitView&) {
        return webrtc_qos::Status::Ok();
      };
  std::unique_ptr<webrtc_qos::VideoPlayClient> play =
      webrtc_qos::CreateVideoPlayClient(play_config);
  if (!play || !play->Start()) {
    return Fail("play start failed");
  }
  const uint8_t bad_rtp[] = {0x01, 0x02, 0x03};
  webrtc_qos::Status malformed =
      play->OnRtpPacket(bad_rtp, sizeof(bad_rtp), 1300000);
  if (malformed.code != webrtc_qos::StatusCode::kMalformedPacket) {
    return Fail("play malformed RTP status mismatch");
  }
  if (!play->Process(1400000)) {
    return Fail("play process failed");
  }
  if (!play->Stop()) {
    return Fail("play stop failed");
  }

  webrtc_qos::ServerQosRouterConfig server_config;
  server_config.session = session;
  server_config.logging = MakeLogs(log_dir);
  server_config.metrics = MakeMetrics(metrics_dir);
  server_config.alerts = MakeAlerts(alerts_dir);
  server_config.sender_output = OkTransport();
  server_config.receiver_output = OkTransport();
  std::unique_ptr<webrtc_qos::ServerQosRouter> server =
      webrtc_qos::CreateServerQosRouter(server_config);
  if (!server || !server->Start()) {
    return Fail("server start failed");
  }
  webrtc_qos::Status server_malformed =
      server->OnSenderRtp(bad_rtp, sizeof(bad_rtp), 1500000);
  if (server_malformed.code != webrtc_qos::StatusCode::kMalformedPacket) {
    return Fail("server malformed RTP status mismatch");
  }
  webrtc_qos::DownlinkQuality quality;
  quality.ids = session.ids;
  quality.report_time_us = 1600000;
  quality.fraction_lost_q8 = 128;
  quality.video_drop_frames = 2;
  quality.recv_bitrate_bps = 200000;
  if (!server->OnDownlinkQuality(quality)) {
    return Fail("server downlink quality failed");
  }
  webrtc_qos::SenderRateCap cap = server->CurrentSenderRateCap(1600000);
  if (cap.cap_bps == 0 || cap.cap_bps == webrtc_qos::kUnlimitedRateCapBps) {
    return Fail("server rate cap invalid");
  }
  if (!server->Stop()) {
    return Fail("server stop failed");
  }

  std::cout << "phase5_release_contract_consumer pass\n";
  return 0;
}
EOF

cmake -S "${WORK_DIR}" -B "${WORK_DIR}/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="${INSTALL_PREFIX}" >/dev/null
cmake --build "${WORK_DIR}/build" -j2 >/dev/null

for executable in contract_role_targets contract_role_bundles; do
  rm -rf "${LOG_DIR}" "${METRICS_DIR}" "${ALERTS_DIR}"
  mkdir -p "${LOG_DIR}" "${METRICS_DIR}" "${ALERTS_DIR}"
  if ! output="$("${WORK_DIR}/build/${executable}" \
    "${LOG_DIR}" "${METRICS_DIR}" "${ALERTS_DIR}" 2>&1)"; then
    echo "${output}" >&2
    fail "${executable} exited with non-zero status"
  fi
  printf '%s\n' "${output}"
  grep -q "phase5_release_contract_consumer pass" <<<"${output}" ||
    fail "${executable} did not report pass"

  shopt -s nullglob
  logs=("${LOG_DIR}"/phase5_release_contract.*.log)
  metrics=("${METRICS_DIR}"/phase5_release_contract_metrics.*.jsonl)
  alerts=("${ALERTS_DIR}"/phase5_release_contract_alerts.*.jsonl)
  (( ${#logs[@]} > 0 )) || fail "${executable} missing runtime logs"
  (( ${#metrics[@]} > 0 )) || fail "${executable} missing runtime metrics"
  (( ${#alerts[@]} > 0 )) || fail "${executable} missing runtime alerts"

  python3 - "${LOG_DIR}" "${METRICS_DIR}" "${ALERTS_DIR}" "${executable}" <<'PY'
import json
import pathlib
import sys

log_dir = pathlib.Path(sys.argv[1])
metrics_dir = pathlib.Path(sys.argv[2])
alerts_dir = pathlib.Path(sys.argv[3])
label = sys.argv[4]

identity = {
    "ts_us",
    "role",
    "session_id",
    "stream_id",
    "transport_id",
    "source_id",
    "track_id",
    "sender_ssrc",
    "receiver_id",
}
payload_like = {"payload", "annexb_bytes", "rtp_bytes", "rtcp_bytes"}

def read_jsonl(paths):
    records = []
    for path in paths:
        with path.open("r", encoding="utf-8") as handle:
            for line_no, line in enumerate(handle, 1):
                if not line.strip():
                    continue
                obj = json.loads(line)
                missing = identity - obj.keys()
                if missing:
                    raise SystemExit(
                        f"{path}:{line_no}: missing fields {sorted(missing)}"
                    )
                leaked = payload_like & obj.keys()
                if leaked:
                    raise SystemExit(
                        f"{path}:{line_no}: payload-like fields {sorted(leaked)}"
                    )
                records.append(obj)
    return records

logs = read_jsonl(sorted(log_dir.glob("*.log")))
metrics = read_jsonl(sorted(metrics_dir.glob("*.jsonl")))
alerts = read_jsonl(sorted(alerts_dir.glob("*.jsonl")))
if not logs or not metrics or not alerts:
    raise SystemExit(f"{label}: missing runtime records")

log_roles = {record["role"] for record in logs}
metric_roles = {record["role"] for record in metrics}
alert_roles = {record["role"] for record in alerts}
if not {"push", "play", "server"}.issubset(log_roles):
    raise SystemExit(f"{label}: logs missing roles {sorted(log_roles)}")
if not {"push", "play", "server"}.issubset(metric_roles):
    raise SystemExit(f"{label}: metrics missing roles {sorted(metric_roles)}")
if not {"play", "server"}.issubset(alert_roles):
    raise SystemExit(f"{label}: alerts missing roles {sorted(alert_roles)}")

log_events = {(record["role"], record.get("event")) for record in logs}
for expected in [
    ("push", "start"),
    ("play", "malformed_rtp"),
    ("server", "malformed_rtp"),
    ("server", "downlink_quality_update"),
]:
    if expected not in log_events:
        raise SystemExit(f"{label}: missing log event {expected}")

alert_rules = {(record["role"], record.get("rule")) for record in alerts}
for expected in [
    ("play", "malformed_rtp"),
    ("server", "malformed_rtp"),
    ("server", "high_downlink_loss"),
    ("server", "video_drop_frames"),
]:
    if expected not in alert_rules:
        raise SystemExit(f"{label}: missing alert rule {expected}")

metric_scopes = {(record["role"], record.get("scope")) for record in metrics}
for expected in [
    ("push", "session"),
    ("play", "session"),
    ("server", "session"),
]:
    if expected not in metric_scopes:
        raise SystemExit(f"{label}: missing metric scope {expected}")

for record in metrics:
    for field in (
        "process_tick_count",
        "process_tick_gap_us",
        "max_process_tick_gap_us",
        "rtp_output_gap_us",
        "max_rtp_output_gap_us",
        "rtp_input_gap_us",
        "max_rtp_input_gap_us",
        "transport_failure_count",
        "consecutive_transport_failures",
        "max_consecutive_transport_failures",
    ):
        if field not in record:
            raise SystemExit(f"{label}: metric missing {field}")

print(
    "validated_%s_release_records logs=%d metrics=%d alerts=%d"
    % (label, len(logs), len(metrics), len(alerts))
)
PY
done

echo "phase5_release_contract pass install_prefix=${INSTALL_PREFIX}"
