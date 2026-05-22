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
  "${OUTPUT_DIR}/monitoring" \
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
            "max_process_tick_gap_ms": 2000,
            "max_rtp_output_gap_ms": 2000,
            "max_rtp_input_gap_ms": 2000,
            "consecutive_transport_failures_threshold": 3,
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
        "health_report": "monitoring/health_report.json",
        "health_summary": "monitoring/health_summary.txt",
        "slo_report": "monitoring/slo_report.json",
        "slo_summary": "monitoring/slo_summary.txt",
        "monitoring_metrics": "monitoring/phase5_monitoring_metrics.prom",
        "alert_policy": "monitoring/alert_policy.json",
        "alert_policy_summary": "monitoring/alert_policy_summary.txt",
        "incident_report": "monitoring/incident_report.json",
        "incident_runbook": "monitoring/incident_runbook.txt",
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
    def max_value(key):
        return max(values(key) or [0])
    max_tick_gap_record = max(
        records,
        key=lambda r: r.get("max_process_tick_gap_us", 0)
        if isinstance(r.get("max_process_tick_gap_us"), (int, float))
        else 0,
        default={},
    )
    metric_rows.append({
        "role": role,
        "records": len(records),
        "min_final_target_bps": min(values("final_target_bps") or [0]),
        "max_final_target_bps": max_value("final_target_bps"),
        "min_adaptation_max_fps": min(values("adaptation_max_fps") or [0]),
        "max_adaptation_max_fps": max_value("adaptation_max_fps"),
        "max_downlink_loss_q8": max_value("downlink_fraction_lost_q8"),
        "max_video_drop_frames": max_value("downlink_video_drop_frames"),
        "max_nack_count": max_value("nack_count"),
        "max_retransmission_count": max_value("retransmission_count"),
        "max_process_tick_gap_us": max_value("max_process_tick_gap_us"),
        "max_rtp_output_gap_us": max_value("max_rtp_output_gap_us"),
        "max_rtp_input_gap_us": max_value("max_rtp_input_gap_us"),
        "max_consecutive_transport_failures": max_value(
            "max_consecutive_transport_failures"
        ),
        "max_tick_gap_session_id": max_tick_gap_record.get("session_id", 0),
        "max_tick_gap_track_id": max_tick_gap_record.get("track_id", 0),
        "max_tick_gap_receiver_id": max_tick_gap_record.get("receiver_id", 0),
    })

with (root / "metrics" / "summary.csv").open("w", encoding="utf-8", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=list(metric_rows[0].keys()))
    writer.writeheader()
    writer.writerows(metric_rows)

alerts = read_jsonl(root / "alerts" / "alerts.jsonl")
alert_counts = Counter(
    (a.get("severity", ""), a.get("role", ""), a.get("rule", "")) for a in alerts
)
alert_category_counts = Counter(
    (a.get("role", ""), a.get("category", "")) for a in alerts
)
first_alert = min(alerts, key=lambda a: a.get("ts_us", 0), default={})
with (root / "alerts" / "alerts_summary.txt").open("w", encoding="utf-8") as handle:
    handle.write(f"alert_records={len(alerts)}\n")
    if first_alert:
        handle.write(
            "first_alert="
            f"ts_us={first_alert.get('ts_us', 0)} "
            f"severity={first_alert.get('severity', '')} "
            f"role={first_alert.get('role', '')} "
            f"rule={first_alert.get('rule', '')} "
            f"category={first_alert.get('category', '')} "
            f"track_id={first_alert.get('track_id', 0)} "
            f"receiver_id={first_alert.get('receiver_id', 0)}\n"
        )
    for (role, category), count in sorted(alert_category_counts.items()):
        handle.write(f"role={role} category={category} count={count}\n")
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
type_counts = Counter(event.get("type", "") for event in events)
for event in events:
    role_counts[event.get("role", "")] += 1
with (root / "timeline" / "summary.txt").open("w", encoding="utf-8") as handle:
    handle.write(f"timeline_events={len(events)}\n")
    for event_type, count in sorted(type_counts.items()):
        handle.write(f"type={event_type} events={count}\n")
    for role, count in sorted(role_counts.items()):
        handle.write(f"role={role} events={count}\n")
    if problem.get("status") == "found":
        handle.write(
            "first_problem="
            f"type={problem.get('type', '')} "
            f"level={problem.get('level', '')} "
            f"role={problem.get('role', '')} "
            f"name={problem.get('name', '')} "
            f"track_id={problem.get('track_id', 0)} "
            f"receiver_id={problem.get('receiver_id', 0)}\n"
        )

metric_by_role = {row["role"]: row for row in metric_rows}
alert_records_by_role = Counter(a.get("role", "") for a in alerts)
alert_rule_counts = Counter(a.get("rule", "") for a in alerts)
alert_role_rule_counts = Counter((a.get("role", ""), a.get("rule", "")) for a in alerts)
alert_categories_by_role = defaultdict(Counter)
alert_rules_by_role = defaultdict(Counter)
for alert in alerts:
    role = alert.get("role", "")
    alert_categories_by_role[role][alert.get("category", "")] += 1
    alert_rules_by_role[role][alert.get("rule", "")] += 1

top_alert_rules = [
    {"severity": severity, "role": role, "rule": rule, "count": count}
    for (severity, role, rule), count in alert_counts.most_common(10)
]

recommended_actions = []
action_by_category = {
    "availability": "inspect process tick gaps, RTP flow gaps, and transport callback failures for the affected role",
    "media_quality": "inspect codec/render health, frame drops, and target bitrate/FPS adaptation for the affected track",
    "network_qos": "inspect downlink loss, NACK rate, retransmission hit/miss, and UDP transport path",
}
for (role, category), count in sorted(alert_category_counts.items()):
    if not category:
        continue
    recommended_actions.append({
        "role": role,
        "category": category,
        "count": count,
        "required": action_by_category.get(
            category,
            "inspect role logs, metrics, alerts, and timeline around the first problem",
        ),
    })

runtime_config = json.loads((root / "runtime_config.json").read_text(encoding="utf-8"))
runtime_alerts = runtime_config.get("runtime", {}).get("alerts", {})
alert_policy_rules = [
    {
        "rule": "process_tick_gap",
        "category": "availability",
        "severity": "WARN",
        "roles": ["push", "server", "play"],
        "enabled_by": "alert_on_process_tick_gap",
        "threshold_ref": "max_process_tick_gap_ms",
        "default_threshold": runtime_alerts.get("max_process_tick_gap_ms", 2000),
        "unit": "ms",
        "required_action": "inspect role worker scheduling and process loop stalls",
    },
    {
        "rule": "sender_rtp_output_gap",
        "category": "availability",
        "severity": "WARN",
        "roles": ["push", "server"],
        "enabled_by": "alert_on_media_flow_gap",
        "threshold_ref": "max_rtp_output_gap_ms",
        "default_threshold": runtime_alerts.get("max_rtp_output_gap_ms", 2000),
        "unit": "ms",
        "required_action": "inspect RTP output path, pacing, and transport callback health",
    },
    {
        "rule": "receiver_rtp_input_gap",
        "category": "availability",
        "severity": "WARN",
        "roles": ["play"],
        "enabled_by": "alert_on_media_flow_gap",
        "threshold_ref": "max_rtp_input_gap_ms",
        "default_threshold": runtime_alerts.get("max_rtp_input_gap_ms", 2000),
        "unit": "ms",
        "required_action": "inspect receiver RTP input path and upstream transport continuity",
    },
    {
        "rule": "consecutive_transport_failures",
        "category": "availability",
        "severity": "WARN",
        "roles": ["push", "server", "play"],
        "enabled_by": "alert_on_transport_failure",
        "threshold_ref": "consecutive_transport_failures_threshold",
        "default_threshold": runtime_alerts.get("consecutive_transport_failures_threshold", 3),
        "unit": "failures",
        "required_action": "inspect transport callback failures and downstream UDP send path",
    },
    {
        "rule": "transport_output_failed",
        "category": "availability",
        "severity": "ERROR",
        "roles": ["push", "play"],
        "enabled_by": "alert_on_transport_failure",
        "threshold_ref": "status_code",
        "default_threshold": "non_ok",
        "unit": "status",
        "required_action": "inspect business transport callback return status and socket errors",
    },
    {
        "rule": "sender_output_failed",
        "category": "availability",
        "severity": "ERROR",
        "roles": ["server"],
        "enabled_by": "alert_on_transport_failure",
        "threshold_ref": "status_code",
        "default_threshold": "non_ok",
        "unit": "status",
        "required_action": "inspect server sender-side transport callback and upstream path",
    },
    {
        "rule": "receiver_output_failed",
        "category": "availability",
        "severity": "ERROR",
        "roles": ["server"],
        "enabled_by": "alert_on_transport_failure",
        "threshold_ref": "status_code",
        "default_threshold": "non_ok",
        "unit": "status",
        "required_action": "inspect server receiver-side transport callback and downstream path",
    },
    {
        "rule": "low_target_bitrate",
        "category": "media_quality",
        "severity": "WARN",
        "roles": ["push"],
        "enabled_by": "alert_on_qos_degradation",
        "threshold_ref": "low_target_bps",
        "default_threshold": runtime_alerts.get("low_target_bps", 700000),
        "unit": "bps",
        "required_action": "inspect congestion feedback, sender caps, and weak-network adaptation",
    },
    {
        "rule": "low_encoder_fps",
        "category": "media_quality",
        "severity": "WARN",
        "roles": ["push"],
        "enabled_by": "alert_on_qos_degradation",
        "threshold_ref": "low_encoder_fps",
        "default_threshold": runtime_alerts.get("low_encoder_fps", 20),
        "unit": "fps",
        "required_action": "inspect encoder pacing, input frame cadence, and adaptation state",
    },
    {
        "rule": "video_drop_frames",
        "category": "media_quality",
        "severity": "WARN",
        "roles": ["server"],
        "enabled_by": "alert_on_media_failure",
        "threshold_ref": "video_drop_frames_threshold",
        "default_threshold": runtime_alerts.get("video_drop_frames_threshold", 1),
        "unit": "frames",
        "required_action": "inspect downstream video drop and receiver QoE evidence",
    },
    {
        "rule": "decode_output_failed",
        "category": "media_quality",
        "severity": "ERROR",
        "roles": ["play"],
        "enabled_by": "alert_on_media_failure",
        "threshold_ref": "status_code",
        "default_threshold": "non_ok",
        "unit": "status",
        "required_action": "inspect decoder/render callback status and decoded AU path",
    },
    {
        "rule": "pacer_enqueue_failed",
        "category": "media_quality",
        "severity": "ERROR",
        "roles": ["push"],
        "enabled_by": "alert_on_media_failure",
        "threshold_ref": "status_code",
        "default_threshold": "non_ok",
        "unit": "status",
        "required_action": "inspect pacer queue capacity and sender media flow",
    },
    {
        "rule": "malformed_h264",
        "category": "media_quality",
        "severity": "ERROR",
        "roles": ["push"],
        "enabled_by": "alert_on_malformed_packet",
        "threshold_ref": "parse_status",
        "default_threshold": "malformed",
        "unit": "status",
        "required_action": "inspect encoder Annex-B framing and H264 access unit boundaries",
    },
    {
        "rule": "pli_generated",
        "category": "media_quality",
        "severity": "WARN",
        "roles": ["play"],
        "enabled_by": "alert_on_recovery_events",
        "threshold_ref": "event_count",
        "default_threshold": 1,
        "unit": "events",
        "required_action": "inspect keyframe request frequency and loss recovery behavior",
    },
    {
        "rule": "jitter_packet_drop",
        "category": "media_quality",
        "severity": "WARN",
        "roles": ["play"],
        "enabled_by": "alert_on_media_failure",
        "threshold_ref": "event_count",
        "default_threshold": 1,
        "unit": "events",
        "required_action": "inspect jitter buffer pressure and RTP ordering/loss",
    },
    {
        "rule": "high_downlink_loss",
        "category": "network_qos",
        "severity": "WARN",
        "roles": ["server"],
        "enabled_by": "alert_on_qos_degradation",
        "threshold_ref": "high_loss_fraction_q8",
        "default_threshold": runtime_alerts.get("high_loss_fraction_q8", 128),
        "unit": "q8_fraction",
        "required_action": "inspect downstream loss, NACK rate, and UDP path quality",
    },
    {
        "rule": "nack_generated",
        "category": "network_qos",
        "severity": "WARN",
        "roles": ["play"],
        "enabled_by": "alert_on_qos_degradation",
        "threshold_ref": "event_count",
        "default_threshold": 1,
        "unit": "events",
        "required_action": "inspect RTP loss/reordering and sender/server retransmission availability",
    },
    {
        "rule": "local_retransmission_hit",
        "category": "network_qos",
        "severity": "WARN",
        "roles": ["server"],
        "enabled_by": "alert_on_recovery_events",
        "threshold_ref": "event_count",
        "default_threshold": 1,
        "unit": "events",
        "required_action": "inspect downlink loss and local retransmission effectiveness",
    },
    {
        "rule": "local_retransmission_miss",
        "category": "network_qos",
        "severity": "WARN",
        "roles": ["server"],
        "enabled_by": "alert_on_recovery_events",
        "threshold_ref": "event_count",
        "default_threshold": 1,
        "unit": "events",
        "required_action": "inspect packet history retention and upstream retransmission path",
    },
    {
        "rule": "sender_retransmission_enqueue",
        "category": "network_qos",
        "severity": "WARN",
        "roles": ["push"],
        "enabled_by": "alert_on_recovery_events",
        "threshold_ref": "event_count",
        "default_threshold": 1,
        "unit": "events",
        "required_action": "inspect sender retransmission volume and NACK pressure",
    },
    {
        "rule": "sender_retransmission_drop",
        "category": "network_qos",
        "severity": "WARN",
        "roles": ["push"],
        "enabled_by": "alert_on_recovery_events",
        "threshold_ref": "event_count",
        "default_threshold": 1,
        "unit": "events",
        "required_action": "inspect sender packet history gaps and retransmission build failures",
    },
    {
        "rule": "malformed_rtp",
        "category": "network_qos",
        "severity": "ERROR",
        "roles": ["server", "play"],
        "enabled_by": "alert_on_malformed_packet",
        "threshold_ref": "parse_status",
        "default_threshold": "malformed",
        "unit": "status",
        "required_action": "inspect RTP framing at UDP boundary and upstream sender behavior",
    },
    {
        "rule": "malformed_rtcp",
        "category": "network_qos",
        "severity": "ERROR",
        "roles": ["push", "server", "play"],
        "enabled_by": "alert_on_malformed_packet",
        "threshold_ref": "parse_status",
        "default_threshold": "malformed",
        "unit": "status",
        "required_action": "inspect RTCP framing and feedback identity at UDP boundary",
    },
    {
        "rule": "unsupported_rtcp",
        "category": "network_qos",
        "severity": "WARN",
        "roles": ["server"],
        "enabled_by": "alert_on_malformed_packet",
        "threshold_ref": "packet_type",
        "default_threshold": "unsupported",
        "unit": "type",
        "required_action": "inspect RTCP packet type compatibility and upstream control path",
    },
]

for rule in alert_policy_rules:
    name = rule["rule"]
    rule["observed_count"] = alert_rule_counts.get(name, 0)
    rule["observed_by_role"] = {
        role: alert_role_rule_counts.get((role, name), 0) for role in rule["roles"]
    }

alert_policy = {
    "schema_version": 1,
    "source": "phase5_debug_bundle",
    "policy_name": "phase5_default_runtime_alert_policy",
    "runtime_thresholds": {
        "suppress_repeated_alerts_ms": runtime_alerts.get("suppress_repeated_alerts_ms", 0),
        "high_loss_fraction_q8": runtime_alerts.get("high_loss_fraction_q8", 128),
        "video_drop_frames_threshold": runtime_alerts.get("video_drop_frames_threshold", 1),
        "low_target_bps": runtime_alerts.get("low_target_bps", 700000),
        "low_encoder_fps": runtime_alerts.get("low_encoder_fps", 20),
        "max_process_tick_gap_ms": runtime_alerts.get("max_process_tick_gap_ms", 2000),
        "max_rtp_output_gap_ms": runtime_alerts.get("max_rtp_output_gap_ms", 2000),
        "max_rtp_input_gap_ms": runtime_alerts.get("max_rtp_input_gap_ms", 2000),
        "consecutive_transport_failures_threshold": runtime_alerts.get(
            "consecutive_transport_failures_threshold", 3
        ),
    },
    "categories": {
        "availability": "process loop, media flow, and transport callback health",
        "media_quality": "codec, render, adaptation, and media continuity health",
        "network_qos": "loss, feedback, retransmission, and malformed network input health",
    },
    "rules": alert_policy_rules,
    "observed_rules": dict(sorted(alert_rule_counts.items())),
    "artifacts": {
        "alerts": "alerts/alerts.jsonl",
        "alerts_summary": "alerts/alerts_summary.txt",
        "health_report": "monitoring/health_report.json",
        "monitoring_metrics": "monitoring/phase5_monitoring_metrics.prom",
        "timeline": "timeline/events.jsonl",
    },
}
with (root / "monitoring" / "alert_policy.json").open(
    "w", encoding="utf-8"
) as handle:
    json.dump(alert_policy, handle, indent=2, sort_keys=True)
    handle.write("\n")

with (root / "monitoring" / "alert_policy_summary.txt").open(
    "w", encoding="utf-8"
) as handle:
    handle.write("policy_name=phase5_default_runtime_alert_policy\n")
    handle.write(f"policy_rules={len(alert_policy_rules)}\n")
    for category in ("availability", "media_quality", "network_qos"):
        count = sum(1 for rule in alert_policy_rules if rule["category"] == category)
        observed = sum(
            rule["observed_count"]
            for rule in alert_policy_rules
            if rule["category"] == category
        )
        handle.write(f"category={category} rules={count} observed={observed}\n")
    for rule in alert_policy_rules:
        handle.write(
            f"rule={rule['rule']} category={rule['category']} "
            f"severity={rule['severity']} roles={','.join(rule['roles'])} "
            f"threshold_ref={rule['threshold_ref']} observed={rule['observed_count']} "
            f"action={rule['required_action']}\n"
        )

role_health = {}
for role in ("push", "server", "play"):
    metrics = metric_by_role.get(role, {})
    role_alert_count = alert_records_by_role.get(role, 0)
    role_health[role] = {
        "status": "attention_required" if role_alert_count else "ok",
        "metric_records": int(metrics.get("records", 0) or 0),
        "alert_records": role_alert_count,
        "alert_categories": dict(sorted(alert_categories_by_role[role].items())),
        "alert_rules": dict(sorted(alert_rules_by_role[role].items())),
        "max_process_tick_gap_us": int(
            metrics.get("max_process_tick_gap_us", 0) or 0
        ),
        "max_rtp_output_gap_us": int(metrics.get("max_rtp_output_gap_us", 0) or 0),
        "max_rtp_input_gap_us": int(metrics.get("max_rtp_input_gap_us", 0) or 0),
        "max_consecutive_transport_failures": int(
            metrics.get("max_consecutive_transport_failures", 0) or 0
        ),
        "max_tick_gap_identity": {
            "session_id": int(metrics.get("max_tick_gap_session_id", 0) or 0),
            "track_id": int(metrics.get("max_tick_gap_track_id", 0) or 0),
            "receiver_id": int(metrics.get("max_tick_gap_receiver_id", 0) or 0),
        },
    }

health_status = "attention_required" if alerts or problem.get("status") == "found" else "ok"
health_report = {
    "schema_version": 1,
    "source": "phase5_debug_bundle",
    "health_status": health_status,
    "roles": role_health,
    "totals": {
        "log_events": type_counts.get("log", 0),
        "metric_events": type_counts.get("metric", 0),
        "alert_events": type_counts.get("alert", 0),
        "timeline_events": len(events),
        "alert_records": len(alerts),
    },
    "first_problem": problem,
    "top_alert_rules": top_alert_rules,
    "recommended_actions": recommended_actions,
    "artifacts": {
        "metrics_summary": "metrics/summary.csv",
        "alerts_summary": "alerts/alerts_summary.txt",
        "timeline_summary": "timeline/summary.txt",
        "first_problem": "timeline/first_problem.json",
        "slo_report": "monitoring/slo_report.json",
        "slo_summary": "monitoring/slo_summary.txt",
        "monitoring_metrics": "monitoring/phase5_monitoring_metrics.prom",
        "alert_policy": "monitoring/alert_policy.json",
        "alert_policy_summary": "monitoring/alert_policy_summary.txt",
        "incident_report": "monitoring/incident_report.json",
        "incident_runbook": "monitoring/incident_runbook.txt",
    },
}
with (root / "monitoring" / "health_report.json").open(
    "w", encoding="utf-8"
) as handle:
    json.dump(health_report, handle, indent=2, sort_keys=True)
    handle.write("\n")

with (root / "monitoring" / "health_summary.txt").open(
    "w", encoding="utf-8"
) as handle:
    handle.write(f"health_status={health_status}\n")
    handle.write(f"alert_records={len(alerts)}\n")
    handle.write(f"timeline_events={len(events)}\n")
    if problem.get("status") == "found":
        handle.write(
            "first_problem="
            f"type={problem.get('type', '')} "
            f"level={problem.get('level', '')} "
            f"role={problem.get('role', '')} "
            f"name={problem.get('name', '')} "
            f"track_id={problem.get('track_id', 0)} "
            f"receiver_id={problem.get('receiver_id', 0)}\n"
        )
    for role, info in sorted(role_health.items()):
        handle.write(
            f"role={role} status={info['status']} "
            f"metric_records={info['metric_records']} "
            f"alert_records={info['alert_records']} "
            f"max_process_tick_gap_us={info['max_process_tick_gap_us']} "
            f"max_rtp_output_gap_us={info['max_rtp_output_gap_us']} "
            f"max_rtp_input_gap_us={info['max_rtp_input_gap_us']} "
            f"max_consecutive_transport_failures={info['max_consecutive_transport_failures']}\n"
        )
    for action in recommended_actions:
        handle.write(
            f"recommended_action=role={action['role']} "
            f"category={action['category']} count={action['count']} "
            f"required={action['required']}\n"
        )

def max_metric(field):
    values = []
    for row in metric_rows:
        try:
            values.append(int(row.get(field, 0) or 0))
        except ValueError:
            values.append(0)
    return max(values or [0])

alert_count_by_category = Counter(alert.get("category", "") for alert in alerts)
slo_objectives = [
    {
        "id": "availability.process_tick_gap",
        "category": "availability",
        "target": "max_process_tick_gap_us <= max_process_tick_gap_ms",
        "observed": max_metric("max_process_tick_gap_us"),
        "threshold": int(runtime_alerts.get("max_process_tick_gap_ms", 2000)) * 1000,
        "unit": "us",
        "source": "metrics/summary.csv",
        "recommended_action": "inspect role worker scheduling and process loop stalls",
    },
    {
        "id": "availability.rtp_output_gap",
        "category": "availability",
        "target": "max_rtp_output_gap_us <= max_rtp_output_gap_ms",
        "observed": max_metric("max_rtp_output_gap_us"),
        "threshold": int(runtime_alerts.get("max_rtp_output_gap_ms", 2000)) * 1000,
        "unit": "us",
        "source": "metrics/summary.csv",
        "recommended_action": "inspect sender/server RTP output continuity and transport callback health",
    },
    {
        "id": "availability.rtp_input_gap",
        "category": "availability",
        "target": "max_rtp_input_gap_us <= max_rtp_input_gap_ms",
        "observed": max_metric("max_rtp_input_gap_us"),
        "threshold": int(runtime_alerts.get("max_rtp_input_gap_ms", 2000)) * 1000,
        "unit": "us",
        "source": "metrics/summary.csv",
        "recommended_action": "inspect receiver RTP input continuity and upstream packet flow",
    },
    {
        "id": "availability.consecutive_transport_failures",
        "category": "availability",
        "target": "max_consecutive_transport_failures < threshold",
        "observed": max_metric("max_consecutive_transport_failures"),
        "threshold": int(runtime_alerts.get("consecutive_transport_failures_threshold", 3)),
        "unit": "failures",
        "source": "metrics/summary.csv",
        "recommended_action": "inspect transport callback failures and downstream UDP send path",
    },
    {
        "id": "media_quality.low_target_bitrate_alerts",
        "category": "media_quality",
        "target": "low_target_bitrate alerts == 0 outside expected weak-network tests",
        "observed": alert_rule_counts.get("low_target_bitrate", 0),
        "threshold": 0,
        "unit": "alerts",
        "source": "alerts/alerts_summary.txt",
        "recommended_action": "inspect congestion feedback, sender caps, and weak-network adaptation",
    },
    {
        "id": "media_quality.video_drop_alerts",
        "category": "media_quality",
        "target": "video_drop_frames alerts == 0",
        "observed": alert_rule_counts.get("video_drop_frames", 0),
        "threshold": 0,
        "unit": "alerts",
        "source": "alerts/alerts_summary.txt",
        "recommended_action": "inspect downstream video drop and receiver QoE evidence",
    },
    {
        "id": "network_qos.high_loss_alerts",
        "category": "network_qos",
        "target": "high_downlink_loss alerts == 0 outside expected weak-network tests",
        "observed": alert_rule_counts.get("high_downlink_loss", 0),
        "threshold": 0,
        "unit": "alerts",
        "source": "alerts/alerts_summary.txt",
        "recommended_action": "inspect downstream loss, NACK rate, retransmission hit/miss, and UDP path quality",
    },
    {
        "id": "network_qos.nack_recovery_alerts",
        "category": "network_qos",
        "target": "NACK/retransmission alerts are explainable by test scenario",
        "observed": alert_rule_counts.get("nack_generated", 0)
        + alert_rule_counts.get("local_retransmission_hit", 0),
        "threshold": 0,
        "unit": "alerts",
        "source": "alerts/alerts_summary.txt",
        "recommended_action": "inspect RTP loss/reordering and retransmission effectiveness",
    },
]

for item in slo_objectives:
    if item["unit"] == "alerts":
        item["status"] = "warn" if int(item["observed"]) > int(item["threshold"]) else "pass"
    elif item["id"] == "availability.consecutive_transport_failures":
        item["status"] = "fail" if int(item["observed"]) >= int(item["threshold"]) else "pass"
    else:
        item["status"] = "fail" if int(item["observed"]) > int(item["threshold"]) else "pass"

slo_status = (
    "fail"
    if any(item["status"] == "fail" for item in slo_objectives)
    else "warn"
    if any(item["status"] == "warn" for item in slo_objectives)
    else "pass"
)
slo_report = {
    "schema_version": 1,
    "source": "phase5_debug_bundle",
    "slo_status": slo_status,
    "scope": "single debug bundle run; not a production SLO claim",
    "categories": {
        "availability": "process loop, RTP flow, and transport callback continuity",
        "media_quality": "adaptation, video drop, decode/render health indicators",
        "network_qos": "loss, NACK, retransmission, and UDP path indicators",
    },
    "runtime_thresholds": {
        "max_process_tick_gap_ms": runtime_alerts.get("max_process_tick_gap_ms", 2000),
        "max_rtp_output_gap_ms": runtime_alerts.get("max_rtp_output_gap_ms", 2000),
        "max_rtp_input_gap_ms": runtime_alerts.get("max_rtp_input_gap_ms", 2000),
        "consecutive_transport_failures_threshold": runtime_alerts.get(
            "consecutive_transport_failures_threshold", 3
        ),
    },
    "objectives": slo_objectives,
    "category_status": {
        category: (
            "fail"
            if any(
                item["category"] == category and item["status"] == "fail"
                for item in slo_objectives
            )
            else "warn"
            if any(
                item["category"] == category and item["status"] == "warn"
                for item in slo_objectives
            )
            else "pass"
        )
        for category in ("availability", "media_quality", "network_qos")
    },
    "observed_alert_categories": dict(sorted(alert_count_by_category.items())),
    "artifacts": {
        "metrics_summary": "metrics/summary.csv",
        "alerts_summary": "alerts/alerts_summary.txt",
        "health_report": "monitoring/health_report.json",
        "alert_policy": "monitoring/alert_policy.json",
        "monitoring_metrics": "monitoring/phase5_monitoring_metrics.prom",
        "timeline": "timeline/events.jsonl",
    },
}
with (root / "monitoring" / "slo_report.json").open(
    "w", encoding="utf-8"
) as handle:
    json.dump(slo_report, handle, indent=2, sort_keys=True)
    handle.write("\n")

with (root / "monitoring" / "slo_summary.txt").open(
    "w", encoding="utf-8"
) as handle:
    handle.write(f"slo_status={slo_status}\n")
    handle.write("scope=single_debug_bundle_run_not_production_slo_claim\n")
    for category, status in sorted(slo_report["category_status"].items()):
        observed = alert_count_by_category.get(category, 0)
        handle.write(f"category={category} status={status} observed_alerts={observed}\n")
    for item in slo_objectives:
        handle.write(
            f"objective={item['id']} category={item['category']} "
            f"status={item['status']} observed={item['observed']} "
            f"threshold={item['threshold']} unit={item['unit']} "
            f"action={item['recommended_action']}\n"
        )

first_problem_role = problem.get("role", "")
incident_steps = []
incident_steps.append({
    "step": 1,
    "name": "open_first_problem",
    "required_action": "start from timeline/first_problem.json and confirm role, rule, track_id, receiver_id, and timestamp",
    "artifacts": ["timeline/first_problem.json", "timeline/summary.txt"],
})
incident_steps.append({
    "step": 2,
    "name": "check_health_report",
    "required_action": "inspect role health, SLO status, top alert rules, and recommended actions",
    "artifacts": [
        "monitoring/health_report.json",
        "monitoring/health_summary.txt",
        "monitoring/slo_report.json",
        "monitoring/slo_summary.txt",
        "monitoring/phase5_monitoring_metrics.prom",
    ],
})
incident_steps.append({
    "step": 3,
    "name": "confirm_alert_policy",
    "required_action": "confirm the triggered alert rule, threshold source, default threshold, role scope, and policy action",
    "artifacts": [
        "monitoring/alert_policy.json",
        "monitoring/alert_policy_summary.txt",
    ],
})
incident_steps.append({
    "step": 4,
    "name": "inspect_role_artifacts",
    "required_action": "open the affected role log, metrics, and alert stream around the first problem timestamp",
    "artifacts": [
        f"log/{first_problem_role}.log" if first_problem_role else "log/{role}.log",
        f"metrics/{first_problem_role}_metrics.jsonl"
        if first_problem_role
        else "metrics/{role}_metrics.jsonl",
        f"alerts/{first_problem_role}_alerts.jsonl"
        if first_problem_role
        else "alerts/{role}_alerts.jsonl",
    ],
})
incident_steps.append({
    "step": 5,
    "name": "correlate_timeline",
    "required_action": "correlate log, metric, and alert events before and after the first problem",
    "artifacts": ["timeline/events.jsonl", "metrics/summary.csv", "alerts/alerts_summary.txt"],
})
incident_steps.append({
    "step": 6,
    "name": "check_runtime_context",
    "required_action": "confirm build, git, runtime config, redaction markers, and transport boundary",
    "artifacts": [
        "metadata.txt",
        "build_config.txt",
        "git_status.txt",
        "runtime_config.json",
        "session_config.json",
    ],
})
incident_steps.append({
    "step": 7,
    "name": "verify_bundle_integrity",
    "required_action": "run sha256 manifest verification before trusting the incident bundle",
    "artifacts": ["manifest.sha256", "files.txt"],
})

incident_report = {
    "schema_version": 1,
    "source": "phase5_debug_bundle",
    "incident_status": health_status,
    "first_problem": problem,
    "affected_role": first_problem_role,
    "top_alert_rules": top_alert_rules[:5],
    "recommended_actions": recommended_actions,
    "runbook_steps": incident_steps,
    "evidence_index": {
        "health_report": "monitoring/health_report.json",
        "slo_report": "monitoring/slo_report.json",
        "alert_policy": "monitoring/alert_policy.json",
        "monitoring_metrics": "monitoring/phase5_monitoring_metrics.prom",
        "timeline": "timeline/events.jsonl",
        "first_problem": "timeline/first_problem.json",
        "metrics_summary": "metrics/summary.csv",
        "alerts_summary": "alerts/alerts_summary.txt",
        "runtime_config": "runtime_config.json",
    },
}
with (root / "monitoring" / "incident_report.json").open(
    "w", encoding="utf-8"
) as handle:
    json.dump(incident_report, handle, indent=2, sort_keys=True)
    handle.write("\n")

with (root / "monitoring" / "incident_runbook.txt").open(
    "w", encoding="utf-8"
) as handle:
    handle.write("incident_runbook=phase5_debug_bundle\n")
    handle.write(f"incident_status={health_status}\n")
    if problem.get("status") == "found":
        handle.write(
            "first_problem="
            f"type={problem.get('type', '')} "
            f"level={problem.get('level', '')} "
            f"role={problem.get('role', '')} "
            f"name={problem.get('name', '')} "
            f"track_id={problem.get('track_id', 0)} "
            f"receiver_id={problem.get('receiver_id', 0)}\n"
        )
    for item in incident_steps:
        handle.write(
            f"step={item['step']} name={item['name']} "
            f"action={item['required_action']} "
            f"artifacts={','.join(item['artifacts'])}\n"
        )
    for action in recommended_actions:
        handle.write(
            f"recommended_action=role={action['role']} "
            f"category={action['category']} count={action['count']} "
            f"required={action['required']}\n"
        )


def prom_escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def prom_labels(**labels):
    items = [
        f'{key}="{prom_escape(value)}"'
        for key, value in sorted(labels.items())
        if value is not None and value != ""
    ]
    return "{" + ",".join(items) + "}" if items else ""


with (root / "monitoring" / "phase5_monitoring_metrics.prom").open(
    "w", encoding="utf-8"
) as handle:
    handle.write("# HELP webrtc_qos_phase5_debug_bundle_info Phase-5 debug bundle metadata marker.\n")
    handle.write("# TYPE webrtc_qos_phase5_debug_bundle_info gauge\n")
    handle.write(
        "webrtc_qos_phase5_debug_bundle_info"
        f"{prom_labels(source='phase5_debug_bundle', health_status=health_status, slo_status=slo_status)} 1\n"
    )
    handle.write("# HELP webrtc_qos_phase5_debug_bundle_timeline_events_total Timeline events by type.\n")
    handle.write("# TYPE webrtc_qos_phase5_debug_bundle_timeline_events_total counter\n")
    for event_type, count in sorted(type_counts.items()):
        handle.write(
            "webrtc_qos_phase5_debug_bundle_timeline_events_total"
            f"{prom_labels(type=event_type)} {count}\n"
        )
    handle.write("# HELP webrtc_qos_phase5_debug_bundle_alerts_total Alert records by role/category/rule/severity.\n")
    handle.write("# TYPE webrtc_qos_phase5_debug_bundle_alerts_total counter\n")
    for (severity, role, rule), count in sorted(alert_counts.items()):
        category = next(
            (
                item.get("category", "")
                for item in alerts
                if item.get("severity", "") == severity
                and item.get("role", "") == role
                and item.get("rule", "") == rule
            ),
            "",
        )
        handle.write(
            "webrtc_qos_phase5_debug_bundle_alerts_total"
            f"{prom_labels(role=role, category=category, rule=rule, severity=severity)} {count}\n"
        )
    handle.write("# HELP webrtc_qos_phase5_debug_bundle_role_metric_records Runtime metric records by role.\n")
    handle.write("# TYPE webrtc_qos_phase5_debug_bundle_role_metric_records gauge\n")
    handle.write("# HELP webrtc_qos_phase5_debug_bundle_role_max_process_tick_gap_us Max process tick gap by role.\n")
    handle.write("# TYPE webrtc_qos_phase5_debug_bundle_role_max_process_tick_gap_us gauge\n")
    handle.write("# HELP webrtc_qos_phase5_debug_bundle_role_max_rtp_output_gap_us Max RTP output gap by role.\n")
    handle.write("# TYPE webrtc_qos_phase5_debug_bundle_role_max_rtp_output_gap_us gauge\n")
    handle.write("# HELP webrtc_qos_phase5_debug_bundle_role_max_rtp_input_gap_us Max RTP input gap by role.\n")
    handle.write("# TYPE webrtc_qos_phase5_debug_bundle_role_max_rtp_input_gap_us gauge\n")
    handle.write("# HELP webrtc_qos_phase5_debug_bundle_role_max_consecutive_transport_failures Max consecutive transport failures by role.\n")
    handle.write("# TYPE webrtc_qos_phase5_debug_bundle_role_max_consecutive_transport_failures gauge\n")
    for role, info in sorted(role_health.items()):
        labels = prom_labels(role=role, status=info.get("status", ""))
        handle.write(
            f"webrtc_qos_phase5_debug_bundle_role_metric_records{labels} {info['metric_records']}\n"
        )
        handle.write(
            f"webrtc_qos_phase5_debug_bundle_role_max_process_tick_gap_us{labels} {info['max_process_tick_gap_us']}\n"
        )
        handle.write(
            f"webrtc_qos_phase5_debug_bundle_role_max_rtp_output_gap_us{labels} {info['max_rtp_output_gap_us']}\n"
        )
        handle.write(
            f"webrtc_qos_phase5_debug_bundle_role_max_rtp_input_gap_us{labels} {info['max_rtp_input_gap_us']}\n"
        )
        handle.write(
            "webrtc_qos_phase5_debug_bundle_role_max_consecutive_transport_failures"
            f"{labels} {info['max_consecutive_transport_failures']}\n"
        )
    handle.write("# HELP webrtc_qos_phase5_debug_bundle_slo_objective_status SLO objective status marker.\n")
    handle.write("# TYPE webrtc_qos_phase5_debug_bundle_slo_objective_status gauge\n")
    handle.write("# HELP webrtc_qos_phase5_debug_bundle_slo_objective_observed SLO objective observed value.\n")
    handle.write("# TYPE webrtc_qos_phase5_debug_bundle_slo_objective_observed gauge\n")
    handle.write("# HELP webrtc_qos_phase5_debug_bundle_slo_objective_threshold SLO objective threshold value.\n")
    handle.write("# TYPE webrtc_qos_phase5_debug_bundle_slo_objective_threshold gauge\n")
    for item in slo_objectives:
        labels = prom_labels(
            objective=item["id"],
            category=item["category"],
            status=item["status"],
            unit=item["unit"],
        )
        handle.write(
            f"webrtc_qos_phase5_debug_bundle_slo_objective_status{labels} 1\n"
        )
        handle.write(
            f"webrtc_qos_phase5_debug_bundle_slo_objective_observed{labels} {item['observed']}\n"
        )
        handle.write(
            f"webrtc_qos_phase5_debug_bundle_slo_objective_threshold{labels} {item['threshold']}\n"
        )
    handle.write("# HELP webrtc_qos_phase5_debug_bundle_alert_policy_rule_observed_total Alert policy observed count by rule.\n")
    handle.write("# TYPE webrtc_qos_phase5_debug_bundle_alert_policy_rule_observed_total counter\n")
    for rule in alert_policy_rules:
        handle.write(
            "webrtc_qos_phase5_debug_bundle_alert_policy_rule_observed_total"
            f"{prom_labels(rule=rule['rule'], category=rule['category'], severity=rule['severity'])} {rule['observed_count']}\n"
        )
    if problem.get("status") == "found":
        handle.write("# HELP webrtc_qos_phase5_debug_bundle_first_problem_info First WARN/ERROR or alert marker.\n")
        handle.write("# TYPE webrtc_qos_phase5_debug_bundle_first_problem_info gauge\n")
        handle.write(
            "webrtc_qos_phase5_debug_bundle_first_problem_info"
            f"{prom_labels(type=problem.get('type', ''), level=problem.get('level', ''), role=problem.get('role', ''), name=problem.get('name', ''))} 1\n"
        )
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
  write_summary "health_report=${OUTPUT_DIR}/monitoring/health_report.json"
  write_summary "health_summary=${OUTPUT_DIR}/monitoring/health_summary.txt"
  write_summary "slo_report=${OUTPUT_DIR}/monitoring/slo_report.json"
  write_summary "slo_summary=${OUTPUT_DIR}/monitoring/slo_summary.txt"
  write_summary "monitoring_metrics=${OUTPUT_DIR}/monitoring/phase5_monitoring_metrics.prom"
  write_summary "alert_policy=${OUTPUT_DIR}/monitoring/alert_policy.json"
  write_summary "alert_policy_summary=${OUTPUT_DIR}/monitoring/alert_policy_summary.txt"
  write_summary "incident_report=${OUTPUT_DIR}/monitoring/incident_report.json"
  write_summary "incident_runbook=${OUTPUT_DIR}/monitoring/incident_runbook.txt"
  write_summary "files=${FILES_FILE}"
  write_summary "manifest=${MANIFEST_FILE}"
  write_summary "phase5_debug_bundle_status=collected"
} >/dev/null

(
  cd "${OUTPUT_DIR}"
  find . -type f \
    ! -path './manifest.sha256' \
    ! -path './files.txt' \
    | sed 's#^\./##' \
    | sort >"${FILES_FILE}"
  while IFS= read -r file; do
    sha256sum "${file}"
  done <"${FILES_FILE}" >"${MANIFEST_FILE}"
)

if [[ "${REQUIRE_SELFTEST_PASS}" == "1" && "${selftest_status}" != "0" ]]; then
  exit "${selftest_status}"
fi
