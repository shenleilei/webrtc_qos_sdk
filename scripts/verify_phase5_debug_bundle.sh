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
  monitoring/health_report.json
  monitoring/health_summary.txt
  monitoring/slo_report.json
  monitoring/slo_summary.txt
  monitoring/phase5_monitoring_metrics.prom
  monitoring/alert_policy.json
  monitoring/alert_policy_summary.txt
  monitoring/incident_report.json
  monitoring/incident_runbook.txt
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

verify_bundle_integrity() {
  python3 - "${BUNDLE_DIR}" <<'PY'
import os
import sys

bundle_dir = sys.argv[1]
files_path = os.path.join(bundle_dir, "files.txt")
manifest_path = os.path.join(bundle_dir, "manifest.sha256")

with open(files_path, "r", encoding="utf-8") as handle:
    files = [line.strip() for line in handle if line.strip()]
with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest_files = []
    for line_no, line in enumerate(handle, 1):
        line = line.rstrip("\n")
        if len(line) < 67:
            raise SystemExit(f"debug bundle manifest line {line_no} is too short")
        digest, rel = line.split(None, 1)
        if len(digest) != 64 or not all(
            ch in "0123456789abcdefABCDEF" for ch in digest
        ):
            raise SystemExit(
                f"debug bundle manifest line {line_no} has invalid sha256"
            )
        manifest_files.append(rel.lstrip("*"))

actual_files = []
for root, _, names in os.walk(bundle_dir):
    for name in names:
        path = os.path.join(root, name)
        rel = os.path.relpath(path, bundle_dir)
        if rel in {"manifest.sha256", "files.txt"}:
            continue
        actual_files.append(rel)
actual_files.sort()

if files != sorted(files):
    raise SystemExit("debug bundle files.txt is not sorted")
if files != manifest_files:
    raise SystemExit("debug bundle files.txt and manifest.sha256 file sets differ")
if files != actual_files:
    raise SystemExit("debug bundle files.txt does not match actual files")
PY
}

verify_bundle_integrity

python3 - "${BUNDLE_DIR}" <<'PY'
import csv
import json
import pathlib
import re
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
    "alerts_max_rtp_output_gap_ms",
    "alerts_max_rtp_input_gap_ms",
    "alerts_consecutive_transport_failures_threshold",
    "alerts_media_flow_gap_enabled",
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
    "max_rtp_output_gap_us",
    "max_rtp_input_gap_us",
    "max_consecutive_transport_failures",
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

health_report = json.loads((root / "monitoring" / "health_report.json").read_text())
if health_report.get("schema_version") != 1:
    raise SystemExit("health_report.json missing schema_version=1")
if health_report.get("source") != "phase5_debug_bundle":
    raise SystemExit("health_report.json has unexpected source")
if health_report.get("health_status") not in {"ok", "attention_required"}:
    raise SystemExit("health_report.json has unexpected health_status")
health_roles = health_report.get("roles", {})
if set(health_roles.keys()) != roles:
    raise SystemExit("health_report.json does not cover push/server/play")
for role, info in health_roles.items():
    if info.get("status") not in {"ok", "attention_required"}:
        raise SystemExit(f"health_report role {role} has unexpected status")
    if int(info.get("metric_records", 0)) <= 0:
        raise SystemExit(f"health_report role {role} missing metric records")
    for key in (
        "max_process_tick_gap_us",
        "max_rtp_output_gap_us",
        "max_rtp_input_gap_us",
        "max_consecutive_transport_failures",
    ):
        if key not in info:
            raise SystemExit(f"health_report role {role} missing {key}")
    identity = info.get("max_tick_gap_identity", {})
    for key in ("session_id", "track_id", "receiver_id"):
        if key not in identity:
            raise SystemExit(
                f"health_report role {role} missing max tick gap identity {key}"
            )
totals = health_report.get("totals", {})
if int(totals.get("timeline_events", 0)) != len(timeline):
    raise SystemExit("health_report timeline total does not match timeline")
if int(totals.get("alert_records", 0)) != len(alerts):
    raise SystemExit("health_report alert total does not match alerts")
if not health_report.get("top_alert_rules"):
    raise SystemExit("health_report missing top_alert_rules")
recommended_actions = health_report.get("recommended_actions", [])
if not recommended_actions:
    raise SystemExit("health_report missing recommended_actions")
categories = {
    action.get("category")
    for action in recommended_actions
    if action.get("category")
}
if not {"network_qos", "media_quality"}.issubset(categories):
    raise SystemExit(
        f"health_report recommended actions missing categories: {sorted(categories)}"
    )
artifacts = health_report.get("artifacts", {})
for key in (
    "metrics_summary",
    "alerts_summary",
    "timeline_summary",
    "first_problem",
    "slo_report",
    "slo_summary",
    "monitoring_metrics",
    "alert_policy",
    "alert_policy_summary",
    "incident_report",
    "incident_runbook",
):
    rel = artifacts.get(key)
    if not rel or not (root / rel).exists():
        raise SystemExit(f"health_report bad artifact pointer {key}")
health_first_problem = health_report.get("first_problem", {})
if health_first_problem.get("status") != "found":
    raise SystemExit("health_report missing first problem")
health_summary = (root / "monitoring" / "health_summary.txt").read_text(
    encoding="utf-8"
)
for required_text in (
    "health_status=",
    "first_problem=",
    "recommended_action=",
):
    if required_text not in health_summary:
        raise SystemExit(f"health summary missing {required_text}")
for role in roles:
    if f"role={role} status=" not in health_summary:
        raise SystemExit(f"health summary missing role {role}")

slo_report = json.loads((root / "monitoring" / "slo_report.json").read_text())
if slo_report.get("schema_version") != 1:
    raise SystemExit("slo_report.json missing schema_version=1")
if slo_report.get("source") != "phase5_debug_bundle":
    raise SystemExit("slo_report.json has unexpected source")
if slo_report.get("slo_status") not in {"pass", "warn", "fail"}:
    raise SystemExit("slo_report.json has unexpected slo_status")
if slo_report.get("scope") != "single debug bundle run; not a production SLO claim":
    raise SystemExit("slo_report.json has unexpected scope")
slo_categories = set(slo_report.get("categories", {}).keys())
if not {"availability", "media_quality", "network_qos"}.issubset(slo_categories):
    raise SystemExit(f"slo report missing categories: {sorted(slo_categories)}")
slo_objectives = slo_report.get("objectives", [])
if len(slo_objectives) < 8:
    raise SystemExit("slo report does not cover enough objectives")
objective_by_id = {item.get("id"): item for item in slo_objectives}
required_slo_objectives = {
    "availability.process_tick_gap",
    "availability.rtp_output_gap",
    "availability.rtp_input_gap",
    "availability.consecutive_transport_failures",
    "media_quality.low_target_bitrate_alerts",
    "media_quality.video_drop_alerts",
    "network_qos.high_loss_alerts",
    "network_qos.nack_recovery_alerts",
}
missing_slo = required_slo_objectives - objective_by_id.keys()
if missing_slo:
    raise SystemExit(f"slo report missing objectives: {sorted(missing_slo)}")
for objective_id, item in objective_by_id.items():
    if item.get("category") not in {"availability", "media_quality", "network_qos"}:
        raise SystemExit(f"slo objective {objective_id} has bad category")
    if item.get("status") not in {"pass", "warn", "fail"}:
        raise SystemExit(f"slo objective {objective_id} has bad status")
    for key in ("target", "observed", "threshold", "unit", "source", "recommended_action"):
        if key not in item:
            raise SystemExit(f"slo objective {objective_id} missing {key}")
    source = item.get("source")
    if not source or not (root / source).exists():
        raise SystemExit(f"slo objective {objective_id} has bad source")
category_status = slo_report.get("category_status", {})
for category in ("availability", "media_quality", "network_qos"):
    if category_status.get(category) not in {"pass", "warn", "fail"}:
        raise SystemExit(f"slo report missing category status {category}")
runtime_slo_thresholds = slo_report.get("runtime_thresholds", {})
for key in (
    "max_process_tick_gap_ms",
    "max_rtp_output_gap_ms",
    "max_rtp_input_gap_ms",
    "consecutive_transport_failures_threshold",
):
    if key not in runtime_slo_thresholds:
        raise SystemExit(f"slo report missing runtime threshold {key}")
slo_artifacts = slo_report.get("artifacts", {})
for key in (
    "metrics_summary",
    "alerts_summary",
    "health_report",
    "alert_policy",
    "monitoring_metrics",
    "timeline",
):
    rel = slo_artifacts.get(key)
    if not rel or not (root / rel).exists():
        raise SystemExit(f"slo report bad artifact pointer {key}")
slo_summary = (root / "monitoring" / "slo_summary.txt").read_text(
    encoding="utf-8"
)
for required_text in (
    "slo_status=",
    "scope=single_debug_bundle_run_not_production_slo_claim",
    "category=availability",
    "category=media_quality",
    "category=network_qos",
    "objective=availability.process_tick_gap",
    "objective=network_qos.high_loss_alerts",
):
    if required_text not in slo_summary:
        raise SystemExit(f"slo summary missing {required_text}")

alert_policy = json.loads((root / "monitoring" / "alert_policy.json").read_text())
if alert_policy.get("schema_version") != 1:
    raise SystemExit("alert_policy.json missing schema_version=1")
if alert_policy.get("source") != "phase5_debug_bundle":
    raise SystemExit("alert_policy.json has unexpected source")
if alert_policy.get("policy_name") != "phase5_default_runtime_alert_policy":
    raise SystemExit("alert_policy.json has unexpected policy_name")
policy_categories = set(alert_policy.get("categories", {}).keys())
if not {"availability", "media_quality", "network_qos"}.issubset(policy_categories):
    raise SystemExit(f"alert policy missing categories: {sorted(policy_categories)}")
policy_rules = alert_policy.get("rules", [])
if len(policy_rules) < 20:
    raise SystemExit("alert policy does not cover enough runtime rules")
rule_by_name = {rule.get("rule"): rule for rule in policy_rules}
required_policy_rules = {
    "process_tick_gap",
    "sender_rtp_output_gap",
    "receiver_rtp_input_gap",
    "consecutive_transport_failures",
    "transport_output_failed",
    "sender_output_failed",
    "receiver_output_failed",
    "low_target_bitrate",
    "low_encoder_fps",
    "high_downlink_loss",
    "video_drop_frames",
    "nack_generated",
    "local_retransmission_hit",
    "malformed_rtp",
    "malformed_rtcp",
    "decode_output_failed",
}
missing_policy_rules = required_policy_rules - rule_by_name.keys()
if missing_policy_rules:
    raise SystemExit(
        f"alert policy missing rules: {sorted(missing_policy_rules)}"
    )
for rule_name, rule in rule_by_name.items():
    if rule.get("category") not in {"availability", "media_quality", "network_qos"}:
        raise SystemExit(f"alert policy rule {rule_name} has bad category")
    if rule.get("severity") not in {"WARN", "ERROR"}:
        raise SystemExit(f"alert policy rule {rule_name} has bad severity")
    if not set(rule.get("roles", [])) <= roles or not rule.get("roles"):
        raise SystemExit(f"alert policy rule {rule_name} has bad roles")
    for key in (
        "enabled_by",
        "threshold_ref",
        "default_threshold",
        "unit",
        "required_action",
        "observed_count",
        "observed_by_role",
    ):
        if key not in rule:
            raise SystemExit(f"alert policy rule {rule_name} missing {key}")
runtime_thresholds = alert_policy.get("runtime_thresholds", {})
for key in (
    "high_loss_fraction_q8",
    "video_drop_frames_threshold",
    "low_target_bps",
    "low_encoder_fps",
    "max_process_tick_gap_ms",
    "max_rtp_output_gap_ms",
    "max_rtp_input_gap_ms",
    "consecutive_transport_failures_threshold",
):
    if key not in runtime_thresholds:
        raise SystemExit(f"alert policy missing runtime threshold {key}")
observed_policy_rules = set(alert_policy.get("observed_rules", {}).keys())
if not rules <= observed_policy_rules:
    raise SystemExit("alert policy observed_rules do not cover alert records")
for rule_name in expected_rules:
    if int(rule_by_name[rule_name].get("observed_count", 0)) <= 0:
        raise SystemExit(f"alert policy did not count observed rule {rule_name}")
policy_artifacts = alert_policy.get("artifacts", {})
for key in ("alerts", "alerts_summary", "health_report", "monitoring_metrics", "timeline"):
    rel = policy_artifacts.get(key)
    if not rel or not (root / rel).exists():
        raise SystemExit(f"alert policy bad artifact pointer {key}")
policy_summary = (root / "monitoring" / "alert_policy_summary.txt").read_text(
    encoding="utf-8"
)
for required_text in (
    "policy_name=phase5_default_runtime_alert_policy",
    "category=availability",
    "category=media_quality",
    "category=network_qos",
    "rule=process_tick_gap",
    "rule=high_downlink_loss",
    "rule=low_target_bitrate",
):
    if required_text not in policy_summary:
        raise SystemExit(f"alert policy summary missing {required_text}")

incident_report = json.loads(
    (root / "monitoring" / "incident_report.json").read_text()
)
if incident_report.get("schema_version") != 1:
    raise SystemExit("incident_report.json missing schema_version=1")
if incident_report.get("source") != "phase5_debug_bundle":
    raise SystemExit("incident_report.json has unexpected source")
if incident_report.get("incident_status") != health_report.get("health_status"):
    raise SystemExit("incident report status does not match health report")
incident_first_problem = incident_report.get("first_problem", {})
if incident_first_problem.get("status") != "found":
    raise SystemExit("incident report missing first problem")
if incident_first_problem.get("name") != first_problem.get("name"):
    raise SystemExit("incident report first problem does not match timeline")
if incident_report.get("affected_role") not in roles:
    raise SystemExit("incident report affected role is not a runtime role")
if not incident_report.get("top_alert_rules"):
    raise SystemExit("incident report missing top alert rules")
if not incident_report.get("recommended_actions"):
    raise SystemExit("incident report missing recommended actions")
runbook_steps = incident_report.get("runbook_steps", [])
expected_step_names = [
    "open_first_problem",
    "check_health_report",
    "confirm_alert_policy",
    "inspect_role_artifacts",
    "correlate_timeline",
    "check_runtime_context",
    "verify_bundle_integrity",
]
if [step.get("name") for step in runbook_steps] != expected_step_names:
    raise SystemExit("incident report runbook steps are incomplete or out of order")
for index, step in enumerate(runbook_steps, 1):
    if step.get("step") != index:
        raise SystemExit("incident report has non-sequential runbook step")
    if not step.get("required_action"):
        raise SystemExit(f"incident report runbook step {index} missing action")
    artifacts = step.get("artifacts", [])
    if not artifacts:
        raise SystemExit(f"incident report runbook step {index} missing artifacts")
    for rel in artifacts:
        if "{" in rel:
            continue
        if not (root / rel).exists():
            raise SystemExit(
                f"incident report runbook step {index} bad artifact {rel}"
            )
evidence_index = incident_report.get("evidence_index", {})
for key in (
    "health_report",
    "slo_report",
    "alert_policy",
    "monitoring_metrics",
    "timeline",
    "first_problem",
    "metrics_summary",
    "alerts_summary",
    "runtime_config",
):
    rel = evidence_index.get(key)
    if not rel or not (root / rel).exists():
        raise SystemExit(f"incident report bad evidence pointer {key}")
incident_runbook = (root / "monitoring" / "incident_runbook.txt").read_text(
    encoding="utf-8"
)
for required_text in (
    "incident_runbook=phase5_debug_bundle",
    "first_problem=",
    "step=1 name=open_first_problem",
    "step=3 name=confirm_alert_policy",
    "step=7 name=verify_bundle_integrity",
    "recommended_action=",
):
    if required_text not in incident_runbook:
        raise SystemExit(f"incident runbook missing {required_text}")

prometheus_text = (
    root / "monitoring" / "phase5_monitoring_metrics.prom"
).read_text(encoding="utf-8")
for required_text in (
    "# TYPE webrtc_qos_phase5_debug_bundle_info gauge",
    "webrtc_qos_phase5_debug_bundle_info",
    "webrtc_qos_phase5_debug_bundle_timeline_events_total",
    "webrtc_qos_phase5_debug_bundle_alerts_total",
    "webrtc_qos_phase5_debug_bundle_role_metric_records",
    "webrtc_qos_phase5_debug_bundle_role_max_process_tick_gap_us",
    "webrtc_qos_phase5_debug_bundle_slo_objective_status",
    "webrtc_qos_phase5_debug_bundle_slo_objective_observed",
    "webrtc_qos_phase5_debug_bundle_slo_objective_threshold",
    "webrtc_qos_phase5_debug_bundle_alert_policy_rule_observed_total",
    "webrtc_qos_phase5_debug_bundle_first_problem_info",
):
    if required_text not in prometheus_text:
        raise SystemExit(f"monitoring metrics missing {required_text}")

prom_line_re = re.compile(
    r"^([A-Za-z_:][A-Za-z0-9_:]*)(\{([^{}]*)\})?\s+"
    r"([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|[+-]?Inf|NaN)$"
)
prom_label_re = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)="((?:\\.|[^"\\])*)"')
prom_records = []
for line_no, line in enumerate(prometheus_text.splitlines(), 1):
    if not line.strip() or line.startswith("#"):
        continue
    match = prom_line_re.match(line)
    if not match:
        raise SystemExit(
            "monitoring metrics line is not valid Prometheus text format: "
            f"line={line_no} text={line}"
        )
    labels = {}
    raw_labels = match.group(3) or ""
    if raw_labels:
        position = 0
        while position < len(raw_labels):
            label_match = prom_label_re.match(raw_labels, position)
            if not label_match:
                raise SystemExit(
                    f"monitoring metrics line {line_no} has invalid labels"
                )
            labels[label_match.group(1)] = label_match.group(2)
            position = label_match.end()
            if position < len(raw_labels):
                if raw_labels[position] != ",":
                    raise SystemExit(
                        f"monitoring metrics line {line_no} has malformed labels"
                    )
                position += 1
    try:
        value = float(match.group(4))
    except ValueError as exc:
        raise SystemExit(
            f"monitoring metrics line {line_no} has invalid value"
        ) from exc
    prom_records.append({
        "name": match.group(1),
        "labels": labels,
        "value": value,
    })
if not prom_records:
    raise SystemExit("monitoring metrics file has no samples")

def prom_has(name, **labels):
    for record in prom_records:
        if record["name"] != name:
            continue
        if all(record["labels"].get(key) == value for key, value in labels.items()):
            return True
    return False

for role in roles:
    if not prom_has("webrtc_qos_phase5_debug_bundle_role_metric_records", role=role):
        raise SystemExit(f"monitoring metrics missing role record gauge {role}")
for event_type in ("log", "metric", "alert"):
    if not prom_has(
        "webrtc_qos_phase5_debug_bundle_timeline_events_total", type=event_type
    ):
        raise SystemExit(f"monitoring metrics missing timeline type {event_type}")
for category in ("availability", "media_quality", "network_qos"):
    if not prom_has(
        "webrtc_qos_phase5_debug_bundle_alert_policy_rule_observed_total",
        category=category,
    ):
        raise SystemExit(f"monitoring metrics missing alert policy category {category}")
for objective in (
    "availability.process_tick_gap",
    "network_qos.high_loss_alerts",
):
    if not prom_has(
        "webrtc_qos_phase5_debug_bundle_slo_objective_status",
        objective=objective,
    ):
        raise SystemExit(f"monitoring metrics missing SLO objective {objective}")

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
    "rtp_output_gap_us",
    "max_rtp_output_gap_us",
    "rtp_input_gap_us",
    "max_rtp_input_gap_us",
    "transport_failure_count",
    "consecutive_transport_failures",
    "max_consecutive_transport_failures",
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
runtime_artifacts = runtime.get("artifacts", {})
for artifact_kind in (
    "health_report",
    "health_summary",
    "slo_report",
    "slo_summary",
    "monitoring_metrics",
    "alert_policy",
    "alert_policy_summary",
    "incident_report",
    "incident_runbook",
):
    rel = runtime_artifacts.get(artifact_kind)
    if not rel or not (root / rel).exists():
        raise SystemExit(f"runtime_config.json bad {artifact_kind} artifact")
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
