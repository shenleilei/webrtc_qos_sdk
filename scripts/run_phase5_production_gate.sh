#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WEBRTC_PREFIX="${WEBRTC_PREFIX:-${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}}"
PHASE5_BUILD_ID="${PHASE5_BUILD_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${SDK_ROOT}/artifacts/phase5_production_gate/${PHASE5_BUILD_ID}}"
PHASE2_OUTPUT_ROOT="${PHASE2_OUTPUT_ROOT:-${OUTPUT_ROOT}/webrtc_first_production_gate}"
PHASE5_DEBUG_BUNDLE_DIR="${PHASE5_DEBUG_BUNDLE_DIR:-${OUTPUT_ROOT}/phase5_debug_bundle}"
FAILURE_DEBUG_BUNDLE_DIR="${FAILURE_DEBUG_BUNDLE_DIR:-${OUTPUT_ROOT}/failure_debug_bundle}"
PHASE5_READINESS_DIR="${PHASE5_READINESS_DIR:-${OUTPUT_ROOT}/phase5_production_readiness}"
LOG_DIR="${LOG_DIR:-${OUTPUT_ROOT}/logs}"
SUMMARY_FILE="${SUMMARY_FILE:-${OUTPUT_ROOT}/phase5_production_gate_summary.txt}"
METADATA_FILE="${METADATA_FILE:-${OUTPUT_ROOT}/metadata.txt}"
FILES_FILE="${FILES_FILE:-${OUTPUT_ROOT}/files.txt}"
MANIFEST_FILE="${MANIFEST_FILE:-${OUTPUT_ROOT}/manifest.sha256}"

SOAK_MINUTES="${SOAK_MINUTES:-120}"
MIN_PRODUCTION_SOAK_MINUTES="${MIN_PRODUCTION_SOAK_MINUTES:-${SOAK_MINUTES}}"
SOAK_CYCLES="${SOAK_CYCLES:-1}"
PREFLIGHT_ONLY="${PREFLIGHT_ONLY:-0}"
PHASE5_DRY_RUN="${PHASE5_DRY_RUN:-0}"
RUN_PHASE5_RELEASE_CONTRACT="${RUN_PHASE5_RELEASE_CONTRACT:-1}"
RUN_PHASE5_READINESS="${RUN_PHASE5_READINESS:-1}"
RUN_PHASE5_DEBUG_BUNDLE="${RUN_PHASE5_DEBUG_BUNDLE:-1}"
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

mkdir -p "${OUTPUT_ROOT}" "${LOG_DIR}"
rm -f "${SUMMARY_FILE}" "${METADATA_FILE}" "${FILES_FILE}" "${MANIFEST_FILE}"

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
      ! -name 'manifest.sha256' \
      ! -name 'files.txt' \
      | sed 's#^\./##' \
      | sort >"${FILES_FILE}"
    while IFS= read -r file; do
      sha256sum "${file}"
    done <"${FILES_FILE}" >"${MANIFEST_FILE}"
  )
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
    write_manifest
    tail -n 80 "${log_file}" >&2 || true
    exit "${status}"
  fi
}

require_script "${SDK_ROOT}/scripts/verify_phase5_release_contract.sh"
require_script "${SDK_ROOT}/scripts/verify_phase5_production_readiness.sh"
require_script "${SDK_ROOT}/scripts/collect_phase5_debug_bundle.sh"
require_script "${SDK_ROOT}/scripts/verify_phase5_debug_bundle.sh"
require_script "${SDK_ROOT}/scripts/run_webrtc_first_phase2_production_gate.sh"
require_script "${SDK_ROOT}/scripts/verify_webrtc_first_phase2_completion_audit.sh"

{
  printf 'PHASE5_BUILD_ID=%s\n' "${PHASE5_BUILD_ID}"
  printf 'SDK_ROOT=%s\n' "${SDK_ROOT}"
  printf 'WEBRTC_PREFIX=%s\n' "${WEBRTC_PREFIX}"
  printf 'OUTPUT_ROOT=%s\n' "${OUTPUT_ROOT}"
  printf 'PHASE2_OUTPUT_ROOT=%s\n' "${PHASE2_OUTPUT_ROOT}"
  printf 'PHASE5_DEBUG_BUNDLE_DIR=%s\n' "${PHASE5_DEBUG_BUNDLE_DIR}"
  printf 'FAILURE_DEBUG_BUNDLE_DIR=%s\n' "${FAILURE_DEBUG_BUNDLE_DIR}"
  printf 'PHASE5_READINESS_DIR=%s\n' "${PHASE5_READINESS_DIR}"
  printf 'SOAK_MINUTES=%s\n' "${SOAK_MINUTES}"
  printf 'MIN_PRODUCTION_SOAK_MINUTES=%s\n' "${MIN_PRODUCTION_SOAK_MINUTES}"
  printf 'SOAK_CYCLES=%s\n' "${SOAK_CYCLES}"
  printf 'PREFLIGHT_ONLY=%s\n' "${PREFLIGHT_ONLY}"
  printf 'PHASE5_DRY_RUN=%s\n' "${PHASE5_DRY_RUN}"
  printf 'RUN_PHASE5_RELEASE_CONTRACT=%s\n' "${RUN_PHASE5_RELEASE_CONTRACT}"
  printf 'RUN_PHASE5_READINESS=%s\n' "${RUN_PHASE5_READINESS}"
  printf 'RUN_PHASE5_DEBUG_BUNDLE=%s\n' "${RUN_PHASE5_DEBUG_BUNDLE}"
  printf 'ALLOW_XVFB_RENDERER=%s\n' "${ALLOW_XVFB_RENDERER}"
  printf 'REAL_RENDERER_USE_XVFB=%s\n' "${REAL_RENDERER_USE_XVFB}"
  printf 'CAPTURE_LIBRARY_DIR=%s\n' "${CAPTURE_LIBRARY_DIR}"
  printf 'CAPTURE_LIBRARY_MANIFEST=%s\n' "${CAPTURE_LIBRARY_MANIFEST}"
  printf 'COLLECTED_AT_UTC=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if git -C "${SDK_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'GIT_HEAD=%s\n' "$(git -C "${SDK_ROOT}" rev-parse HEAD)"
    printf 'GIT_BRANCH=%s\n' "$(git -C "${SDK_ROOT}" rev-parse --abbrev-ref HEAD)"
  fi
} >"${METADATA_FILE}"

write_summary "phase5_production_gate=running"
write_summary "sdk_root=${SDK_ROOT}"
write_summary "webrtc_prefix=${WEBRTC_PREFIX}"
write_summary "output_root=${OUTPUT_ROOT}"
write_summary "phase2_output_root=${PHASE2_OUTPUT_ROOT}"
write_summary "phase5_readiness_dir=${PHASE5_READINESS_DIR}"
write_summary "soak_minutes=${SOAK_MINUTES}"
write_summary "min_production_soak_minutes=${MIN_PRODUCTION_SOAK_MINUTES}"
write_summary "preflight_only=${PREFLIGHT_ONLY}"
write_summary "phase5_dry_run=${PHASE5_DRY_RUN}"
write_summary "capture_library_manifest=${CAPTURE_LIBRARY_MANIFEST}"

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

if [[ "${PHASE5_DRY_RUN}" == "1" ]]; then
  write_summary "phase5_production_gate_status=dry_run"
else
  write_summary "phase5_production_gate_status=pass"
fi
write_summary "phase5_metadata=${METADATA_FILE}"
write_summary "phase5_production_readiness=${PHASE5_READINESS_DIR}"
write_summary "phase5_debug_bundle=${PHASE5_DEBUG_BUNDLE_DIR}"
write_summary "webrtc_first_production_gate=${PHASE2_OUTPUT_ROOT}"
write_summary "manifest=${MANIFEST_FILE}"
write_manifest

echo "phase5_production_gate ${PHASE5_DRY_RUN:+dry_}run status=$(if [[ "${PHASE5_DRY_RUN}" == "1" ]]; then echo dry_run; else echo pass; fi) output_root=${OUTPUT_ROOT}"
