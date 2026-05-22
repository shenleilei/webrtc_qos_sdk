#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WEBRTC_PREFIX="${WEBRTC_PREFIX:-${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${SDK_ROOT}/artifacts/webrtc_first_phase2_production_gate}"
VERIFY_OUTPUT_DIR="${VERIFY_OUTPUT_DIR:-${OUTPUT_ROOT}/phase2_verify_production}"
BUNDLE_OUTPUT_DIR="${BUNDLE_OUTPUT_DIR:-${OUTPUT_ROOT}/phase2_evidence_bundle}"
AUDIT_OUTPUT_DIR="${AUDIT_OUTPUT_DIR:-${OUTPUT_ROOT}/phase2_completion_audit}"
PREFLIGHT_DIR="${PREFLIGHT_DIR:-${OUTPUT_ROOT}/preflight}"
LOG_DIR="${LOG_DIR:-${OUTPUT_ROOT}/logs}"
SUMMARY_FILE="${SUMMARY_FILE:-${OUTPUT_ROOT}/phase2_production_gate_summary.txt}"

SOAK_MINUTES="${SOAK_MINUTES:-120}"
MIN_PRODUCTION_SOAK_MINUTES="${MIN_PRODUCTION_SOAK_MINUTES:-120}"
SOAK_CYCLES="${SOAK_CYCLES:-1}"
PREFLIGHT_ONLY="${PREFLIGHT_ONLY:-0}"
ALLOW_XVFB_RENDERER="${ALLOW_XVFB_RENDERER:-0}"
REAL_RENDERER_USE_XVFB="${REAL_RENDERER_USE_XVFB:-$([[ "${ALLOW_XVFB_RENDERER}" == "1" ]] && echo auto || echo 0)}"

FACADE_FRAMES="${FACADE_FRAMES:-120}"
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
        "phase2 production gate failed: invalid production soak configuration: "
        + ", ".join(errors)
    )
PY

mkdir -p "${OUTPUT_ROOT}" "${PREFLIGHT_DIR}" "${LOG_DIR}"
rm -f "${SUMMARY_FILE}"

log_summary() {
  printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

run_step() {
  local name="$1"
  shift
  local log_file="${LOG_DIR}/${name}.log"
  log_summary "step=${name} status=running"
  if "$@" >"${log_file}" 2>&1; then
    log_summary "step=${name} status=pass log=${log_file}"
  else
    local status=$?
    log_summary "step=${name} status=fail exit=${status} log=${log_file}"
    tail -n 80 "${log_file}" >&2 || true
    exit "${status}"
  fi
}

preflight_failures=0

run_preflight_step() {
  local name="$1"
  shift
  local log_file="${PREFLIGHT_DIR}/${name}.log"
  log_summary "preflight=${name} status=running"
  if "$@" >"${log_file}" 2>&1; then
    log_summary "preflight=${name} status=pass log=${log_file}"
  else
    local status=$?
    preflight_failures=$((preflight_failures + 1))
    log_summary "preflight=${name} status=fail exit=${status} log=${log_file}"
    tail -n 60 "${log_file}" >&2 || true
  fi
}

log_summary "phase2_production_gate=running"
log_summary "sdk_root=${SDK_ROOT}"
log_summary "webrtc_prefix=${WEBRTC_PREFIX}"
log_summary "output_root=${OUTPUT_ROOT}"
log_summary "soak_minutes=${SOAK_MINUTES}"
log_summary "min_production_soak_minutes=${MIN_PRODUCTION_SOAK_MINUTES}"
log_summary "allow_xvfb_renderer=${ALLOW_XVFB_RENDERER}"
log_summary "real_renderer_use_xvfb=${REAL_RENDERER_USE_XVFB}"
log_summary "capture_library_dir=${CAPTURE_LIBRARY_DIR}"
log_summary "capture_library_manifest=${CAPTURE_LIBRARY_MANIFEST}"

run_preflight_step webrtc_modules \
  env PREFIX="${WEBRTC_PREFIX}" REQUIRE_ALL=1 \
    "${SDK_ROOT}/scripts/verify_webrtc_modules.sh"

run_preflight_step capture_manifest \
  env SDK_ROOT="${SDK_ROOT}" \
    CAPTURE_LIBRARY_DIR="${CAPTURE_LIBRARY_DIR}" \
    CAPTURE_LIBRARY_MANIFEST="${CAPTURE_LIBRARY_MANIFEST}" \
    REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES}" \
    CAPTURE_WIDTH="${CAPTURE_WIDTH}" \
    CAPTURE_HEIGHT="${CAPTURE_HEIGHT}" \
    MIN_CAPTURE_FRAMES="${CAPTURE_FRAMES}" \
    SUMMARY_FILE="${PREFLIGHT_DIR}/capture_manifest_summary.txt" \
    "${SDK_ROOT}/scripts/verify_capture_library_manifest.sh"

run_preflight_step real_renderer \
  env SDK_ROOT="${SDK_ROOT}" \
    OUTPUT_DIR="${PREFLIGHT_DIR}/real_renderer" \
    REQUIRE_REAL_RENDERER=1 \
    USE_XVFB="${REAL_RENDERER_USE_XVFB}" \
    FRAMES=5 \
    "${SDK_ROOT}/scripts/verify_real_renderer_smoke.sh"

if [[ "${preflight_failures}" -ne 0 ]]; then
  log_summary "phase2_production_gate_status=preflight_failed"
  log_summary "preflight_failure_count=${preflight_failures}"
  exit 1
fi

if [[ "${PREFLIGHT_ONLY}" == "1" ]]; then
  log_summary "phase2_production_gate_status=preflight_pass"
  exit 0
fi

run_step phase2_verify_production \
  env SDK_ROOT="${SDK_ROOT}" WEBRTC_PREFIX="${WEBRTC_PREFIX}" \
    OUTPUT_DIR="${VERIFY_OUTPUT_DIR}" \
    VERIFY_LEVEL=production \
    FACADE_FRAMES="${FACADE_FRAMES}" \
    QOE_FRAMES="${QOE_FRAMES}" QOE_WIDTH="${QOE_WIDTH}" \
    QOE_HEIGHT="${QOE_HEIGHT}" QOE_CONTENT_MODE="${QOE_CONTENT_MODE}" \
    SOAK_CYCLES="${SOAK_CYCLES}" SOAK_MINUTES="${SOAK_MINUTES}" \
    PRODUCTION_SOAK_MINUTES="${SOAK_MINUTES}" \
    RUN_REAL_RENDERER=1 REQUIRE_REAL_RENDERER=1 \
    USE_XVFB="${REAL_RENDERER_USE_XVFB}" \
    RUN_CAPTURE_LIBRARY=1 REQUIRE_CAPTURE_LIBRARY=1 \
    CAPTURE_LIBRARY_DIR="${CAPTURE_LIBRARY_DIR}" \
    CAPTURE_LIBRARY_MANIFEST="${CAPTURE_LIBRARY_MANIFEST}" \
    CAPTURE_FRAMES="${CAPTURE_FRAMES}" \
    CAPTURE_WIDTH="${CAPTURE_WIDTH}" \
    CAPTURE_HEIGHT="${CAPTURE_HEIGHT}" \
    CAPTURE_SCENARIOS="${CAPTURE_SCENARIOS}" \
    CAPTURE_SEEDS="${CAPTURE_SEEDS}" \
    "${SDK_ROOT}/scripts/verify_webrtc_first_phase2.sh"

run_step collect_evidence_bundle \
  env SDK_ROOT="${SDK_ROOT}" \
    OUTPUT_DIR="${BUNDLE_OUTPUT_DIR}" \
    SMOKE_VERIFY_DIR="${VERIFY_OUTPUT_DIR}" \
    QOE_VERIFY_DIR="${VERIFY_OUTPUT_DIR}" \
    PRODUCTION_VERIFY_DIR="${VERIFY_OUTPUT_DIR}" \
    PRODUCTION_SOAK_DIR="${VERIFY_OUTPUT_DIR}/production_soak" \
    REAL_RENDERER_SOURCE_DIR="${VERIFY_OUTPUT_DIR}/real_renderer" \
    CAPTURE_LIBRARY_SOURCE_DIR="${VERIFY_OUTPUT_DIR}/capture_library" \
    REQUIRE_COMPLETE=1 \
    "${SDK_ROOT}/scripts/collect_webrtc_first_phase2_evidence_bundle.sh"

run_step completion_audit \
  env SDK_ROOT="${SDK_ROOT}" \
    OUTPUT_DIR="${AUDIT_OUTPUT_DIR}" \
    EVIDENCE_BUNDLE_DIR="${BUNDLE_OUTPUT_DIR}" \
    MIN_PRODUCTION_SOAK_MINUTES="${MIN_PRODUCTION_SOAK_MINUTES}" \
    ALLOW_XVFB_RENDERER="${ALLOW_XVFB_RENDERER}" \
    "${SDK_ROOT}/scripts/verify_webrtc_first_phase2_completion_audit.sh"

log_summary "phase2_production_gate_status=pass"
log_summary "phase2_verify_output=${VERIFY_OUTPUT_DIR}"
log_summary "evidence_bundle=${BUNDLE_OUTPUT_DIR}"
log_summary "completion_audit=${AUDIT_OUTPUT_DIR}"
log_summary "completion_audit_metrics=${AUDIT_OUTPUT_DIR}/phase2_completion_audit_metrics.prom"
