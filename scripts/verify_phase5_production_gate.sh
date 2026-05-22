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

(
  cd "${GATE_DIR}"
  sha256sum -c manifest.sha256 >/dev/null
)

summary_has() {
  local pattern="$1"
  rg -q "${pattern}" "${SUMMARY_FILE}"
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
  require_file "${readiness_dir}/logs/webrtc_modules.log"
  require_file "${readiness_dir}/logs/capture_manifest.log"
  require_file "${readiness_dir}/logs/real_renderer.log"
  (
    cd "${readiness_dir}"
    sha256sum -c manifest.sha256 >/dev/null
  )
  rg -q '^phase5_production_readiness_status=not_ready$' "${readiness_summary}" ||
    fail "failed readiness evidence did not record not_ready"
  if ! rg -q '^check=(capture_manifest|real_renderer|webrtc_modules|soak_config) status=fail ' \
      "${readiness_summary}" &&
      ! rg -q '^check=(capture_manifest|real_renderer|webrtc_modules) status=skipped ' \
        "${readiness_summary}"; then
    fail "failed readiness evidence has no actionable failed/skipped readiness check"
  fi
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
  summary_has '^phase5_implementation_gate=' ||
    fail "passed gate summary missing phase5 implementation gate directory"
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
  require_file "${readiness_dir}/logs/webrtc_modules.log"
  require_file "${readiness_dir}/logs/capture_manifest.log"
  require_file "${readiness_dir}/logs/real_renderer.log"
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
  rg -q '^check=webrtc_modules status=pass ' "${readiness_summary}" ||
    fail "phase5 production readiness missing WebRTC modules pass"
  rg -q '^check=capture_manifest status=pass ' "${readiness_summary}" ||
    fail "phase5 production readiness missing capture manifest pass"
  rg -q '^check=real_renderer status=pass ' "${readiness_summary}" ||
    fail "phase5 production readiness missing real renderer pass"
}

require_phase2_completion_evidence() {
  local phase2_dir="${GATE_DIR}/webrtc_first_production_gate"
  local phase2_summary="${phase2_dir}/phase2_production_gate_summary.txt"
  local evidence_bundle="${phase2_dir}/phase2_evidence_bundle"
  local completion_audit="${phase2_dir}/phase2_completion_audit/phase2_completion_audit_summary.txt"

  require_file "${phase2_summary}"
  rg -q '^phase2_production_gate_status=pass$' "${phase2_summary}" ||
    fail "underlying WebRTC-first production gate did not pass"
  rg -q '^evidence_bundle=' "${phase2_summary}" ||
    fail "underlying production gate summary missing evidence bundle pointer"
  rg -q '^completion_audit=' "${phase2_summary}" ||
    fail "underlying production gate summary missing completion audit pointer"

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
  rg -q '^check=evidence_bundle status=pass ' "${completion_audit}" ||
    fail "underlying completion audit missing passed evidence bundle check"
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
  summary_has '^step=webrtc_first_production_gate status=(planned|pass|fail)( |$)' ||
    fail "summary missing production gate step"
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
  summary_has '^step=webrtc_first_production_gate status=pass ' ||
    fail "production gate step did not pass"
  require_success_implementation_gate
  require_success_debug_bundle
  require_success_readiness
  require_phase2_completion_evidence
else
  summary_has '^phase5_production_gate_status=(dry_run|pass|fail)$' ||
    fail "summary missing dry_run/pass/fail status"
  if summary_has '^phase5_production_gate_status=fail$'; then
    summary_has '^step=[^ ]+ status=fail ' ||
      fail "failed gate summary missing failed step"
    require_failed_implementation_evidence
    require_failed_readiness_evidence
    require_failed_gate_debug_bundle
  elif summary_has '^phase5_production_gate_status=pass$'; then
    require_success_implementation_gate
    require_success_readiness
    require_success_debug_bundle
    require_phase2_completion_evidence
  fi
fi

if rg -q 'payload|annexb_bytes|rtp_bytes|token|secret|password' \
  "${GATE_DIR}/metadata.txt" "${SUMMARY_FILE}"; then
  fail "gate metadata/summary contains payload-like or sensitive field"
fi

echo "phase5_production_gate_verify pass gate_dir=${GATE_DIR} require_pass=${REQUIRE_PASS}"
