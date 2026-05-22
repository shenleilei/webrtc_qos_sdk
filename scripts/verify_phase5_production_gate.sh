#!/usr/bin/env bash
set -euo pipefail

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
}

summary_has '^phase5_production_gate=running$' ||
  fail "summary missing gate start marker"
summary_has '^step=phase5_release_contract status=(planned|pass|fail|skipped)( |$)' ||
  fail "summary missing release contract step"

if summary_has '^step=phase5_release_contract status=(planned|pass|fail)( |$)'; then
  require_file "${GATE_DIR}/logs/phase5_release_contract.log"
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
  summary_has '^step=webrtc_first_production_gate status=(planned|pass|fail)( |$)' ||
    fail "summary missing production gate step"
fi

if [[ "${REQUIRE_PASS}" == "1" ]]; then
  summary_has '^phase5_production_gate_status=pass$' ||
    fail "phase5 production gate did not pass"
  summary_has '^step=phase5_release_contract status=pass ' ||
    fail "release contract step did not pass"
  summary_has '^step=collect_phase5_debug_bundle status=pass ' ||
    fail "debug bundle collect step did not pass"
  summary_has '^step=verify_phase5_debug_bundle status=pass ' ||
    fail "debug bundle verify step did not pass"
  summary_has '^step=webrtc_first_production_gate status=pass ' ||
    fail "production gate step did not pass"
  phase2_summary="${GATE_DIR}/webrtc_first_production_gate/phase2_production_gate_summary.txt"
  require_file "${phase2_summary}"
  rg -q '^phase2_production_gate_status=pass$' "${phase2_summary}" ||
    fail "underlying WebRTC-first production gate did not pass"
else
  summary_has '^phase5_production_gate_status=(dry_run|pass|fail)$' ||
    fail "summary missing dry_run/pass/fail status"
  if summary_has '^phase5_production_gate_status=fail$'; then
    summary_has '^step=[^ ]+ status=fail ' ||
      fail "failed gate summary missing failed step"
    require_failed_gate_debug_bundle
  fi
fi

if rg -q 'payload|annexb_bytes|rtp_bytes|token|secret|password' \
  "${GATE_DIR}/metadata.txt" "${SUMMARY_FILE}"; then
  fail "gate metadata/summary contains payload-like or sensitive field"
fi

echo "phase5_production_gate_verify pass gate_dir=${GATE_DIR} require_pass=${REQUIRE_PASS}"
