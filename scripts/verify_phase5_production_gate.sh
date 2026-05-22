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
require_file "${SUMMARY_FILE}"
require_file "${GATE_DIR}/files.txt"
require_file "${GATE_DIR}/manifest.sha256"

[[ -x "${SDK_ROOT}/scripts/verify_phase5_debug_bundle.sh" ]] ||
  fail "missing debug bundle verifier: ${SDK_ROOT}/scripts/verify_phase5_debug_bundle.sh"
[[ -x "${SDK_ROOT}/scripts/verify_phase5_implementation_gate.sh" ]] ||
  fail "missing implementation gate verifier: ${SDK_ROOT}/scripts/verify_phase5_implementation_gate.sh"
[[ -x "${SDK_ROOT}/scripts/verify_capture_library_qoe_csv.sh" ]] ||
  fail "missing capture QoE CSV verifier: ${SDK_ROOT}/scripts/verify_capture_library_qoe_csv.sh"
[[ -x "${SDK_ROOT}/scripts/verify_webrtc_first_qoe_production_soak_archive.sh" ]] ||
  fail "missing production soak archive verifier: ${SDK_ROOT}/scripts/verify_webrtc_first_qoe_production_soak_archive.sh"

(
  cd "${GATE_DIR}"
  sha256sum -c manifest.sha256 >/dev/null
)

summary_has() {
  local pattern="$1"
  rg -q "${pattern}" "${SUMMARY_FILE}"
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
    fi
    if [[ -f "${readiness_dir}/external_phase2_evidence_import/phase2_external_evidence_import.json" ]]; then
      python3 - "${readiness_dir}/external_phase2_evidence_import/phase2_external_evidence_import.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    report = json.load(fh)
if report.get("schema_version") != 1:
    raise SystemExit("external phase2 import schema_version mismatch")
if report.get("source") != "phase5_phase2_external_evidence_import":
    raise SystemExit("external phase2 import source mismatch")
artifacts = report.get("artifacts", {})
for key in (
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
  rg -q '^action=(capture_manifest|real_renderer|webrtc_modules|soak_config|external_phase2_evidence_bundle|script_[^ ]+) status=(fail|skipped) ' \
    "${readiness_dir}/next_required_actions.txt" ||
    fail "failed readiness evidence missing actionable remediation file"
  verify_readiness_json "${readiness_dir}" "not_ready"
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
  (
    cd "${implementation_dir}"
    sha256sum -c manifest.sha256 >/dev/null
  )
  rg -q '^phase5_implementation_gate_status=fail$' "${implementation_summary}" ||
    fail "failed implementation evidence did not record fail status"
  rg -q '^step=[^ ]+ status=fail ' "${implementation_summary}" ||
    fail "failed implementation evidence missing failed step"
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
    "phase2_completion_audit",
    "production_soak",
    "production_soak_raw_evidence",
    "real_renderer",
    "real_renderer_raw_evidence",
    "capture_library",
    "capture_qoe_raw_evidence",
    "evidence_bundle",
    "git_head_match",
):
    if checks.get(required) != "pass":
        raise SystemExit(f"external phase2 import missing pass check {required}")
artifacts = report.get("artifacts", {})
for key in (
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
    if not artifacts.get(key):
        raise SystemExit(f"external phase2 import missing artifact pointer {key}")
for section_name, keys in (
    ("production_soak", ("summary", "csv", "config", "archive")),
    ("real_renderer", ("summary", "metrics")),
    ("capture_library", ("manifest_summary", "qoe_csv", "qoe_summary")),
):
    section = report.get(section_name, {})
    for key in keys:
        if not section.get(key):
            raise SystemExit(
                f"external phase2 import missing {section_name}.{key}"
            )
PY
  else
    require_file "${readiness_dir}/logs/capture_manifest.log"
    require_file "${readiness_dir}/logs/real_renderer.log"
  fi
  (
    cd "${readiness_dir}"
    sha256sum -c manifest.sha256 >/dev/null
  )
  rg -q '^phase5_production_readiness_status=ready$' "${readiness_summary}" ||
    fail "phase5 production readiness was not ready"
  rg -q '^failure_count=0$' "${readiness_summary}" ||
    fail "phase5 production readiness recorded failures"
  rg -q '^skipped_count=0$' "${readiness_summary}" ||
    fail "phase5 production readiness recorded skipped checks"
  rg -q '^action_count=0$' "${readiness_summary}" ||
    fail "phase5 production readiness recorded remediation actions"
  rg -q '^check=webrtc_modules status=pass ' "${readiness_summary}" ||
    fail "phase5 production readiness missing WebRTC modules pass"
  rg -q '^check=capture_manifest status=pass ' "${readiness_summary}" ||
    fail "phase5 production readiness missing capture manifest pass"
  rg -q '^check=real_renderer status=pass ' "${readiness_summary}" ||
    fail "phase5 production readiness missing real renderer pass"
  if rg -q '^check=external_phase2_evidence_bundle status=pass ' "${readiness_summary}"; then
    rg -q '^check=capture_manifest status=pass source=external_phase2_evidence_bundle ' "${readiness_summary}" ||
      fail "external readiness missing capture manifest external source"
    rg -q '^check=real_renderer status=pass source=external_phase2_evidence_bundle ' "${readiness_summary}" ||
      fail "external readiness missing real renderer external source"
  fi
  verify_readiness_json "${readiness_dir}" "ready"
}

require_phase2_completion_evidence() {
  local phase2_dir="${GATE_DIR}/webrtc_first_production_gate"
  local phase2_summary="${phase2_dir}/phase2_production_gate_summary.txt"
  local evidence_bundle="${phase2_dir}/phase2_evidence_bundle"
  local completion_audit="${phase2_dir}/phase2_completion_audit/phase2_completion_audit_summary.txt"
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
  if rg -q '^phase2_evidence_source=external_bundle$' "${phase2_summary}"; then
    require_file "${phase2_dir}/phase2_external_evidence_import.json"
    require_file "${phase2_dir}/phase2_external_evidence_import.txt"
    rg -q '^import_status=pass$' "${phase2_dir}/phase2_external_evidence_import.txt" ||
      fail "imported Phase-2 evidence report did not pass"
    rg -q '^check=git_head_match status=pass$' "${phase2_dir}/phase2_external_evidence_import.txt" ||
      fail "imported Phase-2 evidence did not match git head"
  fi

  require_file "${evidence_bundle}/manifest.sha256"
  require_file "${evidence_bundle}/files.txt"
  (
    cd "${evidence_bundle}"
    sha256sum -c manifest.sha256 >/dev/null
  )

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
  require_file "${production_soak_summary}"
  require_file "${production_soak_csv}"
  require_file "${production_soak_config}"
  require_file "${production_soak_archive}"
  OUTPUT_DIR="${production_soak_dir}" REQUIRE_SOAK_TARBALL=1 \
    "${SDK_ROOT}/scripts/verify_webrtc_first_qoe_production_soak_archive.sh" >/dev/null
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
  rg -q '^real_renderer_status=pass$' "${real_renderer_summary}" ||
    fail "real renderer summary did not pass"
  if rg -q '^renderer_backend=xvfb$' "${real_renderer_summary}"; then
    fail "real renderer summary used xvfb backend"
  fi
  rg -q '^(frame,|metric,value)' "${real_renderer_metrics}" ||
    fail "real renderer metrics missing expected header"
  require_file "${evidence_bundle}/capture_library/capture_manifest_summary.txt"
  require_file "${evidence_bundle}/capture_library/webrtc_first_qoe_capture_library_720p.csv"
  require_file "${evidence_bundle}/capture_library/capture_qoe_summary.txt"
  rg -q '^capture_manifest_verification=true$' \
    "${evidence_bundle}/capture_library/capture_manifest_summary.txt" ||
    fail "capture manifest summary did not verify"
  rg -q '^capture_qoe_verification=true$' \
    "${evidence_bundle}/capture_library/capture_qoe_summary.txt" ||
    fail "capture QoE summary did not verify"
  local required_capture_categories
  required_capture_categories="$(
    awk -F= '$1=="required_categories"{gsub(/,/," ",$2); print $2}' \
      "${evidence_bundle}/capture_library/capture_qoe_summary.txt" | tail -1
  )"
  required_capture_categories="${required_capture_categories:-indoor_face outdoor_walking low_light_noise screen_text high_motion scene_cut}"
  CAPTURE_QOE_CSV="${evidence_bundle}/capture_library/webrtc_first_qoe_capture_library_720p.csv" \
    REQUIRED_CAPTURE_CATEGORIES="${required_capture_categories}" \
    "${SDK_ROOT}/scripts/verify_capture_library_qoe_csv.sh" >/dev/null
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
if float(requirements.get("soak_minutes", 0)) < float(
    requirements.get("min_production_soak_minutes", 120)
):
    raise SystemExit("release evidence soak minutes below minimum")
if requirements.get("multi_receiver_fanout") != "deferred_before_p5_completion":
    raise SystemExit("release evidence fanout requirement mismatch")

observability = doc.get("observability", {})
if observability.get("debug_bundle_slo_status") not in {"pass", "warn", "fail"}:
    raise SystemExit("release evidence missing debug bundle SLO status")
fanout = doc.get("fanout", {})
if fanout.get("status") != "deferred":
    raise SystemExit("release evidence fanout status must be deferred")

required_evidence = {
    "phase5_implementation_gate",
    "phase5_production_readiness",
    "phase5_debug_bundle",
    "phase2_production_gate",
    "phase2_completion_audit",
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
missing = required_evidence - by_id.keys()
if missing:
    raise SystemExit(f"release evidence missing ids: {sorted(missing)}")
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
    "phase5_implementation_gate",
    "phase5_production_readiness",
    "phase5_debug_bundle",
    "phase2_production_gate",
    "phase2_evidence_bundle",
    "phase2_completion_audit",
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

capture = doc.get("capture_library", {})
for key in ("manifest_summary", "qoe_csv", "qoe_summary"):
    rel = capture.get(key)
    if not rel or not os.path.exists(os.path.join(gate_dir, rel)):
        raise SystemExit(f"release evidence bad capture pointer {key}")

def normalize_rel(path):
    return os.path.normpath(path).replace(os.sep, "/")

phase2_evidence_bundle_rel = artifacts.get("phase2_evidence_bundle", "")
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

production_soak = doc.get("production_soak", {})
for key in ("summary", "csv", "config", "archive"):
    rel = production_soak.get(key)
    if not rel or not os.path.exists(os.path.join(gate_dir, rel)):
        raise SystemExit(f"release evidence bad production soak pointer {key}")
real_renderer = doc.get("real_renderer", {})
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

if evidence_number(production_soak, "soak_minutes") < 120:
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
if real_renderer.get("status") != "pass":
    raise SystemExit("release evidence real renderer did not pass")
if real_renderer.get("backend") == "xvfb":
    raise SystemExit("release evidence real renderer used xvfb backend")
if evidence_number(real_renderer, "rendered_frames") <= 0:
    raise SystemExit("release evidence real renderer rendered no frames")

def capture_number(key, default=0):
    value = capture.get(key, default)
    if value is None or value == "":
        value = default
    return float(value)

rows = int(capture.get("rows", 0) or 0)
pass_rows = int(capture.get("pass_rows", 0) or 0)
if rows <= 0 or pass_rows != rows:
    raise SystemExit("release evidence capture QoE rows are incomplete")
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
    "evidence=production_soak status=pass",
    "evidence=production_soak_csv status=pass",
    "evidence=real_renderer status=pass",
    "evidence=real_renderer_summary status=pass",
    "evidence=capture_library status=pass",
    "evidence=capture_qoe_csv status=pass",
    "production_soak_csv=",
    "production_soak_rows=",
    "real_renderer_summary=",
    "capture_qoe_csv=",
    "capture_qoe_rows=",
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
    summary_has '^step=[^ ]+ status=fail ' ||
      fail "failed gate summary missing failed step"
    if summary_has '^step=phase5_implementation_gate status=pass '; then
      require_success_implementation_gate
    fi
    require_failed_implementation_evidence
    require_failed_readiness_evidence
    require_failed_gate_debug_bundle
  elif summary_has '^phase5_production_gate_status=pass$'; then
    require_success_implementation_gate
    require_success_readiness
    require_success_debug_bundle
    require_phase2_completion_evidence
    require_release_evidence
  fi
fi

scan_files=("${GATE_DIR}/metadata.txt" "${SUMMARY_FILE}")
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
