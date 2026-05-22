#!/usr/bin/env bash
set -euo pipefail

BUNDLE_DIR="${BUNDLE_DIR:-${1:-/root/webrtc_qos_sdk/artifacts/phase5_debug_bundle}}"
REQUIRE_SELFTEST_PASS="${REQUIRE_SELFTEST_PASS:-1}"

fail() {
  echo "phase5 debug bundle verification failed: $*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -s "${path}" ]] || fail "missing or empty file: ${path}"
}

require_no_payload_like_fields() {
  local path="$1"
  if rg -q '"payload"|"annexb_bytes"|"rtp_bytes"|token|secret|password' "${path}"; then
    fail "bundle file contains payload-like or sensitive field: ${path}"
  fi
}

[[ -d "${BUNDLE_DIR}" ]] || fail "missing bundle directory: ${BUNDLE_DIR}"

required_files=(
  metadata.txt
  build_config.txt
  git_status.txt
  session_config.json
  runtime_config.json
  debug_bundle_summary.txt
  manifest.sha256
  files.txt
  log/push.log
  log/server.log
  log/play.log
  metrics/push_metrics.jsonl
  metrics/server_metrics.jsonl
  metrics/play_metrics.jsonl
  metrics/summary.csv
  alerts/push_alerts.jsonl
  alerts/server_alerts.jsonl
  alerts/play_alerts.jsonl
  alerts/alerts.jsonl
  alerts/alerts_summary.txt
  timeline/events.jsonl
  timeline/first_problem.json
  timeline/summary.txt
  evidence/udp_selftest_output.txt
)

for rel in "${required_files[@]}"; do
  require_file "${BUNDLE_DIR}/${rel}"
done

if [[ "${REQUIRE_SELFTEST_PASS}" == "1" ]]; then
  rg -q 'udp_selftest .*pass=true' "${BUNDLE_DIR}/evidence/udp_selftest_output.txt" ||
    fail "UDP selftest output did not show pass=true"
fi

(
  cd "${BUNDLE_DIR}"
  sha256sum -c manifest.sha256 >/dev/null
)

python3 - "${BUNDLE_DIR}" <<'PY'
import csv
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

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
required_config_dump = {
    "schema_version",
    "transport",
    "peer_connection",
    "resolved_track_count",
    "start_bitrate_bps",
    "min_bitrate_bps",
    "max_bitrate_bps",
    "twcc_extension_id",
    "rtcp_sr_rr_interval_ms",
    "logging_enabled",
    "log_json_lines",
    "log_max_file_bytes",
    "log_max_files",
    "log_max_queue_records",
    "metrics_enabled",
    "metrics_interval_ms",
    "metrics_include_track_snapshots",
    "alerts_enabled",
    "alerts_high_loss_fraction_q8",
    "alerts_low_target_bps",
    "alerts_low_encoder_fps",
    "alerts_max_process_tick_gap_ms",
    "redaction_media_bytes",
    "redaction_runtime_paths",
}
forbidden_config_dump_keys = {
    "payload",
    "annexb_bytes",
    "rtp_bytes",
    "token",
    "secret",
    "password",
    "log_dir",
    "log_directory",
    "metrics_dir",
    "metrics_directory",
    "alerts_dir",
    "alerts_directory",
    "directory",
    "path",
    "absolute_path",
    "runtime_path",
    "runtime_directory",
}

def read_jsonl(path):
    records = []
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            if not line.strip():
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{line_no}: invalid JSON: {exc}")
    return records

roles = {"push", "server", "play"}
for role in roles:
    log_records = read_jsonl(root / "log" / f"{role}.log")
    metric_records = read_jsonl(root / "metrics" / f"{role}_metrics.jsonl")
    alert_records = read_jsonl(root / "alerts" / f"{role}_alerts.jsonl")
    if not log_records:
        raise SystemExit(f"missing log records for role {role}")
    if not metric_records:
        raise SystemExit(f"missing metric records for role {role}")
    if not alert_records:
        raise SystemExit(f"missing alert records for role {role}")
    config_dumps = [
        record for record in log_records if record.get("event") == "config_dump"
    ]
    if not config_dumps:
        raise SystemExit(f"missing config_dump log record for role {role}")
    for index, record in enumerate(config_dumps, 1):
        missing = required_config_dump - record.keys()
        if missing:
            raise SystemExit(
                f"config_dump:{role}:{index}: missing fields {sorted(missing)}"
            )
        leaked_keys = forbidden_config_dump_keys & {
            str(key).lower() for key in record.keys()
        }
        if leaked_keys:
            raise SystemExit(
                f"config_dump:{role}:{index}: forbidden fields {sorted(leaked_keys)}"
            )
        if record.get("schema_version") != 1:
            raise SystemExit(f"config_dump:{role}:{index}: bad schema_version")
        if record.get("transport") != "udp" or record.get("peer_connection") is not False:
            raise SystemExit(f"config_dump:{role}:{index}: bad transport boundary")
        if int(record.get("resolved_track_count", 0)) <= 0:
            raise SystemExit(f"config_dump:{role}:{index}: bad track count")
        if record.get("redaction_media_bytes") != "omitted":
            raise SystemExit(f"config_dump:{role}:{index}: missing media redaction")
        if record.get("redaction_runtime_paths") != "omitted":
            raise SystemExit(f"config_dump:{role}:{index}: missing path redaction")
        for key, value in record.items():
            if key in {"redaction_media_bytes", "redaction_runtime_paths"}:
                continue
            if isinstance(value, str) and value.startswith("/"):
                raise SystemExit(
                    f"config_dump:{role}:{index}: leaked absolute path in {key}"
                )
    for collection_name, records in [
        ("log", log_records),
        ("metric", metric_records),
        ("alert", alert_records),
    ]:
        for index, record in enumerate(records, 1):
            missing = required_identity - record.keys()
            if missing:
                raise SystemExit(
                    f"{collection_name}:{role}:{index}: missing fields {sorted(missing)}"
                )

with (root / "metrics" / "summary.csv").open("r", encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle))
if {row["role"] for row in rows} != roles:
    raise SystemExit("metrics summary does not cover push/server/play")
if min(int(row["records"]) for row in rows) <= 0:
    raise SystemExit("metrics summary has empty role")
summary_required_columns = {
    "max_process_tick_gap_us",
    "max_tick_gap_session_id",
    "max_tick_gap_track_id",
    "max_tick_gap_receiver_id",
}
for row in rows:
    missing_columns = summary_required_columns - row.keys()
    if missing_columns:
        raise SystemExit(
            f"metrics summary missing columns: {sorted(missing_columns)}"
        )
    if int(row.get("max_process_tick_gap_us", "0")) <= 0:
        raise SystemExit(
            f"metrics summary missing positive tick gap for role {row.get('role')}"
        )

alerts = read_jsonl(root / "alerts" / "alerts.jsonl")
rules = {record.get("rule") for record in alerts}
expected_rules = {
    "high_downlink_loss",
    "video_drop_frames",
    "low_target_bitrate",
    "low_encoder_fps",
    "nack_generated",
    "local_retransmission_hit",
}
missing_rules = expected_rules - rules
if missing_rules:
    raise SystemExit(f"missing expected alert rules: {sorted(missing_rules)}")
alerts_summary = (root / "alerts" / "alerts_summary.txt").read_text(
    encoding="utf-8"
)
for required_text in (
    "first_alert=",
    "category=network_qos",
    "category=media_quality",
):
    if required_text not in alerts_summary:
        raise SystemExit(f"alerts summary missing {required_text}")
for role in roles:
    if f"role={role} " not in alerts_summary:
        raise SystemExit(f"alerts summary missing role {role}")

timeline = read_jsonl(root / "timeline" / "events.jsonl")
if not timeline:
    raise SystemExit("empty timeline")
event_types = {event.get("type") for event in timeline}
if not {"log", "metric", "alert"}.issubset(event_types):
    raise SystemExit(f"timeline missing event types: {sorted(event_types)}")

first_problem = json.loads((root / "timeline" / "first_problem.json").read_text())
if first_problem.get("status") != "found":
    raise SystemExit("first_problem.json did not identify a WARN/ERROR or alert")
timeline_summary = (root / "timeline" / "summary.txt").read_text(
    encoding="utf-8"
)
for required_text in (
    "type=alert events=",
    "type=log events=",
    "type=metric events=",
    "first_problem=",
):
    if required_text not in timeline_summary:
        raise SystemExit(f"timeline summary missing {required_text}")

session = json.loads((root / "session_config.json").read_text())
profiles = session.get("profiles", [])
if len(profiles) < 2:
    raise SystemExit("session_config.json missing single/dual track profiles")
dual = next((profile for profile in profiles if profile.get("label") == "dual_track"), None)
if not dual or len(dual.get("tracks", [])) != 2:
    raise SystemExit("session_config.json missing dual-track definition")

runtime = json.loads((root / "runtime_config.json").read_text())
if runtime.get("schema_version") != 1:
    raise SystemExit("runtime_config.json missing schema_version=1")
transport = runtime.get("transport", {})
if transport.get("kind") != "udp" or transport.get("peer_connection") is not False:
    raise SystemExit("runtime_config.json has unexpected transport boundary")
selftest = runtime.get("selftest", {})
if selftest.get("frames", 0) <= 0:
    raise SystemExit("runtime_config.json missing positive selftest frames")
runtime_section = runtime.get("runtime", {})
for section in ("logging", "metrics", "alerts"):
    if runtime_section.get(section, {}).get("enabled") is not True:
        raise SystemExit(f"runtime_config.json missing enabled {section}")
logging_config = runtime_section.get("logging", {})
if int(logging_config.get("max_queue_records", 0)) <= 0:
    raise SystemExit("runtime_config.json missing positive logging max_queue_records")
metric_required_fields = {
    "process_tick_count",
    "process_tick_gap_us",
    "max_process_tick_gap_us",
}
for role in roles:
    for index, record in enumerate(read_jsonl(root / "metrics" / f"{role}_metrics.jsonl"), 1):
        missing = metric_required_fields - record.keys()
        if missing:
            raise SystemExit(
                f"metric:{role}:{index}: missing tick fields {sorted(missing)}"
            )
roles_config = runtime.get("roles", [])
if {item.get("role") for item in roles_config} != roles:
    raise SystemExit("runtime_config.json does not cover push/server/play roles")
for item in roles_config:
    artifacts = item.get("artifacts", {})
    for artifact_kind in ("log", "metrics", "alerts"):
        rel = artifacts.get(artifact_kind)
        if not rel or not (root / rel).exists():
            raise SystemExit(
                f"runtime_config.json role {item.get('role')} bad {artifact_kind} artifact"
            )
redaction = runtime.get("redaction", {})
for key in ("media_bytes", "raw_frames", "auth_material", "absolute_runtime_paths"):
    if redaction.get(key) != "omitted":
        raise SystemExit(f"runtime_config.json missing redaction marker {key}")

print(
    "validated_phase5_debug_bundle roles=%s alerts=%d timeline=%d config_dump=pass"
    % (",".join(sorted(roles)), len(alerts), len(timeline))
)
PY

while IFS= read -r rel; do
  require_no_payload_like_fields "${BUNDLE_DIR}/${rel}"
done <"${BUNDLE_DIR}/files.txt"

echo "phase5_debug_bundle pass bundle_dir=${BUNDLE_DIR}"
