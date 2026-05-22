#!/usr/bin/env bash
set -euo pipefail

GATE_DIR="${GATE_DIR:-${1:-/root/webrtc_qos_sdk/artifacts/phase5_production_gate/latest}}"
REQUIRE_PASS="${REQUIRE_PASS:-0}"

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
require_file "${GATE_DIR}/phase5_production_gate_summary.txt"
require_file "${GATE_DIR}/files.txt"
require_file "${GATE_DIR}/manifest.sha256"

(
  cd "${GATE_DIR}"
  sha256sum -c manifest.sha256 >/dev/null
)

require_file "${GATE_DIR}/logs/phase5_release_contract.log"
require_file "${GATE_DIR}/logs/collect_phase5_debug_bundle.log"
require_file "${GATE_DIR}/logs/verify_phase5_debug_bundle.log"
require_file "${GATE_DIR}/logs/webrtc_first_production_gate.log"

rg -q '^phase5_production_gate=running$' \
  "${GATE_DIR}/phase5_production_gate_summary.txt" ||
  fail "summary missing gate start marker"
rg -q '^step=phase5_release_contract status=(planned|pass)' \
  "${GATE_DIR}/phase5_production_gate_summary.txt" ||
  fail "summary missing release contract step"
rg -q '^step=collect_phase5_debug_bundle status=(planned|pass)' \
  "${GATE_DIR}/phase5_production_gate_summary.txt" ||
  fail "summary missing debug bundle collect step"
rg -q '^step=verify_phase5_debug_bundle status=(planned|pass)' \
  "${GATE_DIR}/phase5_production_gate_summary.txt" ||
  fail "summary missing debug bundle verify step"
rg -q '^step=webrtc_first_production_gate status=(planned|pass)' \
  "${GATE_DIR}/phase5_production_gate_summary.txt" ||
  fail "summary missing production gate step"

if [[ "${REQUIRE_PASS}" == "1" ]]; then
  rg -q '^phase5_production_gate_status=pass$' \
    "${GATE_DIR}/phase5_production_gate_summary.txt" ||
    fail "phase5 production gate did not pass"
  phase2_summary="${GATE_DIR}/webrtc_first_production_gate/phase2_production_gate_summary.txt"
  require_file "${phase2_summary}"
  rg -q '^phase2_production_gate_status=pass$' "${phase2_summary}" ||
    fail "underlying WebRTC-first production gate did not pass"
else
  rg -q '^phase5_production_gate_status=(dry_run|pass)$' \
    "${GATE_DIR}/phase5_production_gate_summary.txt" ||
    fail "summary missing dry_run/pass status"
fi

if rg -q 'payload|annexb_bytes|rtp_bytes|token|secret|password' \
  "${GATE_DIR}/metadata.txt" "${GATE_DIR}/phase5_production_gate_summary.txt"; then
  fail "gate metadata/summary contains payload-like or sensitive field"
fi

echo "phase5_production_gate_verify pass gate_dir=${GATE_DIR} require_pass=${REQUIRE_PASS}"
