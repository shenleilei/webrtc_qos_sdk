#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WEBRTC_PREFIX="${WEBRTC_PREFIX:-${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify}"
VERIFY_LEVEL="${VERIFY_LEVEL:-smoke}"
FACADE_FRAMES="${FACADE_FRAMES:-36}"
QOE_FRAMES="${QOE_FRAMES:-20}"
QOE_WIDTH="${QOE_WIDTH:-320}"
QOE_HEIGHT="${QOE_HEIGHT:-180}"
QOE_CONTENT_MODE="${QOE_CONTENT_MODE:-block_motion}"
SOAK_CYCLES="${SOAK_CYCLES:-1}"
SOAK_MINUTES="${SOAK_MINUTES:-0}"
PRODUCTION_SOAK_MINUTES="${PRODUCTION_SOAK_MINUTES:-120}"
RUN_REAL_RENDERER="${RUN_REAL_RENDERER:-auto}"
REQUIRE_REAL_RENDERER="${REQUIRE_REAL_RENDERER:-0}"
RUN_CAPTURE_LIBRARY="${RUN_CAPTURE_LIBRARY:-auto}"
REQUIRE_CAPTURE_LIBRARY="${REQUIRE_CAPTURE_LIBRARY:-0}"
CAPTURE_LIBRARY_DIR="${CAPTURE_LIBRARY_DIR:-${SDK_ROOT}/capture_library}"
CAPTURE_LIBRARY_MANIFEST="${CAPTURE_LIBRARY_MANIFEST:-${CAPTURE_LIBRARY_DIR}/manifest.csv}"
CAPTURE_FRAMES="${CAPTURE_FRAMES:-12}"
CAPTURE_WIDTH="${CAPTURE_WIDTH:-320}"
CAPTURE_HEIGHT="${CAPTURE_HEIGHT:-180}"
CAPTURE_SCENARIOS="${CAPTURE_SCENARIOS:-baseline}"
CAPTURE_SEEDS="${CAPTURE_SEEDS:-1}"

mkdir -p "${OUTPUT_DIR}/logs"
SUMMARY_FILE="${OUTPUT_DIR}/phase2_verify_summary.txt"
rm -f "${SUMMARY_FILE}"

case "${VERIFY_LEVEL}" in
  smoke|qoe|production) ;;
  *)
    echo "invalid VERIFY_LEVEL=${VERIFY_LEVEL}; expected smoke, qoe, or production" >&2
    exit 2
    ;;
esac

log_summary() {
  printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

run_step() {
  local name="$1"
  shift
  local log_file="${OUTPUT_DIR}/logs/${name}.log"
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

skip_step() {
  local name="$1"
  local reason="$2"
  log_summary "step=${name} status=skipped reason=${reason}"
}

log_summary "phase2_verify_level=${VERIFY_LEVEL}"
log_summary "sdk_root=${SDK_ROOT}"
log_summary "webrtc_prefix=${WEBRTC_PREFIX}"
log_summary "output_dir=${OUTPUT_DIR}"

run_step no_selfmade_media_stack \
  env SDK_ROOT="${SDK_ROOT}" PREFIX="${WEBRTC_PREFIX}" \
    "${SDK_ROOT}/scripts/verify_no_selfmade_media_stack.sh"

run_step webrtc_modules \
  env PREFIX="${WEBRTC_PREFIX}" REQUIRE_ALL=1 \
    "${SDK_ROOT}/scripts/verify_webrtc_modules.sh"

run_step cmake_package \
  env PREFIX="${WEBRTC_PREFIX}" \
    "${SDK_ROOT}/scripts/verify_cmake_package.sh"

run_step webrtc_first_loopback \
  env PREFIX="${WEBRTC_PREFIX}" \
    "${SDK_ROOT}/scripts/verify_webrtc_first_loopback.sh"

run_step webrtc_first_pacing_probe \
  env PREFIX="${WEBRTC_PREFIX}" \
    "${SDK_ROOT}/scripts/verify_webrtc_first_pacing_probe.sh"

run_step webrtc_first_roles \
  env PREFIX="${WEBRTC_PREFIX}" SDK_ROOT="${SDK_ROOT}" \
    "${SDK_ROOT}/scripts/verify_webrtc_first_roles.sh"

run_step facade_weak_network_matrix \
  env PREFIX="${WEBRTC_PREFIX}" OUTPUT_DIR="${OUTPUT_DIR}/facade_matrix" \
    FRAMES="${FACADE_FRAMES}" \
    "${SDK_ROOT}/scripts/run_webrtc_first_facade_matrix.sh"

if [[ "${VERIFY_LEVEL}" == "qoe" || "${VERIFY_LEVEL}" == "production" ]]; then
  run_step low_rps_low_bitrate_qoe \
    env SDK_ROOT="${SDK_ROOT}" WEBRTC_PREFIX="${WEBRTC_PREFIX}" \
      OUTPUT_DIR="${OUTPUT_DIR}/low_rps_low_bitrate" \
      QOE_FRAMES="${QOE_FRAMES}" QOE_WIDTH="${QOE_WIDTH}" \
      QOE_HEIGHT="${QOE_HEIGHT}" QOE_CONTENT_MODE="${QOE_CONTENT_MODE}" \
      "${SDK_ROOT}/scripts/run_webrtc_first_qoe_low_rps_low_bitrate_check.sh"

  run_step recovery_time_distribution \
    env OUTPUT_DIR="${OUTPUT_DIR}/recovery_distribution" \
      SUMMARY_FILE="${OUTPUT_DIR}/recovery_distribution/recovery_distribution_summary.txt" \
      "${SDK_ROOT}/scripts/verify_recovery_time_distribution.sh" \
      "${OUTPUT_DIR}/low_rps_low_bitrate/ffmpeg_qoe/webrtc_first_ffmpeg_qoe_low_rps_low_bitrate.csv"
else
  skip_step low_rps_low_bitrate_qoe "VERIFY_LEVEL=smoke"
  skip_step recovery_time_distribution "VERIFY_LEVEL=smoke"
fi

if [[ "${VERIFY_LEVEL}" == "production" ]]; then
  if [[ "${SOAK_MINUTES}" == "0" ]]; then
    SOAK_MINUTES="${PRODUCTION_SOAK_MINUTES}"
  fi
  run_step production_soak \
    env SDK_ROOT="${SDK_ROOT}" WEBRTC_PREFIX="${WEBRTC_PREFIX}" \
      OUTPUT_DIR="${OUTPUT_DIR}/production_soak" \
      SOAK_CYCLES="${SOAK_CYCLES}" SOAK_MINUTES="${SOAK_MINUTES}" \
      "${SDK_ROOT}/scripts/run_webrtc_first_qoe_production_soak.sh"

  if [[ "${RUN_REAL_RENDERER}" == "auto" ]]; then
    RUN_REAL_RENDERER=1
  fi
  if [[ "${RUN_CAPTURE_LIBRARY}" == "auto" ]]; then
    RUN_CAPTURE_LIBRARY=1
  fi
else
  if [[ "${RUN_REAL_RENDERER}" == "auto" ]]; then
    RUN_REAL_RENDERER=0
  fi
  if [[ "${RUN_CAPTURE_LIBRARY}" == "auto" ]]; then
    RUN_CAPTURE_LIBRARY=0
  fi
  skip_step production_soak "VERIFY_LEVEL=${VERIFY_LEVEL}"
fi

if [[ "${RUN_REAL_RENDERER}" == "1" ]]; then
  run_step real_renderer \
    env SDK_ROOT="${SDK_ROOT}" OUTPUT_DIR="${OUTPUT_DIR}/real_renderer" \
      REQUIRE_REAL_RENDERER="${REQUIRE_REAL_RENDERER}" \
      "${SDK_ROOT}/scripts/verify_real_renderer_smoke.sh"
else
  skip_step real_renderer "RUN_REAL_RENDERER=${RUN_REAL_RENDERER}"
fi

if [[ "${RUN_CAPTURE_LIBRARY}" == "1" ]]; then
  if [[ ! -d "${CAPTURE_LIBRARY_DIR}" ]]; then
    if [[ "${REQUIRE_CAPTURE_LIBRARY}" == "1" ]]; then
      log_summary "step=capture_library status=fail reason=missing_dir dir=${CAPTURE_LIBRARY_DIR}"
      exit 2
    fi
    skip_step capture_library "missing_dir=${CAPTURE_LIBRARY_DIR}"
  else
    run_step capture_library \
      env SDK_ROOT="${SDK_ROOT}" WEBRTC_PREFIX="${WEBRTC_PREFIX}" \
        OUTPUT_DIR="${OUTPUT_DIR}/capture_library" \
        CAPTURE_LIBRARY_DIR="${CAPTURE_LIBRARY_DIR}" \
        CAPTURE_LIBRARY_MANIFEST="${CAPTURE_LIBRARY_MANIFEST}" \
        REQUIRE_CAPTURE_MANIFEST=1 \
        FRAMES="${CAPTURE_FRAMES}" WIDTH="${CAPTURE_WIDTH}" \
        HEIGHT="${CAPTURE_HEIGHT}" SCENARIOS="${CAPTURE_SCENARIOS}" \
        SEEDS="${CAPTURE_SEEDS}" MIN_CAPTURE_FRAMES="${CAPTURE_FRAMES}" \
        "${SDK_ROOT}/scripts/run_webrtc_first_qoe_capture_library_720p.sh"
  fi
else
  skip_step capture_library "RUN_CAPTURE_LIBRARY=${RUN_CAPTURE_LIBRARY}"
fi

log_summary "phase2_verify_status=pass"
log_summary "summary=${SUMMARY_FILE}"
