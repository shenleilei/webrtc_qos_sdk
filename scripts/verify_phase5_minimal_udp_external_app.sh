#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}"
SOURCE_BUILD_DIR="${SOURCE_BUILD_DIR:-/tmp/webrtc_qos_phase5_external_source_build.$$}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/tmp/webrtc_qos_phase5_external_install.$$}"
APP_BUILD_DIR="${APP_BUILD_DIR:-/tmp/webrtc_qos_phase5_external_app_build.$$}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_phase5_external_logs.$$}"
METRICS_DIR="${METRICS_DIR:-/tmp/webrtc_qos_phase5_external_metrics.$$}"
ALERTS_DIR="${ALERTS_DIR:-/tmp/webrtc_qos_phase5_external_alerts.$$}"
FRAMES="${FRAMES:-36}"

cleanup() {
  if [[ "${KEEP_WORK_DIR:-0}" != "1" ]]; then
    rm -rf "${SOURCE_BUILD_DIR}" "${INSTALL_PREFIX}" "${APP_BUILD_DIR}" \
      "${LOG_DIR}" "${METRICS_DIR}" "${ALERTS_DIR}"
  fi
}
trap cleanup EXIT

fail() {
  echo "phase5 minimal UDP external app verification failed: $*" >&2
  exit 1
}

require_output() {
  local pattern="$1"
  local text="$2"
  local message="$3"
  if ! grep -qE "${pattern}" <<<"${text}"; then
    fail "${message}"
  fi
}

rm -rf "${SOURCE_BUILD_DIR}" "${INSTALL_PREFIX}" "${APP_BUILD_DIR}" \
  "${LOG_DIR}" "${METRICS_DIR}" "${ALERTS_DIR}"
mkdir -p "${LOG_DIR}" "${METRICS_DIR}" "${ALERTS_DIR}"

if find "${SDK_ROOT}/examples/minimal_udp_app" -type f \
  \( -name 'CMakeLists.txt' -o -name '*.cc' -o -name '*.h' \) -print0 |
  xargs -0 rg -n '#include "src/|#include <src/|third_party/webrtc|api/peer_connection|pc/peer_connection|RTCPeerConnection|PeerConnection'; then
  fail "external sample depends on SDK src/ or WebRTC PeerConnection internals"
fi

cmake -S "${SDK_ROOT}" -B "${SOURCE_BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DWEBRTC_QOS_ENABLE_WEBRTC_FACADE=ON \
  -DWEBRTC_QOS_WEBRTC_MODULE_PREFIX="${PREFIX}" >/dev/null
cmake --build "${SOURCE_BUILD_DIR}" -j2 >/dev/null
cmake --install "${SOURCE_BUILD_DIR}" --prefix "${INSTALL_PREFIX}" >/dev/null

cmake -S "${SDK_ROOT}/examples/minimal_udp_app" -B "${APP_BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="${INSTALL_PREFIX}" >/dev/null
cmake --build "${APP_BUILD_DIR}" -j2 >/dev/null

selftest_output="$("${APP_BUILD_DIR}/minimal_udp_selftest" \
  --frames "${FRAMES}" --tracks 2 \
  --log-dir "${LOG_DIR}" \
  --metrics-dir "${METRICS_DIR}" \
  --alerts-dir "${ALERTS_DIR}")"
printf '%s\n' "${selftest_output}"
require_output 'minimal_udp_selftest .*backend=webrtc_first_facade' \
  "${selftest_output}" "external selftest did not use WebRTC facade"
require_output 'transport=udp' "${selftest_output}" \
  "external selftest did not use UDP transport"
require_output 'peer_connection=false' "${selftest_output}" \
  "external selftest must not use PeerConnection"
require_output 'tracks=2' "${selftest_output}" \
  "external selftest did not use default dual-track profile"
require_output 'decoded_tracks=2' "${selftest_output}" \
  "external selftest did not decode both tracks"
require_output 'pass=true' "${selftest_output}" \
  "external selftest did not pass"

sender_output="$("${APP_BUILD_DIR}/minimal_udp_sender" \
  0 127.0.0.1:9 --frames 3 --tracks 2)"
server_output="$("${APP_BUILD_DIR}/minimal_udp_server" \
  0 127.0.0.1:9 127.0.0.1:10 --frames 3 --tracks 2)"
receiver_output="$("${APP_BUILD_DIR}/minimal_udp_receiver" \
  0 127.0.0.1:9 --frames 3 --tracks 2)"
printf '%s\n%s\n%s\n' "${sender_output}" "${server_output}" "${receiver_output}"
require_output 'minimal_udp_sender .*backend=webrtc_first_facade.*tracks=2' \
  "${sender_output}" "sender role smoke failed"
require_output 'minimal_udp_server .*backend=webrtc_first_facade.*tracks=2' \
  "${server_output}" "server role smoke failed"
require_output 'minimal_udp_receiver .*backend=webrtc_first_facade.*tracks=2' \
  "${receiver_output}" "receiver role smoke failed"

shopt -s nullglob
push_logs=("${LOG_DIR}"/minimal_udp.push.*.log)
server_logs=("${LOG_DIR}"/minimal_udp.server.*.log)
play_logs=("${LOG_DIR}"/minimal_udp.play.*.log)
push_metrics=("${METRICS_DIR}"/minimal_udp_metrics.push.*.jsonl)
server_metrics=("${METRICS_DIR}"/minimal_udp_metrics.server.*.jsonl)
play_metrics=("${METRICS_DIR}"/minimal_udp_metrics.play.*.jsonl)
push_alerts=("${ALERTS_DIR}"/minimal_udp_alerts.push.*.jsonl)
server_alerts=("${ALERTS_DIR}"/minimal_udp_alerts.server.*.jsonl)
play_alerts=("${ALERTS_DIR}"/minimal_udp_alerts.play.*.jsonl)
(( ${#push_logs[@]} > 0 )) || fail "missing push log"
(( ${#server_logs[@]} > 0 )) || fail "missing server log"
(( ${#play_logs[@]} > 0 )) || fail "missing play log"
(( ${#push_metrics[@]} > 0 )) || fail "missing push metrics"
(( ${#server_metrics[@]} > 0 )) || fail "missing server metrics"
(( ${#play_metrics[@]} > 0 )) || fail "missing play metrics"
(( ${#push_alerts[@]} > 0 )) || fail "missing push alerts"
(( ${#server_alerts[@]} > 0 )) || fail "missing server alerts"
(( ${#play_alerts[@]} > 0 )) || fail "missing play alerts"

python3 - "${LOG_DIR}" "${METRICS_DIR}" "${ALERTS_DIR}" <<'PY'
import json
import pathlib
import sys

log_dir = pathlib.Path(sys.argv[1])
metrics_dir = pathlib.Path(sys.argv[2])
alerts_dir = pathlib.Path(sys.argv[3])

def read_jsonl(paths):
    records = []
    for path in paths:
        with path.open("r", encoding="utf-8") as handle:
            for line_no, line in enumerate(handle, 1):
                if not line.strip():
                    continue
                records.append(json.loads(line))
    return records

required_identity = {
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

for root, pattern in [
    (log_dir, "*.log"),
    (metrics_dir, "*.jsonl"),
    (alerts_dir, "*.jsonl"),
]:
    records = read_jsonl(sorted(root.glob(pattern)))
    if not records:
        raise SystemExit(f"no records found under {root}")
    for index, record in enumerate(records, 1):
        missing = required_identity - record.keys()
        if missing:
            raise SystemExit(f"{root}:{index}: missing fields {sorted(missing)}")
        if any(key in record for key in ("payload", "annexb_bytes", "rtp_bytes")):
            raise SystemExit(f"{root}:{index}: payload-like field found")

metrics = read_jsonl(sorted(metrics_dir.glob("*.jsonl")))
alerts = read_jsonl(sorted(alerts_dir.glob("*.jsonl")))
if min(r.get("adaptation_target_bps", 0) for r in metrics if r["role"] == "push") > 600000:
    raise SystemExit("push metrics did not capture weak-network bitrate downshift")
if max(r.get("nack_count", 0) for r in metrics if r["role"] == "play") <= 0:
    raise SystemExit("play metrics did not capture NACK")
if max(r.get("retransmission_count", 0) for r in metrics if r["role"] == "server") <= 0:
    raise SystemExit("server metrics did not capture retransmission")
rules = {r.get("rule") for r in alerts}
for rule in [
    "low_target_bitrate",
    "low_encoder_fps",
    "high_downlink_loss",
    "video_drop_frames",
    "nack_generated",
    "local_retransmission_hit",
]:
    if rule not in rules:
        raise SystemExit(f"missing alert rule {rule}")
print(
    "validated_external_records logs=%d metrics=%d alerts=%d"
    % (
        len(read_jsonl(sorted(log_dir.glob("*.log")))),
        len(metrics),
        len(alerts),
    )
)
PY

echo "phase5_minimal_udp_external_app pass build_dir=${APP_BUILD_DIR}"
