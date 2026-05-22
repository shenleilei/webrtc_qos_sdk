#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}"
BUILD_DIR="${BUILD_DIR:-/tmp/webrtc_qos_phase5_logging_build.$$}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_phase5_logs.$$}"
FRAMES="${FRAMES:-36}"

cleanup() {
  if [[ "${KEEP_WORK_DIR:-0}" != "1" ]]; then
    rm -rf "${BUILD_DIR}" "${LOG_DIR}"
  fi
}
trap cleanup EXIT

fail() {
  echo "phase5 logging verification failed: $*" >&2
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

require_log() {
  local pattern="$1"
  local message="$2"
  if ! rg -q "${pattern}" "${LOG_DIR}"; then
    find "${LOG_DIR}" -maxdepth 1 -type f -print >&2 || true
    fail "${message}"
  fi
}

run_demo() {
  local label="$1"
  shift
  local output
  if ! output="$("${demo}" "$@" 2>&1)"; then
    echo "${output}" >&2
    fail "${label} exited with non-zero status"
  fi
  printf '%s\n' "${output}"
}

rm -rf "${BUILD_DIR}" "${LOG_DIR}"
mkdir -p "${LOG_DIR}"

cmake -S "${SDK_ROOT}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DWEBRTC_QOS_ENABLE_WEBRTC_FACADE=ON \
  -DWEBRTC_QOS_WEBRTC_MODULE_PREFIX="${PREFIX}" >/dev/null
cmake --build "${BUILD_DIR}" \
  --target webrtc_qos_webrtc_first_udp_demo -j2 >/dev/null

demo="${BUILD_DIR}/webrtc_qos_webrtc_first_udp_demo"

plain_output="$(run_demo "plain UDP selftest" selftest "${FRAMES}")"
printf '%s\n' "${plain_output}"
require_output "udp_selftest .*pass=true" "${plain_output}" \
  "UDP selftest without file logging did not pass"
if grep -q '"ts_us"' <<<"${plain_output}"; then
  fail "default logging leaked JSON lines to stdout/stderr"
fi

rm -rf "${LOG_DIR}"
mkdir -p "${LOG_DIR}"
logged_output="$(run_demo "logged UDP selftest" selftest "${FRAMES}" \
  --log-dir "${LOG_DIR}")"
printf '%s\n' "${logged_output}"
require_output "udp_selftest .*pass=true" "${logged_output}" \
  "UDP selftest with file logging did not pass"
require_output "udp_selftest_single_track .*decoded_tracks=1.*pass=true" \
  "${logged_output}" "single-track UDP selftest did not pass"
require_output "udp_selftest_dual_track .*decoded_tracks=2.*pass=true" \
  "${logged_output}" "dual-track UDP selftest did not pass"
if grep -q '"ts_us"' <<<"${logged_output}"; then
  fail "file logging leaked JSON lines to stdout/stderr"
fi

shopt -s nullglob
push_logs=("${LOG_DIR}"/webrtc_qos_udp.push.*.log)
server_logs=("${LOG_DIR}"/webrtc_qos_udp.server.*.log)
play_logs=("${LOG_DIR}"/webrtc_qos_udp.play.*.log)
(( ${#push_logs[@]} > 0 )) || fail "missing push role log file"
(( ${#server_logs[@]} > 0 )) || fail "missing server role log file"
(( ${#play_logs[@]} > 0 )) || fail "missing play role log file"

require_log '"role":"push","event":"start"' "missing push start event"
require_log '"role":"push","event":"push_au"' "missing push access-unit event"
require_log '"role":"push","event":"sender_rate_cap_update"' \
  "missing push rate-cap update event"
require_log '"role":"server","event":"start"' "missing server start event"
require_log '"role":"server","event":"downlink_quality_update"' \
  "missing server downlink quality event"
require_log '"role":"server","event":"local_retransmission_hit"' \
  "missing server local retransmission event"
require_log '"role":"play","event":"start"' "missing play start event"
require_log '"role":"play","event":"decode_au_output"' \
  "missing play decoded access-unit event"
require_log '"session_id":1' "missing transport identity fields"

if rg -q '"payload"|"annexb_bytes"|"rtp_bytes"' "${LOG_DIR}"; then
  fail "logs contain media payload-like fields"
fi

python3 - "${LOG_DIR}" <<'PY'
import json
import pathlib
import sys

log_dir = pathlib.Path(sys.argv[1])
required = {
    "ts_us",
    "level",
    "role",
    "event",
    "session_id",
    "stream_id",
    "transport_id",
    "source_id",
    "track_id",
    "sender_ssrc",
    "receiver_id",
}
lines = 0
for path in log_dir.glob("*.log"):
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            if not line.strip():
                continue
            obj = json.loads(line)
            missing = required - obj.keys()
            if missing:
                raise SystemExit(
                    f"{path}:{line_no}: missing fields: {sorted(missing)}"
                )
            lines += 1
if lines == 0:
    raise SystemExit("no JSON log lines found")
print(f"validated_json_lines={lines}")
PY

echo "phase5_logging pass log_dir=${LOG_DIR}"
