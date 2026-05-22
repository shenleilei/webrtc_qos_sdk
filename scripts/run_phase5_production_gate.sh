#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WEBRTC_PREFIX="${WEBRTC_PREFIX:-${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}}"
PHASE5_BUILD_ID="${PHASE5_BUILD_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${SDK_ROOT}/artifacts/phase5_production_gate/${PHASE5_BUILD_ID}}"
PHASE2_OUTPUT_ROOT="${PHASE2_OUTPUT_ROOT:-${OUTPUT_ROOT}/webrtc_first_production_gate}"
PHASE2_EVIDENCE_BUNDLE_DIR="${PHASE2_EVIDENCE_BUNDLE_DIR:-}"
DEFAULT_PHASE5_IMPLEMENTATION_GATE_DIR="${OUTPUT_ROOT}/phase5_implementation_gate"
PHASE5_IMPLEMENTATION_GATE_DIR="${PHASE5_IMPLEMENTATION_GATE_DIR:-${DEFAULT_PHASE5_IMPLEMENTATION_GATE_DIR}}"
PHASE5_DEBUG_BUNDLE_DIR="${PHASE5_DEBUG_BUNDLE_DIR:-${OUTPUT_ROOT}/phase5_debug_bundle}"
FAILURE_DEBUG_BUNDLE_DIR="${FAILURE_DEBUG_BUNDLE_DIR:-${OUTPUT_ROOT}/failure_debug_bundle}"
PHASE5_READINESS_DIR="${PHASE5_READINESS_DIR:-${OUTPUT_ROOT}/phase5_production_readiness}"
LOG_DIR="${LOG_DIR:-${OUTPUT_ROOT}/logs}"
SUMMARY_FILE="${SUMMARY_FILE:-${OUTPUT_ROOT}/phase5_production_gate_summary.txt}"
METADATA_FILE="${METADATA_FILE:-${OUTPUT_ROOT}/metadata.txt}"
GIT_TRACKED_STATUS_FILE="${GIT_TRACKED_STATUS_FILE:-${OUTPUT_ROOT}/git_tracked_status.txt}"
FILES_FILE="${FILES_FILE:-${OUTPUT_ROOT}/files.txt}"
MANIFEST_FILE="${MANIFEST_FILE:-${OUTPUT_ROOT}/manifest.sha256}"
RELEASE_EVIDENCE_JSON="${RELEASE_EVIDENCE_JSON:-${OUTPUT_ROOT}/phase5_release_evidence.json}"
RELEASE_EVIDENCE_SUMMARY="${RELEASE_EVIDENCE_SUMMARY:-${OUTPUT_ROOT}/phase5_release_evidence.txt}"
PHASE5_GATE_METRICS_PROM="${PHASE5_GATE_METRICS_PROM:-${OUTPUT_ROOT}/phase5_production_gate_metrics.prom}"

SOAK_MINUTES="${SOAK_MINUTES:-120}"
MIN_PRODUCTION_SOAK_MINUTES="${MIN_PRODUCTION_SOAK_MINUTES:-120}"
SOAK_CYCLES="${SOAK_CYCLES:-1}"
PREFLIGHT_ONLY="${PREFLIGHT_ONLY:-0}"
PHASE5_DRY_RUN="${PHASE5_DRY_RUN:-0}"
RUN_PHASE5_IMPLEMENTATION_GATE="${RUN_PHASE5_IMPLEMENTATION_GATE:-1}"
RUN_PHASE5_RELEASE_CONTRACT="${RUN_PHASE5_RELEASE_CONTRACT:-1}"
RUN_PHASE5_READINESS="${RUN_PHASE5_READINESS:-1}"
RUN_PHASE5_DEBUG_BUNDLE="${RUN_PHASE5_DEBUG_BUNDLE:-1}"
ALLOW_XVFB_RENDERER="${ALLOW_XVFB_RENDERER:-0}"
REAL_RENDERER_USE_XVFB="${REAL_RENDERER_USE_XVFB:-$([[ "${ALLOW_XVFB_RENDERER}" == "1" ]] && echo auto || echo 0)}"

FACADE_FRAMES="${FACADE_FRAMES:-120}"
PHASE5_IMPLEMENTATION_FRAMES="${PHASE5_IMPLEMENTATION_FRAMES:-36}"
QOE_FRAMES="${QOE_FRAMES:-120}"
QOE_WIDTH="${QOE_WIDTH:-1280}"
QOE_HEIGHT="${QOE_HEIGHT:-720}"
QOE_CONTENT_MODE="${QOE_CONTENT_MODE:-block_motion}"

CAPTURE_LIBRARY_DIR="${CAPTURE_LIBRARY_DIR:-${SDK_ROOT}/capture_library}"
CAPTURE_LIBRARY_MANIFEST="${CAPTURE_LIBRARY_MANIFEST:-${CAPTURE_LIBRARY_DIR}/manifest.csv}"
CAPTURE_WIDTH="${CAPTURE_WIDTH:-1280}"
CAPTURE_HEIGHT="${CAPTURE_HEIGHT:-720}"
CAPTURE_FRAMES="${CAPTURE_FRAMES:-120}"
CAPTURE_SCENARIOS="${CAPTURE_SCENARIOS:-baseline weak_network_low_rps_low_bitrate walking_dead_zone_recover oscillating_edge_recover}"
CAPTURE_SEEDS="${CAPTURE_SEEDS:-1}"
REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES:-indoor_face outdoor_walking low_light_noise screen_text high_motion scene_cut}"

if [[ "${PHASE5_IMPLEMENTATION_GATE_DIR}" != "${DEFAULT_PHASE5_IMPLEMENTATION_GATE_DIR}" ]]; then
  echo "phase5 production gate failed: PHASE5_IMPLEMENTATION_GATE_DIR must be ${DEFAULT_PHASE5_IMPLEMENTATION_GATE_DIR} for self-contained evidence" >&2
  exit 1
fi

python3 - "${SOAK_MINUTES}" "${MIN_PRODUCTION_SOAK_MINUTES}" <<'PY'
import sys

soak_minutes = float(sys.argv[1])
min_soak_minutes = float(sys.argv[2])
phase5_minimum = 120.0
errors = []
if min_soak_minutes < phase5_minimum:
    errors.append(
        "MIN_PRODUCTION_SOAK_MINUTES=%g<%g"
        % (min_soak_minutes, phase5_minimum)
    )
if soak_minutes < phase5_minimum:
    errors.append("SOAK_MINUTES=%g<%g" % (soak_minutes, phase5_minimum))
if soak_minutes < min_soak_minutes:
    errors.append(
        "SOAK_MINUTES=%g<MIN_PRODUCTION_SOAK_MINUTES=%g"
        % (soak_minutes, min_soak_minutes)
    )
if errors:
    raise SystemExit(
        "phase5 production gate failed: invalid production soak configuration: "
        + ", ".join(errors)
    )
PY

mkdir -p "${OUTPUT_ROOT}" "${LOG_DIR}"
rm -f "${SUMMARY_FILE}" "${METADATA_FILE}" "${GIT_TRACKED_STATUS_FILE}" \
  "${FILES_FILE}" "${MANIFEST_FILE}"

write_summary() {
  printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

require_script() {
  local path="$1"
  [[ -x "${path}" ]] || {
    echo "phase5 production gate failed: missing executable script: ${path}" >&2
    exit 1
  }
}

write_manifest() {
  (
    cd "${OUTPUT_ROOT}"
    find . -type f \
      ! -path './manifest.sha256' \
      ! -path './files.txt' \
      | sed 's#^\./##' \
      | sort >"${FILES_FILE}"
    while IFS= read -r file; do
      sha256sum "${file}"
    done <"${FILES_FILE}" >"${MANIFEST_FILE}"
  )
}

write_gate_metrics() {
  python3 - "${SUMMARY_FILE}" "${PHASE5_GATE_METRICS_PROM}" <<'PY'
import collections
import re
import sys

summary_path, metrics_path = sys.argv[1:3]
status = "unknown"
steps = []
failure_bundle_status = "missing"
release_evidence_status = "missing"
step_re = re.compile(r"^step=([^ ]+) status=([^ ]+)")
with open(summary_path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if line.startswith("phase5_production_gate_status="):
            status = line.split("=", 1)[1]
        match = step_re.match(line)
        if match:
            step, step_status = match.groups()
            steps.append((step, step_status))
            if step == "phase5_release_evidence":
                release_evidence_status = step_status
        if line.startswith("failure_debug_bundle_status="):
            value = line.split("=", 1)[1].split()[0]
            failure_bundle_status = value


def prom_escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def prom_labels(**labels):
    items = [
        f'{key}="{prom_escape(value)}"'
        for key, value in sorted(labels.items())
        if value is not None and value != ""
    ]
    return "{" + ",".join(items) + "}" if items else ""


step_counts = collections.Counter(step_status for _, step_status in steps)
with open(metrics_path, "w", encoding="utf-8") as fh:
    fh.write("# HELP webrtc_qos_phase5_production_gate_info Phase-5 production gate status marker.\n")
    fh.write("# TYPE webrtc_qos_phase5_production_gate_info gauge\n")
    fh.write(
        "webrtc_qos_phase5_production_gate_info"
        f"{prom_labels(source='phase5_production_gate', status=status)} 1\n"
    )
    fh.write("# HELP webrtc_qos_phase5_production_gate_steps_total Phase-5 production gate step count by status.\n")
    fh.write("# TYPE webrtc_qos_phase5_production_gate_steps_total gauge\n")
    for step_status, count in sorted(step_counts.items()):
        fh.write(
            "webrtc_qos_phase5_production_gate_steps_total"
            f"{prom_labels(status=step_status)} {count}\n"
        )
    fh.write("# HELP webrtc_qos_phase5_production_gate_step_status Phase-5 production gate observed step status.\n")
    fh.write("# TYPE webrtc_qos_phase5_production_gate_step_status gauge\n")
    for step, step_status in steps:
        fh.write(
            "webrtc_qos_phase5_production_gate_step_status"
            f"{prom_labels(step=step, status=step_status)} 1\n"
        )
    fh.write("# HELP webrtc_qos_phase5_production_gate_failure_debug_bundle_status Failure debug bundle status marker.\n")
    fh.write("# TYPE webrtc_qos_phase5_production_gate_failure_debug_bundle_status gauge\n")
    fh.write(
        "webrtc_qos_phase5_production_gate_failure_debug_bundle_status"
        f"{prom_labels(status=failure_bundle_status)} 1\n"
    )
    fh.write("# HELP webrtc_qos_phase5_production_gate_release_evidence_status Release evidence step status marker.\n")
    fh.write("# TYPE webrtc_qos_phase5_production_gate_release_evidence_status gauge\n")
    fh.write(
        "webrtc_qos_phase5_production_gate_release_evidence_status"
        f"{prom_labels(status=release_evidence_status)} 1\n"
    )
PY
}

write_release_evidence() {
  python3 - \
    "${OUTPUT_ROOT}" \
    "${SUMMARY_FILE}" \
    "${METADATA_FILE}" \
    "${PHASE5_IMPLEMENTATION_GATE_DIR}" \
    "${PHASE5_READINESS_DIR}" \
    "${PHASE5_DEBUG_BUNDLE_DIR}" \
    "${PHASE2_OUTPUT_ROOT}" \
    "${PHASE2_EVIDENCE_BUNDLE_DIR}" \
    "${RELEASE_EVIDENCE_JSON}" \
    "${RELEASE_EVIDENCE_SUMMARY}" \
    "${SOAK_MINUTES}" \
    "${MIN_PRODUCTION_SOAK_MINUTES}" \
    "${ALLOW_XVFB_RENDERER}" \
    "${REAL_RENDERER_USE_XVFB}" \
    "${CAPTURE_LIBRARY_DIR}" \
    "${CAPTURE_LIBRARY_MANIFEST}" <<'PY'
import json
import os
import sys

(
    output_root,
    summary_file,
    metadata_file,
    implementation_dir,
    readiness_dir,
    debug_bundle_dir,
    phase2_dir,
    imported_phase2_evidence_bundle,
    release_json,
    release_summary,
    soak_minutes,
    min_soak_minutes,
    allow_xvfb_renderer,
    real_renderer_use_xvfb,
    capture_library_dir,
    capture_library_manifest,
) = sys.argv[1:17]


def rel(path):
    return os.path.relpath(path, output_root)


def kv_summary(path):
    values = {}
    if not os.path.exists(path):
        return values
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key] = value
    return values


def metadata_value(path, key, default=""):
    values = kv_summary(path)
    return values.get(key, default)


def has_line(path, expected):
    if not os.path.exists(path):
        return False
    with open(path, "r", encoding="utf-8") as fh:
        return any(line.strip() == expected for line in fh)


def has_prefix(path, prefix):
    if not os.path.exists(path):
        return False
    with open(path, "r", encoding="utf-8") as fh:
        return any(line.startswith(prefix) for line in fh)


def parse_number(value):
    try:
        number = float(value)
    except ValueError:
        return value
    if number.is_integer():
        return int(number)
    return number


def has_file(path):
    return os.path.isfile(path) and os.path.getsize(path) > 0


def valid_sha256(value):
    return isinstance(value, str) and len(value) == 64 and all(
        ch in "0123456789abcdefABCDEF" for ch in value
    )


def number_value(values, key, default=0):
    parsed = parse_number(values.get(key, str(default)))
    return parsed if isinstance(parsed, (int, float)) else default


def has_capture_fixture_marker(path):
    if not os.path.exists(path):
        return False
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read().lower()
    return any(
        marker in text
        for marker in (
            "fixture",
            "artifacts/capture_library_phase2_fixture",
            "artifacts/capture_library_fixture",
        )
    )


def category_tokens(value):
    return {
        token.strip()
        for token in str(value or "").replace(",", " ").split()
        if token.strip()
    }


def capture_categories_cover(values, manifest_values):
    required_categories = category_tokens(
        values.get("required_categories")
        or manifest_values.get("required_categories")
        or "indoor_face,outdoor_walking,low_light_noise,screen_text,high_motion,scene_cut"
    )
    observed_categories = category_tokens(
        values.get("categories") or manifest_values.get("categories") or ""
    )
    return bool(required_categories) and required_categories <= observed_categories


def capture_qoe_summary_complete(values, manifest_values):
    rows = number_value(values, "rows")
    pass_rows = number_value(values, "pass_rows", -1)
    return (
        values.get("capture_qoe_verification") == "true"
        and rows > 0
        and pass_rows == rows
        and capture_categories_cover(values, manifest_values)
        and number_value(values, "playable_ratio_min") > 0
        and number_value(values, "avg_psnr_y_min") > 0
        and number_value(values, "avg_ssim_y_min") > 0
        and number_value(values, "decode_errors", 1) == 0
        and number_value(values, "freeze_count", 1) == 0
        and number_value(values, "renderer_proxy_drop_frames", 1) == 0
    )


implementation_summary = os.path.join(
    implementation_dir, "phase5_implementation_gate_summary.txt"
)
implementation_metrics = os.path.join(
    implementation_dir, "phase5_implementation_gate_metrics.prom"
)
readiness_summary = os.path.join(readiness_dir, "phase5_production_readiness_summary.txt")
readiness_report = os.path.join(readiness_dir, "readiness_report.json")
next_required_actions_json = os.path.join(readiness_dir, "next_required_actions.json")
risk_milestone_report = os.path.join(readiness_dir, "risk_milestone_report.json")
risk_milestone_summary = os.path.join(readiness_dir, "risk_milestone_summary.txt")
readiness_metrics = os.path.join(
    readiness_dir, "phase5_production_readiness_metrics.prom"
)
readiness_check_records = os.path.join(readiness_dir, "check_records.jsonl")
debug_slo = os.path.join(debug_bundle_dir, "monitoring", "slo_report.json")
phase2_summary = os.path.join(phase2_dir, "phase2_production_gate_summary.txt")
phase2_audit_summary = os.path.join(
    phase2_dir,
    "phase2_completion_audit",
    "phase2_completion_audit_summary.txt",
)
phase2_audit_metrics = os.path.join(
    phase2_dir,
    "phase2_completion_audit",
    "phase2_completion_audit_metrics.prom",
)
phase2_evidence_bundle = os.path.join(phase2_dir, "phase2_evidence_bundle")
production_soak_dir = os.path.join(phase2_evidence_bundle, "production_soak")
production_soak_summary = os.path.join(
    production_soak_dir, "webrtc_first_qoe_production_soak_summary.txt"
)
production_soak_csv = os.path.join(
    production_soak_dir, "webrtc_first_qoe_production_soak.csv"
)
production_soak_config = os.path.join(
    production_soak_dir, "webrtc_first_qoe_production_soak_config.env"
)
production_soak_archive = os.path.join(
    production_soak_dir, "webrtc_first_qoe_production_soak_archive.tar.gz"
)
real_renderer_dir = os.path.join(phase2_evidence_bundle, "real_renderer")
real_renderer_summary = os.path.join(real_renderer_dir, "real_renderer_summary.txt")
real_renderer_metrics = os.path.join(real_renderer_dir, "real_renderer_metrics.csv")
capture_evidence_dir = os.path.join(phase2_evidence_bundle, "capture_library")
capture_manifest_summary = os.path.join(
    capture_evidence_dir, "capture_manifest_summary.txt"
)
capture_qoe_csv = os.path.join(
    capture_evidence_dir, "webrtc_first_qoe_capture_library_720p.csv"
)
capture_qoe_summary = os.path.join(capture_evidence_dir, "capture_qoe_summary.txt")

readiness = kv_summary(readiness_summary)
metadata = kv_summary(metadata_file)
phase2_audit = kv_summary(phase2_audit_summary)
production_soak = kv_summary(production_soak_summary)
production_soak_runtime = kv_summary(production_soak_config)
real_renderer = kv_summary(real_renderer_summary)
capture_manifest = kv_summary(capture_manifest_summary)
capture_qoe = kv_summary(capture_qoe_summary)
capture_fixture_marker = has_capture_fixture_marker(capture_manifest_summary)
capture_manifest_complete = (
    capture_manifest.get("capture_manifest_verification") == "true"
    and valid_sha256(capture_manifest.get("capture_manifest_sha256"))
    and not capture_fixture_marker
)
capture_qoe_complete = capture_qoe_summary_complete(capture_qoe, capture_manifest)
slo_status = "missing"
if os.path.exists(debug_slo):
    with open(debug_slo, "r", encoding="utf-8") as fh:
        slo_status = json.load(fh).get("slo_status", "missing")

checks = {
    "phase5_implementation_gate": has_line(
        implementation_summary, "phase5_implementation_gate_status=pass"
    ),
    "phase5_implementation_gate_metrics": has_file(implementation_metrics),
    "phase5_production_readiness": readiness.get(
        "phase5_production_readiness_status"
    )
    == "ready",
    "phase5_production_readiness_report": has_file(readiness_report),
    "phase5_next_required_actions": has_file(next_required_actions_json),
    "phase5_risk_milestone_report": has_file(risk_milestone_report),
    "phase5_risk_milestone_summary": has_file(risk_milestone_summary),
    "phase5_production_readiness_metrics": has_file(readiness_metrics),
    "phase5_readiness_check_records": has_file(readiness_check_records),
    "git_worktree_clean": metadata.get("GIT_TRACKED_WORKTREE_CLEAN") == "1"
    and has_prefix(readiness_summary, "check=git_worktree_clean status=pass "),
    "phase5_debug_bundle": has_file(
        os.path.join(debug_bundle_dir, "manifest.sha256")
    )
    and has_file(debug_slo),
    "phase2_production_gate": has_line(phase2_summary, "phase2_production_gate_status=pass"),
    "phase2_completion_audit": has_line(
        phase2_audit_summary, "phase2_completion_audit=pass"
    )
    and phase2_audit.get("phase2_completion_status") == "complete",
    "phase2_completion_audit_metrics": has_file(phase2_audit_metrics),
    "production_soak": has_prefix(phase2_audit_summary, "check=production_soak status=pass "),
    "real_renderer": has_prefix(phase2_audit_summary, "check=real_renderer status=pass ")
    and real_renderer.get("real_renderer_status") == "pass"
    and real_renderer.get("renderer_backend") != "xvfb"
    and number_value(real_renderer, "rendered_frames") > 0,
    "production_soak_summary": has_file(production_soak_summary)
    and production_soak.get("rows", "0") != "0"
    and production_soak.get("rows") == production_soak.get("pass_rows"),
    "production_soak_csv": has_file(production_soak_csv),
    "production_soak_config": has_file(production_soak_config),
    "production_soak_archive": has_file(production_soak_archive),
    "real_renderer_summary": real_renderer.get("real_renderer_status") == "pass"
    and real_renderer.get("renderer_backend") != "xvfb",
    "real_renderer_metrics": has_file(real_renderer_metrics),
    "capture_library": has_prefix(
        phase2_audit_summary, "check=capture_library status=pass "
    )
    and capture_manifest_complete
    and has_file(capture_qoe_csv)
    and capture_qoe_complete,
    "capture_manifest_summary": capture_manifest_complete,
    "capture_qoe_csv": has_file(capture_qoe_csv) and capture_qoe_complete,
    "capture_qoe_summary": capture_qoe_complete,
    "evidence_bundle": has_prefix(
        phase2_audit_summary, "check=evidence_bundle status=pass "
    )
    and has_file(os.path.join(phase2_evidence_bundle, "manifest.sha256")),
}

evidence = [
    {
        "id": name,
        "status": "pass" if passed else "fail",
        "artifact": artifact,
    }
    for name, passed, artifact in (
        (
            "phase5_implementation_gate",
            checks["phase5_implementation_gate"],
            rel(implementation_summary),
        ),
        (
            "phase5_implementation_gate_metrics",
            checks["phase5_implementation_gate_metrics"],
            rel(implementation_metrics),
        ),
        (
            "phase5_production_readiness",
            checks["phase5_production_readiness"],
            rel(readiness_summary),
        ),
        (
            "phase5_production_readiness_report",
            checks["phase5_production_readiness_report"],
            rel(readiness_report),
        ),
        (
            "phase5_next_required_actions",
            checks["phase5_next_required_actions"],
            rel(next_required_actions_json),
        ),
        (
            "phase5_risk_milestone_report",
            checks["phase5_risk_milestone_report"],
            rel(risk_milestone_report),
        ),
        (
            "phase5_risk_milestone_summary",
            checks["phase5_risk_milestone_summary"],
            rel(risk_milestone_summary),
        ),
        (
            "phase5_production_readiness_metrics",
            checks["phase5_production_readiness_metrics"],
            rel(readiness_metrics),
        ),
        (
            "phase5_readiness_check_records",
            checks["phase5_readiness_check_records"],
            rel(readiness_check_records),
        ),
        (
            "git_worktree_clean",
            checks["git_worktree_clean"],
            rel(os.path.join(output_root, "git_tracked_status.txt")),
        ),
        (
            "phase5_debug_bundle",
            checks["phase5_debug_bundle"],
            rel(os.path.join(debug_bundle_dir, "manifest.sha256")),
        ),
        (
            "phase2_production_gate",
            checks["phase2_production_gate"],
            rel(phase2_summary),
        ),
        (
            "phase2_completion_audit",
            checks["phase2_completion_audit"],
            rel(phase2_audit_summary),
        ),
        (
            "phase2_completion_audit_metrics",
            checks["phase2_completion_audit_metrics"],
            rel(phase2_audit_metrics),
        ),
        (
            "production_soak",
            checks["production_soak"],
            rel(phase2_audit_summary),
        ),
        (
            "production_soak_summary",
            checks["production_soak_summary"],
            rel(production_soak_summary),
        ),
        (
            "production_soak_csv",
            checks["production_soak_csv"],
            rel(production_soak_csv),
        ),
        (
            "production_soak_config",
            checks["production_soak_config"],
            rel(production_soak_config),
        ),
        (
            "production_soak_archive",
            checks["production_soak_archive"],
            rel(production_soak_archive),
        ),
        (
            "real_renderer",
            checks["real_renderer"],
            rel(phase2_audit_summary),
        ),
        (
            "real_renderer_summary",
            checks["real_renderer_summary"],
            rel(real_renderer_summary),
        ),
        (
            "real_renderer_metrics",
            checks["real_renderer_metrics"],
            rel(real_renderer_metrics),
        ),
        (
            "capture_library",
            checks["capture_library"],
            rel(phase2_audit_summary),
        ),
        (
            "capture_manifest_summary",
            checks["capture_manifest_summary"],
            rel(capture_manifest_summary),
        ),
        (
            "capture_qoe_csv",
            checks["capture_qoe_csv"],
            rel(capture_qoe_csv),
        ),
        (
            "capture_qoe_summary",
            checks["capture_qoe_summary"],
            rel(capture_qoe_summary),
        ),
        (
            "evidence_bundle",
            checks["evidence_bundle"],
            rel(os.path.join(phase2_evidence_bundle, "manifest.sha256")),
        ),
    )
]
release_status = "pass" if all(checks.values()) else "fail"
doc = {
    "schema_version": 1,
    "source": "phase5_production_gate",
    "scope": "phase5 formal production release evidence",
    "release_status": release_status,
    "formal_completion_status": "complete" if release_status == "pass" else "incomplete",
    "requirements": {
        "soak_minutes": parse_number(soak_minutes),
        "min_production_soak_minutes": parse_number(min_soak_minutes),
        "allow_xvfb_renderer": allow_xvfb_renderer == "1",
        "real_renderer_use_xvfb": real_renderer_use_xvfb,
        "git_head": metadata_value(metadata_file, "GIT_HEAD", ""),
        "git_branch": metadata_value(metadata_file, "GIT_BRANCH", ""),
        "git_tracked_worktree_clean": metadata.get("GIT_TRACKED_WORKTREE_CLEAN")
        == "1",
        "git_tracked_status": rel(
            os.path.join(output_root, "git_tracked_status.txt")
        ),
        "capture_library_dir": capture_library_dir,
        "capture_library_manifest": capture_library_manifest,
        "phase2_evidence_source": "external_bundle"
        if imported_phase2_evidence_bundle
        else "direct_phase2_production_gate",
        "imported_phase2_evidence_bundle": imported_phase2_evidence_bundle,
        "multi_receiver_fanout": "deferred_before_p5_completion",
    },
    "observability": {
        "implementation_gate_metrics": rel(implementation_metrics),
        "production_readiness_metrics": rel(readiness_metrics),
        "phase2_completion_audit_metrics": rel(phase2_audit_metrics),
        "debug_bundle_slo_status": slo_status,
        "debug_bundle_slo_report": rel(debug_slo),
    },
    "production_soak": {
        "summary": rel(production_soak_summary),
        "csv": rel(production_soak_csv),
        "config": rel(production_soak_config),
        "archive": rel(production_soak_archive),
        "soak_minutes": parse_number(production_soak_runtime.get("SOAK_MINUTES", "0")),
        "cycles": parse_number(production_soak.get("cycles", "0")),
        "rows": parse_number(production_soak.get("rows", "0")),
        "pass_rows": parse_number(production_soak.get("pass_rows", "0")),
        "playable_ratio_min": parse_number(
            production_soak.get("playable_ratio_min", "0")
        ),
        "avg_psnr_y_min": parse_number(production_soak.get("avg_psnr_y_min", "0")),
        "avg_ssim_y_min": parse_number(production_soak.get("avg_ssim_y_min", "0")),
        "decode_errors": parse_number(production_soak.get("decode_errors", "0")),
        "freeze_count": parse_number(production_soak.get("freeze_count", "0")),
        "renderer_proxy_drop_frames": parse_number(
            production_soak.get("renderer_proxy_drop_frames", "0")
        ),
    },
    "real_renderer": {
        "summary": rel(real_renderer_summary),
        "metrics": rel(real_renderer_metrics),
        "status": real_renderer.get("real_renderer_status", ""),
        "backend": real_renderer.get("renderer_backend", ""),
        "rendered_frames": parse_number(real_renderer.get("rendered_frames", "0")),
        "late_frames": parse_number(real_renderer.get("late_frames", "0")),
        "max_present_gap_ms": parse_number(
            real_renderer.get("max_present_gap_ms", "0")
        ),
        "max_present_jitter_ms": parse_number(
            real_renderer.get("max_present_jitter_ms", "0")
        ),
    },
    "capture_library": {
        "manifest_summary": rel(capture_manifest_summary),
        "qoe_csv": rel(capture_qoe_csv),
        "qoe_summary": rel(capture_qoe_summary),
        "categories": capture_qoe.get(
            "categories", capture_manifest.get("categories", "")
        ),
        "required_categories": capture_qoe.get(
            "required_categories", capture_manifest.get("required_categories", "")
        ),
        "manifest_sha256": capture_manifest.get("capture_manifest_sha256", ""),
        "rows": parse_number(capture_qoe.get("rows", "0")),
        "pass_rows": parse_number(capture_qoe.get("pass_rows", "0")),
        "playable_ratio_min": parse_number(capture_qoe.get("playable_ratio_min", "0")),
        "avg_psnr_y_min": parse_number(capture_qoe.get("avg_psnr_y_min", "0")),
        "avg_ssim_y_min": parse_number(capture_qoe.get("avg_ssim_y_min", "0")),
        "decode_errors": parse_number(capture_qoe.get("decode_errors", "0")),
        "freeze_count": parse_number(capture_qoe.get("freeze_count", "0")),
        "renderer_proxy_drop_frames": parse_number(
            capture_qoe.get("renderer_proxy_drop_frames", "0")
        ),
    },
    "evidence": evidence,
    "artifacts": {
        "gate_summary": rel(summary_file),
        "metadata": rel(metadata_file),
        "git_tracked_status": rel(
            os.path.join(output_root, "git_tracked_status.txt")
        ),
        "phase5_implementation_gate": rel(implementation_dir),
        "phase5_implementation_gate_metrics": rel(implementation_metrics),
        "phase5_production_readiness": rel(readiness_dir),
        "phase5_production_readiness_report": rel(readiness_report),
        "phase5_next_required_actions": rel(next_required_actions_json),
        "phase5_risk_milestone_report": rel(risk_milestone_report),
        "phase5_risk_milestone_summary": rel(risk_milestone_summary),
        "phase5_production_readiness_metrics": rel(readiness_metrics),
        "phase5_readiness_check_records": rel(readiness_check_records),
        "phase5_debug_bundle": rel(debug_bundle_dir),
        "phase2_production_gate": rel(phase2_dir),
        "phase2_evidence_bundle": rel(phase2_evidence_bundle),
        "phase2_completion_audit": rel(phase2_audit_summary),
        "phase2_completion_audit_metrics": rel(phase2_audit_metrics),
        "production_soak_summary": rel(production_soak_summary),
        "production_soak_csv": rel(production_soak_csv),
        "production_soak_config": rel(production_soak_config),
        "production_soak_archive": rel(production_soak_archive),
        "real_renderer_summary": rel(real_renderer_summary),
        "real_renderer_metrics": rel(real_renderer_metrics),
        "capture_manifest_summary": rel(capture_manifest_summary),
        "capture_qoe_csv": rel(capture_qoe_csv),
        "capture_qoe_summary": rel(capture_qoe_summary),
    },
    "phase2_evidence_source": "external_bundle"
    if imported_phase2_evidence_bundle
    else "direct_phase2_production_gate",
    "fanout": {
        "status": "deferred",
        "reason": "P5 baseline excludes multi-receiver fanout",
    },
}

with open(release_json, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")

with open(release_summary, "w", encoding="utf-8") as fh:
    fh.write(f"release_status={release_status}\n")
    fh.write(f"formal_completion_status={doc['formal_completion_status']}\n")
    fh.write("scope=phase5_formal_production_release_evidence\n")
    fh.write(f"phase2_evidence_source={doc['phase2_evidence_source']}\n")
    fh.write("fanout_status=deferred\n")
    fh.write(
        "min_production_soak_minutes="
        f"{doc['requirements']['min_production_soak_minutes']}\n"
    )
    for item in evidence:
        fh.write(
            f"evidence={item['id']} status={item['status']} "
            f"artifact={item['artifact']}\n"
        )
    fh.write(f"phase5_readiness_report={rel(readiness_report)}\n")
    fh.write(f"phase5_readiness_metrics={rel(readiness_metrics)}\n")
    fh.write(f"phase5_risk_milestone_report={rel(risk_milestone_report)}\n")
    fh.write(f"production_soak_csv={rel(production_soak_csv)}\n")
    fh.write(f"production_soak_archive={rel(production_soak_archive)}\n")
    fh.write(f"production_soak_minutes={doc['production_soak']['soak_minutes']}\n")
    fh.write(f"production_soak_rows={doc['production_soak']['rows']}\n")
    fh.write(f"real_renderer_summary={rel(real_renderer_summary)}\n")
    fh.write(f"real_renderer_backend={doc['real_renderer']['backend']}\n")
    fh.write(f"real_renderer_status={doc['real_renderer']['status']}\n")
    fh.write(
        f"capture_manifest_sha256={doc['capture_library']['manifest_sha256']}\n"
    )
    fh.write(f"capture_qoe_csv={rel(capture_qoe_csv)}\n")
    fh.write(f"capture_qoe_summary={rel(capture_qoe_summary)}\n")
    fh.write(f"capture_qoe_rows={doc['capture_library']['rows']}\n")
    fh.write(
        "capture_qoe_minima="
        f"playable_ratio={doc['capture_library']['playable_ratio_min']} "
        f"psnr_y={doc['capture_library']['avg_psnr_y_min']} "
        f"ssim_y={doc['capture_library']['avg_ssim_y_min']}\n"
    )

if release_status != "pass":
    failed = ",".join(name for name, passed in checks.items() if not passed)
    raise SystemExit(f"phase5 release evidence incomplete: {failed}")
PY
}

collect_failure_debug_bundle() {
  local failed_step="$1"
  if [[ "${PHASE5_DRY_RUN}" == "1" ]]; then
    return
  fi
  write_summary "failure_debug_bundle_status=collecting failed_step=${failed_step}"
  if env SDK_ROOT="${SDK_ROOT}" PREFIX="${WEBRTC_PREFIX}" \
      OUTPUT_DIR="${FAILURE_DEBUG_BUNDLE_DIR}" \
      "${SDK_ROOT}/scripts/collect_phase5_debug_bundle.sh" \
      >"${LOG_DIR}/failure_debug_bundle_collect.log" 2>&1; then
    if env BUNDLE_DIR="${FAILURE_DEBUG_BUNDLE_DIR}" \
        "${SDK_ROOT}/scripts/verify_phase5_debug_bundle.sh" \
        >"${LOG_DIR}/failure_debug_bundle_verify.log" 2>&1; then
      write_summary "failure_debug_bundle_status=pass dir=${FAILURE_DEBUG_BUNDLE_DIR}"
    else
      local verify_status=$?
      write_summary "failure_debug_bundle_status=verify_failed exit=${verify_status} dir=${FAILURE_DEBUG_BUNDLE_DIR} log=${LOG_DIR}/failure_debug_bundle_verify.log"
    fi
  else
    local collect_status=$?
    write_summary "failure_debug_bundle_status=collect_failed exit=${collect_status} dir=${FAILURE_DEBUG_BUNDLE_DIR} log=${LOG_DIR}/failure_debug_bundle_collect.log"
  fi
}

run_step() {
  local name="$1"
  shift
  local log_file="${LOG_DIR}/${name}.log"
  write_summary "step=${name} status=running"
  if [[ "${PHASE5_DRY_RUN}" == "1" ]]; then
    {
      printf 'dry_run=true\n'
      printf 'command='
      printf '%q ' "$@"
      printf '\n'
    } >"${log_file}"
    write_summary "step=${name} status=planned log=${log_file}"
    return
  fi
  if "$@" >"${log_file}" 2>&1; then
    write_summary "step=${name} status=pass log=${log_file}"
  else
    local status=$?
    write_summary "step=${name} status=fail exit=${status} log=${log_file}"
    write_summary "phase5_production_gate_status=fail"
    collect_failure_debug_bundle "${name}"
    write_summary "failure_debug_bundle=${FAILURE_DEBUG_BUNDLE_DIR}"
    write_summary "phase5_production_gate_metrics=${PHASE5_GATE_METRICS_PROM}"
    write_gate_metrics
    write_manifest
    tail -n 80 "${log_file}" >&2 || true
    exit "${status}"
  fi
}

require_script "${SDK_ROOT}/scripts/run_phase5_implementation_gate.sh"
require_script "${SDK_ROOT}/scripts/verify_phase5_implementation_gate.sh"
require_script "${SDK_ROOT}/scripts/verify_phase5_release_contract.sh"
require_script "${SDK_ROOT}/scripts/verify_phase5_production_readiness.sh"
require_script "${SDK_ROOT}/scripts/collect_phase5_debug_bundle.sh"
require_script "${SDK_ROOT}/scripts/verify_phase5_debug_bundle.sh"
require_script "${SDK_ROOT}/scripts/run_webrtc_first_phase2_production_gate.sh"
require_script "${SDK_ROOT}/scripts/import_phase5_phase2_evidence_bundle.sh"
require_script "${SDK_ROOT}/scripts/verify_webrtc_first_phase2_completion_audit.sh"

{
  printf 'PHASE5_BUILD_ID=%s\n' "${PHASE5_BUILD_ID}"
  printf 'SDK_ROOT=%s\n' "${SDK_ROOT}"
  printf 'WEBRTC_PREFIX=%s\n' "${WEBRTC_PREFIX}"
  printf 'OUTPUT_ROOT=%s\n' "${OUTPUT_ROOT}"
  printf 'PHASE2_OUTPUT_ROOT=%s\n' "${PHASE2_OUTPUT_ROOT}"
  printf 'PHASE2_EVIDENCE_BUNDLE_DIR=%s\n' "${PHASE2_EVIDENCE_BUNDLE_DIR}"
  printf 'PHASE5_IMPLEMENTATION_GATE_DIR=%s\n' "${PHASE5_IMPLEMENTATION_GATE_DIR}"
  printf 'PHASE5_DEBUG_BUNDLE_DIR=%s\n' "${PHASE5_DEBUG_BUNDLE_DIR}"
  printf 'FAILURE_DEBUG_BUNDLE_DIR=%s\n' "${FAILURE_DEBUG_BUNDLE_DIR}"
  printf 'PHASE5_READINESS_DIR=%s\n' "${PHASE5_READINESS_DIR}"
  printf 'SOAK_MINUTES=%s\n' "${SOAK_MINUTES}"
  printf 'MIN_PRODUCTION_SOAK_MINUTES=%s\n' "${MIN_PRODUCTION_SOAK_MINUTES}"
  printf 'SOAK_CYCLES=%s\n' "${SOAK_CYCLES}"
  printf 'PREFLIGHT_ONLY=%s\n' "${PREFLIGHT_ONLY}"
  printf 'PHASE5_DRY_RUN=%s\n' "${PHASE5_DRY_RUN}"
  printf 'RUN_PHASE5_IMPLEMENTATION_GATE=%s\n' "${RUN_PHASE5_IMPLEMENTATION_GATE}"
  printf 'RUN_PHASE5_RELEASE_CONTRACT=%s\n' "${RUN_PHASE5_RELEASE_CONTRACT}"
  printf 'RUN_PHASE5_READINESS=%s\n' "${RUN_PHASE5_READINESS}"
  printf 'RUN_PHASE5_DEBUG_BUNDLE=%s\n' "${RUN_PHASE5_DEBUG_BUNDLE}"
  printf 'PHASE5_IMPLEMENTATION_FRAMES=%s\n' "${PHASE5_IMPLEMENTATION_FRAMES}"
  printf 'ALLOW_XVFB_RENDERER=%s\n' "${ALLOW_XVFB_RENDERER}"
  printf 'REAL_RENDERER_USE_XVFB=%s\n' "${REAL_RENDERER_USE_XVFB}"
  printf 'CAPTURE_LIBRARY_DIR=%s\n' "${CAPTURE_LIBRARY_DIR}"
  printf 'CAPTURE_LIBRARY_MANIFEST=%s\n' "${CAPTURE_LIBRARY_MANIFEST}"
  printf 'COLLECTED_AT_UTC=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if git -C "${SDK_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'GIT_HEAD=%s\n' "$(git -C "${SDK_ROOT}" rev-parse HEAD)"
    printf 'GIT_BRANCH=%s\n' "$(git -C "${SDK_ROOT}" rev-parse --abbrev-ref HEAD)"
    git -C "${SDK_ROOT}" status --short --untracked-files=no >"${GIT_TRACKED_STATUS_FILE}"
    if [[ -s "${GIT_TRACKED_STATUS_FILE}" ]]; then
      printf 'GIT_TRACKED_WORKTREE_CLEAN=0\n'
    else
      printf 'GIT_TRACKED_WORKTREE_CLEAN=1\n'
      printf 'tracked_changes=0\n' >"${GIT_TRACKED_STATUS_FILE}"
    fi
  else
    printf 'GIT_TRACKED_WORKTREE_CLEAN=0\n'
    printf 'git_status=not_a_git_checkout\n' >"${GIT_TRACKED_STATUS_FILE}"
  fi
} >"${METADATA_FILE}"

write_summary "phase5_production_gate=running"
write_summary "sdk_root=${SDK_ROOT}"
write_summary "webrtc_prefix=${WEBRTC_PREFIX}"
write_summary "output_root=${OUTPUT_ROOT}"
write_summary "phase2_output_root=${PHASE2_OUTPUT_ROOT}"
write_summary "phase2_evidence_bundle_dir=${PHASE2_EVIDENCE_BUNDLE_DIR}"
write_summary "phase5_implementation_gate_dir=${PHASE5_IMPLEMENTATION_GATE_DIR}"
write_summary "phase5_readiness_dir=${PHASE5_READINESS_DIR}"
write_summary "soak_minutes=${SOAK_MINUTES}"
write_summary "min_production_soak_minutes=${MIN_PRODUCTION_SOAK_MINUTES}"
write_summary "preflight_only=${PREFLIGHT_ONLY}"
write_summary "phase5_dry_run=${PHASE5_DRY_RUN}"
write_summary "capture_library_manifest=${CAPTURE_LIBRARY_MANIFEST}"

if [[ "${RUN_PHASE5_IMPLEMENTATION_GATE}" == "1" ]]; then
  run_step phase5_implementation_gate \
    env SDK_ROOT="${SDK_ROOT}" PREFIX="${WEBRTC_PREFIX}" \
      OUTPUT_ROOT="${PHASE5_IMPLEMENTATION_GATE_DIR}" \
      FRAMES="${PHASE5_IMPLEMENTATION_FRAMES}" \
      RUN_PHASE5_RELEASE_CONTRACT=1 \
      RUN_PHASE5_DEBUG_BUNDLE=1 \
      "${SDK_ROOT}/scripts/run_phase5_implementation_gate.sh"
  run_step verify_phase5_implementation_gate \
    env GATE_DIR="${PHASE5_IMPLEMENTATION_GATE_DIR}" REQUIRE_PASS=1 \
      "${SDK_ROOT}/scripts/verify_phase5_implementation_gate.sh"
  write_summary "phase5_implementation_gate=${PHASE5_IMPLEMENTATION_GATE_DIR}"
else
  write_summary "step=phase5_implementation_gate status=skipped RUN_PHASE5_IMPLEMENTATION_GATE=${RUN_PHASE5_IMPLEMENTATION_GATE}"
fi

if [[ "${RUN_PHASE5_RELEASE_CONTRACT}" == "1" ]]; then
  run_step phase5_release_contract \
    env SDK_ROOT="${SDK_ROOT}" PREFIX="${WEBRTC_PREFIX}" \
      "${SDK_ROOT}/scripts/verify_phase5_release_contract.sh"
else
  write_summary "step=phase5_release_contract status=skipped RUN_PHASE5_RELEASE_CONTRACT=${RUN_PHASE5_RELEASE_CONTRACT}"
fi

if [[ "${RUN_PHASE5_READINESS}" == "1" ]]; then
  run_step phase5_production_readiness \
    env SDK_ROOT="${SDK_ROOT}" PREFIX="${WEBRTC_PREFIX}" \
      OUTPUT_DIR="${PHASE5_READINESS_DIR}" \
      SOAK_MINUTES="${SOAK_MINUTES}" \
      MIN_PRODUCTION_SOAK_MINUTES="${MIN_PRODUCTION_SOAK_MINUTES}" \
      ALLOW_XVFB_RENDERER="${ALLOW_XVFB_RENDERER}" \
      REAL_RENDERER_USE_XVFB="${REAL_RENDERER_USE_XVFB}" \
      CAPTURE_LIBRARY_DIR="${CAPTURE_LIBRARY_DIR}" \
      CAPTURE_LIBRARY_MANIFEST="${CAPTURE_LIBRARY_MANIFEST}" \
      CAPTURE_WIDTH="${CAPTURE_WIDTH}" \
      CAPTURE_HEIGHT="${CAPTURE_HEIGHT}" \
      CAPTURE_FRAMES="${CAPTURE_FRAMES}" \
      REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES}" \
      PHASE2_EVIDENCE_BUNDLE_DIR="${PHASE2_EVIDENCE_BUNDLE_DIR}" \
      REQUIRE_READY=1 \
      "${SDK_ROOT}/scripts/verify_phase5_production_readiness.sh"
else
  write_summary "step=phase5_production_readiness status=skipped RUN_PHASE5_READINESS=${RUN_PHASE5_READINESS}"
fi

if [[ "${RUN_PHASE5_DEBUG_BUNDLE}" == "1" ]]; then
  run_step collect_phase5_debug_bundle \
    env SDK_ROOT="${SDK_ROOT}" PREFIX="${WEBRTC_PREFIX}" \
      OUTPUT_DIR="${PHASE5_DEBUG_BUNDLE_DIR}" \
      "${SDK_ROOT}/scripts/collect_phase5_debug_bundle.sh"
  run_step verify_phase5_debug_bundle \
    env BUNDLE_DIR="${PHASE5_DEBUG_BUNDLE_DIR}" \
      "${SDK_ROOT}/scripts/verify_phase5_debug_bundle.sh"
else
  write_summary "step=phase5_debug_bundle status=skipped RUN_PHASE5_DEBUG_BUNDLE=${RUN_PHASE5_DEBUG_BUNDLE}"
fi

if [[ -n "${PHASE2_EVIDENCE_BUNDLE_DIR}" ]]; then
  run_step import_phase2_evidence_bundle \
    env SDK_ROOT="${SDK_ROOT}" \
      OUTPUT_ROOT="${PHASE2_OUTPUT_ROOT}" \
      PHASE2_EVIDENCE_BUNDLE_DIR="${PHASE2_EVIDENCE_BUNDLE_DIR}" \
      MIN_PRODUCTION_SOAK_MINUTES="${MIN_PRODUCTION_SOAK_MINUTES}" \
      ALLOW_XVFB_RENDERER="${ALLOW_XVFB_RENDERER}" \
      ALLOW_FIXTURE_CAPTURE=0 \
      REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES}" \
      "${SDK_ROOT}/scripts/import_phase5_phase2_evidence_bundle.sh"
else
  run_step webrtc_first_production_gate \
    env SDK_ROOT="${SDK_ROOT}" WEBRTC_PREFIX="${WEBRTC_PREFIX}" \
      OUTPUT_ROOT="${PHASE2_OUTPUT_ROOT}" \
      SOAK_MINUTES="${SOAK_MINUTES}" \
      MIN_PRODUCTION_SOAK_MINUTES="${MIN_PRODUCTION_SOAK_MINUTES}" \
      SOAK_CYCLES="${SOAK_CYCLES}" \
      PREFLIGHT_ONLY="${PREFLIGHT_ONLY}" \
      ALLOW_XVFB_RENDERER="${ALLOW_XVFB_RENDERER}" \
      REAL_RENDERER_USE_XVFB="${REAL_RENDERER_USE_XVFB}" \
      FACADE_FRAMES="${FACADE_FRAMES}" \
      QOE_FRAMES="${QOE_FRAMES}" QOE_WIDTH="${QOE_WIDTH}" \
      QOE_HEIGHT="${QOE_HEIGHT}" QOE_CONTENT_MODE="${QOE_CONTENT_MODE}" \
      CAPTURE_LIBRARY_DIR="${CAPTURE_LIBRARY_DIR}" \
      CAPTURE_LIBRARY_MANIFEST="${CAPTURE_LIBRARY_MANIFEST}" \
      CAPTURE_WIDTH="${CAPTURE_WIDTH}" \
      CAPTURE_HEIGHT="${CAPTURE_HEIGHT}" \
      CAPTURE_FRAMES="${CAPTURE_FRAMES}" \
      CAPTURE_SCENARIOS="${CAPTURE_SCENARIOS}" \
      CAPTURE_SEEDS="${CAPTURE_SEEDS}" \
      REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES}" \
      "${SDK_ROOT}/scripts/run_webrtc_first_phase2_production_gate.sh"
fi

if [[ "${PHASE5_DRY_RUN}" != "1" ]]; then
  run_step phase5_release_evidence write_release_evidence
fi

if [[ "${PHASE5_DRY_RUN}" == "1" ]]; then
  write_summary "phase5_production_gate_status=dry_run"
else
  write_summary "phase5_production_gate_status=pass"
fi
write_summary "phase5_metadata=${METADATA_FILE}"
write_summary "phase5_implementation_gate=${PHASE5_IMPLEMENTATION_GATE_DIR}"
write_summary "phase5_production_readiness=${PHASE5_READINESS_DIR}"
write_summary "phase5_debug_bundle=${PHASE5_DEBUG_BUNDLE_DIR}"
write_summary "webrtc_first_production_gate=${PHASE2_OUTPUT_ROOT}"
if [[ "${PHASE5_DRY_RUN}" != "1" ]]; then
  write_summary "phase5_release_evidence=${RELEASE_EVIDENCE_JSON}"
  write_summary "phase5_release_evidence_summary=${RELEASE_EVIDENCE_SUMMARY}"
fi
write_summary "phase5_production_gate_metrics=${PHASE5_GATE_METRICS_PROM}"
write_gate_metrics
write_summary "manifest=${MANIFEST_FILE}"
write_manifest

echo "phase5_production_gate ${PHASE5_DRY_RUN:+dry_}run status=$(if [[ "${PHASE5_DRY_RUN}" == "1" ]]; then echo dry_run; else echo pass; fi) output_root=${OUTPUT_ROOT}"
