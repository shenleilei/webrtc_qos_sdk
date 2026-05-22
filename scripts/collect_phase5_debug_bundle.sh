#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PREFIX="${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/phase5_debug_bundle}"
BUILD_DIR="${BUILD_DIR:-/tmp/webrtc_qos_phase5_debug_bundle_build.$$}"
WORK_DIR="${WORK_DIR:-/tmp/webrtc_qos_phase5_debug_bundle_work.$$}"
FRAMES="${FRAMES:-36}"
RUN_SELFTEST="${RUN_SELFTEST:-1}"
REQUIRE_SELFTEST_PASS="${REQUIRE_SELFTEST_PASS:-1}"

LOG_SOURCE_DIR="${LOG_SOURCE_DIR:-${WORK_DIR}/logs}"
METRICS_SOURCE_DIR="${METRICS_SOURCE_DIR:-${WORK_DIR}/metrics}"
ALERTS_SOURCE_DIR="${ALERTS_SOURCE_DIR:-${WORK_DIR}/alerts}"
QOE_CSV="${QOE_CSV:-}"
RENDERER_SUMMARY="${RENDERER_SUMMARY:-}"

SUMMARY_FILE="${OUTPUT_DIR}/debug_bundle_summary.txt"
MANIFEST_FILE="${OUTPUT_DIR}/manifest.sha256"
FILES_FILE="${OUTPUT_DIR}/files.txt"

cleanup() {
  if [[ "${KEEP_WORK_DIR:-0}" != "1" ]]; then
    rm -rf "${BUILD_DIR}" "${WORK_DIR}"
  fi
}
trap cleanup EXIT

rm -rf "${OUTPUT_DIR}" "${WORK_DIR}"
mkdir -p "${OUTPUT_DIR}/log" "${OUTPUT_DIR}/metrics" "${OUTPUT_DIR}/alerts" \
  "${OUTPUT_DIR}/evidence" "${OUTPUT_DIR}/timeline" \
  "${LOG_SOURCE_DIR}" "${METRICS_SOURCE_DIR}" "${ALERTS_SOURCE_DIR}"

write_summary() {
  printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

copy_optional_file() {
  local name="$1"
  local src="$2"
  local dst="$3"
  if [[ -n "${src}" && -s "${src}" ]]; then
    cp -a "${src}" "${dst}"
    write_summary "artifact=${name} status=copied source=${src} dest=${dst}"
  else
    write_summary "artifact=${name} status=not_collected source=${src:-unset}"
  fi
}

concat_role_files() {
  local source_dir="$1"
  local role="$2"
  local suffix="$3"
  local output="$4"
  mapfile -t files < <(
    find "${source_dir}" -maxdepth 1 -type f -name "*.${role}.*.${suffix}" \
      | sort
  )
  if (( ${#files[@]} == 0 )); then
    : >"${output}"
    write_summary "role_artifact=${role}_${suffix} status=missing source=${source_dir}"
    return
  fi
  cat "${files[@]}" >"${output}"
  write_summary "role_artifact=${role}_${suffix} status=collected files=${#files[@]} dest=${output}"
}

{
  printf 'SDK_ROOT=%s\n' "${SDK_ROOT}"
  printf 'PREFIX=%s\n' "${PREFIX}"
  printf 'OUTPUT_DIR=%s\n' "${OUTPUT_DIR}"
  printf 'BUILD_DIR=%s\n' "${BUILD_DIR}"
  printf 'WORK_DIR=%s\n' "${WORK_DIR}"
  printf 'FRAMES=%s\n' "${FRAMES}"
  printf 'RUN_SELFTEST=%s\n' "${RUN_SELFTEST}"
  printf 'COLLECTED_AT_UTC=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'HOSTNAME=%s\n' "$(hostname 2>/dev/null || true)"
  printf 'UNAME=%s\n' "$(uname -a 2>/dev/null || true)"
  if git -C "${SDK_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'GIT_HEAD=%s\n' "$(git -C "${SDK_ROOT}" rev-parse HEAD)"
    printf 'GIT_BRANCH=%s\n' "$(git -C "${SDK_ROOT}" rev-parse --abbrev-ref HEAD)"
  fi
} >"${OUTPUT_DIR}/metadata.txt"

{
  printf 'CMAKE_BUILD_TYPE=Release\n'
  printf 'WEBRTC_QOS_ENABLE_WEBRTC_FACADE=ON\n'
  printf 'WEBRTC_QOS_WEBRTC_MODULE_PREFIX=%s\n' "${PREFIX}"
  printf 'SDK_ROOT=%s\n' "${SDK_ROOT}"
  printf 'PREFIX=%s\n' "${PREFIX}"
} >"${OUTPUT_DIR}/build_config.txt"

{
  if git -C "${SDK_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'git_head=%s\n' "$(git -C "${SDK_ROOT}" rev-parse HEAD)"
    printf 'git_log_oneline=%s\n' "$(git -C "${SDK_ROOT}" log -1 --oneline)"
    printf '\n[git status --short]\n'
    git -C "${SDK_ROOT}" status --short
  else
    printf 'git_status=not_a_git_checkout\n'
  fi
} >"${OUTPUT_DIR}/git_status.txt"

cat >"${OUTPUT_DIR}/session_config.json" <<'EOF'
{
  "source": "demo/webrtc_first_udp",
  "transport": "udp",
  "peer_connection": false,
  "profiles": [
    {
      "label": "single_track",
      "session_id": 1,
      "stream_id": 1,
      "transport_id": 1,
      "receiver_id": 8738,
      "source_id": 1,
      "start_bitrate_bps": 1200000,
      "min_bitrate_bps": 300000,
      "max_bitrate_bps": 2500000,
      "tracks": [
        {"track_id": 101, "sender_ssrc": 305419896, "base_track": true, "weight": 100}
      ]
    },
    {
      "label": "dual_track",
      "session_id": 1,
      "stream_id": 1,
      "transport_id": 1,
      "receiver_id": 8738,
      "source_id": 1,
      "start_bitrate_bps": 1200000,
      "min_bitrate_bps": 300000,
      "max_bitrate_bps": 2500000,
      "tracks": [
        {"track_id": 101, "sender_ssrc": 305419896, "base_track": true, "weight": 70},
        {"track_id": 202, "sender_ssrc": 322263929, "base_track": false, "weight": 30}
      ]
    }
  ],
  "runtime_outputs": {
    "logs": "log/{push,server,play}.log",
    "metrics": "metrics/{push,server,play}_metrics.jsonl",
    "alerts": "alerts/alerts.jsonl"
  }
}
EOF

python3 - "${OUTPUT_DIR}/runtime_config.json" "${FRAMES}" \
  "${RUN_SELFTEST}" "${REQUIRE_SELFTEST_PASS}" <<'PY'
import json
import sys

path = sys.argv[1]
frames = int(sys.argv[2])
run_selftest = sys.argv[3] == "1"
require_selftest_pass = sys.argv[4] == "1"

runtime_config = {
    "schema_version": 1,
    "source": "demo/webrtc_first_udp",
    "transport": {
        "kind": "udp",
        "wire_envelope": "WQUD/v1",
        "peer_connection": False,
        "transport_bytes": "opaque",
    },
    "selftest": {
        "frames": frames,
        "run_enabled": run_selftest,
        "require_pass": require_selftest_pass,
    },
    "roles": [
        {
            "role": "push",
            "factory": "CreateVideoPushClient",
            "worker_model": "single_role_worker",
            "artifacts": {
                "log": "log/push.log",
                "metrics": "metrics/push_metrics.jsonl",
                "alerts": "alerts/push_alerts.jsonl",
            },
        },
        {
            "role": "server",
            "factory": "CreateServerQosRouter",
            "worker_model": "single_role_worker",
            "artifacts": {
                "log": "log/server.log",
                "metrics": "metrics/server_metrics.jsonl",
                "alerts": "alerts/server_alerts.jsonl",
            },
        },
        {
            "role": "play",
            "factory": "CreateVideoPlayClient",
            "worker_model": "single_role_worker",
            "artifacts": {
                "log": "log/play.log",
                "metrics": "metrics/play_metrics.jsonl",
                "alerts": "alerts/play_alerts.jsonl",
            },
        },
    ],
    "runtime": {
        "logging": {
            "enabled": True,
            "min_level": "INFO",
            "basename": "webrtc_qos_udp",
            "json_lines": True,
            "also_stderr": False,
            "max_file_bytes": 1048576,
            "max_files": 4,
            "max_queue_records": 4096,
        },
        "metrics": {
            "enabled": True,
            "basename": "webrtc_qos_udp_metrics",
            "interval_ms": 100,
            "include_track_snapshots": True,
            "max_file_bytes": 1048576,
            "max_files": 4,
        },
        "alerts": {
            "enabled": True,
            "basename": "webrtc_qos_udp_alerts",
            "suppress_repeated_alerts_ms": 0,
            "high_loss_fraction_q8": 128,
            "video_drop_frames_threshold": 1,
            "low_target_bps": 700000,
            "low_encoder_fps": 20,
            "max_file_bytes": 1048576,
            "max_files": 4,
        },
    },
    "artifacts": {
        "metadata": "metadata.txt",
        "build_config": "build_config.txt",
        "git_status": "git_status.txt",
        "session_config": "session_config.json",
        "runtime_config": "runtime_config.json",
        "metrics_summary": "metrics/summary.csv",
        "alerts_summary": "alerts/alerts_summary.txt",
        "timeline": "timeline/events.jsonl",
        "first_problem": "timeline/first_problem.json",
    },
    "redaction": {
        "media_bytes": "omitted",
        "raw_frames": "omitted",
        "auth_material": "omitted",
        "absolute_runtime_paths": "omitted",
    },
}

with open(path, "w", encoding="utf-8") as handle:
    json.dump(runtime_config, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

write_summary "phase5_debug_bundle=collecting"
write_summary "output_dir=${OUTPUT_DIR}"

selftest_status=0
if [[ "${RUN_SELFTEST}" == "1" ]]; then
  cmake -S "${SDK_ROOT}" -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DWEBRTC_QOS_ENABLE_WEBRTC_FACADE=ON \
    -DWEBRTC_QOS_WEBRTC_MODULE_PREFIX="${PREFIX}" \
    >"${OUTPUT_DIR}/evidence/cmake_configure.log" 2>&1
  cmake --build "${BUILD_DIR}" \
    --target webrtc_qos_webrtc_first_udp_demo -j2 \
    >"${OUTPUT_DIR}/evidence/cmake_build.log" 2>&1

  demo="${BUILD_DIR}/webrtc_qos_webrtc_first_udp_demo"
  set +e
  "${demo}" selftest "${FRAMES}" \
    --log-dir "${LOG_SOURCE_DIR}" \
    --metrics-dir "${METRICS_SOURCE_DIR}" \
    --alerts-dir "${ALERTS_SOURCE_DIR}" \
    >"${OUTPUT_DIR}/evidence/udp_selftest_output.txt" 2>&1
  selftest_status=$?
  set -e
  write_summary "udp_selftest_status=${selftest_status}"
else
  write_summary "udp_selftest_status=not_run"
  : >"${OUTPUT_DIR}/evidence/udp_selftest_output.txt"
fi

concat_role_files "${LOG_SOURCE_DIR}" push log "${OUTPUT_DIR}/log/push.log"
concat_role_files "${LOG_SOURCE_DIR}" server log "${OUTPUT_DIR}/log/server.log"
concat_role_files "${LOG_SOURCE_DIR}" play log "${OUTPUT_DIR}/log/play.log"

concat_role_files "${METRICS_SOURCE_DIR}" push jsonl \
  "${OUTPUT_DIR}/metrics/push_metrics.jsonl"
concat_role_files "${METRICS_SOURCE_DIR}" server jsonl \
  "${OUTPUT_DIR}/metrics/server_metrics.jsonl"
concat_role_files "${METRICS_SOURCE_DIR}" play jsonl \
  "${OUTPUT_DIR}/metrics/play_metrics.jsonl"

concat_role_files "${ALERTS_SOURCE_DIR}" push jsonl \
  "${OUTPUT_DIR}/alerts/push_alerts.jsonl"
concat_role_files "${ALERTS_SOURCE_DIR}" server jsonl \
  "${OUTPUT_DIR}/alerts/server_alerts.jsonl"
concat_role_files "${ALERTS_SOURCE_DIR}" play jsonl \
  "${OUTPUT_DIR}/alerts/play_alerts.jsonl"
cat "${OUTPUT_DIR}/alerts/"*_alerts.jsonl >"${OUTPUT_DIR}/alerts/alerts.jsonl"

copy_optional_file qoe_csv "${QOE_CSV}" "${OUTPUT_DIR}/evidence/qoe.csv"
copy_optional_file renderer_summary "${RENDERER_SUMMARY}" \
  "${OUTPUT_DIR}/evidence/renderer_summary.txt"

python3 - "${OUTPUT_DIR}" <<'PY'
import csv
import json
import pathlib
import sys
from collections import Counter, defaultdict

root = pathlib.Path(sys.argv[1])

def read_jsonl(path):
    records = []
    if not path.exists():
        return records
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            records.append(json.loads(line))
    return records

metric_rows = []
for role in ("push", "server", "play"):
    records = read_jsonl(root / "metrics" / f"{role}_metrics.jsonl")
    def values(key):
        return [r[key] for r in records if isinstance(r.get(key), (int, float))]
    metric_rows.append({
        "role": role,
        "records": len(records),
        "min_final_target_bps": min(values("final_target_bps") or [0]),
        "max_final_target_bps": max(values("final_target_bps") or [0]),
        "min_adaptation_max_fps": min(values("adaptation_max_fps") or [0]),
        "max_adaptation_max_fps": max(values("adaptation_max_fps") or [0]),
        "max_downlink_loss_q8": max(values("downlink_fraction_lost_q8") or [0]),
        "max_video_drop_frames": max(values("downlink_video_drop_frames") or [0]),
        "max_nack_count": max(values("nack_count") or [0]),
        "max_retransmission_count": max(values("retransmission_count") or [0]),
    })

with (root / "metrics" / "summary.csv").open("w", encoding="utf-8", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=list(metric_rows[0].keys()))
    writer.writeheader()
    writer.writerows(metric_rows)

alerts = read_jsonl(root / "alerts" / "alerts.jsonl")
alert_counts = Counter(
    (a.get("severity", ""), a.get("role", ""), a.get("rule", "")) for a in alerts
)
with (root / "alerts" / "alerts_summary.txt").open("w", encoding="utf-8") as handle:
    handle.write(f"alert_records={len(alerts)}\n")
    for (severity, role, rule), count in sorted(alert_counts.items()):
        handle.write(
            f"severity={severity} role={role} rule={rule} count={count}\n"
        )

events = []
for role in ("push", "server", "play"):
    for record in read_jsonl(root / "log" / f"{role}.log"):
        events.append({
            "ts_us": record.get("ts_us", 0),
            "type": "log",
            "role": record.get("role", role),
            "level": record.get("level", ""),
            "name": record.get("event", ""),
            "session_id": record.get("session_id", 0),
            "track_id": record.get("track_id", 0),
            "receiver_id": record.get("receiver_id", 0),
        })
for record in alerts:
    events.append({
        "ts_us": record.get("ts_us", 0),
        "type": "alert",
        "role": record.get("role", ""),
        "level": record.get("severity", ""),
        "name": record.get("rule", ""),
        "session_id": record.get("session_id", 0),
        "track_id": record.get("track_id", 0),
        "receiver_id": record.get("receiver_id", 0),
    })
for role in ("push", "server", "play"):
    for record in read_jsonl(root / "metrics" / f"{role}_metrics.jsonl"):
        events.append({
            "ts_us": record.get("ts_us", 0),
            "type": "metric",
            "role": record.get("role", role),
            "level": "",
            "name": record.get("scope", "snapshot"),
            "session_id": record.get("session_id", 0),
            "track_id": record.get("track_id", 0),
            "receiver_id": record.get("receiver_id", 0),
        })

events.sort(key=lambda item: (item.get("ts_us", 0), item.get("type", "")))
with (root / "timeline" / "events.jsonl").open("w", encoding="utf-8") as handle:
    for event in events:
        handle.write(json.dumps(event, separators=(",", ":")) + "\n")

problem = {"status": "none"}
for event in events:
    if event.get("level") in {"WARN", "ERROR"}:
        problem = {"status": "found", **event}
        break
with (root / "timeline" / "first_problem.json").open("w", encoding="utf-8") as handle:
    json.dump(problem, handle, indent=2, sort_keys=True)
    handle.write("\n")

role_counts = defaultdict(int)
for event in events:
    role_counts[event.get("role", "")] += 1
with (root / "timeline" / "summary.txt").open("w", encoding="utf-8") as handle:
    handle.write(f"timeline_events={len(events)}\n")
    for role, count in sorted(role_counts.items()):
        handle.write(f"role={role} events={count}\n")
PY

{
  write_summary "metadata=${OUTPUT_DIR}/metadata.txt"
  write_summary "build_config=${OUTPUT_DIR}/build_config.txt"
  write_summary "git_status=${OUTPUT_DIR}/git_status.txt"
  write_summary "session_config=${OUTPUT_DIR}/session_config.json"
  write_summary "runtime_config=${OUTPUT_DIR}/runtime_config.json"
  write_summary "metrics_summary=${OUTPUT_DIR}/metrics/summary.csv"
  write_summary "alerts_summary=${OUTPUT_DIR}/alerts/alerts_summary.txt"
  write_summary "timeline=${OUTPUT_DIR}/timeline/events.jsonl"
  write_summary "first_problem=${OUTPUT_DIR}/timeline/first_problem.json"
  write_summary "files=${FILES_FILE}"
  write_summary "manifest=${MANIFEST_FILE}"
  write_summary "phase5_debug_bundle_status=collected"
} >/dev/null

(
  cd "${OUTPUT_DIR}"
  find . -type f \
    ! -name 'manifest.sha256' \
    ! -name 'files.txt' \
    | sed 's#^\./##' \
    | sort >"${FILES_FILE}"
  while IFS= read -r file; do
    sha256sum "${file}"
  done <"${FILES_FILE}" >"${MANIFEST_FILE}"
)

if [[ "${REQUIRE_SELFTEST_PASS}" == "1" && "${selftest_status}" != "0" ]]; then
  exit "${selftest_status}"
fi
