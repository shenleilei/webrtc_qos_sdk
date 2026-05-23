#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GATE_DIR="${GATE_DIR:-${1:-/root/webrtc_qos_sdk/artifacts/phase5_production_gate/latest}}"
REQUIRE_PASS="${REQUIRE_PASS:-0}"
SUMMARY_FILE="${GATE_DIR}/phase5_production_gate_summary.txt"

fail() {
  echo "phase5 production gate verification failed: $*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -s "${path}" ]] || fail "missing or empty file: ${path}"
}

[[ -d "${GATE_DIR}" ]] || fail "missing gate directory: ${GATE_DIR}"

require_file "${GATE_DIR}/metadata.txt"
require_file "${GATE_DIR}/git_tracked_status.txt"
require_file "${SUMMARY_FILE}"
require_file "${GATE_DIR}/files.txt"
require_file "${GATE_DIR}/manifest.sha256"
require_file "${GATE_DIR}/phase5_production_gate_metrics.prom"

[[ -x "${SDK_ROOT}/scripts/verify_phase5_debug_bundle.sh" ]] ||
  fail "missing debug bundle verifier: ${SDK_ROOT}/scripts/verify_phase5_debug_bundle.sh"
[[ -x "${SDK_ROOT}/scripts/verify_phase5_implementation_gate.sh" ]] ||
  fail "missing implementation gate verifier: ${SDK_ROOT}/scripts/verify_phase5_implementation_gate.sh"
[[ -x "${SDK_ROOT}/scripts/verify_capture_library_qoe_csv.sh" ]] ||
  fail "missing capture QoE CSV verifier: ${SDK_ROOT}/scripts/verify_capture_library_qoe_csv.sh"
[[ -x "${SDK_ROOT}/scripts/verify_capture_library_evidence.sh" ]] ||
  fail "missing capture evidence verifier: ${SDK_ROOT}/scripts/verify_capture_library_evidence.sh"
[[ -x "${SDK_ROOT}/scripts/verify_webrtc_first_qoe_production_soak_archive.sh" ]] ||
  fail "missing production soak archive verifier: ${SDK_ROOT}/scripts/verify_webrtc_first_qoe_production_soak_archive.sh"
[[ -x "${SDK_ROOT}/scripts/verify_webrtc_first_qoe_production_soak_evidence.sh" ]] ||
  fail "missing production soak evidence verifier: ${SDK_ROOT}/scripts/verify_webrtc_first_qoe_production_soak_evidence.sh"

(
  cd "${GATE_DIR}"
  sha256sum -c manifest.sha256 >/dev/null
)

verify_top_manifest_consistency() {
  local dir="$1"
  local label="$2"
  python3 - "${dir}" "${label}" <<'PY'
import os
import sys

gate_dir, label = sys.argv[1:3]
files_path = os.path.join(gate_dir, "files.txt")
manifest_path = os.path.join(gate_dir, "manifest.sha256")

with open(files_path, "r", encoding="utf-8") as fh:
    files = [line.strip() for line in fh if line.strip()]
with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest_files = []
    for line_no, line in enumerate(fh, 1):
        line = line.rstrip("\n")
        if len(line) < 67:
            raise SystemExit(f"{label} manifest line {line_no} is too short")
        digest, rel = line.split(None, 1)
        if len(digest) != 64 or not all(
            ch in "0123456789abcdefABCDEF" for ch in digest
        ):
            raise SystemExit(f"{label} manifest line {line_no} has invalid sha256")
        manifest_files.append(rel.lstrip("*"))

actual_files = []
for root, _, names in os.walk(gate_dir):
    for name in names:
        path = os.path.join(root, name)
        rel = os.path.relpath(path, gate_dir)
        if rel in {"manifest.sha256", "files.txt"}:
            continue
        actual_files.append(rel)
actual_files.sort()

if files != sorted(files):
    raise SystemExit(f"{label} files.txt is not sorted")
if files != manifest_files:
    raise SystemExit(f"{label} files.txt and manifest.sha256 file sets differ")
if files != actual_files:
    raise SystemExit(f"{label} files.txt does not match actual files")
PY
}

verify_top_manifest_consistency "${GATE_DIR}" "top"

summary_has() {
  local pattern="$1"
  rg -q "${pattern}" "${SUMMARY_FILE}"
}

verify_gate_metrics() {
  local expected_status="$1"
  python3 - "${GATE_DIR}/phase5_production_gate_metrics.prom" "${expected_status}" "${GATE_DIR}" <<'PY'
import collections
import json
import pathlib
import re
import sys

path, expected_status, gate_dir = sys.argv[1:4]
text = pathlib.Path(path).read_text(encoding="utf-8")
for required_text in (
    "# TYPE webrtc_qos_phase5_production_gate_info gauge",
    "webrtc_qos_phase5_production_gate_info",
    "webrtc_qos_phase5_production_gate_steps_total",
    "webrtc_qos_phase5_production_gate_step_status",
    "webrtc_qos_phase5_production_gate_failure_debug_bundle_status",
    "webrtc_qos_phase5_production_gate_release_evidence_status",
    "webrtc_qos_phase5_release_evidence_info",
    "webrtc_qos_phase5_release_evidence_items_total",
):
    if required_text not in text:
        raise SystemExit(f"production gate metrics missing {required_text}")

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
            f"production gate metrics line {line_no} is invalid: {line}"
        )
    labels = {}
    raw_labels = match.group(3) or ""
    position = 0
    while position < len(raw_labels):
        label_match = label_re.match(raw_labels, position)
        if not label_match:
            raise SystemExit(
                f"production gate metrics line {line_no} has invalid labels"
            )
        labels[label_match.group(1)] = label_match.group(2)
        position = label_match.end()
        if position < len(raw_labels):
            if raw_labels[position] != ",":
                raise SystemExit(
                    f"production gate metrics line {line_no} has malformed labels"
                )
            position += 1
    records.append({
        "name": match.group(1),
        "labels": labels,
        "value": float(match.group(4)),
    })
if not records:
    raise SystemExit("production gate metrics file has no samples")

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

def values(name, **labels):
    matched = []
    for record in records:
        if record["name"] != name:
            continue
        if not all(record["labels"].get(key) == label for key, label in labels.items()):
            continue
        matched.append(record["value"])
    return matched

def release_evidence_item_metric_counts():
    counts = {}
    for record in records:
        if record["name"] != "webrtc_qos_phase5_release_evidence_items_total":
            continue
        item_status = record["labels"].get("status")
        if not item_status:
            raise SystemExit(
                "production gate metrics release evidence item count missing status label"
            )
        if item_status in counts:
            raise SystemExit(
                f"production gate metrics duplicate release evidence item count status {item_status}"
            )
        if record["value"] < 0 or int(record["value"]) != record["value"]:
            raise SystemExit(
                f"production gate metrics invalid release evidence item count for {item_status}"
            )
        counts[item_status] = int(record["value"])
    return counts

def release_evidence_json_counts():
    json_path = pathlib.Path(gate_dir) / "phase5_release_evidence.json"
    try:
        with json_path.open("r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        raise SystemExit("passed gate metrics missing release evidence json")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"passed gate metrics release evidence json is invalid: {exc}")
    evidence = doc.get("evidence")
    if not isinstance(evidence, list):
        raise SystemExit("passed gate metrics release evidence list missing")
    counts = collections.Counter()
    for item in evidence:
        if isinstance(item, dict):
            counts[str(item.get("status") or "missing")] += 1
        else:
            counts["invalid"] += 1
    return doc, counts

if not has(
    "webrtc_qos_phase5_production_gate_info",
    value=1,
    status=expected_status,
):
    raise SystemExit("production gate metrics missing expected gate status")
for step in ("phase5_implementation_gate", "phase5_release_contract", "phase5_production_readiness"):
    if not has("webrtc_qos_phase5_production_gate_step_status", step=step):
        raise SystemExit(f"production gate metrics missing step {step}")
if expected_status == "fail":
    if not has("webrtc_qos_phase5_production_gate_steps_total", status="fail"):
        raise SystemExit("failed gate metrics missing failed step count")
    if not has(
        "webrtc_qos_phase5_production_gate_failure_debug_bundle_status",
        value=1,
        status="pass",
    ):
        raise SystemExit("failed gate metrics missing verified failure bundle marker")
elif expected_status == "pass":
    if not has(
        "webrtc_qos_phase5_production_gate_release_evidence_status",
        value=1,
        status="pass",
    ):
        raise SystemExit("passed gate metrics missing release evidence pass marker")
    if not has(
        "webrtc_qos_phase5_release_evidence_info",
        value=1,
        formal_completion_status="complete",
        status="pass",
    ):
        raise SystemExit("passed gate metrics missing release evidence complete info")
    release_doc, expected_item_counts = release_evidence_json_counts()
    if not has(
        "webrtc_qos_phase5_release_evidence_info",
        value=1,
        formal_completion_status=str(
            release_doc.get("formal_completion_status") or "unknown"
        ),
        status=str(release_doc.get("release_status") or "unknown"),
    ):
        raise SystemExit("passed gate metrics release evidence info mismatch")
    observed_item_counts = release_evidence_item_metric_counts()
    item_statuses = (
        set(expected_item_counts)
        | set(observed_item_counts)
        | {"fail", "invalid", "missing", "pass"}
    )
    for item_status in sorted(item_statuses):
        expected_count = expected_item_counts.get(item_status, 0)
        observed_count = observed_item_counts.get(item_status)
        if observed_count is None:
            raise SystemExit(
                f"passed gate metrics missing release evidence item count for {item_status}"
            )
        if observed_count != expected_count:
            raise SystemExit(
                "passed gate metrics release evidence item count mismatch "
                f"status={item_status} expected={expected_count} observed={observed_count}"
            )
    pass_item_counts = values(
        "webrtc_qos_phase5_release_evidence_items_total",
        status="pass",
    )
    if not pass_item_counts or sum(pass_item_counts) <= 0:
        raise SystemExit("passed gate metrics missing release evidence pass item count")
    for bad_status in ("fail", "missing", "invalid"):
        bad_item_counts = values(
            "webrtc_qos_phase5_release_evidence_items_total",
            status=bad_status,
        )
        if any(value != 0 for value in bad_item_counts):
            raise SystemExit(
                f"passed gate metrics has release evidence {bad_status} items"
            )
elif expected_status == "dry_run":
    if not has("webrtc_qos_phase5_production_gate_steps_total", status="planned"):
        raise SystemExit("dry-run gate metrics missing planned step count")
PY
}

verify_phase2_completion_audit_metrics() {
  local metrics_file="$1"
  python3 - "${metrics_file}" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
for required_text in (
    "# TYPE webrtc_qos_phase2_completion_audit_info gauge",
    "webrtc_qos_phase2_completion_audit_info",
    "webrtc_qos_phase2_completion_audit_checks_total",
    "webrtc_qos_phase2_completion_audit_check_status",
    "webrtc_qos_phase2_completion_audit_production_evidence_status",
):
    if required_text not in text:
        raise SystemExit(f"phase2 completion audit metrics missing {required_text}")

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
            f"phase2 completion audit metrics line {line_no} is invalid: {line}"
        )
    labels = {}
    raw_labels = match.group(3) or ""
    position = 0
    while position < len(raw_labels):
        label_match = label_re.match(raw_labels, position)
        if not label_match:
            raise SystemExit(
                f"phase2 completion audit metrics line {line_no} has invalid labels"
            )
        labels[label_match.group(1)] = label_match.group(2)
        position = label_match.end()
        if position < len(raw_labels):
            if raw_labels[position] != ",":
                raise SystemExit(
                    f"phase2 completion audit metrics line {line_no} has malformed labels"
                )
            position += 1
    records.append({
        "name": match.group(1),
        "labels": labels,
        "value": float(match.group(4)),
    })
if not records:
    raise SystemExit("phase2 completion audit metrics file has no samples")

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
    "webrtc_qos_phase2_completion_audit_info",
    value=1,
    audit_status="pass",
    completion_status="complete",
):
    raise SystemExit("phase2 completion audit metrics missing pass/complete marker")
for check in ("production_soak", "real_renderer", "capture_library", "evidence_bundle"):
    if not has(
        "webrtc_qos_phase2_completion_audit_check_status",
        value=1,
        check=check,
        status="pass",
    ):
        raise SystemExit(f"phase2 completion audit metrics missing pass check {check}")
    if not has(
        "webrtc_qos_phase2_completion_audit_production_evidence_status",
        value=1,
        check=check,
        status="pass",
    ):
        raise SystemExit(
            f"phase2 completion audit metrics missing production evidence {check}"
        )
if not has("webrtc_qos_phase2_completion_audit_checks_total", value=0, status="fail"):
    raise SystemExit("phase2 completion audit metrics recorded failed checks")
PY
}

verify_readiness_json() {
  local readiness_dir="$1"
  local expected_status="$2"
  python3 - "${readiness_dir}" "${expected_status}" <<'PY'
import json
import sys

readiness_dir, expected_status = sys.argv[1:3]
report_path = f"{readiness_dir}/readiness_report.json"
actions_path = f"{readiness_dir}/next_required_actions.json"
risk_path = f"{readiness_dir}/risk_milestone_report.json"

with open(report_path, "r", encoding="utf-8") as fh:
    report = json.load(fh)
with open(actions_path, "r", encoding="utf-8") as fh:
    actions_doc = json.load(fh)
with open(risk_path, "r", encoding="utf-8") as fh:
    risk_doc = json.load(fh)

if report.get("schema_version") != 1:
    raise SystemExit("readiness_report schema_version must be 1")
if actions_doc.get("schema_version") != 1:
    raise SystemExit("next_required_actions schema_version must be 1")
if risk_doc.get("schema_version") != 1:
    raise SystemExit("risk_milestone_report schema_version must be 1")
if report.get("source") != "phase5_production_readiness":
    raise SystemExit("readiness_report source mismatch")
if actions_doc.get("source") != "phase5_production_readiness":
    raise SystemExit("next_required_actions source mismatch")
if risk_doc.get("source") != "phase5_production_readiness":
    raise SystemExit("risk_milestone_report source mismatch")
if report.get("readiness_status") != expected_status:
    raise SystemExit("readiness_report status mismatch")
if actions_doc.get("readiness_status") != expected_status:
    raise SystemExit("next_required_actions status mismatch")
if risk_doc.get("readiness_status") != expected_status:
    raise SystemExit("risk_milestone_report status mismatch")

checks = report.get("checks")
actions = report.get("next_required_actions")
actions_doc_actions = actions_doc.get("actions")
if not isinstance(checks, list) or not checks:
    raise SystemExit("readiness_report checks must be a non-empty list")
if not isinstance(actions, list):
    raise SystemExit("readiness_report actions must be a list")
if actions != actions_doc_actions:
    raise SystemExit("readiness_report actions differ from next_required_actions")
if report.get("action_count") != len(actions):
    raise SystemExit("readiness_report action_count mismatch")
if actions_doc.get("action_count") != len(actions):
    raise SystemExit("next_required_actions action_count mismatch")
if risk_doc.get("next_required_actions") != actions:
    raise SystemExit("risk_milestone_report actions differ from readiness report")
if risk_doc.get("formal_completion_status") != "requires_passed_phase5_production_gate":
    raise SystemExit("risk_milestone_report completion status mismatch")

milestones = risk_doc.get("milestones")
risks = risk_doc.get("risks")
if not isinstance(milestones, list) or len(milestones) < 6:
    raise SystemExit("risk_milestone_report milestones must include M1-M6")
if not isinstance(risks, list) or len(risks) < 5:
    raise SystemExit("risk_milestone_report risks must include R1-R5")
milestone_by_id = {item.get("id"): item for item in milestones}
risk_by_id = {item.get("id"): item for item in risks}
for required in ("M1", "M2", "M3", "M4", "M5", "M6"):
    if required not in milestone_by_id:
        raise SystemExit(f"risk_milestone_report missing milestone {required}")
for required in ("R1", "R2", "R3", "R4", "R5"):
    if required not in risk_by_id:
        raise SystemExit(f"risk_milestone_report missing risk {required}")
if milestone_by_id["M6"].get("status") != "deferred":
    raise SystemExit("fanout milestone must remain deferred in P5 baseline")
if risk_by_id["R5"].get("status") != "deferred":
    raise SystemExit("fanout risk must remain deferred in P5 baseline")

statuses = {item.get("status") for item in checks}
if expected_status == "ready":
    if report.get("failure_count") != 0 or report.get("skipped_count") != 0:
        raise SystemExit("ready report contains failures or skipped checks")
    if actions:
        raise SystemExit("ready report contains remediation actions")
    required_passes = {"webrtc_modules", "capture_manifest", "real_renderer"}
    if any(item.get("check") == "external_phase2_evidence_bundle" for item in checks):
        required_passes.add("external_phase2_evidence_bundle")
    passed = {item.get("check") for item in checks if item.get("status") == "pass"}
    missing = sorted(required_passes - passed)
    if missing:
        raise SystemExit(f"ready report missing passed checks: {missing}")
    if risk_doc.get("phase5_basis_status") != "ready_for_formal_production_gate":
        raise SystemExit("ready risk report basis status mismatch")
    if milestone_by_id["M1"].get("status") != "ready":
        raise SystemExit("ready risk report M1 status mismatch")
    if risk_by_id["R4"].get("status") != "controlled":
        raise SystemExit("ready risk report production environment risk mismatch")
else:
    if not actions:
        raise SystemExit("not_ready report contains no remediation actions")
    if not ({"fail", "skipped"} & statuses):
        raise SystemExit("not_ready report has no failed/skipped checks")
    actionable = {
        "capture_manifest",
        "real_renderer",
        "webrtc_modules",
        "soak_config",
        "external_phase2_evidence_bundle",
    }
    action_names = {item.get("action") for item in actions}
    has_actionable = any(name in actionable or str(name).startswith("script_") for name in action_names)
    if not has_actionable:
        raise SystemExit("not_ready report has no actionable remediation")
    if risk_doc.get("phase5_basis_status") != "not_ready_for_formal_production_gate":
        raise SystemExit("not_ready risk report basis status mismatch")
    if milestone_by_id["M1"].get("status") != "blocked":
        raise SystemExit("not_ready risk report M1 status mismatch")
    if "M1" not in risk_doc.get("blocked_milestones", []):
        raise SystemExit("not_ready risk report missing blocked M1")
    if risk_by_id["R4"].get("status") != "blocked":
        raise SystemExit("not_ready risk report production environment risk mismatch")
PY
}

verify_readiness_metrics() {
  local readiness_dir="$1"
  local expected_status="$2"
  python3 - "${readiness_dir}" "${expected_status}" <<'PY'
import pathlib
import re
import sys

readiness_dir, expected_status = sys.argv[1:3]
path = pathlib.Path(readiness_dir) / "phase5_production_readiness_metrics.prom"
text = path.read_text(encoding="utf-8")
for required_text in (
    "# TYPE webrtc_qos_phase5_production_readiness_info gauge",
    "webrtc_qos_phase5_production_readiness_info",
    "webrtc_qos_phase5_production_readiness_failures_total",
    "webrtc_qos_phase5_production_readiness_actions_total",
    "webrtc_qos_phase5_production_readiness_check_status",
    "webrtc_qos_phase5_production_readiness_milestone_status",
    "webrtc_qos_phase5_production_readiness_risk_status",
    "webrtc_qos_phase5_production_readiness_action_required",
):
    if required_text not in text:
        raise SystemExit(f"readiness metrics missing {required_text}")

prom_line_re = re.compile(
    r"^([A-Za-z_:][A-Za-z0-9_:]*)(\{([^{}]*)\})?\s+"
    r"([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|[+-]?Inf|NaN)$"
)
prom_label_re = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)="((?:\\.|[^"\\])*)"')
records = []
for line_no, line in enumerate(text.splitlines(), 1):
    if not line.strip() or line.startswith("#"):
        continue
    match = prom_line_re.match(line)
    if not match:
        raise SystemExit(
            "readiness metrics line is not valid Prometheus text format: "
            f"line={line_no} text={line}"
        )
    labels = {}
    raw_labels = match.group(3) or ""
    position = 0
    while position < len(raw_labels):
        label_match = prom_label_re.match(raw_labels, position)
        if not label_match:
            raise SystemExit(f"readiness metrics line {line_no} has invalid labels")
        labels[label_match.group(1)] = label_match.group(2)
        position = label_match.end()
        if position < len(raw_labels):
            if raw_labels[position] != ",":
                raise SystemExit(
                    f"readiness metrics line {line_no} has malformed labels"
                )
            position += 1
    try:
        value = float(match.group(4))
    except ValueError as exc:
        raise SystemExit(
            f"readiness metrics line {line_no} has invalid value"
        ) from exc
    records.append({"name": match.group(1), "labels": labels, "value": value})
if not records:
    raise SystemExit("readiness metrics file has no samples")

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
    "webrtc_qos_phase5_production_readiness_info",
    readiness_status=expected_status,
):
    raise SystemExit("readiness metrics missing readiness info status")
for check in ("soak_config", "webrtc_modules"):
    if not has("webrtc_qos_phase5_production_readiness_check_status", check=check):
        raise SystemExit(f"readiness metrics missing check status {check}")
for milestone in ("M1", "M6"):
    if not has(
        "webrtc_qos_phase5_production_readiness_milestone_status",
        milestone=milestone,
    ):
        raise SystemExit(f"readiness metrics missing milestone {milestone}")
for risk in ("R4", "R5"):
    if not has("webrtc_qos_phase5_production_readiness_risk_status", risk=risk):
        raise SystemExit(f"readiness metrics missing risk {risk}")
if expected_status == "ready":
    if not has(
        "webrtc_qos_phase5_production_readiness_milestone_status",
        value=1,
        milestone="M1",
        status="ready",
    ):
        raise SystemExit("ready metrics missing ready M1 marker")
    if not has("webrtc_qos_phase5_production_readiness_actions_total", value=0):
        raise SystemExit("ready metrics action count is not zero")
    if not has(
        "webrtc_qos_phase5_production_readiness_action_required",
        value=0,
        action="none",
    ):
        raise SystemExit("ready metrics missing no-action marker")
else:
    if not has(
        "webrtc_qos_phase5_production_readiness_milestone_status",
        value=1,
        milestone="M1",
        status="blocked",
    ):
        raise SystemExit("not_ready metrics missing blocked M1 marker")
    if not has("webrtc_qos_phase5_production_readiness_action_required"):
        raise SystemExit("not_ready metrics missing required action marker")
PY
}

require_failed_gate_debug_bundle() {
  summary_has '^failure_debug_bundle_status=pass ' ||
    fail "failed gate did not collect verified failure debug bundle"
  summary_has '^failure_debug_bundle=' ||
    fail "failed gate summary missing failure debug bundle directory"
  require_file "${GATE_DIR}/logs/failure_debug_bundle_collect.log"
  require_file "${GATE_DIR}/logs/failure_debug_bundle_verify.log"
  require_file "${GATE_DIR}/failure_debug_bundle/manifest.sha256"
  require_file "${GATE_DIR}/failure_debug_bundle/runtime_config.json"
  (
    cd "${GATE_DIR}/failure_debug_bundle"
    sha256sum -c manifest.sha256 >/dev/null
  )
  BUNDLE_DIR="${GATE_DIR}/failure_debug_bundle" \
    "${SDK_ROOT}/scripts/verify_phase5_debug_bundle.sh" >/dev/null
}

require_failed_readiness_evidence() {
  summary_has '^step=phase5_production_readiness status=fail ' || return 0
  summary_has '^phase5_readiness_dir=' ||
    fail "failed readiness gate summary missing readiness directory"
  local readiness_dir="${GATE_DIR}/phase5_production_readiness"
  local readiness_summary="${readiness_dir}/phase5_production_readiness_summary.txt"
  require_file "${readiness_summary}"
  require_file "${readiness_dir}/files.txt"
  require_file "${readiness_dir}/manifest.sha256"
  require_file "${readiness_dir}/next_required_actions.txt"
  require_file "${readiness_dir}/next_required_actions.json"
  require_file "${readiness_dir}/readiness_report.json"
  require_file "${readiness_dir}/risk_milestone_report.json"
  require_file "${readiness_dir}/risk_milestone_summary.txt"
  require_file "${readiness_dir}/phase5_production_readiness_metrics.prom"
  require_file "${readiness_dir}/check_records.jsonl"
  require_file "${readiness_dir}/action_records.jsonl"
  require_file "${readiness_dir}/logs/webrtc_modules.log"
  if [[ -f "${readiness_dir}/logs/external_phase2_evidence_bundle.log" ]]; then
    require_file "${readiness_dir}/logs/external_phase2_evidence_bundle.log"
    if [[ -f "${readiness_dir}/external_phase2_evidence_import/manifest.sha256" ]]; then
      (
        cd "${readiness_dir}/external_phase2_evidence_import"
        sha256sum -c manifest.sha256 >/dev/null
      )
      verify_top_manifest_consistency \
        "${readiness_dir}/external_phase2_evidence_import" \
        "readiness external phase2 import"
    fi
    if [[ -f "${readiness_dir}/external_phase2_evidence_import/phase2_external_evidence_import.json" ]]; then
      python3 - "${readiness_dir}/external_phase2_evidence_import/phase2_external_evidence_import.json" <<'PY'
import json
import sys

report_path = sys.argv[1]
with open(report_path, "r", encoding="utf-8") as fh:
    report = json.load(fh)
if report.get("schema_version") != 1:
    raise SystemExit("external phase2 import schema_version mismatch")
if report.get("source") != "phase5_phase2_external_evidence_import":
    raise SystemExit("external phase2 import source mismatch")
artifacts = report.get("artifacts", {})
for key in (
    "phase2_evidence_metadata",
    "phase2_completion_audit_metrics",
    "production_soak_summary",
    "production_soak_csv",
    "production_soak_config",
    "production_soak_archive",
    "production_soak_evidence_log",
    "real_renderer_summary",
    "real_renderer_metrics",
    "capture_manifest_summary",
    "capture_qoe_csv",
    "capture_qoe_summary",
):
    if key not in artifacts:
        raise SystemExit(f"external phase2 import missing artifact pointer {key}")
PY
    fi
  else
    require_file "${readiness_dir}/logs/capture_manifest.log"
    require_file "${readiness_dir}/logs/real_renderer.log"
  fi
  (
    cd "${readiness_dir}"
    sha256sum -c manifest.sha256 >/dev/null
  )
  verify_top_manifest_consistency "${readiness_dir}" "readiness"
  rg -q '^phase5_production_readiness_status=not_ready$' "${readiness_summary}" ||
    fail "failed readiness evidence did not record not_ready"
  if ! rg -q '^check=(capture_manifest|real_renderer|webrtc_modules|soak_config|external_phase2_evidence_bundle|script_[^ ]+) status=fail ' \
      "${readiness_summary}" &&
      ! rg -q '^check=(capture_manifest|real_renderer|webrtc_modules|external_phase2_evidence_bundle) status=skipped ' \
        "${readiness_summary}"; then
    fail "failed readiness evidence has no actionable failed/skipped readiness check"
  fi
  rg -q '^next_required_actions_file=' "${readiness_summary}" ||
    fail "failed readiness evidence missing next required actions pointer"
  rg -q '^next_required_actions_json=' "${readiness_summary}" ||
    fail "failed readiness evidence missing structured next required actions pointer"
  rg -q '^readiness_report_json=' "${readiness_summary}" ||
    fail "failed readiness evidence missing readiness report pointer"
  rg -q '^risk_milestone_report_json=' "${readiness_summary}" ||
    fail "failed readiness evidence missing risk milestone report pointer"
  rg -q '^readiness_metrics_prom=' "${readiness_summary}" ||
    fail "failed readiness evidence missing readiness metrics pointer"
  rg -q '^action=(capture_manifest|real_renderer|webrtc_modules|soak_config|external_phase2_evidence_bundle|script_[^ ]+) status=(fail|skipped) ' \
    "${readiness_dir}/next_required_actions.txt" ||
    fail "failed readiness evidence missing actionable remediation file"
  verify_readiness_json "${readiness_dir}" "not_ready"
  verify_readiness_metrics "${readiness_dir}" "not_ready"
}

require_failed_implementation_evidence() {
  summary_has '^step=phase5_implementation_gate status=fail ' || return 0
  summary_has '^phase5_implementation_gate_dir=' ||
    fail "failed implementation gate summary missing implementation directory"
  local implementation_dir="${GATE_DIR}/phase5_implementation_gate"
  local implementation_summary="${implementation_dir}/phase5_implementation_gate_summary.txt"
  require_file "${implementation_summary}"
  require_file "${implementation_dir}/files.txt"
  require_file "${implementation_dir}/manifest.sha256"
  require_file "${implementation_dir}/phase5_implementation_gate_metrics.prom"
  (
    cd "${implementation_dir}"
    sha256sum -c manifest.sha256 >/dev/null
  )
  rg -q '^phase5_implementation_gate_status=fail$' "${implementation_summary}" ||
    fail "failed implementation evidence did not record fail status"
  rg -q '^step=[^ ]+ status=fail ' "${implementation_summary}" ||
    fail "failed implementation evidence missing failed step"
  GATE_DIR="${implementation_dir}" REQUIRE_PASS=0 \
    "${SDK_ROOT}/scripts/verify_phase5_implementation_gate.sh" >/dev/null
}

require_success_debug_bundle() {
  summary_has '^phase5_debug_bundle=' ||
    fail "passed gate summary missing phase5 debug bundle directory"
  require_file "${GATE_DIR}/phase5_debug_bundle/manifest.sha256"
  require_file "${GATE_DIR}/phase5_debug_bundle/runtime_config.json"
  require_file "${GATE_DIR}/phase5_debug_bundle/log/push.log"
  require_file "${GATE_DIR}/phase5_debug_bundle/metrics/push_metrics.jsonl"
  require_file "${GATE_DIR}/phase5_debug_bundle/alerts/alerts.jsonl"
  require_file "${GATE_DIR}/phase5_debug_bundle/timeline/events.jsonl"
  (
    cd "${GATE_DIR}/phase5_debug_bundle"
    sha256sum -c manifest.sha256 >/dev/null
  )
  BUNDLE_DIR="${GATE_DIR}/phase5_debug_bundle" \
    "${SDK_ROOT}/scripts/verify_phase5_debug_bundle.sh" >/dev/null
}

require_success_implementation_gate() {
  if ! summary_has '^phase5_implementation_gate=' &&
      ! summary_has '^phase5_implementation_gate_dir='; then
    fail "gate summary missing phase5 implementation gate directory"
  fi
  require_file "${GATE_DIR}/phase5_implementation_gate/manifest.sha256"
  require_file "${GATE_DIR}/phase5_implementation_gate/phase5_implementation_gate_summary.txt"
  require_file "${GATE_DIR}/phase5_implementation_gate/phase5_implementation_gate_metrics.prom"
  (
    cd "${GATE_DIR}/phase5_implementation_gate"
    sha256sum -c manifest.sha256 >/dev/null
  )
  GATE_DIR="${GATE_DIR}/phase5_implementation_gate" REQUIRE_PASS=1 \
    "${SDK_ROOT}/scripts/verify_phase5_implementation_gate.sh" >/dev/null
}

require_success_readiness() {
  summary_has '^phase5_production_readiness=' ||
    fail "passed gate summary missing phase5 production readiness directory"
  local readiness_dir="${GATE_DIR}/phase5_production_readiness"
  local readiness_summary="${readiness_dir}/phase5_production_readiness_summary.txt"
  require_file "${readiness_summary}"
  require_file "${readiness_dir}/files.txt"
  require_file "${readiness_dir}/manifest.sha256"
  require_file "${readiness_dir}/next_required_actions.json"
  require_file "${readiness_dir}/readiness_report.json"
  require_file "${readiness_dir}/risk_milestone_report.json"
  require_file "${readiness_dir}/risk_milestone_summary.txt"
  require_file "${readiness_dir}/phase5_production_readiness_metrics.prom"
  require_file "${readiness_dir}/check_records.jsonl"
  require_file "${readiness_dir}/logs/webrtc_modules.log"
  if [[ -f "${readiness_dir}/logs/external_phase2_evidence_bundle.log" ]]; then
    require_file "${readiness_dir}/logs/external_phase2_evidence_bundle.log"
    require_file "${readiness_dir}/external_phase2_evidence_import/phase2_external_evidence_import.json"
    require_file "${readiness_dir}/external_phase2_evidence_import/phase2_external_evidence_import.txt"
    require_file "${readiness_dir}/external_phase2_evidence_import/manifest.sha256"
    (
      cd "${readiness_dir}/external_phase2_evidence_import"
      sha256sum -c manifest.sha256 >/dev/null
    )
    verify_top_manifest_consistency \
      "${readiness_dir}/external_phase2_evidence_import" \
      "readiness external phase2 import"
    python3 - "${readiness_dir}/external_phase2_evidence_import/phase2_external_evidence_import.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    report = json.load(fh)
if report.get("schema_version") != 1:
    raise SystemExit("external phase2 import schema_version mismatch")
if report.get("source") != "phase5_phase2_external_evidence_import":
    raise SystemExit("external phase2 import source mismatch")
if report.get("import_status") != "pass":
    raise SystemExit("external phase2 import did not pass")
checks = {item.get("check"): item.get("status") for item in report.get("checks", [])}
for required in (
    "bundle_manifest",
    "bundle_files_manifest_consistency",
    "bundle_git_worktree_clean",
    "phase2_completion_audit",
    "phase2_completion_audit_metrics",
    "production_soak",
    "production_soak_evidence",
    "production_soak_raw_evidence",
    "real_renderer",
    "real_renderer_raw_evidence",
    "real_renderer_rendered_frames",
    "capture_library",
    "capture_library_evidence",
    "capture_qoe_raw_evidence",
    "evidence_bundle",
    "git_head_match",
):
    if checks.get(required) != "pass":
        raise SystemExit(f"external phase2 import missing pass check {required}")
artifacts = report.get("artifacts", {})
for key in (
    "phase2_evidence_metadata",
    "phase2_completion_audit_metrics",
    "production_soak_summary",
    "production_soak_csv",
    "production_soak_config",
    "production_soak_archive",
    "production_soak_evidence_log",
    "real_renderer_summary",
    "real_renderer_metrics",
    "capture_manifest_summary",
    "capture_qoe_csv",
    "capture_qoe_summary",
    "capture_library_evidence_log",
):
    if not artifacts.get(key):
        raise SystemExit(f"external phase2 import missing artifact pointer {key}")
for section_name, keys in (
    ("production_soak", ("summary", "csv", "config", "archive")),
    ("real_renderer", ("summary", "metrics")),
    ("capture_library", ("manifest_summary", "qoe_csv", "qoe_summary", "manifest_sha256")),
):
    section = report.get(section_name, {})
    for key in keys:
        if not section.get(key):
            raise SystemExit(
                f"external phase2 import missing {section_name}.{key}"
            )
    if section_name == "capture_library" and not (
        len(section.get("manifest_sha256", "")) == 64
        and all(ch in "0123456789abcdefABCDEF" for ch in section["manifest_sha256"])
    ):
        raise SystemExit("external phase2 import bad capture manifest sha256")
    if (
        section_name == "capture_library"
        and section.get("qoe_manifest_sha256") != section.get("manifest_sha256")
    ):
        raise SystemExit("external phase2 import capture QoE manifest sha256 mismatch")
    if section_name == "capture_library" and not (
        len(section.get("media_sha256", "")) == 64
        and all(ch in "0123456789abcdefABCDEF" for ch in section["media_sha256"])
    ):
        raise SystemExit("external phase2 import bad capture media sha256")
    if (
        section_name == "capture_library"
        and section.get("qoe_media_sha256") != section.get("media_sha256")
    ):
        raise SystemExit("external phase2 import capture QoE media sha256 mismatch")
    if section_name == "real_renderer" and float(
        section.get("rendered_frames", 0) or 0
    ) <= 0:
        raise SystemExit("external phase2 import real renderer rendered no frames")

def import_number(section, key, default=0):
    value = section.get(key, default)
    if value is None or value == "":
        value = default
    return float(value)

def import_category_tokens(value):
    return {
        token.strip()
        for token in str(value or "").replace(",", " ").split()
        if token.strip()
    }

def import_categories_cover(observed, required):
    required_categories = import_category_tokens(
        required
        or "indoor_face,outdoor_walking,low_light_noise,screen_text,high_motion,scene_cut"
    )
    observed_categories = import_category_tokens(observed)
    return bool(required_categories) and required_categories <= observed_categories

capture = report.get("capture_library", {})
if capture.get("fixture") is True:
    raise SystemExit("external phase2 import used fixture capture library")
rows = int(capture.get("rows", 0) or 0)
pass_rows = int(capture.get("pass_rows", 0) or 0)
if rows <= 0 or pass_rows != rows:
    raise SystemExit("external phase2 import capture QoE rows are incomplete")
if not import_categories_cover(capture.get("categories"), capture.get("required_categories")):
    raise SystemExit("external phase2 import capture required categories are incomplete")
if import_number(capture, "playable_ratio_min") <= 0:
    raise SystemExit("external phase2 import capture playable ratio missing")
if import_number(capture, "avg_psnr_y_min") <= 0:
    raise SystemExit("external phase2 import capture PSNR missing")
if import_number(capture, "avg_ssim_y_min") <= 0:
    raise SystemExit("external phase2 import capture SSIM missing")
if import_number(capture, "decode_errors", 1) != 0:
    raise SystemExit("external phase2 import capture decode errors are non-zero")
if import_number(capture, "freeze_count", 1) != 0:
    raise SystemExit("external phase2 import capture freeze count is non-zero")
if import_number(capture, "renderer_proxy_drop_frames", 1) != 0:
    raise SystemExit("external phase2 import capture renderer drops are non-zero")
PY
  else
    require_file "${readiness_dir}/logs/capture_manifest.log"
    require_file "${readiness_dir}/logs/real_renderer.log"
  fi
  (
    cd "${readiness_dir}"
    sha256sum -c manifest.sha256 >/dev/null
  )
  verify_top_manifest_consistency "${readiness_dir}" "readiness"
  rg -q '^phase5_production_readiness_status=ready$' "${readiness_summary}" ||
    fail "phase5 production readiness was not ready"
  rg -q '^check=git_worktree_clean status=pass ' "${readiness_summary}" ||
    fail "phase5 production readiness missing clean git worktree pass"
  rg -q '^failure_count=0$' "${readiness_summary}" ||
    fail "phase5 production readiness recorded failures"
  rg -q '^skipped_count=0$' "${readiness_summary}" ||
    fail "phase5 production readiness recorded skipped checks"
  rg -q '^action_count=0$' "${readiness_summary}" ||
    fail "phase5 production readiness recorded remediation actions"
  rg -q '^readiness_metrics_prom=' "${readiness_summary}" ||
    fail "phase5 production readiness missing readiness metrics pointer"
  rg -q '^check=webrtc_modules status=pass ' "${readiness_summary}" ||
    fail "phase5 production readiness missing WebRTC modules pass"
  rg -q '^check=capture_manifest status=pass ' "${readiness_summary}" ||
    fail "phase5 production readiness missing capture manifest pass"
  rg -q '^check=real_renderer status=pass ' "${readiness_summary}" ||
    fail "phase5 production readiness missing real renderer pass"
  if rg -q '^p5_skip_capture_library=1$' "${readiness_summary}"; then
    rg -q '^check=capture_manifest status=pass policy=skipped_by_p5_no_production_data ' "${readiness_summary}" ||
      fail "phase5 production readiness missing capture library policy skip evidence"
  fi
  if rg -q '^p5_skip_real_renderer=1$' "${readiness_summary}"; then
    rg -q '^check=real_renderer status=pass policy=skipped_by_p5_no_gpu_display_environment ' "${readiness_summary}" ||
      fail "phase5 production readiness missing real renderer policy skip evidence"
  fi
  if rg -q '^check=external_phase2_evidence_bundle status=pass ' "${readiness_summary}"; then
    rg -q '^check=capture_manifest status=pass source=external_phase2_evidence_bundle ' "${readiness_summary}" ||
      fail "external readiness missing capture manifest external source"
    rg -q '^check=real_renderer status=pass source=external_phase2_evidence_bundle ' "${readiness_summary}" ||
      fail "external readiness missing real renderer external source"
  fi
  verify_readiness_json "${readiness_dir}" "ready"
  verify_readiness_metrics "${readiness_dir}" "ready"
}

require_phase2_completion_evidence() {
  local phase2_dir="${GATE_DIR}/webrtc_first_production_gate"
  local phase2_summary="${phase2_dir}/phase2_production_gate_summary.txt"
  local evidence_bundle="${phase2_dir}/phase2_evidence_bundle"
  local completion_audit="${phase2_dir}/phase2_completion_audit/phase2_completion_audit_summary.txt"
  local completion_audit_metrics="${phase2_dir}/phase2_completion_audit/phase2_completion_audit_metrics.prom"
  local production_soak_dir="${evidence_bundle}/production_soak"
  local production_soak_summary="${production_soak_dir}/webrtc_first_qoe_production_soak_summary.txt"
  local production_soak_csv="${production_soak_dir}/webrtc_first_qoe_production_soak.csv"
  local production_soak_config="${production_soak_dir}/webrtc_first_qoe_production_soak_config.env"
  local production_soak_archive="${production_soak_dir}/webrtc_first_qoe_production_soak_archive.tar.gz"
  local real_renderer_summary="${evidence_bundle}/real_renderer/real_renderer_summary.txt"
  local real_renderer_metrics="${evidence_bundle}/real_renderer/real_renderer_metrics.csv"

  require_file "${phase2_summary}"
  rg -q '^phase2_production_gate_status=pass$' "${phase2_summary}" ||
    fail "underlying WebRTC-first production gate did not pass"
  rg -q '^evidence_bundle=' "${phase2_summary}" ||
    fail "underlying production gate summary missing evidence bundle pointer"
  rg -q '^completion_audit=' "${phase2_summary}" ||
    fail "underlying production gate summary missing completion audit pointer"
  rg -q '^completion_audit_metrics=' "${phase2_summary}" ||
    fail "underlying production gate summary missing completion audit metrics pointer"
  if rg -q '^phase2_evidence_source=external_bundle$' "${phase2_summary}"; then
    require_file "${phase2_dir}/phase2_external_evidence_import.json"
    require_file "${phase2_dir}/phase2_external_evidence_import.txt"
    require_file "${phase2_dir}/files.txt"
    require_file "${phase2_dir}/manifest.sha256"
    (
      cd "${phase2_dir}"
      sha256sum -c manifest.sha256 >/dev/null
    )
    verify_top_manifest_consistency "${phase2_dir}" "phase2 external import"
    rg -q '^import_status=pass$' "${phase2_dir}/phase2_external_evidence_import.txt" ||
      fail "imported Phase-2 evidence report did not pass"
    rg -q '^check=bundle_files_manifest_consistency status=pass$' "${phase2_dir}/phase2_external_evidence_import.txt" ||
      fail "imported Phase-2 evidence manifest file set was not consistent"
    rg -q '^check=git_head_match status=pass$' "${phase2_dir}/phase2_external_evidence_import.txt" ||
      fail "imported Phase-2 evidence did not match git head"
    rg -q '^check=bundle_git_worktree_clean status=pass$' "${phase2_dir}/phase2_external_evidence_import.txt" ||
      fail "imported Phase-2 evidence was not generated from a clean tracked worktree"
    rg -q '^check=phase2_completion_audit_metrics status=pass$' "${phase2_dir}/phase2_external_evidence_import.txt" ||
      fail "imported Phase-2 evidence did not include completion audit metrics"
    rg -q '^check=production_soak_evidence status=pass$' "${phase2_dir}/phase2_external_evidence_import.txt" ||
      fail "imported Phase-2 production soak evidence did not pass"
    rg -q '^check=real_renderer_rendered_frames status=pass$' "${phase2_dir}/phase2_external_evidence_import.txt" ||
      fail "imported Phase-2 renderer evidence rendered no frames"
  fi

  require_file "${evidence_bundle}/manifest.sha256"
  require_file "${evidence_bundle}/files.txt"
  (
    cd "${evidence_bundle}"
    sha256sum -c manifest.sha256 >/dev/null
  )
  verify_top_manifest_consistency "${evidence_bundle}" "phase2 evidence bundle"

  require_file "${completion_audit}"
  rg -q '^phase2_completion_audit=pass$' "${completion_audit}" ||
    fail "underlying Phase-2 completion audit did not pass"
  rg -q '^phase2_completion_status=complete$' "${completion_audit}" ||
    fail "underlying Phase-2 completion status is not complete"
  rg -q '^check=production_soak status=pass ' "${completion_audit}" ||
    fail "underlying completion audit missing passed production soak check"
  rg -q '^check=real_renderer status=pass ' "${completion_audit}" ||
    fail "underlying completion audit missing passed real renderer check"
  rg -q '^check=capture_library status=pass ' "${completion_audit}" ||
    fail "underlying completion audit missing passed capture library check"
  rg -q ' qoe_csv=' "${completion_audit}" ||
    fail "underlying completion audit missing capture QoE CSV pointer"
  rg -q '^check=evidence_bundle status=pass ' "${completion_audit}" ||
    fail "underlying completion audit missing passed evidence bundle check"
  require_file "${completion_audit_metrics}"
  verify_phase2_completion_audit_metrics "${completion_audit_metrics}"
  require_file "${production_soak_summary}"
  require_file "${production_soak_csv}"
  require_file "${production_soak_config}"
  require_file "${production_soak_archive}"
  OUTPUT_DIR="${production_soak_dir}" REQUIRE_SOAK_TARBALL=1 \
    "${SDK_ROOT}/scripts/verify_webrtc_first_qoe_production_soak_archive.sh" >/dev/null
  PRODUCTION_SOAK_DIR="${production_soak_dir}" \
    PRODUCTION_SOAK_SUMMARY="${production_soak_summary}" \
    PRODUCTION_SOAK_CSV="${production_soak_csv}" \
    PRODUCTION_SOAK_CONFIG="${production_soak_config}" \
    PRODUCTION_SOAK_ARCHIVE="${production_soak_archive}" \
    MIN_PRODUCTION_SOAK_MINUTES=120 \
    REQUIRE_PRODUCTION_SOAK_ARCHIVE=1 \
    "${SDK_ROOT}/scripts/verify_webrtc_first_qoe_production_soak_evidence.sh" >/dev/null
  local production_soak_minutes
  production_soak_minutes="$(
    awk -F= '$1=="SOAK_MINUTES"{print $2}' "${production_soak_config}" | tail -1
  )"
  python3 - "${production_soak_minutes:-0}" <<'PY'
import sys

if float(sys.argv[1] or 0) < 120:
    raise SystemExit("production soak minutes below phase5 minimum")
PY
  require_file "${real_renderer_summary}"
  require_file "${real_renderer_metrics}"
  if rg -q '^real_renderer_status=skipped_by_policy$' "${real_renderer_summary}"; then
    rg -q '^check=real_renderer status=pass .*policy=skipped_by_p5_no_gpu_display_environment' \
      "${completion_audit}" ||
      fail "underlying completion audit missing real renderer policy skip marker"
  else
    SUMMARY_FILE="${real_renderer_summary}" \
      METRICS_FILE="${real_renderer_metrics}" \
      ALLOW_XVFB_RENDERER=0 \
      "${SDK_ROOT}/scripts/verify_real_renderer_evidence.sh" >/dev/null
  fi
  require_file "${evidence_bundle}/capture_library/capture_manifest_summary.txt"
  require_file "${evidence_bundle}/capture_library/webrtc_first_qoe_capture_library_720p.csv"
  require_file "${evidence_bundle}/capture_library/capture_qoe_summary.txt"
  if rg -q '^capture_manifest_verification=skipped_by_policy$' \
      "${evidence_bundle}/capture_library/capture_manifest_summary.txt"; then
    rg -q '^capture_qoe_verification=skipped_by_policy$' \
      "${evidence_bundle}/capture_library/capture_qoe_summary.txt" ||
      fail "capture QoE summary missing policy skip marker"
    rg -q '^check=capture_library status=pass .*policy=skipped_by_p5_no_production_data' \
      "${completion_audit}" ||
      fail "underlying completion audit missing capture policy skip marker"
  else
    rg -q '^capture_manifest_verification=true$' \
      "${evidence_bundle}/capture_library/capture_manifest_summary.txt" ||
      fail "capture manifest summary did not verify"
    rg -q '^capture_manifest_sha256=[0-9a-fA-F]{64}$' \
      "${evidence_bundle}/capture_library/capture_manifest_summary.txt" ||
      fail "capture manifest summary missing sha256"
    rg -q '^capture_media_sha256=[0-9a-fA-F]{64}$' \
      "${evidence_bundle}/capture_library/capture_manifest_summary.txt" ||
      fail "capture manifest summary missing media sha256"
    local required_capture_categories
    required_capture_categories="$(
      awk -F= '$1=="required_categories"{gsub(/,/," ",$2); print $2}' \
        "${evidence_bundle}/capture_library/capture_qoe_summary.txt" | tail -1
    )"
    required_capture_categories="${required_capture_categories:-indoor_face outdoor_walking low_light_noise screen_text high_motion scene_cut}"
    CAPTURE_MANIFEST_SUMMARY="${evidence_bundle}/capture_library/capture_manifest_summary.txt" \
      CAPTURE_QOE_CSV="${evidence_bundle}/capture_library/webrtc_first_qoe_capture_library_720p.csv" \
      CAPTURE_QOE_SUMMARY="${evidence_bundle}/capture_library/capture_qoe_summary.txt" \
      REQUIRED_CAPTURE_CATEGORIES="${required_capture_categories}" \
      ALLOW_FIXTURE_CAPTURE=0 \
      "${SDK_ROOT}/scripts/verify_capture_library_evidence.sh" >/dev/null
  fi
}

require_release_evidence() {
  summary_has '^phase5_release_evidence=' ||
    fail "passed gate summary missing release evidence json pointer"
  summary_has '^phase5_release_evidence_summary=' ||
    fail "passed gate summary missing release evidence summary pointer"
  require_file "${GATE_DIR}/phase5_release_evidence.json"
  require_file "${GATE_DIR}/phase5_release_evidence.txt"
  python3 - "${GATE_DIR}" <<'PY'
import json
import os
import sys

gate_dir = sys.argv[1]
json_path = os.path.join(gate_dir, "phase5_release_evidence.json")
summary_path = os.path.join(gate_dir, "phase5_release_evidence.txt")

with open(json_path, "r", encoding="utf-8") as fh:
    doc = json.load(fh)
with open(summary_path, "r", encoding="utf-8") as fh:
    summary = fh.read()
metadata = {}
with open(os.path.join(gate_dir, "metadata.txt"), "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if line and "=" in line:
            key, value = line.split("=", 1)
            metadata[key] = value

if doc.get("schema_version") != 1:
    raise SystemExit("release evidence schema_version must be 1")
if doc.get("source") != "phase5_production_gate":
    raise SystemExit("release evidence source mismatch")
if doc.get("scope") != "phase5 formal production release evidence":
    raise SystemExit("release evidence scope mismatch")
if doc.get("release_status") != "pass":
    raise SystemExit("release evidence status is not pass")
if doc.get("formal_completion_status") != "complete":
    raise SystemExit("release evidence formal completion status is not complete")

requirements = doc.get("requirements", {})
phase5_min_soak_minutes = 120.0
release_soak_minutes = float(requirements.get("soak_minutes", 0))
release_min_soak_minutes = float(
    requirements.get("min_production_soak_minutes", 0)
)
if release_min_soak_minutes < phase5_min_soak_minutes:
    raise SystemExit("release evidence minimum soak minutes below phase5 floor")
if release_soak_minutes < release_min_soak_minutes:
    raise SystemExit("release evidence soak minutes below minimum")
if requirements.get("multi_receiver_fanout") != "deferred_before_p5_completion":
    raise SystemExit("release evidence fanout requirement mismatch")
if metadata.get("GIT_TRACKED_WORKTREE_CLEAN") != "1":
    raise SystemExit("production gate metadata was not generated from a clean tracked worktree")
if requirements.get("git_head") and requirements.get("git_head") != metadata.get("GIT_HEAD"):
    raise SystemExit("release evidence git head does not match metadata")
if requirements.get("git_tracked_worktree_clean") is not True:
    raise SystemExit("release evidence was not generated from a clean tracked worktree")
git_status = requirements.get("git_tracked_status")
if not git_status or not os.path.exists(os.path.join(gate_dir, git_status)):
    raise SystemExit("release evidence missing tracked git status artifact")
with open(os.path.join(gate_dir, git_status), "r", encoding="utf-8") as fh:
    if fh.read().strip() != "tracked_changes=0":
        raise SystemExit("release evidence tracked git status is not clean")

observability = doc.get("observability", {})
gate_metrics = observability.get("phase5_production_gate_metrics")
if gate_metrics != "phase5_production_gate_metrics.prom" or not os.path.exists(
    os.path.join(gate_dir, "phase5_production_gate_metrics.prom")
):
    raise SystemExit("release evidence missing production gate metrics")
implementation_metrics = observability.get("implementation_gate_metrics")
if not implementation_metrics or not os.path.exists(
    os.path.join(gate_dir, implementation_metrics)
):
    raise SystemExit("release evidence missing implementation gate metrics")
phase2_audit_metrics = observability.get("phase2_completion_audit_metrics")
if not phase2_audit_metrics or not os.path.exists(
    os.path.join(gate_dir, phase2_audit_metrics)
):
    raise SystemExit("release evidence missing Phase-2 completion audit metrics")
readiness_metrics = observability.get("production_readiness_metrics")
if not readiness_metrics or not os.path.exists(
    os.path.join(gate_dir, readiness_metrics)
):
    raise SystemExit("release evidence missing production readiness metrics")
if observability.get("debug_bundle_slo_status") not in {"pass", "warn", "fail"}:
    raise SystemExit("release evidence missing debug bundle SLO status")
for key in (
    "debug_bundle_health_report",
    "debug_bundle_slo_report",
    "debug_bundle_monitoring_metrics",
    "debug_bundle_alert_policy",
    "debug_bundle_incident_report",
    "debug_bundle_timeline",
    "debug_bundle_first_problem",
):
    rel = observability.get(key)
    if not rel or not os.path.exists(os.path.join(gate_dir, rel)):
        raise SystemExit(f"release evidence missing observability pointer {key}")
fanout = doc.get("fanout", {})
if fanout.get("status") != "deferred":
    raise SystemExit("release evidence fanout status must be deferred")

def valid_sha256(value):
    return isinstance(value, str) and len(value) == 64 and all(
        ch in "0123456789abcdefABCDEF" for ch in value
    )


def read_top_manifest(gate_dir):
    manifest = {}
    with open(os.path.join(gate_dir, "manifest.sha256"), "r", encoding="utf-8") as fh:
        for line_no, line in enumerate(fh, 1):
            parts = line.strip().split(None, 1)
            if len(parts) != 2:
                raise SystemExit(f"top manifest line {line_no} is malformed")
            digest, rel = parts
            rel = rel.lstrip("*")
            if not valid_sha256(digest):
                raise SystemExit(f"top manifest line {line_no} has invalid sha256")
            manifest[rel] = digest
    return manifest


top_manifest = read_top_manifest(gate_dir)

def category_tokens(value):
    return {
        token.strip()
        for token in str(value or "").replace(",", " ").split()
        if token.strip()
    }

def categories_cover(observed, required):
    required_categories = category_tokens(
        required
        or "indoor_face,outdoor_walking,low_light_noise,screen_text,high_motion,scene_cut"
    )
    observed_categories = category_tokens(observed)
    return bool(required_categories) and required_categories <= observed_categories

required_evidence = {
    "phase5_gate_files",
    "phase5_gate_manifest",
    "phase5_production_gate_metrics",
    "phase5_release_evidence_json",
    "phase5_release_evidence_summary",
    "phase5_implementation_gate",
    "phase5_implementation_gate_metrics",
    "phase5_production_readiness",
    "phase5_production_readiness_report",
    "phase5_next_required_actions",
    "phase5_risk_milestone_report",
    "phase5_risk_milestone_summary",
    "phase5_production_readiness_metrics",
    "phase5_readiness_check_records",
    "git_worktree_clean",
    "phase5_debug_bundle",
    "phase5_debug_runtime_config",
    "phase5_debug_alerts_summary",
    "phase5_debug_timeline",
    "phase5_debug_first_problem",
    "phase5_debug_health_report",
    "phase5_debug_slo_report",
    "phase5_debug_monitoring_metrics",
    "phase5_debug_alert_policy",
    "phase5_debug_incident_report",
    "phase5_debug_incident_runbook",
    "phase2_production_gate",
    "phase2_completion_audit",
    "phase2_completion_audit_metrics",
    "production_soak",
    "production_soak_summary",
    "production_soak_csv",
    "production_soak_config",
    "production_soak_archive",
    "real_renderer",
    "real_renderer_summary",
    "real_renderer_metrics",
    "capture_library",
    "capture_manifest_summary",
    "capture_qoe_csv",
    "capture_qoe_summary",
    "evidence_bundle",
}
evidence = doc.get("evidence")
if not isinstance(evidence, list):
    raise SystemExit("release evidence list missing")
by_id = {item.get("id"): item for item in evidence}
if len(by_id) != len(evidence):
    raise SystemExit("release evidence contains duplicate ids")
missing = required_evidence - by_id.keys()
if missing:
    raise SystemExit(f"release evidence missing ids: {sorted(missing)}")
unexpected = by_id.keys() - required_evidence
if unexpected:
    raise SystemExit(f"release evidence contains unexpected ids: {sorted(unexpected)}")
for evidence_id, item in by_id.items():
    if item.get("status") != "pass":
        raise SystemExit(f"release evidence {evidence_id} did not pass")
    artifact = item.get("artifact")
    if not artifact or not os.path.exists(os.path.join(gate_dir, artifact)):
        raise SystemExit(f"release evidence {evidence_id} has bad artifact pointer")

artifacts = doc.get("artifacts", {})
for key in (
    "gate_summary",
    "metadata",
    "phase5_gate_files",
    "phase5_gate_manifest",
    "phase5_production_gate_metrics",
    "phase5_release_evidence_json",
    "phase5_release_evidence_summary",
    "git_tracked_status",
    "phase5_implementation_gate",
    "phase5_implementation_gate_metrics",
    "phase5_production_readiness",
    "phase5_production_readiness_report",
    "phase5_next_required_actions",
    "phase5_risk_milestone_report",
    "phase5_risk_milestone_summary",
    "phase5_production_readiness_metrics",
    "phase5_readiness_check_records",
    "phase5_debug_bundle",
    "phase5_debug_runtime_config",
    "phase5_debug_alerts_summary",
    "phase5_debug_timeline",
    "phase5_debug_first_problem",
    "phase5_debug_health_report",
    "phase5_debug_slo_report",
    "phase5_debug_monitoring_metrics",
    "phase5_debug_alert_policy",
    "phase5_debug_incident_report",
    "phase5_debug_incident_runbook",
    "phase2_production_gate",
    "phase2_evidence_bundle",
    "phase2_completion_audit",
    "phase2_completion_audit_metrics",
    "production_soak_summary",
    "production_soak_csv",
    "production_soak_config",
    "production_soak_archive",
    "real_renderer_summary",
    "real_renderer_metrics",
    "capture_manifest_summary",
    "capture_qoe_csv",
    "capture_qoe_summary",
):
    rel = artifacts.get(key)
    if not rel or not os.path.exists(os.path.join(gate_dir, rel)):
        raise SystemExit(f"release evidence bad artifact pointer {key}")

for key, expected_rel in (
    ("phase5_release_evidence_json", "phase5_release_evidence.json"),
    ("phase5_release_evidence_summary", "phase5_release_evidence.txt"),
):
    rel = artifacts.get(key)
    if rel != expected_rel:
        raise SystemExit(
            f"release evidence artifact {key} points to {rel}, expected {expected_rel}"
        )
    if by_id[key].get("artifact") != expected_rel:
        raise SystemExit(
            f"release evidence item {key} points to "
            f"{by_id[key].get('artifact')}, expected {expected_rel}"
        )
    if rel not in top_manifest:
        raise SystemExit(f"top manifest missing release evidence artifact {rel}")

expected_gate_artifacts = {
    "phase5_gate_files": "files.txt",
    "phase5_gate_manifest": "manifest.sha256",
    "phase5_production_gate_metrics": "phase5_production_gate_metrics.prom",
}
for evidence_id, expected_rel in expected_gate_artifacts.items():
    if artifacts.get(evidence_id) != expected_rel:
        raise SystemExit(
            f"release evidence artifact {evidence_id} points to "
            f"{artifacts.get(evidence_id)}, expected {expected_rel}"
        )
    if by_id[evidence_id].get("artifact") != expected_rel:
        raise SystemExit(
            f"release evidence item {evidence_id} points to "
            f"{by_id[evidence_id].get('artifact')}, expected {expected_rel}"
        )

capture = doc.get("capture_library", {})
capture_policy_skipped = capture.get("policy_skipped") is True
for key in ("manifest_summary", "qoe_csv", "qoe_summary"):
    rel = capture.get(key)
    if not rel or not os.path.exists(os.path.join(gate_dir, rel)):
        raise SystemExit(f"release evidence bad capture pointer {key}")
manifest_summary_path = os.path.join(gate_dir, capture["manifest_summary"])
manifest_summary = {}
with open(manifest_summary_path, "r", encoding="utf-8") as fh:
    manifest_summary_text = ""
    for line in fh:
        manifest_summary_text += line
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        manifest_summary[key] = value
if not capture_policy_skipped and any(
    marker in manifest_summary_text.lower()
    for marker in (
        "fixture",
        "artifacts/capture_library_phase2_fixture",
        "artifacts/capture_library_fixture",
    )
):
    raise SystemExit("release evidence capture manifest used fixture library")
if capture_policy_skipped:
    if manifest_summary.get("capture_manifest_verification") != "skipped_by_policy":
        raise SystemExit("release evidence capture manifest policy skip mismatch")
else:
    if not valid_sha256(capture.get("manifest_sha256")):
        raise SystemExit("release evidence capture manifest sha256 missing")
    if capture.get("manifest_sha256") != manifest_summary.get("capture_manifest_sha256"):
        raise SystemExit("release evidence capture manifest sha256 mismatch")
    if capture.get("qoe_manifest_sha256") != capture.get("manifest_sha256"):
        raise SystemExit("release evidence capture QoE manifest sha256 mismatch")
    if not valid_sha256(capture.get("media_sha256")):
        raise SystemExit("release evidence capture media sha256 missing")
    if capture.get("media_sha256") != manifest_summary.get("capture_media_sha256"):
        raise SystemExit("release evidence capture media sha256 mismatch")
    if capture.get("qoe_media_sha256") != capture.get("media_sha256"):
        raise SystemExit("release evidence capture QoE media sha256 mismatch")

def normalize_rel(path):
    return os.path.normpath(path).replace(os.sep, "/")

phase2_evidence_bundle_rel = artifacts.get("phase2_evidence_bundle", "")
readiness_artifact_base = normalize_rel(artifacts.get("phase5_production_readiness", ""))
debug_artifact_base = normalize_rel(artifacts.get("phase5_debug_bundle", ""))
production_soak_artifact_base = normalize_rel(
    os.path.join(phase2_evidence_bundle_rel, "production_soak")
)
real_renderer_artifact_base = normalize_rel(
    os.path.join(phase2_evidence_bundle_rel, "real_renderer")
)
capture_artifact_base = normalize_rel(
    os.path.join(phase2_evidence_bundle_rel, "capture_library")
)
expected_production_soak_artifacts = {
    "production_soak_summary": normalize_rel(
        os.path.join(
            production_soak_artifact_base,
            "webrtc_first_qoe_production_soak_summary.txt",
        )
    ),
    "production_soak_csv": normalize_rel(
        os.path.join(
            production_soak_artifact_base, "webrtc_first_qoe_production_soak.csv"
        )
    ),
    "production_soak_config": normalize_rel(
        os.path.join(
            production_soak_artifact_base,
            "webrtc_first_qoe_production_soak_config.env",
        )
    ),
    "production_soak_archive": normalize_rel(
        os.path.join(
            production_soak_artifact_base,
            "webrtc_first_qoe_production_soak_archive.tar.gz",
        )
    ),
}
expected_real_renderer_artifacts = {
    "real_renderer_summary": normalize_rel(
        os.path.join(real_renderer_artifact_base, "real_renderer_summary.txt")
    ),
    "real_renderer_metrics": normalize_rel(
        os.path.join(real_renderer_artifact_base, "real_renderer_metrics.csv")
    ),
}
expected_capture_artifacts = {
    "capture_manifest_summary": normalize_rel(
        os.path.join(capture_artifact_base, "capture_manifest_summary.txt")
    ),
    "capture_qoe_csv": normalize_rel(
        os.path.join(
            capture_artifact_base, "webrtc_first_qoe_capture_library_720p.csv"
        )
    ),
    "capture_qoe_summary": normalize_rel(
        os.path.join(capture_artifact_base, "capture_qoe_summary.txt")
    ),
}
capture_pointer_keys = {
    "capture_manifest_summary": "manifest_summary",
    "capture_qoe_csv": "qoe_csv",
    "capture_qoe_summary": "qoe_summary",
}
expected_readiness_artifacts = {
    "phase5_production_readiness_report": normalize_rel(
        os.path.join(readiness_artifact_base, "readiness_report.json")
    ),
    "phase5_next_required_actions": normalize_rel(
        os.path.join(readiness_artifact_base, "next_required_actions.json")
    ),
    "phase5_risk_milestone_report": normalize_rel(
        os.path.join(readiness_artifact_base, "risk_milestone_report.json")
    ),
    "phase5_risk_milestone_summary": normalize_rel(
        os.path.join(readiness_artifact_base, "risk_milestone_summary.txt")
    ),
    "phase5_production_readiness_metrics": normalize_rel(
        os.path.join(
            readiness_artifact_base, "phase5_production_readiness_metrics.prom"
        )
    ),
    "phase5_readiness_check_records": normalize_rel(
        os.path.join(readiness_artifact_base, "check_records.jsonl")
    ),
}
expected_debug_artifacts = {
    "phase5_debug_runtime_config": normalize_rel(
        os.path.join(debug_artifact_base, "runtime_config.json")
    ),
    "phase5_debug_alerts_summary": normalize_rel(
        os.path.join(debug_artifact_base, "alerts", "alerts_summary.txt")
    ),
    "phase5_debug_timeline": normalize_rel(
        os.path.join(debug_artifact_base, "timeline", "events.jsonl")
    ),
    "phase5_debug_first_problem": normalize_rel(
        os.path.join(debug_artifact_base, "timeline", "first_problem.json")
    ),
    "phase5_debug_health_report": normalize_rel(
        os.path.join(debug_artifact_base, "monitoring", "health_report.json")
    ),
    "phase5_debug_slo_report": normalize_rel(
        os.path.join(debug_artifact_base, "monitoring", "slo_report.json")
    ),
    "phase5_debug_monitoring_metrics": normalize_rel(
        os.path.join(
            debug_artifact_base, "monitoring", "phase5_monitoring_metrics.prom"
        )
    ),
    "phase5_debug_alert_policy": normalize_rel(
        os.path.join(debug_artifact_base, "monitoring", "alert_policy.json")
    ),
    "phase5_debug_incident_report": normalize_rel(
        os.path.join(debug_artifact_base, "monitoring", "incident_report.json")
    ),
    "phase5_debug_incident_runbook": normalize_rel(
        os.path.join(debug_artifact_base, "monitoring", "incident_runbook.txt")
    ),
}

production_soak = doc.get("production_soak", {})
for key in ("summary", "csv", "config", "archive"):
    rel = production_soak.get(key)
    if not rel or not os.path.exists(os.path.join(gate_dir, rel)):
        raise SystemExit(f"release evidence bad production soak pointer {key}")
real_renderer = doc.get("real_renderer", {})
real_renderer_policy_skipped = (
    real_renderer.get("policy_skipped") is True
    and real_renderer.get("status") == "skipped_by_policy"
)
for key in ("summary", "metrics"):
    rel = real_renderer.get(key)
    if not rel or not os.path.exists(os.path.join(gate_dir, rel)):
        raise SystemExit(f"release evidence bad real renderer pointer {key}")

def require_consistent_pointer(evidence_id, expected_rel, nested_rel=None):
    artifact_rel = artifacts.get(evidence_id)
    evidence_rel = by_id[evidence_id].get("artifact")
    if normalize_rel(artifact_rel) != expected_rel:
        raise SystemExit(
            f"release evidence artifact {evidence_id} points to "
            f"{artifact_rel}, expected {expected_rel}"
        )
    if normalize_rel(evidence_rel) != expected_rel:
        raise SystemExit(
            f"release evidence item {evidence_id} points to "
            f"{evidence_rel}, expected {expected_rel}"
        )
    if nested_rel is not None and normalize_rel(nested_rel) != expected_rel:
        raise SystemExit(
            f"release evidence nested pointer {evidence_id} points to "
            f"{nested_rel}, expected {expected_rel}"
        )

for evidence_id, expected_rel in expected_readiness_artifacts.items():
    require_consistent_pointer(evidence_id, expected_rel)
for evidence_id, expected_rel in expected_debug_artifacts.items():
    require_consistent_pointer(evidence_id, expected_rel)
for evidence_id, expected_rel in expected_production_soak_artifacts.items():
    nested_key = evidence_id.replace("production_soak_", "")
    require_consistent_pointer(evidence_id, expected_rel, production_soak.get(nested_key))
for evidence_id, expected_rel in expected_real_renderer_artifacts.items():
    nested_key = evidence_id.replace("real_renderer_", "")
    require_consistent_pointer(evidence_id, expected_rel, real_renderer.get(nested_key))
for evidence_id, expected_rel in expected_capture_artifacts.items():
    require_consistent_pointer(
        evidence_id, expected_rel, capture.get(capture_pointer_keys[evidence_id])
    )

def evidence_number(section, key, default=0):
    value = section.get(key, default)
    if value is None or value == "":
        value = default
    return float(value)

if evidence_number(production_soak, "soak_minutes") < release_min_soak_minutes:
    raise SystemExit("release evidence production soak minutes below declared minimum")
if evidence_number(production_soak, "soak_minutes") < phase5_min_soak_minutes:
    raise SystemExit("release evidence production soak minutes below minimum")
rows = int(production_soak.get("rows", 0) or 0)
pass_rows = int(production_soak.get("pass_rows", 0) or 0)
if rows <= 0 or pass_rows != rows:
    raise SystemExit("release evidence production soak rows are incomplete")
if evidence_number(production_soak, "decode_errors", 1) != 0:
    raise SystemExit("release evidence production soak decode errors are non-zero")
if evidence_number(production_soak, "freeze_count", 1) != 0:
    raise SystemExit("release evidence production soak freeze count is non-zero")
if evidence_number(production_soak, "renderer_proxy_drop_frames", 1) != 0:
    raise SystemExit("release evidence production soak renderer drops are non-zero")
if real_renderer_policy_skipped:
    pass
elif real_renderer.get("status") != "pass":
    raise SystemExit("release evidence real renderer did not pass")
elif real_renderer.get("backend") == "xvfb":
    raise SystemExit("release evidence real renderer used xvfb backend")
elif evidence_number(real_renderer, "rendered_frames") <= 0:
    raise SystemExit("release evidence real renderer rendered no frames")

def capture_number(key, default=0):
    value = capture.get(key, default)
    if value is None or value == "":
        value = default
    return float(value)

if capture_policy_skipped:
    if int(capture.get("rows", 0) or 0) != 0:
        raise SystemExit("release evidence capture policy skip has rows")
else:
    rows = int(capture.get("rows", 0) or 0)
    pass_rows = int(capture.get("pass_rows", 0) or 0)
    if rows <= 0 or pass_rows != rows:
        raise SystemExit("release evidence capture QoE rows are incomplete")
    if not categories_cover(capture.get("categories"), capture.get("required_categories")):
        raise SystemExit("release evidence capture required categories are incomplete")
    if capture_number("playable_ratio_min") <= 0:
        raise SystemExit("release evidence capture playable ratio missing")
    if capture_number("avg_psnr_y_min") <= 0:
        raise SystemExit("release evidence capture PSNR missing")
    if capture_number("avg_ssim_y_min") <= 0:
        raise SystemExit("release evidence capture SSIM missing")
    if capture_number("decode_errors", 1) != 0:
        raise SystemExit("release evidence capture decode errors are non-zero")
    if capture_number("freeze_count", 1) != 0:
        raise SystemExit("release evidence capture freeze count is non-zero")
    if capture_number("renderer_proxy_drop_frames", 1) != 0:
        raise SystemExit("release evidence capture renderer drops are non-zero")

for expected in (
    "release_status=pass",
    "formal_completion_status=complete",
    "scope=phase5_formal_production_release_evidence",
    "fanout_status=deferred",
    "min_production_soak_minutes=",
    "phase5_gate_files=files.txt",
    "phase5_gate_manifest=manifest.sha256",
    "phase5_production_gate_metrics=phase5_production_gate_metrics.prom",
    "phase5_release_evidence_json=phase5_release_evidence.json",
    "phase5_release_evidence_summary=phase5_release_evidence.txt",
    "evidence=phase5_gate_files status=pass",
    "evidence=phase5_gate_manifest status=pass",
    "evidence=phase5_production_gate_metrics status=pass",
    "evidence=phase5_implementation_gate_metrics status=pass",
    "evidence=phase5_production_readiness_report status=pass",
    "evidence=phase5_production_readiness_metrics status=pass",
    "evidence=phase5_debug_health_report status=pass",
    "evidence=phase5_debug_monitoring_metrics status=pass",
    "evidence=phase5_debug_incident_report status=pass",
    "evidence=git_worktree_clean status=pass",
    "evidence=phase2_completion_audit_metrics status=pass",
    "evidence=production_soak status=pass",
    "evidence=production_soak_csv status=pass",
    "evidence=real_renderer status=pass",
    "evidence=real_renderer_summary status=pass",
    "evidence=capture_library status=pass",
    "evidence=capture_qoe_csv status=pass",
    "phase5_readiness_report=",
    "phase5_readiness_metrics=",
    "phase5_risk_milestone_report=",
    "phase5_debug_health_report=",
    "phase5_debug_monitoring_metrics=",
    "phase5_debug_incident_report=",
    "production_soak_csv=",
    "production_soak_rows=",
    "real_renderer_summary=",
    "capture_qoe_csv=",
    "capture_qoe_rows=",
    "capture_manifest_sha256=",
    "capture_media_sha256=",
):
    if expected not in summary:
        raise SystemExit(f"release evidence summary missing {expected}")
PY
}

summary_has '^phase5_production_gate=running$' ||
  fail "summary missing gate start marker"
summary_has '^step=phase5_implementation_gate status=(planned|pass|fail|skipped)( |$)' ||
  fail "summary missing implementation gate step"
summary_has '^step=phase5_release_contract status=(planned|pass|fail|skipped)( |$)' ||
  fail "summary missing release contract step"
summary_has '^step=phase5_production_readiness status=(planned|pass|fail|skipped)( |$)' ||
  fail "summary missing production readiness step"

if summary_has '^step=phase5_implementation_gate status=(planned|pass|fail)( |$)'; then
  require_file "${GATE_DIR}/logs/phase5_implementation_gate.log"
fi
if summary_has '^step=verify_phase5_implementation_gate status=(planned|pass|fail)( |$)'; then
  require_file "${GATE_DIR}/logs/verify_phase5_implementation_gate.log"
fi
if summary_has '^step=phase5_release_contract status=(planned|pass|fail)( |$)'; then
  require_file "${GATE_DIR}/logs/phase5_release_contract.log"
fi
if summary_has '^step=phase5_production_readiness status=(planned|pass|fail)( |$)'; then
  require_file "${GATE_DIR}/logs/phase5_production_readiness.log"
fi
if summary_has '^step=collect_phase5_debug_bundle status=(planned|pass|fail)( |$)'; then
  require_file "${GATE_DIR}/logs/collect_phase5_debug_bundle.log"
fi
if summary_has '^step=verify_phase5_debug_bundle status=(planned|pass|fail)( |$)'; then
  require_file "${GATE_DIR}/logs/verify_phase5_debug_bundle.log"
fi
if summary_has '^step=webrtc_first_production_gate status=(planned|pass|fail)( |$)'; then
  require_file "${GATE_DIR}/logs/webrtc_first_production_gate.log"
fi
if summary_has '^step=import_phase2_evidence_bundle status=(planned|pass|fail)( |$)'; then
  require_file "${GATE_DIR}/logs/import_phase2_evidence_bundle.log"
fi
if summary_has '^step=phase5_release_evidence status=(planned|pass|fail)( |$)'; then
  require_file "${GATE_DIR}/logs/phase5_release_evidence.log"
fi

if ! summary_has '^phase5_production_gate_status=fail$'; then
  if ! summary_has '^step=phase5_debug_bundle status=skipped'; then
    summary_has '^step=collect_phase5_debug_bundle status=(planned|pass|fail)( |$)' ||
    fail "summary missing debug bundle collect step"
    summary_has '^step=verify_phase5_debug_bundle status=(planned|pass|fail)( |$)' ||
    fail "summary missing debug bundle verify step"
  fi
  if ! summary_has '^step=phase5_implementation_gate status=skipped'; then
    summary_has '^step=verify_phase5_implementation_gate status=(planned|pass|fail)( |$)' ||
      fail "summary missing implementation gate verify step"
  fi
  if ! summary_has '^step=webrtc_first_production_gate status=(planned|pass|fail)( |$)' &&
      ! summary_has '^step=import_phase2_evidence_bundle status=(planned|pass|fail)( |$)'; then
    fail "summary missing production gate or imported phase2 evidence step"
  fi
  if ! summary_has '^phase5_production_gate_status=dry_run$'; then
    summary_has '^step=phase5_release_evidence status=(pass|fail)( |$)' ||
      fail "summary missing release evidence step"
  fi
fi

if [[ "${REQUIRE_PASS}" == "1" ]]; then
  summary_has '^phase5_production_gate_status=pass$' ||
    fail "phase5 production gate did not pass"
  verify_gate_metrics "pass"
  summary_has '^step=phase5_implementation_gate status=pass ' ||
    fail "implementation gate step did not pass"
  summary_has '^step=verify_phase5_implementation_gate status=pass ' ||
    fail "implementation gate verify step did not pass"
  summary_has '^step=phase5_release_contract status=pass ' ||
    fail "release contract step did not pass"
  summary_has '^step=phase5_production_readiness status=pass ' ||
    fail "production readiness step did not pass"
  summary_has '^step=collect_phase5_debug_bundle status=pass ' ||
    fail "debug bundle collect step did not pass"
  summary_has '^step=verify_phase5_debug_bundle status=pass ' ||
    fail "debug bundle verify step did not pass"
  if ! summary_has '^step=webrtc_first_production_gate status=pass ' &&
      ! summary_has '^step=import_phase2_evidence_bundle status=pass '; then
    fail "production gate or imported phase2 evidence step did not pass"
  fi
  summary_has '^step=phase5_release_evidence status=pass ' ||
    fail "release evidence step did not pass"
  require_success_implementation_gate
  require_success_debug_bundle
  require_success_readiness
  require_phase2_completion_evidence
  require_release_evidence
else
  summary_has '^phase5_production_gate_status=(dry_run|pass|fail)$' ||
    fail "summary missing dry_run/pass/fail status"
  if summary_has '^phase5_production_gate_status=fail$'; then
    verify_gate_metrics "fail"
    summary_has '^step=[^ ]+ status=fail ' ||
      fail "failed gate summary missing failed step"
    if summary_has '^step=phase5_implementation_gate status=pass '; then
      require_success_implementation_gate
    fi
    require_failed_implementation_evidence
    require_failed_readiness_evidence
    require_failed_gate_debug_bundle
  elif summary_has '^phase5_production_gate_status=pass$'; then
    verify_gate_metrics "pass"
    require_success_implementation_gate
    require_success_readiness
    require_success_debug_bundle
    require_phase2_completion_evidence
    require_release_evidence
  elif summary_has '^phase5_production_gate_status=dry_run$'; then
    verify_gate_metrics "dry_run"
  fi
fi

scan_files=(
  "${GATE_DIR}/metadata.txt"
  "${GATE_DIR}/git_tracked_status.txt"
  "${SUMMARY_FILE}"
)
for optional_scan_file in \
    "${GATE_DIR}/phase5_release_evidence.json" \
    "${GATE_DIR}/phase5_release_evidence.txt"; do
  if [[ -f "${optional_scan_file}" ]]; then
    scan_files+=("${optional_scan_file}")
  fi
done
if rg -q 'payload|annexb_bytes|rtp_bytes|token|secret|password' \
  "${scan_files[@]}"; then
  fail "gate metadata/summary/release evidence contains payload-like or sensitive field"
fi

echo "phase5_production_gate_verify pass gate_dir=${GATE_DIR} require_pass=${REQUIRE_PASS}"
