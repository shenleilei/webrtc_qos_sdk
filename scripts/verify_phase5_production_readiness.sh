#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WEBRTC_PREFIX="${WEBRTC_PREFIX:-${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/phase5_production_readiness}"
SUMMARY_FILE="${SUMMARY_FILE:-${OUTPUT_DIR}/phase5_production_readiness_summary.txt}"
LOG_DIR="${LOG_DIR:-${OUTPUT_DIR}/logs}"
FILES_FILE="${FILES_FILE:-${OUTPUT_DIR}/files.txt}"
MANIFEST_FILE="${MANIFEST_FILE:-${OUTPUT_DIR}/manifest.sha256}"

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

failures=0
skipped_count=0

write_summary() {
  printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

record_fail() {
  local name="$1"
  local reason="$2"
  write_summary "check=${name} status=fail reason=${reason}"
  failures=$((failures + 1))
}

record_pass() {
  local name="$1"
  local detail="$2"
  write_summary "check=${name} status=pass ${detail}"
}

record_skip() {
  local name="$1"
  local reason="$2"
  write_summary "check=${name} status=skipped ${reason}"
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
write_summary "require_ready=${REQUIRE_READY}"
if git -C "${SDK_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
  write_summary "git_head=$(git -C "${SDK_ROOT}" rev-parse HEAD)"
  write_summary "git_branch=$(git -C "${SDK_ROOT}" rev-parse --abbrev-ref HEAD)"
fi

for script in \
    verify_webrtc_modules.sh \
    verify_capture_library_manifest.sh \
    verify_real_renderer_smoke.sh \
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

write_summary "failure_count=${failures}"
write_summary "skipped_count=${skipped_count}"
if [[ "${failures}" -eq 0 && "${skipped_count}" -eq 0 ]]; then
  write_summary "phase5_production_readiness_status=ready"
else
  write_summary "phase5_production_readiness_status=not_ready"
  write_summary "next_required_actions=fix_failed_checks_then_run_phase5_production_gate_with_SOAK_MINUTES_ge_${MIN_PRODUCTION_SOAK_MINUTES}"
fi
write_summary "files=${FILES_FILE}"
write_summary "manifest=${MANIFEST_FILE}"
write_manifest

if rg -q 'payload|annexb_bytes|rtp_bytes|token|secret|password' \
  "${SUMMARY_FILE}"; then
  echo "phase5 production readiness failed: sensitive field in summary" >&2
  exit 1
fi

if [[ "${REQUIRE_READY}" == "1" &&
    ( "${failures}" -ne 0 || "${skipped_count}" -ne 0 ) ]]; then
  exit 1
fi

echo "phase5_production_readiness status=$(if [[ "${failures}" -eq 0 && "${skipped_count}" -eq 0 ]]; then echo ready; else echo not_ready; fi) output_dir=${OUTPUT_DIR}"
