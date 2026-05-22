#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/phase5_completion_audit}"
SUMMARY_FILE="${SUMMARY_FILE:-${OUTPUT_DIR}/phase5_completion_audit_summary.txt}"
PHASE5_COMPLETION_AUDIT_METRICS_PROM="${PHASE5_COMPLETION_AUDIT_METRICS_PROM:-${OUTPUT_DIR}/phase5_completion_audit_metrics.prom}"
PHASE5_GATE_DIR="${PHASE5_GATE_DIR:-}"
PHASE5_DEBUG_BUNDLE_DIR="${PHASE5_DEBUG_BUNDLE_DIR:-${SDK_ROOT}/artifacts/phase5_debug_bundle}"
if [[ -z "${PHASE5_IMPLEMENTATION_GATE_DIR:-}" && -n "${PHASE5_GATE_DIR}" &&
    -d "${PHASE5_GATE_DIR}/phase5_implementation_gate" ]]; then
  PHASE5_IMPLEMENTATION_GATE_DIR="${PHASE5_GATE_DIR}/phase5_implementation_gate"
else
  PHASE5_IMPLEMENTATION_GATE_DIR="${PHASE5_IMPLEMENTATION_GATE_DIR:-${SDK_ROOT}/artifacts/phase5_implementation_gate/latest}"
fi
REQUIRE_PRODUCTION_EVIDENCE="${REQUIRE_PRODUCTION_EVIDENCE:-1}"
ALLOW_DRY_RUN_GATE="${ALLOW_DRY_RUN_GATE:-0}"

mkdir -p "${OUTPUT_DIR}"
rm -f "${SUMMARY_FILE}" "${PHASE5_COMPLETION_AUDIT_METRICS_PROM}"

write_summary() {
  printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

write_audit_metrics() {
  python3 - \
    "${SUMMARY_FILE}" \
    "${PHASE5_COMPLETION_AUDIT_METRICS_PROM}" \
    "${REQUIRE_PRODUCTION_EVIDENCE}" <<'PY'
import collections
import re
import sys

summary_path, metrics_path, require_production_evidence = sys.argv[1:4]
audit_status = "unknown"
completion_status = "unknown"
next_required_action = "none"
checks = []
check_re = re.compile(r"^check=([^ ]+) status=([^ ]+)(?: |$)")
with open(summary_path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        match = check_re.match(line)
        if match:
            checks.append(match.groups())
            continue
        if line.startswith("phase5_completion_audit="):
            audit_status = line.split("=", 1)[1]
        elif line.startswith("phase5_completion_status="):
            completion_status = line.split("=", 1)[1]
        elif line.startswith("next_required_actions="):
            next_required_action = line.split("=", 1)[1]


def prom_escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def prom_labels(**labels):
    items = [
        f'{key}="{prom_escape(value)}"'
        for key, value in sorted(labels.items())
        if value is not None and value != ""
    ]
    return "{" + ",".join(items) + "}" if items else ""


status_counts = collections.Counter(status for _, status in checks)
production_evidence_status = "missing"
for check, status in checks:
    if check == "production_evidence":
        production_evidence_status = status

with open(metrics_path, "w", encoding="utf-8") as fh:
    fh.write("# HELP webrtc_qos_phase5_completion_audit_info Phase-5 completion audit status marker.\n")
    fh.write("# TYPE webrtc_qos_phase5_completion_audit_info gauge\n")
    fh.write(
        "webrtc_qos_phase5_completion_audit_info"
        f"{prom_labels(audit_status=audit_status, completion_status=completion_status, require_production_evidence=require_production_evidence, source='phase5_completion_audit')} 1\n"
    )
    fh.write("# HELP webrtc_qos_phase5_completion_audit_checks_total Phase-5 completion audit check count by status.\n")
    fh.write("# TYPE webrtc_qos_phase5_completion_audit_checks_total gauge\n")
    for status in ("pass", "warn", "fail"):
        fh.write(
            "webrtc_qos_phase5_completion_audit_checks_total"
            f"{prom_labels(status=status)} {status_counts.get(status, 0)}\n"
        )
    fh.write("# HELP webrtc_qos_phase5_completion_audit_check_status Phase-5 completion audit observed check status.\n")
    fh.write("# TYPE webrtc_qos_phase5_completion_audit_check_status gauge\n")
    for check, status in checks:
        fh.write(
            "webrtc_qos_phase5_completion_audit_check_status"
            f"{prom_labels(check=check, status=status)} 1\n"
        )
    fh.write("# HELP webrtc_qos_phase5_completion_audit_production_evidence_status Phase-5 completion audit production evidence status marker.\n")
    fh.write("# TYPE webrtc_qos_phase5_completion_audit_production_evidence_status gauge\n")
    fh.write(
        "webrtc_qos_phase5_completion_audit_production_evidence_status"
        f"{prom_labels(status=production_evidence_status)} 1\n"
    )
    fh.write("# HELP webrtc_qos_phase5_completion_audit_next_required_action_info Phase-5 completion audit next required action marker.\n")
    fh.write("# TYPE webrtc_qos_phase5_completion_audit_next_required_action_info gauge\n")
    fh.write(
        "webrtc_qos_phase5_completion_audit_next_required_action_info"
        f"{prom_labels(action=next_required_action)} 1\n"
    )

text = open(metrics_path, "r", encoding="utf-8").read()
for required_text in (
    "# TYPE webrtc_qos_phase5_completion_audit_info gauge",
    "webrtc_qos_phase5_completion_audit_info",
    "webrtc_qos_phase5_completion_audit_checks_total",
    "webrtc_qos_phase5_completion_audit_check_status",
    "webrtc_qos_phase5_completion_audit_production_evidence_status",
    "webrtc_qos_phase5_completion_audit_next_required_action_info",
):
    if required_text not in text:
        raise SystemExit(f"completion audit metrics missing {required_text}")

line_re = re.compile(
    r"^([A-Za-z_:][A-Za-z0-9_:]*)(\{([^{}]*)\})?\s+"
    r"([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|[+-]?Inf|NaN)$"
)
label_re = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)="((?:\\.|[^"\\])*)"')
records = []
for line_no, line in enumerate(text.splitlines(), 1):
    if not line.strip() or line.startswith("#"):
        continue
    match = line_re.match(line)
    if not match:
        raise SystemExit(
            f"completion audit metrics line {line_no} is invalid: {line}"
        )
    labels = {}
    raw_labels = match.group(3) or ""
    position = 0
    while position < len(raw_labels):
        label_match = label_re.match(raw_labels, position)
        if not label_match:
            raise SystemExit(
                f"completion audit metrics line {line_no} has invalid labels"
            )
        labels[label_match.group(1)] = label_match.group(2)
        position = label_match.end()
        if position < len(raw_labels):
            if raw_labels[position] != ",":
                raise SystemExit(
                    f"completion audit metrics line {line_no} has malformed labels"
                )
            position += 1
    records.append({
        "name": match.group(1),
        "labels": labels,
        "value": float(match.group(4)),
    })
if not records:
    raise SystemExit("completion audit metrics file has no samples")


def has(name, value=None, **labels):
    for record in records:
        if record["name"] != name:
            continue
        if not all(record["labels"].get(key) == label for key, label in labels.items()):
            continue
        if value is not None and record["value"] != value:
            continue
        return True
    return False


if not has(
    "webrtc_qos_phase5_completion_audit_info",
    value=1,
    audit_status=audit_status,
    completion_status=completion_status,
    require_production_evidence=require_production_evidence,
):
    raise SystemExit("completion audit metrics missing matching audit info sample")
if not has(
    "webrtc_qos_phase5_completion_audit_production_evidence_status",
    value=1,
    status=production_evidence_status,
):
    raise SystemExit("completion audit metrics missing production evidence sample")
PY
}

has_file() {
  [[ -s "$1" ]]
}

pass_count=0
failures=0
warnings=0

audit_pass() {
  local name="$1"
  local detail="$2"
  write_summary "check=${name} status=pass ${detail}"
  pass_count=$((pass_count + 1))
}

audit_fail() {
  local name="$1"
  local reason="$2"
  write_summary "check=${name} status=fail reason=${reason}"
  failures=$((failures + 1))
}

audit_warn() {
  local name="$1"
  local detail="$2"
  write_summary "check=${name} status=warn ${detail}"
  warnings=$((warnings + 1))
}

script_exists() {
  local script="$1"
  [[ -x "${SDK_ROOT}/scripts/${script}" ]]
}

require_script() {
  local script="$1"
  local check_name="$2"
  if script_exists "${script}"; then
    audit_pass "${check_name}" "script=scripts/${script}"
  else
    audit_fail "${check_name}" "missing_script=scripts/${script}"
  fi
}

require_doc_pattern() {
  local file="$1"
  local pattern="$2"
  local check_name="$3"
  if rg -q "${pattern}" "${SDK_ROOT}/${file}"; then
    audit_pass "${check_name}" "file=${file}"
  else
    audit_fail "${check_name}" "missing_pattern=${pattern} file=${file}"
  fi
}

write_summary "phase5_completion_audit=running"
write_summary "sdk_root=${SDK_ROOT}"
write_summary "output_dir=${OUTPUT_DIR}"
write_summary "phase5_gate_dir=${PHASE5_GATE_DIR}"
write_summary "phase5_debug_bundle_dir=${PHASE5_DEBUG_BUNDLE_DIR}"
write_summary "phase5_implementation_gate_dir=${PHASE5_IMPLEMENTATION_GATE_DIR}"
write_summary "require_production_evidence=${REQUIRE_PRODUCTION_EVIDENCE}"
if git -C "${SDK_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
  write_summary "git_head=$(git -C "${SDK_ROOT}" rev-parse HEAD)"
  write_summary "git_branch=$(git -C "${SDK_ROOT}" rev-parse --abbrev-ref HEAD)"
fi

require_script verify_phase5_logging.sh logging_gate
require_script verify_phase5_metrics.sh metrics_gate
require_script verify_phase5_alerts.sh alerts_gate
require_script collect_phase5_debug_bundle.sh debug_bundle_collector
require_script verify_phase5_debug_bundle.sh debug_bundle_verifier
require_script verify_phase5_minimal_udp_external_app.sh external_minimal_udp_gate
require_script verify_phase5_error_contract.sh error_contract_gate
require_script verify_phase5_release_contract.sh release_contract_gate
require_script run_phase5_implementation_gate.sh implementation_gate_wrapper
require_script verify_phase5_implementation_gate.sh implementation_gate_verifier
require_script verify_phase5_production_readiness.sh production_readiness_gate
require_script import_phase5_phase2_evidence_bundle.sh production_external_evidence_import_gate
require_script verify_capture_library_qoe_csv.sh production_capture_qoe_csv_gate
require_script run_phase5_production_gate.sh production_gate_wrapper
require_script verify_phase5_production_gate.sh production_gate_verifier
require_script verify_no_selfmade_media_stack.sh no_selfmade_media_stack_gate

require_doc_pattern README.md 'verify_phase5_logging.sh' readme_logging
require_doc_pattern README.md 'log-max-file-bytes' readme_log_rotation
require_doc_pattern README.md 'verify_phase5_metrics.sh' readme_metrics
require_doc_pattern README.md 'metrics-max-file-bytes' readme_metrics_rotation
require_doc_pattern README.md 'verify_phase5_alerts.sh' readme_alerts
require_doc_pattern README.md 'alerts-max-file-bytes' readme_alerts_rotation
require_doc_pattern README.md 'verify_phase5_error_contract.sh' readme_error_contract
require_doc_pattern README.md 'verify_phase5_release_contract.sh' readme_release_contract
require_doc_pattern README.md 'run_phase5_implementation_gate.sh' readme_implementation_gate
require_doc_pattern README.md 'run_phase5_production_gate.sh' readme_production_gate
require_doc_pattern README.md 'verify_phase5_production_readiness.sh' readme_production_readiness
require_doc_pattern docs/minimal_udp_integration_best_practice.md \
  'runtime_config.json' minimal_udp_runtime_config
require_doc_pattern docs/minimal_udp_integration_best_practice.md \
  'verify_phase5_release_contract.sh' minimal_udp_release_contract
require_doc_pattern webrtc_first_phase5_plan.md \
  'P5 以前不做多接收端' phase5_no_fanout_before_p5
require_doc_pattern webrtc_first_phase5_plan.md \
  'scripts/run_phase5_production_gate.sh' phase5_plan_production_gate
require_doc_pattern scripts/verify_phase5_logging.sh \
  'validated_log_rotation' logging_rotation_gate
require_doc_pattern scripts/verify_phase5_logging.sh \
  'validated_stop_flush' logging_stop_flush_gate
require_doc_pattern scripts/verify_phase5_logging.sh \
  'validated_config_dump' logging_config_dump_gate
require_doc_pattern scripts/verify_phase5_logging.sh \
  'validated_async_log_queue' logging_async_queue_gate
require_doc_pattern scripts/verify_phase5_logging.sh \
  'dropped_log_count' logging_dropped_count_gate
require_doc_pattern scripts/verify_phase5_logging.sh \
  'validated_no_runtime_stdout_stderr_logging' logging_no_runtime_stdout_stderr_gate
require_doc_pattern scripts/verify_phase5_logging.sh \
  'scope=include/webrtc_qos,src' logging_no_runtime_stdout_stderr_sdk_scope
require_doc_pattern scripts/verify_phase5_logging.sh \
  'also_stderr' logging_no_stderr_fallback_gate
require_doc_pattern scripts/verify_phase5_error_contract.sh \
  'unwritable log dir' logging_unwritable_dir_contract
require_doc_pattern scripts/verify_phase5_error_contract.sh \
  'unwritable metrics dir' metrics_unwritable_dir_contract
require_doc_pattern scripts/verify_phase5_error_contract.sh \
  'unwritable alerts dir' alerts_unwritable_dir_contract
require_doc_pattern scripts/verify_phase5_metrics.sh \
  'validated_metrics_rotation' metrics_rotation_gate
require_doc_pattern scripts/verify_phase5_alerts.sh \
  'validated_alert_rotation' alerts_rotation_gate
require_doc_pattern scripts/verify_phase5_alerts.sh \
  'validated_process_tick_gap_alert' alerts_process_tick_gap_gate
require_doc_pattern scripts/verify_phase5_alerts.sh \
  'validated_media_flow_gap_alert' alerts_media_flow_gap_gate
require_doc_pattern scripts/verify_phase5_alerts.sh \
  'validated_consecutive_transport_failure_alert' alerts_consecutive_transport_failure_gate
require_doc_pattern scripts/verify_phase5_metrics.sh \
  'max_process_tick_gap_us' metrics_process_tick_gap_gate
require_doc_pattern scripts/verify_phase5_metrics.sh \
  'max_rtp_output_gap_us' metrics_media_flow_gap_gate
require_doc_pattern scripts/verify_phase5_metrics.sh \
  'max_consecutive_transport_failures' metrics_transport_failure_gate
require_doc_pattern scripts/verify_phase5_debug_bundle.sh \
  'config_dump=pass' debug_bundle_config_dump_gate
require_doc_pattern scripts/verify_phase5_debug_bundle.sh \
  'first_alert=' debug_bundle_alert_summary_gate
require_doc_pattern scripts/verify_phase5_debug_bundle.sh \
  'first_problem=' debug_bundle_timeline_summary_gate
require_doc_pattern scripts/collect_phase5_debug_bundle.sh \
  'health_report.json' debug_bundle_health_report_collector
require_doc_pattern scripts/verify_phase5_debug_bundle.sh \
  'health_report.json' debug_bundle_health_report_verifier
require_doc_pattern scripts/verify_phase5_debug_bundle.sh \
  'recommended_actions' debug_bundle_health_actions_gate
require_doc_pattern scripts/collect_phase5_debug_bundle.sh \
  'slo_report.json' debug_bundle_slo_report_collector
require_doc_pattern scripts/verify_phase5_debug_bundle.sh \
  'slo_report.json' debug_bundle_slo_report_verifier
require_doc_pattern scripts/verify_phase5_debug_bundle.sh \
  'single debug bundle run; not a production SLO claim' debug_bundle_slo_scope_gate
require_doc_pattern scripts/verify_phase5_debug_bundle.sh \
  'availability.process_tick_gap' debug_bundle_slo_availability_gate
require_doc_pattern scripts/collect_phase5_debug_bundle.sh \
  'alert_policy.json' debug_bundle_alert_policy_collector
require_doc_pattern scripts/verify_phase5_debug_bundle.sh \
  'alert_policy.json' debug_bundle_alert_policy_verifier
require_doc_pattern scripts/verify_phase5_debug_bundle.sh \
  'phase5_default_runtime_alert_policy' debug_bundle_alert_policy_name
require_doc_pattern scripts/collect_phase5_debug_bundle.sh \
  'incident_report.json' debug_bundle_incident_report_collector
require_doc_pattern scripts/verify_phase5_debug_bundle.sh \
  'incident_report.json' debug_bundle_incident_report_verifier
require_doc_pattern scripts/verify_phase5_debug_bundle.sh \
  'verify_bundle_integrity' debug_bundle_incident_runbook_gate
require_doc_pattern scripts/collect_phase5_debug_bundle.sh \
  'phase5_monitoring_metrics.prom' debug_bundle_monitoring_metrics_collector
require_doc_pattern scripts/verify_phase5_debug_bundle.sh \
  'phase5_monitoring_metrics.prom' debug_bundle_monitoring_metrics_verifier
require_doc_pattern scripts/verify_phase5_debug_bundle.sh \
  'webrtc_qos_phase5_debug_bundle_slo_objective_status' debug_bundle_monitoring_metrics_slo_gate
require_doc_pattern scripts/verify_phase5_debug_bundle.sh \
  'webrtc_qos_phase5_debug_bundle_alerts_total' debug_bundle_monitoring_metrics_alert_gate
require_doc_pattern scripts/verify_phase5_implementation_gate.sh \
  'validated_phase5_implementation_records' implementation_gate_runtime_records
require_doc_pattern scripts/run_phase5_implementation_gate.sh \
  'phase5_minimal_udp_external_app' implementation_gate_runs_external_sample
require_doc_pattern scripts/run_phase5_implementation_gate.sh \
  'phase5_error_contract' implementation_gate_runs_error_contract
require_doc_pattern scripts/run_phase5_implementation_gate.sh \
  "! -path './manifest.sha256'" implementation_gate_top_manifest_scope
require_doc_pattern scripts/run_phase5_implementation_gate.sh \
  'phase5_implementation_gate_metrics.prom' implementation_gate_metrics_collector
require_doc_pattern scripts/verify_phase5_implementation_gate.sh \
  'verify_gate_metrics' implementation_gate_metrics_verifier
require_doc_pattern scripts/verify_phase5_implementation_gate.sh \
  'webrtc_qos_phase5_implementation_gate_step_status' implementation_gate_metrics_step_gate
require_doc_pattern scripts/verify_phase5_implementation_gate.sh \
  'webrtc_qos_phase5_implementation_gate_debug_bundle_status' implementation_gate_metrics_debug_bundle_gate
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'verify_phase5_debug_bundle.sh' production_gate_debug_bundle_verifier
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'require_success_debug_bundle' production_gate_success_bundle_gate
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'require_success_readiness' production_gate_success_readiness_gate
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'require_failed_gate_debug_bundle' production_gate_failure_bundle_gate
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'require_failed_readiness_evidence' production_gate_failed_readiness_gate
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'phase5_production_readiness' production_gate_runs_readiness_gate
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'phase5_implementation_gate' production_gate_runs_implementation_gate
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'verify_phase5_implementation_gate' production_gate_verifies_implementation_gate
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'require_success_implementation_gate' production_gate_success_implementation_gate
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  "step=phase5_implementation_gate status=pass" production_gate_failed_path_implementation_gate
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'require_failed_implementation_evidence' production_gate_failed_implementation_gate
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'phase5_implementation_gate_metrics' production_gate_release_implementation_metrics_index
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'release evidence missing implementation gate metrics' production_gate_release_implementation_metrics_gate
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'phase5_implementation_gate_metrics.prom' production_gate_verifies_implementation_metrics
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'git_worktree_clean' production_readiness_git_worktree_gate
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'GIT_TRACKED_WORKTREE_CLEAN' production_gate_git_worktree_metadata
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'evidence=git_worktree_clean status=pass' production_gate_release_git_worktree_gate
require_doc_pattern scripts/verify_webrtc_first_phase2_completion_audit.sh \
  'phase2_completion_audit_metrics.prom' production_gate_phase2_completion_metrics_collector
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'phase2_completion_audit_metrics' production_gate_release_phase2_completion_metrics_index
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'webrtc_qos_phase2_completion_audit_info' production_gate_phase2_completion_metrics_verifier
require_doc_pattern scripts/import_phase5_phase2_evidence_bundle.sh \
  'phase2_completion_audit_metrics' production_gate_external_import_phase2_completion_metrics
require_doc_pattern scripts/collect_webrtc_first_phase2_evidence_bundle.sh \
  'GIT_TRACKED_WORKTREE_CLEAN' production_gate_phase2_bundle_git_clean_collector
require_doc_pattern scripts/import_phase5_phase2_evidence_bundle.sh \
  'bundle_git_worktree_clean' production_gate_external_import_git_clean_gate
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'bundle_git_worktree_clean status=pass' production_gate_external_import_git_clean_verifier
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'phase2_completion_audit=pass' production_gate_phase2_completion_audit_gate
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'production_soak_archive' production_gate_release_soak_archive_index
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'MIN_PRODUCTION_SOAK_MINUTES="\$\{MIN_PRODUCTION_SOAK_MINUTES:-120\}"' production_gate_min_soak_default
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'SOAK_MINUTES=%g<%g' production_gate_soak_minutes_preflight
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'SOAK_MINUTES=%g<MIN_PRODUCTION_SOAK_MINUTES=%g' production_gate_soak_minutes_vs_min_preflight
require_doc_pattern scripts/run_webrtc_first_phase2_production_gate.sh \
  'MIN_PRODUCTION_SOAK_MINUTES="\$\{MIN_PRODUCTION_SOAK_MINUTES:-120\}"' phase2_production_gate_min_soak_default
require_doc_pattern scripts/run_webrtc_first_phase2_production_gate.sh \
  'SOAK_MINUTES=%g<%g' phase2_production_gate_soak_minutes_preflight
require_doc_pattern scripts/run_webrtc_first_phase2_production_gate.sh \
  'SOAK_MINUTES=%g<MIN_PRODUCTION_SOAK_MINUTES=%g' phase2_production_gate_soak_minutes_vs_min_preflight
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'real_renderer_metrics' production_gate_release_renderer_metrics_index
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'verify_webrtc_first_qoe_production_soak_archive.sh' production_gate_release_soak_reverify
require_doc_pattern scripts/run_webrtc_first_qoe_production_soak.sh \
  'sdk_git_tracked_worktree_clean' production_soak_archive_git_clean_metadata
require_doc_pattern scripts/run_webrtc_first_qoe_production_soak.sh \
  'status --short --untracked-files=no' production_soak_archive_tracked_status_only
require_doc_pattern scripts/verify_webrtc_first_qoe_production_soak_archive.sh \
  'REQUIRE_CLEAN_GIT_WORKTREE' production_soak_archive_git_clean_gate
require_doc_pattern scripts/verify_webrtc_first_qoe_production_soak_archive.sh \
  'sdk_git_tracked_worktree_clean' production_soak_archive_git_clean_verifier
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'release evidence real renderer used xvfb backend' production_gate_release_renderer_xvfb_gate
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'capture_qoe_csv' production_gate_release_capture_qoe_index
require_doc_pattern scripts/verify_capture_library_manifest.sh \
  'capture_manifest_sha256' production_gate_capture_manifest_sha256_collector
require_doc_pattern scripts/verify_webrtc_first_phase2_completion_audit.sh \
  'capture_manifest_sha256' production_gate_capture_manifest_sha256_audit
require_doc_pattern scripts/verify_webrtc_first_phase2_completion_audit.sh \
  'manifest_sha256=' production_gate_capture_manifest_sha256_audit_summary_gate
require_doc_pattern scripts/import_phase5_phase2_evidence_bundle.sh \
  'manifest_sha256' production_gate_external_import_capture_manifest_sha256
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'capture_manifest_sha256' production_gate_release_capture_manifest_sha256_index
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'capture manifest sha256 mismatch' production_gate_release_capture_manifest_sha256_verifier
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'capture_qoe_minima' production_gate_release_capture_qoe_minima
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'verify_capture_library_qoe_csv.sh' production_gate_release_capture_qoe_reverify
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'release evidence capture QoE rows are incomplete' production_gate_release_capture_qoe_rows
require_doc_pattern scripts/verify_webrtc_first_phase2_completion_audit.sh \
  'verify_capture_library_qoe_csv.sh' production_gate_capture_qoe_csv_audit
require_doc_pattern scripts/verify_webrtc_first_phase2_completion_audit.sh \
  'qoe_csv=' production_gate_capture_qoe_csv_evidence
require_doc_pattern scripts/run_webrtc_first_qoe_capture_library_720p.sh \
  'capture_qoe_summary.txt' production_gate_capture_qoe_summary
require_doc_pattern scripts/verify_capture_library_qoe_csv.sh \
  'renderer_proxy_drop_frames' production_gate_capture_qoe_drop_gate
require_doc_pattern scripts/verify_capture_library_qoe_csv.sh \
  'missing_categories' production_gate_capture_qoe_category_gate
require_doc_pattern scripts/import_phase5_phase2_evidence_bundle.sh \
  'phase5_phase2_external_evidence_import' production_gate_external_evidence_import_report
require_doc_pattern scripts/import_phase5_phase2_evidence_bundle.sh \
  'production_soak_raw_evidence' production_gate_external_import_soak_raw_evidence
require_doc_pattern scripts/import_phase5_phase2_evidence_bundle.sh \
  'real_renderer_raw_evidence' production_gate_external_import_renderer_raw_evidence
require_doc_pattern scripts/import_phase5_phase2_evidence_bundle.sh \
  'capture_qoe_raw_evidence' production_gate_external_import_capture_raw_evidence
require_doc_pattern scripts/import_phase5_phase2_evidence_bundle.sh \
  'production_soak_archive' production_gate_external_import_soak_archive_pointer
require_doc_pattern scripts/import_phase5_phase2_evidence_bundle.sh \
  'real_renderer_metrics' production_gate_external_import_renderer_metrics_pointer
require_doc_pattern scripts/import_phase5_phase2_evidence_bundle.sh \
  'capture_qoe_csv' production_gate_external_import_capture_qoe_pointer
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'PHASE2_EVIDENCE_BUNDLE_DIR' production_gate_external_evidence_import_runner
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'external_phase2_evidence_bundle' production_readiness_external_evidence_gate
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'external_phase2_import_report_passed' production_readiness_external_import_report_gate
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'import_status.*pass' production_readiness_external_import_status_gate
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'capture_qoe_raw_evidence' production_readiness_external_import_capture_qoe_gate
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'source_git_worktree_clean' production_readiness_external_import_git_clean_gate
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'fixture_capture_allowed' production_readiness_external_import_fixture_gate
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'phase2_evidence_source=external_bundle' production_gate_external_evidence_verifier
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'external phase2 import missing artifact pointer' production_gate_external_import_artifact_pointer_gate
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'external phase2 import missing \{section_name\}' production_gate_external_import_section_pointer_gate
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'phase5_release_evidence.json' production_gate_release_evidence_collector
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'require_release_evidence' production_gate_release_evidence_verifier
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'phase5 formal production release evidence' production_gate_release_evidence_scope
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'evidence=production_soak status=pass' production_gate_release_evidence_soak
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'step=phase5_release_evidence status=pass' production_gate_release_evidence_step
require_doc_pattern scripts/run_phase5_production_gate.sh \
  'phase5_production_gate_metrics.prom' production_gate_metrics_collector
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'verify_gate_metrics' production_gate_metrics_verifier
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'webrtc_qos_phase5_production_gate_step_status' production_gate_metrics_step_gate
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'webrtc_qos_phase5_production_gate_failure_debug_bundle_status' production_gate_metrics_failure_bundle_gate
require_doc_pattern scripts/verify_phase5_completion_audit.sh \
  'phase5_completion_audit_metrics.prom' completion_audit_metrics_collector
require_doc_pattern scripts/verify_phase5_completion_audit.sh \
  'webrtc_qos_phase5_completion_audit_info' completion_audit_metrics_info_gate
require_doc_pattern scripts/verify_phase5_completion_audit.sh \
  'webrtc_qos_phase5_completion_audit_production_evidence_status' completion_audit_metrics_production_gate
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'phase5_production_readiness_status=' production_readiness_status_gate
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'invalid_production_soak_config' production_readiness_min_soak_config_gate
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'MIN_PRODUCTION_SOAK_MINUTES=%g<%g' production_readiness_min_soak_floor_gate
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'SOAK_MINUTES_ge_120' production_readiness_min_soak_action_floor
require_doc_pattern scripts/import_phase5_phase2_evidence_bundle.sh \
  'MIN_PRODUCTION_SOAK_MINUTES=%g<%g' production_import_min_soak_floor_gate
require_doc_pattern scripts/import_phase5_phase2_evidence_bundle.sh \
  'production_soak_minutes >= phase5_min_soak_minutes' production_import_soak_minutes_floor_gate
require_doc_pattern scripts/verify_webrtc_first_phase2_completion_audit.sh \
  'production_soak_minimum_config' phase2_completion_audit_min_soak_config_gate
require_doc_pattern scripts/verify_webrtc_first_phase2_completion_audit.sh \
  'MIN_PRODUCTION_SOAK_MINUTES=%g<%g' phase2_completion_audit_min_soak_floor_gate
require_doc_pattern scripts/verify_webrtc_first_phase2_completion_audit.sh \
  'SOAK_MINUTES_ge_120' phase2_completion_audit_min_soak_action_floor
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'readiness_status="ready"' production_readiness_ready_branch
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'next_required_actions_file' production_readiness_actions_file
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'readiness_report.json' production_readiness_structured_report
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'next_required_actions.json' production_readiness_structured_actions
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'risk_milestone_report.json' production_readiness_risk_milestone_report
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'phase5_production_readiness_metrics.prom' production_readiness_metrics_collector
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'webrtc_qos_phase5_production_readiness_milestone_status' production_readiness_metrics_milestone_gate
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'verify_readiness_metrics' production_gate_readiness_metrics_verifier
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'webrtc_qos_phase5_production_readiness_risk_status' production_gate_readiness_metrics_risk_gate
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'formal_completion_status' production_readiness_completion_status_gate
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'fanout_evaluation' production_readiness_fanout_deferred
require_doc_pattern scripts/verify_phase5_production_readiness.sh \
  'action_for_check' production_readiness_action_mapping
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'next_required_actions.txt' production_gate_failed_readiness_actions
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'verify_readiness_json' production_gate_readiness_json_gate
require_doc_pattern scripts/verify_phase5_production_gate.sh \
  'risk_milestone_report.json' production_gate_risk_milestone_json_gate
require_doc_pattern scripts/run_phase5_production_gate.sh \
  "! -path './manifest.sha256'" production_gate_top_manifest_scope

if has_file "${PHASE5_DEBUG_BUNDLE_DIR}/manifest.sha256" &&
    has_file "${PHASE5_DEBUG_BUNDLE_DIR}/runtime_config.json"; then
  if BUNDLE_DIR="${PHASE5_DEBUG_BUNDLE_DIR}" \
      "${SDK_ROOT}/scripts/verify_phase5_debug_bundle.sh" >/dev/null 2>&1; then
    audit_pass debug_bundle_evidence "bundle=${PHASE5_DEBUG_BUNDLE_DIR}"
  else
    audit_fail debug_bundle_evidence "verify_failed bundle=${PHASE5_DEBUG_BUNDLE_DIR}"
  fi
else
  audit_warn debug_bundle_evidence \
    "missing_or_not_collected bundle=${PHASE5_DEBUG_BUNDLE_DIR}"
fi

if has_file "${PHASE5_IMPLEMENTATION_GATE_DIR}/manifest.sha256" &&
    has_file "${PHASE5_IMPLEMENTATION_GATE_DIR}/phase5_implementation_gate_summary.txt"; then
  if GATE_DIR="${PHASE5_IMPLEMENTATION_GATE_DIR}" REQUIRE_PASS=1 \
      "${SDK_ROOT}/scripts/verify_phase5_implementation_gate.sh" >/dev/null 2>&1; then
    audit_pass implementation_evidence "gate=${PHASE5_IMPLEMENTATION_GATE_DIR}"
  else
    audit_fail implementation_evidence \
      "phase5_implementation_gate_verify_failed gate=${PHASE5_IMPLEMENTATION_GATE_DIR}"
  fi
else
  audit_fail implementation_evidence \
    "missing_or_not_collected gate=${PHASE5_IMPLEMENTATION_GATE_DIR}"
fi

if [[ -n "${PHASE5_GATE_DIR}" ]]; then
  if [[ "${REQUIRE_PRODUCTION_EVIDENCE}" == "1" ]]; then
    if GATE_DIR="${PHASE5_GATE_DIR}" REQUIRE_PASS=1 \
        "${SDK_ROOT}/scripts/verify_phase5_production_gate.sh" >/dev/null 2>&1; then
      audit_pass production_evidence "gate=${PHASE5_GATE_DIR}"
    else
      audit_fail production_evidence "phase5_gate_not_pass gate=${PHASE5_GATE_DIR}"
    fi
  else
    if GATE_DIR="${PHASE5_GATE_DIR}" REQUIRE_PASS=0 \
        "${SDK_ROOT}/scripts/verify_phase5_production_gate.sh" >/dev/null 2>&1; then
      if rg -q '^phase5_production_gate_status=dry_run$' \
          "${PHASE5_GATE_DIR}/phase5_production_gate_summary.txt"; then
        if [[ "${ALLOW_DRY_RUN_GATE}" == "1" ]]; then
          audit_warn production_evidence "dry_run_gate=${PHASE5_GATE_DIR}"
        else
          audit_fail production_evidence "dry_run_not_production gate=${PHASE5_GATE_DIR}"
        fi
      elif rg -q '^phase5_production_gate_status=fail$' \
          "${PHASE5_GATE_DIR}/phase5_production_gate_summary.txt"; then
        audit_warn production_evidence "verified_failed_gate_not_production gate=${PHASE5_GATE_DIR}"
      else
        audit_pass production_evidence "gate=${PHASE5_GATE_DIR}"
      fi
    else
      audit_fail production_evidence "phase5_gate_verify_failed gate=${PHASE5_GATE_DIR}"
    fi
  fi
else
  if [[ "${REQUIRE_PRODUCTION_EVIDENCE}" == "1" ]]; then
    audit_fail production_evidence "missing PHASE5_GATE_DIR with passed production gate"
  else
    audit_warn production_evidence "not_required PHASE5_GATE_DIR unset"
  fi
fi

if [[ "${failures}" -eq 0 && "${REQUIRE_PRODUCTION_EVIDENCE}" == "1" ]]; then
  write_summary "phase5_completion_status=complete"
  write_summary "phase5_completion_audit=pass"
  write_summary "pass_count=${pass_count}"
  write_summary "warning_count=${warnings}"
  write_summary "phase5_completion_audit_metrics=${PHASE5_COMPLETION_AUDIT_METRICS_PROM}"
  write_audit_metrics
  exit 0
fi

if [[ "${failures}" -eq 0 ]]; then
  write_summary "phase5_completion_status=implemented_without_required_production_evidence"
  write_summary "phase5_completion_audit=pass_non_production"
  write_summary "pass_count=${pass_count}"
  write_summary "warning_count=${warnings}"
  write_summary "next_required_actions=rerun_phase5_completion_audit_with_REQUIRE_PRODUCTION_EVIDENCE_1_after_passed_phase5_production_gate"
  write_summary "phase5_completion_audit_metrics=${PHASE5_COMPLETION_AUDIT_METRICS_PROM}"
  write_audit_metrics
  exit 0
fi

write_summary "phase5_completion_status=incomplete"
write_summary "phase5_completion_audit=fail"
write_summary "pass_count=${pass_count}"
write_summary "warning_count=${warnings}"
write_summary "failure_count=${failures}"
write_summary "next_required_actions=run_phase5_implementation_gate_then_run_phase5_production_gate_with_SOAK_MINUTES_ge_120_real_renderer_pass_formal_capture_library"
write_summary "phase5_completion_audit_metrics=${PHASE5_COMPLETION_AUDIT_METRICS_PROM}"
write_audit_metrics
exit 1
