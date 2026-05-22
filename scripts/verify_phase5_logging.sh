#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}"
BUILD_DIR="${BUILD_DIR:-/tmp/webrtc_qos_phase5_logging_build.$$}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_phase5_logs.$$}"
ROTATION_LOG_DIR="${ROTATION_LOG_DIR:-/tmp/webrtc_qos_phase5_rotation_logs.$$}"
QUEUE_LOG_DIR="${QUEUE_LOG_DIR:-/tmp/webrtc_qos_phase5_queue_logs.$$}"
FRAMES="${FRAMES:-36}"

cleanup() {
  if [[ "${KEEP_WORK_DIR:-0}" != "1" ]]; then
    rm -rf "${BUILD_DIR}" "${LOG_DIR}" "${ROTATION_LOG_DIR}" "${QUEUE_LOG_DIR}"
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

rm -rf "${BUILD_DIR}" "${LOG_DIR}" "${ROTATION_LOG_DIR}" "${QUEUE_LOG_DIR}"
mkdir -p "${LOG_DIR}" "${ROTATION_LOG_DIR}" "${QUEUE_LOG_DIR}"

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
require_log '"role":"push","event":"config_dump"' "missing push config dump event"
require_log '"role":"push","event":"stop"' "missing push stop event"
require_log '"role":"push","event":"push_au"' "missing push access-unit event"
require_log '"role":"push","event":"sender_rate_cap_update"' \
  "missing push rate-cap update event"
require_log '"role":"server","event":"start"' "missing server start event"
require_log '"role":"server","event":"config_dump"' \
  "missing server config dump event"
require_log '"role":"server","event":"stop"' "missing server stop event"
require_log '"role":"server","event":"downlink_quality_update"' \
  "missing server downlink quality event"
require_log '"role":"server","event":"local_retransmission_hit"' \
  "missing server local retransmission event"
require_log '"role":"play","event":"start"' "missing play start event"
require_log '"role":"play","event":"config_dump"' "missing play config dump event"
require_log '"role":"play","event":"stop"' "missing play stop event"
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
roles = {"push", "server", "play"}
event_ts = {role: {"start": [], "stop": []} for role in roles}
config_dumps = {role: [] for role in roles}
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
            role = obj.get("role")
            event = obj.get("event")
            if role in event_ts and event in event_ts[role]:
                event_ts[role][event].append(obj["ts_us"])
            if role in config_dumps and event == "config_dump":
                config_dumps[role].append(obj)
            lines += 1
if lines == 0:
    raise SystemExit("no JSON log lines found")
for role in sorted(roles):
    starts = event_ts[role]["start"]
    stops = event_ts[role]["stop"]
    if not starts:
        raise SystemExit(f"{role}: missing start event")
    if not stops:
        raise SystemExit(f"{role}: missing stop event")
    if max(stops) < min(starts):
        raise SystemExit(f"{role}: stop event timestamp is before start event")
    dumps = config_dumps[role]
    if not dumps:
        raise SystemExit(f"{role}: missing config_dump event")
    for obj in dumps:
        required_config = {
            "schema_version",
            "transport",
            "peer_connection",
            "resolved_track_count",
            "start_bitrate_bps",
            "min_bitrate_bps",
            "max_bitrate_bps",
            "logging_enabled",
            "log_max_file_bytes",
            "log_max_files",
            "log_max_queue_records",
            "metrics_enabled",
            "alerts_enabled",
            "alerts_max_process_tick_gap_ms",
            "alerts_max_rtp_output_gap_ms",
            "alerts_max_rtp_input_gap_ms",
            "alerts_consecutive_transport_failures_threshold",
            "alerts_media_flow_gap_enabled",
            "redaction_media_bytes",
            "redaction_runtime_paths",
        }
        missing_config = required_config - obj.keys()
        if missing_config:
            raise SystemExit(
                f"{role}: config_dump missing fields {sorted(missing_config)}"
            )
        if obj.get("transport") != "udp" or obj.get("peer_connection") is not False:
            raise SystemExit(f"{role}: config_dump has bad transport boundary")
        if obj.get("redaction_media_bytes") != "omitted":
            raise SystemExit(f"{role}: config_dump missing media redaction")
        if obj.get("redaction_runtime_paths") != "omitted":
            raise SystemExit(f"{role}: config_dump missing path redaction")
print(f"validated_json_lines={lines}")
print(
    "validated_config_dump "
    + " ".join(f"{role}_dumps={len(config_dumps[role])}" for role in sorted(roles))
)
print(
    "validated_stop_flush "
    + " ".join(
        f"{role}_starts={len(event_ts[role]['start'])} "
        f"{role}_stops={len(event_ts[role]['stop'])}"
        for role in sorted(roles)
    )
)
PY

rotation_output="$(run_demo "rotating UDP selftest" selftest 90 \
  --log-dir "${ROTATION_LOG_DIR}" \
  --log-max-file-bytes 512 \
  --log-max-files 3)"
printf '%s\n' "${rotation_output}"
require_output "udp_selftest .*pass=true" "${rotation_output}" \
  "UDP selftest with rotating file logging did not pass"
if grep -q '"ts_us"' <<<"${rotation_output}"; then
  fail "rotating file logging leaked JSON lines to stdout/stderr"
fi

python3 - "${ROTATION_LOG_DIR}" <<'PY'
import json
import pathlib
import sys

log_dir = pathlib.Path(sys.argv[1])
roles = {"push", "server", "play"}
files_by_role = {role: sorted(log_dir.glob(f"webrtc_qos_udp.{role}.*.log")) for role in roles}
for role, paths in files_by_role.items():
    grouped = {}
    for path in paths:
        prefix, index, suffix = path.name.rsplit(".", 2)
        if suffix != "log":
            raise SystemExit(f"{path}: unexpected suffix {suffix}")
        grouped.setdefault(prefix, []).append((int(index), path))
    if not grouped:
        raise SystemExit(f"{role}: missing rotated log files")
    saw_rotation = False
    for prefix, indexed_paths in grouped.items():
        if len(indexed_paths) > 3:
            raise SystemExit(
                f"{role}:{prefix}: max_files=3 exceeded, got {len(indexed_paths)}"
            )
        indexes = sorted(index for index, _ in indexed_paths)
        if indexes != list(range(len(indexes))):
            raise SystemExit(f"{role}:{prefix}: non-contiguous rotation indexes {indexes}")
        saw_rotation = saw_rotation or len(indexed_paths) >= 2
        for _, path in indexed_paths:
            if path.stat().st_size <= 0:
                raise SystemExit(f"{path}: empty rotated log file")
            with path.open("r", encoding="utf-8") as handle:
                for line_no, line in enumerate(handle, 1):
                    if not line.strip():
                        continue
                    record = json.loads(line)
                    if record.get("role") != role:
                        raise SystemExit(
                            f"{path}:{line_no}: role mismatch {record.get('role')} != {role}"
                        )
                    break
                else:
                    raise SystemExit(f"{path}: no JSON records")
    if not saw_rotation:
        raise SystemExit(f"{role}: no logger instance produced multiple rotated files")
print(
    "validated_log_rotation "
    + " ".join(f"{role}_files={len(paths)}" for role, paths in sorted(files_by_role.items()))
)
PY

queue_output="$(run_demo "bounded-queue UDP selftest" selftest 180 \
  --log-dir "${QUEUE_LOG_DIR}" \
  --log-max-queue-records 1)"
printf '%s\n' "${queue_output}"
require_output "udp_selftest .*pass=true" "${queue_output}" \
  "UDP selftest with bounded async logging queue did not pass"
if grep -q '"ts_us"' <<<"${queue_output}"; then
  fail "bounded async file logging leaked JSON lines to stdout/stderr"
fi

python3 - "${QUEUE_LOG_DIR}" <<'PY'
import json
import pathlib
import sys

log_dir = pathlib.Path(sys.argv[1])
roles = {"push", "server", "play"}
records_by_role = {role: [] for role in roles}
dropped_total = 0
for path in sorted(log_dir.glob("*.log")):
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            if not line.strip():
                continue
            record = json.loads(line)
            role = record.get("role")
            if role in records_by_role:
                records_by_role[role].append(record)
            dropped_total += int(record.get("dropped_log_count", 0))
for role, records in sorted(records_by_role.items()):
    if not records:
        raise SystemExit(f"{role}: missing async logger records")
    if not any(record.get("event") == "stop" for record in records):
        raise SystemExit(f"{role}: stop event was not flushed under queue pressure")
if dropped_total <= 0:
    raise SystemExit("missing positive dropped_log_count under queue pressure")
print(
    "validated_async_log_queue "
    + " ".join(f"{role}_records={len(records)}" for role, records in sorted(records_by_role.items()))
    + f" dropped_log_count={dropped_total}"
)
PY

echo "phase5_logging pass log_dir=${LOG_DIR}"
