#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/phase5_completion_audit}"
SUMMARY_FILE="${SUMMARY_FILE:-${OUTPUT_DIR}/phase5_completion_audit_summary.txt}"
PHASE5_GATE_DIR="${PHASE5_GATE_DIR:-}"
PHASE5_DEBUG_BUNDLE_DIR="${PHASE5_DEBUG_BUNDLE_DIR:-${SDK_ROOT}/artifacts/phase5_debug_bundle}"
REQUIRE_PRODUCTION_EVIDENCE="${REQUIRE_PRODUCTION_EVIDENCE:-1}"
ALLOW_DRY_RUN_GATE="${ALLOW_DRY_RUN_GATE:-0}"

mkdir -p "${OUTPUT_DIR}"
rm -f "${SUMMARY_FILE}"

write_summary() {
  printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
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
require_doc_pattern README.md 'run_phase5_production_gate.sh' readme_production_gate
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
require_doc_pattern scripts/verify_phase5_metrics.sh \
  'validated_metrics_rotation' metrics_rotation_gate
require_doc_pattern scripts/verify_phase5_alerts.sh \
  'validated_alert_rotation' alerts_rotation_gate

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
  exit 0
fi

if [[ "${failures}" -eq 0 ]]; then
  write_summary "phase5_completion_status=implemented_without_required_production_evidence"
  write_summary "phase5_completion_audit=pass_non_production"
  write_summary "pass_count=${pass_count}"
  write_summary "warning_count=${warnings}"
  exit 0
fi

write_summary "phase5_completion_status=incomplete"
write_summary "phase5_completion_audit=fail"
write_summary "pass_count=${pass_count}"
write_summary "warning_count=${warnings}"
write_summary "failure_count=${failures}"
write_summary "next_required_actions=run_phase5_production_gate_with_SOAK_MINUTES_ge_120_real_renderer_pass_formal_capture_library"
exit 1
