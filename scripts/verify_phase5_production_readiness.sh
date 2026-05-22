#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WEBRTC_PREFIX="${WEBRTC_PREFIX:-${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/phase5_production_readiness}"
SUMMARY_FILE="${SUMMARY_FILE:-${OUTPUT_DIR}/phase5_production_readiness_summary.txt}"
LOG_DIR="${LOG_DIR:-${OUTPUT_DIR}/logs}"
NEXT_REQUIRED_ACTIONS_FILE="${OUTPUT_DIR}/next_required_actions.txt"
NEXT_REQUIRED_ACTIONS_JSON="${OUTPUT_DIR}/next_required_actions.json"
READINESS_REPORT_JSON="${OUTPUT_DIR}/readiness_report.json"
RISK_MILESTONE_REPORT_JSON="${OUTPUT_DIR}/risk_milestone_report.json"
RISK_MILESTONE_SUMMARY_FILE="${OUTPUT_DIR}/risk_milestone_summary.txt"
READINESS_METRICS_PROM="${OUTPUT_DIR}/phase5_production_readiness_metrics.prom"
CHECK_RECORDS_JSONL="${OUTPUT_DIR}/check_records.jsonl"
ACTION_RECORDS_JSONL="${OUTPUT_DIR}/action_records.jsonl"
FILES_FILE="${FILES_FILE:-${OUTPUT_DIR}/files.txt}"
MANIFEST_FILE="${MANIFEST_FILE:-${OUTPUT_DIR}/manifest.sha256}"
PHASE2_EVIDENCE_BUNDLE_DIR="${PHASE2_EVIDENCE_BUNDLE_DIR:-}"
EXTERNAL_PHASE2_IMPORT_DIR="${EXTERNAL_PHASE2_IMPORT_DIR:-${OUTPUT_DIR}/external_phase2_evidence_import}"

SOAK_MINUTES="${SOAK_MINUTES:-120}"
MIN_PRODUCTION_SOAK_MINUTES="${MIN_PRODUCTION_SOAK_MINUTES:-120}"
ALLOW_XVFB_RENDERER="${ALLOW_XVFB_RENDERER:-0}"
REAL_RENDERER_USE_XVFB="${REAL_RENDERER_USE_XVFB:-$([[ "${ALLOW_XVFB_RENDERER}" == "1" ]] && echo auto || echo 0)}"
CAPTURE_LIBRARY_DIR="${CAPTURE_LIBRARY_DIR:-${SDK_ROOT}/capture_library}"
CAPTURE_LIBRARY_MANIFEST="${CAPTURE_LIBRARY_MANIFEST:-${CAPTURE_LIBRARY_DIR}/manifest.csv}"
CAPTURE_WIDTH="${CAPTURE_WIDTH:-1280}"
CAPTURE_HEIGHT="${CAPTURE_HEIGHT:-720}"
CAPTURE_FRAMES="${CAPTURE_FRAMES:-120}"
REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES:-indoor_face outdoor_walking low_light_noise screen_text high_motion scene_cut}"
REQUIRE_READY="${REQUIRE_READY:-0}"

RUN_WEBRTC_MODULES="${RUN_WEBRTC_MODULES:-1}"
RUN_CAPTURE_MANIFEST="${RUN_CAPTURE_MANIFEST:-1}"
RUN_REAL_RENDERER="${RUN_REAL_RENDERER:-1}"

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}" "${LOG_DIR}"
: >"${NEXT_REQUIRED_ACTIONS_FILE}"
: >"${CHECK_RECORDS_JSONL}"
: >"${ACTION_RECORDS_JSONL}"

failures=0
skipped_count=0
action_count=0

write_summary() {
  printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

action_for_check() {
  local name="$1"
  case "${name}" in
    script_*)
      local script="${name#script_}"
      printf 'restore_or_make_executable script=scripts/%s before rerunning readiness' "${script}"
      ;;
    soak_config)
      printf 'set SOAK_MINUTES>=%s for the formal production gate' "${MIN_PRODUCTION_SOAK_MINUTES}"
      ;;
    webrtc_modules)
      printf 'build_or_install WebRTC modules and set PREFIX or WEBRTC_PREFIX, then run scripts/verify_webrtc_modules.sh with REQUIRE_ALL=1'
      ;;
    capture_manifest)
      printf 'provide formal capture library manifest.csv with required categories and set CAPTURE_LIBRARY_DIR/CAPTURE_LIBRARY_MANIFEST'
      ;;
    real_renderer)
      printf 'run on a host with a real display/GPU renderer and rerun scripts/verify_real_renderer_smoke.sh with REQUIRE_REAL_RENDERER=1'
      ;;
    external_phase2_evidence_bundle)
      printf 'provide a Phase-2 evidence bundle from the formal renderer/capture/soak host and set PHASE2_EVIDENCE_BUNDLE_DIR'
      ;;
    git_worktree_clean)
      printf 'commit_or_stash tracked source changes before generating formal Phase-5 production evidence'
      ;;
    *)
      printf 'fix check=%s and rerun scripts/verify_phase5_production_readiness.sh' "${name}"
      ;;
  esac
}

record_check_json() {
  local name="$1"
  local status="$2"
  local detail="$3"
  python3 - "${CHECK_RECORDS_JSONL}" "${name}" "${status}" "${detail}" <<'PY'
import json
import sys

path, name, status, detail = sys.argv[1:5]
record = {
    "check": name,
    "status": status,
    "detail": detail,
}
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, sort_keys=True) + "\n")
PY
}

record_action_json() {
  local name="$1"
  local status="$2"
  local reason="$3"
  local required="$4"
  python3 - "${ACTION_RECORDS_JSONL}" "${name}" "${status}" "${reason}" "${required}" <<'PY'
import json
import sys

path, name, status, reason, required = sys.argv[1:6]
record = {
    "action": name,
    "status": status,
    "reason": reason,
    "required": required,
}
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, sort_keys=True) + "\n")
PY
}

record_action() {
  local name="$1"
  local status="$2"
  local reason="$3"
  local required
  required="$(action_for_check "${name}")"
  printf 'action=%s status=%s reason=%s required=%s\n' \
    "${name}" "${status}" "${reason}" "${required}" \
    >>"${NEXT_REQUIRED_ACTIONS_FILE}"
  record_action_json "${name}" "${status}" "${reason}" "${required}"
  action_count=$((action_count + 1))
}

record_fail() {
  local name="$1"
  local reason="$2"
  write_summary "check=${name} status=fail reason=${reason}"
  record_check_json "${name}" "fail" "${reason}"
  record_action "${name}" "fail" "${reason}"
  failures=$((failures + 1))
}

record_pass() {
  local name="$1"
  local detail="$2"
  write_summary "check=${name} status=pass ${detail}"
  record_check_json "${name}" "pass" "${detail}"
}

record_skip() {
  local name="$1"
  local reason="$2"
  write_summary "check=${name} status=skipped ${reason}"
  record_check_json "${name}" "skipped" "${reason}"
  record_action "${name}" "skipped" "${reason}"
  skipped_count=$((skipped_count + 1))
}

run_check() {
  local name="$1"
  shift
  local log_file="${LOG_DIR}/${name}.log"
  write_summary "check=${name} status=running log=${log_file}"
  if "$@" >"${log_file}" 2>&1; then
    record_pass "${name}" "log=${log_file}"
  else
    local status=$?
    record_fail "${name}" "exit=${status} log=${log_file}"
  fi
}

write_readiness_reports() {
  local readiness_status="$1"
  python3 - \
    "${READINESS_REPORT_JSON}" \
    "${NEXT_REQUIRED_ACTIONS_JSON}" \
    "${RISK_MILESTONE_REPORT_JSON}" \
    "${RISK_MILESTONE_SUMMARY_FILE}" \
    "${READINESS_METRICS_PROM}" \
    "${CHECK_RECORDS_JSONL}" \
    "${ACTION_RECORDS_JSONL}" \
    "${readiness_status}" \
    "${failures}" \
    "${skipped_count}" \
    "${action_count}" \
    "${SDK_ROOT}" \
    "${WEBRTC_PREFIX}" \
    "${SOAK_MINUTES}" \
    "${MIN_PRODUCTION_SOAK_MINUTES}" \
    "${ALLOW_XVFB_RENDERER}" \
    "${REAL_RENDERER_USE_XVFB}" \
    "${CAPTURE_LIBRARY_DIR}" \
    "${CAPTURE_LIBRARY_MANIFEST}" \
    "${REQUIRE_READY}" \
    "${PHASE2_EVIDENCE_BUNDLE_DIR}" <<'PY'
import json
import os
import sys

(
    report_path,
    actions_path,
    risk_report_path,
    risk_summary_path,
    readiness_metrics_path,
    checks_jsonl,
    actions_jsonl,
    readiness_status,
    failure_count,
    skipped_count,
    action_count,
    sdk_root,
    web_rtc_prefix,
    soak_minutes,
    min_soak_minutes,
    allow_xvfb_renderer,
    real_renderer_use_xvfb,
    capture_library_dir,
    capture_library_manifest,
    require_ready,
    phase2_evidence_bundle_dir,
) = sys.argv[1:22]


def read_jsonl(path):
    records = []
    if not os.path.exists(path):
        return records
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records


def parse_number(value):
    try:
        number = float(value)
    except ValueError:
        return value
    if number.is_integer():
        return int(number)
    return number


checks = read_jsonl(checks_jsonl)
actions = read_jsonl(actions_jsonl)
checks_by_name = {item.get("check"): item for item in checks}
actions_by_name = {item.get("action"): item for item in actions}


def check_status(name):
    return checks_by_name.get(name, {}).get("status", "missing")


def check_evidence(names):
    evidence = []
    for name in names:
        item = checks_by_name.get(name)
        if item is None:
            evidence.append({"check": name, "status": "missing", "detail": "not_recorded"})
        else:
            evidence.append(item)
    return evidence


def action_blockers(names):
    blockers = []
    for name in names:
        item = actions_by_name.get(name)
        if item is not None:
            blockers.append(item)
    return blockers


def gate_backed_status(names):
    return "gate_available" if all(check_status(name) == "pass" for name in names) else "blocked"


def gate_backed_blockers(names):
    return [
        {
            "action": name,
            "status": check_status(name),
            "required": f"restore_or_rerun {name}",
        }
        for name in names
        if check_status(name) != "pass"
    ]


if phase2_evidence_bundle_dir:
    production_checks = [
        "git_worktree_clean",
        "soak_config",
        "webrtc_modules",
        "external_phase2_evidence_bundle",
    ]
else:
    production_checks = [
        "git_worktree_clean",
        "soak_config",
        "webrtc_modules",
        "capture_manifest",
        "real_renderer",
    ]
logging_checks = [
    "script_verify_phase5_logging.sh",
    "script_run_phase5_implementation_gate.sh",
    "script_verify_phase5_implementation_gate.sh",
]
observability_checks = [
    "script_verify_phase5_metrics.sh",
    "script_verify_phase5_alerts.sh",
    "script_collect_phase5_debug_bundle.sh",
    "script_verify_phase5_debug_bundle.sh",
]
minimal_udp_checks = [
    "script_verify_phase5_minimal_udp_external_app.sh",
    "script_run_phase5_implementation_gate.sh",
]
release_checks = [
    "script_verify_phase5_release_contract.sh",
    "script_verify_phase5_error_contract.sh",
    "script_verify_no_selfmade_media_stack.sh",
]

production_blockers = action_blockers(production_checks)
milestones = [
    {
        "id": "M1",
        "name": "production_evidence_closure",
        "status": "ready" if readiness_status == "ready" else "blocked",
        "required_evidence": production_checks
        + ["passed_phase5_production_gate", "passed_phase5_completion_audit"],
        "current_evidence": check_evidence(production_checks),
        "blockers": production_blockers,
    },
    {
        "id": "M2",
        "name": "logging_fileization",
        "status": gate_backed_status(logging_checks),
        "required_evidence": [
            "phase5_logging implementation gate",
            "role log files",
            "rotation",
            "stop flush",
            "async queue drop accounting",
        ],
        "current_evidence": check_evidence(logging_checks),
        "blockers": gate_backed_blockers(logging_checks),
    },
    {
        "id": "M3",
        "name": "metrics_alerts_debug_bundle",
        "status": gate_backed_status(observability_checks),
        "required_evidence": [
            "phase5_metrics implementation gate",
            "phase5_alerts implementation gate",
            "debug bundle collect and verify",
        ],
        "current_evidence": check_evidence(observability_checks),
        "blockers": gate_backed_blockers(observability_checks),
    },
    {
        "id": "M4",
        "name": "external_minimal_udp_app",
        "status": gate_backed_status(minimal_udp_checks),
        "required_evidence": [
            "external minimal UDP app builds from install prefix",
            "selftest emits logs metrics alerts",
        ],
        "current_evidence": check_evidence(minimal_udp_checks),
        "blockers": gate_backed_blockers(minimal_udp_checks),
    },
    {
        "id": "M5",
        "name": "release_contract",
        "status": gate_backed_status(release_checks),
        "required_evidence": [
            "release contract gate",
            "error contract gate",
            "no self-made media stack gate",
        ],
        "current_evidence": check_evidence(release_checks),
        "blockers": gate_backed_blockers(release_checks),
    },
    {
        "id": "M6",
        "name": "fanout_evaluation",
        "status": "deferred",
        "required_evidence": [
            "explicit scope decision after M1-M5",
            "receiver-level observability before any fanout work",
        ],
        "current_evidence": [
            {
                "check": "phase5_scope",
                "status": "deferred",
                "detail": "P5 baseline excludes multi-receiver fanout",
            }
        ],
        "blockers": [],
    },
]

risk_environment_status = "controlled" if readiness_status == "ready" else "blocked"
risks = [
    {
        "id": "R1",
        "name": "logging_realtime_overhead",
        "status": "control_available" if gate_backed_status(logging_checks) == "gate_available" else "open",
        "mitigation": [
            "file logging uses bounded async queue",
            "default info logging avoids packet-level detail",
            "dropped_log_count is recorded under pressure",
        ],
        "evidence": check_evidence(logging_checks),
    },
    {
        "id": "R2",
        "name": "logging_sensitive_material",
        "status": "control_available" if gate_backed_status(logging_checks) == "gate_available" else "open",
        "mitigation": [
            "config dump is redacted",
            "runtime paths are excluded from config dump",
            "media bytes and auth material are not emitted",
        ],
        "evidence": check_evidence(logging_checks),
    },
    {
        "id": "R3",
        "name": "alert_noise",
        "status": "control_available" if gate_backed_status(observability_checks) == "gate_available" else "open",
        "mitigation": [
            "alert policy separates availability media_quality and network_qos",
            "weak-network degradation is not treated as fatal by itself",
            "debug bundle records rule counts and first problem",
        ],
        "evidence": check_evidence(observability_checks),
    },
    {
        "id": "R4",
        "name": "production_environment_dependency",
        "status": risk_environment_status,
        "mitigation": [
            "readiness gate records missing formal environment evidence",
            "production gate requires formal capture manifest and real renderer",
            "completion audit requires passed production evidence",
        ],
        "evidence": check_evidence(production_checks),
        "required_actions": production_blockers,
    },
    {
        "id": "R5",
        "name": "fanout_scope_creep",
        "status": "deferred",
        "mitigation": [
            "P5 baseline does not include multi-receiver fanout",
            "fanout is evaluated only after production observability is closed",
        ],
        "evidence": [
            {
                "check": "phase5_scope",
                "status": "deferred",
                "detail": "multi-receiver fanout is not a P5 baseline gate",
            }
        ],
    },
]

blocked_milestones = [
    item["id"] for item in milestones if item["status"] == "blocked"
]
risk_doc = {
    "schema_version": 1,
    "source": "phase5_production_readiness",
    "readiness_status": readiness_status,
    "phase5_basis_status": (
        "ready_for_formal_production_gate"
        if readiness_status == "ready"
        else "not_ready_for_formal_production_gate"
    ),
    "formal_completion_status": "requires_passed_phase5_production_gate",
    "blocked_milestones": blocked_milestones,
    "milestones": milestones,
    "risks": risks,
    "next_required_actions": actions,
}

actions_doc = {
    "schema_version": 1,
    "source": "phase5_production_readiness",
    "readiness_status": readiness_status,
    "action_count": len(actions),
    "actions": actions,
}
report = {
    "schema_version": 1,
    "source": "phase5_production_readiness",
    "readiness_status": readiness_status,
    "failure_count": int(failure_count),
    "skipped_count": int(skipped_count),
    "action_count": int(action_count),
    "requirements": {
        "sdk_root": sdk_root,
        "web_rtc_prefix": web_rtc_prefix,
        "soak_minutes": parse_number(soak_minutes),
        "min_production_soak_minutes": parse_number(min_soak_minutes),
        "allow_xvfb_renderer": allow_xvfb_renderer == "1",
        "real_renderer_use_xvfb": real_renderer_use_xvfb,
        "capture_library_dir": capture_library_dir,
        "capture_library_manifest": capture_library_manifest,
        "phase2_evidence_bundle_dir": phase2_evidence_bundle_dir,
        "require_ready": require_ready == "1",
    },
    "checks": checks,
    "next_required_actions": actions,
}

for path, document in (
    (report_path, report),
    (actions_path, actions_doc),
    (risk_report_path, risk_doc),
):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(document, fh, indent=2, sort_keys=True)
        fh.write("\n")

with open(risk_summary_path, "w", encoding="utf-8") as fh:
    fh.write(f"phase5_basis_status={risk_doc['phase5_basis_status']}\n")
    fh.write(f"formal_completion_status={risk_doc['formal_completion_status']}\n")
    fh.write(f"blocked_milestones={','.join(blocked_milestones) or 'none'}\n")
    for item in milestones:
        fh.write(f"milestone={item['id']} status={item['status']} name={item['name']}\n")
    for item in risks:
        fh.write(f"risk={item['id']} status={item['status']} name={item['name']}\n")


def prom_escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def prom_labels(**labels):
    items = [
        f'{key}="{prom_escape(value)}"'
        for key, value in sorted(labels.items())
        if value is not None and value != ""
    ]
    return "{" + ",".join(items) + "}" if items else ""


def status_value(status, expected):
    return 1 if status == expected else 0


def prom_number(value, default=0):
    number = parse_number(value)
    return number if isinstance(number, (int, float)) else default


check_status_values = ("pass", "fail", "skipped", "missing")
milestone_status_values = ("ready", "blocked", "gate_available", "deferred")
risk_status_values = ("controlled", "blocked", "control_available", "open", "deferred")
with open(readiness_metrics_path, "w", encoding="utf-8") as fh:
    fh.write("# HELP webrtc_qos_phase5_production_readiness_info Phase-5 production readiness metadata marker.\n")
    fh.write("# TYPE webrtc_qos_phase5_production_readiness_info gauge\n")
    fh.write(
        "webrtc_qos_phase5_production_readiness_info"
        f"{prom_labels(source='phase5_production_readiness', readiness_status=readiness_status, phase5_basis_status=risk_doc['phase5_basis_status'], formal_completion_status=risk_doc['formal_completion_status'])} 1\n"
    )
    fh.write("# HELP webrtc_qos_phase5_production_readiness_failures_total Phase-5 readiness failed check count.\n")
    fh.write("# TYPE webrtc_qos_phase5_production_readiness_failures_total gauge\n")
    fh.write(f"webrtc_qos_phase5_production_readiness_failures_total {failure_count}\n")
    fh.write("# HELP webrtc_qos_phase5_production_readiness_skipped_total Phase-5 readiness skipped check count.\n")
    fh.write("# TYPE webrtc_qos_phase5_production_readiness_skipped_total gauge\n")
    fh.write(f"webrtc_qos_phase5_production_readiness_skipped_total {skipped_count}\n")
    fh.write("# HELP webrtc_qos_phase5_production_readiness_actions_total Phase-5 readiness remediation action count.\n")
    fh.write("# TYPE webrtc_qos_phase5_production_readiness_actions_total gauge\n")
    fh.write(f"webrtc_qos_phase5_production_readiness_actions_total {action_count}\n")
    fh.write("# HELP webrtc_qos_phase5_production_readiness_soak_minutes Configured production soak minutes.\n")
    fh.write("# TYPE webrtc_qos_phase5_production_readiness_soak_minutes gauge\n")
    fh.write(f"webrtc_qos_phase5_production_readiness_soak_minutes {prom_number(soak_minutes)}\n")
    fh.write("# HELP webrtc_qos_phase5_production_readiness_min_soak_minutes Required minimum production soak minutes.\n")
    fh.write("# TYPE webrtc_qos_phase5_production_readiness_min_soak_minutes gauge\n")
    fh.write(f"webrtc_qos_phase5_production_readiness_min_soak_minutes {prom_number(min_soak_minutes)}\n")
    fh.write("# HELP webrtc_qos_phase5_production_readiness_check_status Check status marker by check and status.\n")
    fh.write("# TYPE webrtc_qos_phase5_production_readiness_check_status gauge\n")
    for item in checks:
        check = item.get("check", "")
        status = item.get("status", "missing")
        for expected in check_status_values:
            fh.write(
                "webrtc_qos_phase5_production_readiness_check_status"
                f"{prom_labels(check=check, status=expected)} {status_value(status, expected)}\n"
            )
    fh.write("# HELP webrtc_qos_phase5_production_readiness_milestone_status Milestone status marker by milestone and status.\n")
    fh.write("# TYPE webrtc_qos_phase5_production_readiness_milestone_status gauge\n")
    for item in milestones:
        status = item.get("status", "")
        for expected in milestone_status_values:
            fh.write(
                "webrtc_qos_phase5_production_readiness_milestone_status"
                f"{prom_labels(milestone=item.get('id', ''), name=item.get('name', ''), status=expected)} {status_value(status, expected)}\n"
            )
    fh.write("# HELP webrtc_qos_phase5_production_readiness_risk_status Risk status marker by risk and status.\n")
    fh.write("# TYPE webrtc_qos_phase5_production_readiness_risk_status gauge\n")
    for item in risks:
        status = item.get("status", "")
        for expected in risk_status_values:
            fh.write(
                "webrtc_qos_phase5_production_readiness_risk_status"
                f"{prom_labels(risk=item.get('id', ''), name=item.get('name', ''), status=expected)} {status_value(status, expected)}\n"
            )
    fh.write("# HELP webrtc_qos_phase5_production_readiness_action_required Remediation action marker.\n")
    fh.write("# TYPE webrtc_qos_phase5_production_readiness_action_required gauge\n")
    if actions:
        for item in actions:
            fh.write(
                "webrtc_qos_phase5_production_readiness_action_required"
                f"{prom_labels(action=item.get('action', ''), status=item.get('status', ''), reason=item.get('reason', ''))} 1\n"
            )
    else:
        fh.write(
            "webrtc_qos_phase5_production_readiness_action_required"
            f"{prom_labels(action='none', status='none', reason='no_required_actions')} 0\n"
        )
PY
}

write_manifest() {
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
}

write_summary "phase5_production_readiness=running"
write_summary "sdk_root=${SDK_ROOT}"
write_summary "webrtc_prefix=${WEBRTC_PREFIX}"
write_summary "output_dir=${OUTPUT_DIR}"
write_summary "soak_minutes=${SOAK_MINUTES}"
write_summary "min_production_soak_minutes=${MIN_PRODUCTION_SOAK_MINUTES}"
write_summary "allow_xvfb_renderer=${ALLOW_XVFB_RENDERER}"
write_summary "real_renderer_use_xvfb=${REAL_RENDERER_USE_XVFB}"
write_summary "capture_library_dir=${CAPTURE_LIBRARY_DIR}"
write_summary "capture_library_manifest=${CAPTURE_LIBRARY_MANIFEST}"
write_summary "phase2_evidence_bundle_dir=${PHASE2_EVIDENCE_BUNDLE_DIR}"
write_summary "require_ready=${REQUIRE_READY}"
if git -C "${SDK_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
  write_summary "git_head=$(git -C "${SDK_ROOT}" rev-parse HEAD)"
  write_summary "git_branch=$(git -C "${SDK_ROOT}" rev-parse --abbrev-ref HEAD)"
  git_status_log="${LOG_DIR}/git_tracked_status.log"
  git -C "${SDK_ROOT}" status --short --untracked-files=no >"${git_status_log}"
  if [[ -s "${git_status_log}" ]]; then
    write_summary "git_tracked_worktree_clean=0"
    record_fail "git_worktree_clean" "tracked_changes_present log=${git_status_log}"
  else
    write_summary "git_tracked_worktree_clean=1"
    record_pass "git_worktree_clean" "tracked_changes=0 log=${git_status_log}"
  fi
else
  write_summary "git_tracked_worktree_clean=0"
  record_fail "git_worktree_clean" "not_a_git_checkout"
fi

for script in \
    run_phase5_implementation_gate.sh \
    verify_phase5_implementation_gate.sh \
    verify_phase5_logging.sh \
    verify_phase5_metrics.sh \
    verify_phase5_alerts.sh \
    verify_phase5_error_contract.sh \
    verify_phase5_minimal_udp_external_app.sh \
    verify_phase5_release_contract.sh \
    verify_no_selfmade_media_stack.sh \
    collect_phase5_debug_bundle.sh \
    verify_phase5_debug_bundle.sh \
    verify_webrtc_modules.sh \
    verify_capture_library_manifest.sh \
    verify_real_renderer_smoke.sh \
    import_phase5_phase2_evidence_bundle.sh \
    run_phase5_production_gate.sh \
    verify_phase5_production_gate.sh \
    verify_phase5_completion_audit.sh; do
  if [[ -x "${SDK_ROOT}/scripts/${script}" ]]; then
    record_pass "script_${script}" "path=scripts/${script}"
  else
    record_fail "script_${script}" "missing_or_not_executable=scripts/${script}"
  fi
done

if python3 - "${SOAK_MINUTES}" "${MIN_PRODUCTION_SOAK_MINUTES}" <<'PY'
import sys
soak = float(sys.argv[1])
minimum = float(sys.argv[2])
raise SystemExit(0 if soak >= minimum else 1)
PY
then
  record_pass "soak_config" "SOAK_MINUTES=${SOAK_MINUTES}"
else
  record_fail "soak_config" "SOAK_MINUTES=${SOAK_MINUTES}<${MIN_PRODUCTION_SOAK_MINUTES}"
fi

if [[ "${RUN_WEBRTC_MODULES}" == "1" ]]; then
  run_check "webrtc_modules" \
    env PREFIX="${WEBRTC_PREFIX}" REQUIRE_ALL=1 \
      "${SDK_ROOT}/scripts/verify_webrtc_modules.sh"
else
  record_skip "webrtc_modules" "RUN_WEBRTC_MODULES=${RUN_WEBRTC_MODULES}"
fi

if [[ -n "${PHASE2_EVIDENCE_BUNDLE_DIR}" ]]; then
  run_check "external_phase2_evidence_bundle" \
    env SDK_ROOT="${SDK_ROOT}" \
      OUTPUT_ROOT="${EXTERNAL_PHASE2_IMPORT_DIR}" \
      PHASE2_EVIDENCE_BUNDLE_DIR="${PHASE2_EVIDENCE_BUNDLE_DIR}" \
      MIN_PRODUCTION_SOAK_MINUTES="${MIN_PRODUCTION_SOAK_MINUTES}" \
      ALLOW_XVFB_RENDERER="${ALLOW_XVFB_RENDERER}" \
      ALLOW_FIXTURE_CAPTURE=0 \
      REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES}" \
      "${SDK_ROOT}/scripts/import_phase5_phase2_evidence_bundle.sh"
  if [[ -s "${EXTERNAL_PHASE2_IMPORT_DIR}/phase2_external_evidence_import.json" ]]; then
    record_pass "capture_manifest" \
      "source=external_phase2_evidence_bundle report=${EXTERNAL_PHASE2_IMPORT_DIR}/phase2_external_evidence_import.json"
    record_pass "real_renderer" \
      "source=external_phase2_evidence_bundle report=${EXTERNAL_PHASE2_IMPORT_DIR}/phase2_external_evidence_import.json"
  fi
else
  if [[ "${RUN_CAPTURE_MANIFEST}" == "1" ]]; then
    run_check "capture_manifest" \
      env SDK_ROOT="${SDK_ROOT}" \
        CAPTURE_LIBRARY_DIR="${CAPTURE_LIBRARY_DIR}" \
        CAPTURE_LIBRARY_MANIFEST="${CAPTURE_LIBRARY_MANIFEST}" \
        REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES}" \
        CAPTURE_WIDTH="${CAPTURE_WIDTH}" \
        CAPTURE_HEIGHT="${CAPTURE_HEIGHT}" \
        MIN_CAPTURE_FRAMES="${CAPTURE_FRAMES}" \
        SUMMARY_FILE="${OUTPUT_DIR}/capture_manifest_summary.txt" \
        "${SDK_ROOT}/scripts/verify_capture_library_manifest.sh"
  else
    record_skip "capture_manifest" "RUN_CAPTURE_MANIFEST=${RUN_CAPTURE_MANIFEST}"
  fi

  if [[ "${RUN_REAL_RENDERER}" == "1" ]]; then
    run_check "real_renderer" \
      env SDK_ROOT="${SDK_ROOT}" \
        OUTPUT_DIR="${OUTPUT_DIR}/real_renderer" \
        REQUIRE_REAL_RENDERER=1 \
        USE_XVFB="${REAL_RENDERER_USE_XVFB}" \
        FRAMES=5 \
        "${SDK_ROOT}/scripts/verify_real_renderer_smoke.sh"
  else
    record_skip "real_renderer" "RUN_REAL_RENDERER=${RUN_REAL_RENDERER}"
  fi
fi

if [[ "${failures}" -eq 0 && "${skipped_count}" -eq 0 ]]; then
  readiness_status="ready"
else
  readiness_status="not_ready"
fi

write_summary "failure_count=${failures}"
write_summary "skipped_count=${skipped_count}"
write_summary "action_count=${action_count}"
write_summary "next_required_actions_file=${NEXT_REQUIRED_ACTIONS_FILE}"
write_summary "next_required_actions_json=${NEXT_REQUIRED_ACTIONS_JSON}"
write_summary "readiness_report_json=${READINESS_REPORT_JSON}"
write_summary "risk_milestone_report_json=${RISK_MILESTONE_REPORT_JSON}"
write_summary "risk_milestone_summary_file=${RISK_MILESTONE_SUMMARY_FILE}"
write_summary "readiness_metrics_prom=${READINESS_METRICS_PROM}"
write_summary "check_records_jsonl=${CHECK_RECORDS_JSONL}"
write_summary "action_records_jsonl=${ACTION_RECORDS_JSONL}"
write_summary "phase5_production_readiness_status=${readiness_status}"
if [[ "${readiness_status}" != "ready" ]]; then
  write_summary "next_required_actions=fix_failed_checks_then_run_phase5_production_gate_with_SOAK_MINUTES_ge_${MIN_PRODUCTION_SOAK_MINUTES}"
fi
write_readiness_reports "${readiness_status}"
write_summary "files=${FILES_FILE}"
write_summary "manifest=${MANIFEST_FILE}"
write_manifest

if rg -q 'payload|annexb_bytes|rtp_bytes|token|secret|password' \
  "${SUMMARY_FILE}" \
  "${NEXT_REQUIRED_ACTIONS_FILE}" \
  "${NEXT_REQUIRED_ACTIONS_JSON}" \
  "${READINESS_REPORT_JSON}" \
  "${RISK_MILESTONE_REPORT_JSON}" \
  "${RISK_MILESTONE_SUMMARY_FILE}" \
  "${READINESS_METRICS_PROM}" \
  "${CHECK_RECORDS_JSONL}" \
  "${ACTION_RECORDS_JSONL}"; then
  echo "phase5 production readiness failed: sensitive field in summary" >&2
  exit 1
fi

if [[ "${REQUIRE_READY}" == "1" &&
    ( "${failures}" -ne 0 || "${skipped_count}" -ne 0 ) ]]; then
  exit 1
fi

echo "phase5_production_readiness status=$(if [[ "${failures}" -eq 0 && "${skipped_count}" -eq 0 ]]; then echo ready; else echo not_ready; fi) output_dir=${OUTPUT_DIR}"
