#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/webrtc_first_phase2_evidence_bundle}"

SMOKE_VERIFY_DIR="${SMOKE_VERIFY_DIR:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_smoke}"
QOE_VERIFY_DIR="${QOE_VERIFY_DIR:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_qoe}"
PRODUCTION_VERIFY_DIR="${PRODUCTION_VERIFY_DIR:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_production}"
PRODUCTION_SOAK_DIR="${PRODUCTION_SOAK_DIR:-${PRODUCTION_VERIFY_DIR}/production_soak}"
REAL_RENDERER_SOURCE_DIR="${REAL_RENDERER_SOURCE_DIR:-${PRODUCTION_VERIFY_DIR}/real_renderer}"
CAPTURE_LIBRARY_SOURCE_DIR="${CAPTURE_LIBRARY_SOURCE_DIR:-${PRODUCTION_VERIFY_DIR}/capture_library}"

REQUIRE_COMPLETE="${REQUIRE_COMPLETE:-0}"
INCLUDE_LOGS="${INCLUDE_LOGS:-1}"

SUMMARY_FILE="${OUTPUT_DIR}/phase2_evidence_bundle_summary.txt"
METADATA_FILE="${OUTPUT_DIR}/metadata.env"
FILES_FILE="${OUTPUT_DIR}/files.txt"
MANIFEST_FILE="${OUTPUT_DIR}/manifest.sha256"

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

missing_count=0

write_summary() {
  printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

mark_missing() {
  local name="$1"
  local path="$2"
  write_summary "artifact=${name} status=missing source=${path}"
  missing_count=$((missing_count + 1))
}

copy_file() {
  local name="$1"
  local src="$2"
  local dst="$3"
  if [[ -s "${src}" ]]; then
    mkdir -p "$(dirname "${dst}")"
    cp -a "${src}" "${dst}"
    write_summary "artifact=${name} status=copied source=${src} dest=${dst}"
  else
    mark_missing "${name}" "${src}"
  fi
}

copy_dir_if_exists() {
  local name="$1"
  local src="$2"
  local dst="$3"
  if [[ -d "${src}" ]]; then
    mkdir -p "$(dirname "${dst}")"
    cp -a "${src}" "${dst}"
    write_summary "artifact=${name} status=copied source=${src} dest=${dst}"
  else
    mark_missing "${name}" "${src}"
  fi
}

{
  printf 'SDK_ROOT=%q\n' "${SDK_ROOT}"
  printf 'OUTPUT_DIR=%q\n' "${OUTPUT_DIR}"
  printf 'SMOKE_VERIFY_DIR=%q\n' "${SMOKE_VERIFY_DIR}"
  printf 'QOE_VERIFY_DIR=%q\n' "${QOE_VERIFY_DIR}"
  printf 'PRODUCTION_VERIFY_DIR=%q\n' "${PRODUCTION_VERIFY_DIR}"
  printf 'PRODUCTION_SOAK_DIR=%q\n' "${PRODUCTION_SOAK_DIR}"
  printf 'REAL_RENDERER_SOURCE_DIR=%q\n' "${REAL_RENDERER_SOURCE_DIR}"
  printf 'CAPTURE_LIBRARY_SOURCE_DIR=%q\n' "${CAPTURE_LIBRARY_SOURCE_DIR}"
  printf 'REQUIRE_COMPLETE=%q\n' "${REQUIRE_COMPLETE}"
  printf 'INCLUDE_LOGS=%q\n' "${INCLUDE_LOGS}"
  printf 'COLLECTED_AT_UTC=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if git -C "${SDK_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'GIT_HEAD=%q\n' "$(git -C "${SDK_ROOT}" rev-parse HEAD)"
  fi
} >"${METADATA_FILE}"

write_summary "phase2_evidence_bundle=collecting"
write_summary "output_dir=${OUTPUT_DIR}"
write_summary "include_logs=${INCLUDE_LOGS}"

copy_file smoke_summary \
  "${SMOKE_VERIFY_DIR}/phase2_verify_summary.txt" \
  "${OUTPUT_DIR}/smoke/phase2_verify_summary.txt"
copy_file qoe_summary \
  "${QOE_VERIFY_DIR}/phase2_verify_summary.txt" \
  "${OUTPUT_DIR}/qoe/phase2_verify_summary.txt"
copy_file qoe_low_rps_summary \
  "${QOE_VERIFY_DIR}/low_rps_low_bitrate/webrtc_first_low_rps_low_bitrate_summary.txt" \
  "${OUTPUT_DIR}/qoe/low_rps_low_bitrate/webrtc_first_low_rps_low_bitrate_summary.txt"
copy_file qoe_recovery_distribution_summary \
  "${QOE_VERIFY_DIR}/recovery_distribution/recovery_distribution_summary.txt" \
  "${OUTPUT_DIR}/qoe/recovery_distribution/recovery_distribution_summary.txt"

copy_file production_phase2_summary \
  "${PRODUCTION_VERIFY_DIR}/phase2_verify_summary.txt" \
  "${OUTPUT_DIR}/production/phase2_verify_summary.txt"
copy_file production_soak_summary \
  "${PRODUCTION_SOAK_DIR}/webrtc_first_qoe_production_soak_summary.txt" \
  "${OUTPUT_DIR}/production_soak/webrtc_first_qoe_production_soak_summary.txt"
copy_file production_soak_config \
  "${PRODUCTION_SOAK_DIR}/webrtc_first_qoe_production_soak_config.env" \
  "${OUTPUT_DIR}/production_soak/webrtc_first_qoe_production_soak_config.env"
copy_file production_soak_csv \
  "${PRODUCTION_SOAK_DIR}/webrtc_first_qoe_production_soak.csv" \
  "${OUTPUT_DIR}/production_soak/webrtc_first_qoe_production_soak.csv"
copy_file production_soak_archive \
  "${PRODUCTION_SOAK_DIR}/webrtc_first_qoe_production_soak_archive.tar.gz" \
  "${OUTPUT_DIR}/production_soak/webrtc_first_qoe_production_soak_archive.tar.gz"
copy_dir_if_exists production_soak_archive_dir \
  "${PRODUCTION_SOAK_DIR}/archive" \
  "${OUTPUT_DIR}/production_soak/archive"

copy_file real_renderer_summary \
  "${REAL_RENDERER_SOURCE_DIR}/real_renderer_summary.txt" \
  "${OUTPUT_DIR}/real_renderer/real_renderer_summary.txt"
copy_file real_renderer_metrics \
  "${REAL_RENDERER_SOURCE_DIR}/real_renderer_metrics.csv" \
  "${OUTPUT_DIR}/real_renderer/real_renderer_metrics.csv"

copy_file capture_manifest_summary \
  "${CAPTURE_LIBRARY_SOURCE_DIR}/capture_manifest_summary.txt" \
  "${OUTPUT_DIR}/capture_library/capture_manifest_summary.txt"
copy_file capture_qoe_csv \
  "${CAPTURE_LIBRARY_SOURCE_DIR}/webrtc_first_qoe_capture_library_720p.csv" \
  "${OUTPUT_DIR}/capture_library/webrtc_first_qoe_capture_library_720p.csv"
copy_file capture_qoe_log \
  "${CAPTURE_LIBRARY_SOURCE_DIR}/webrtc_first_qoe_capture_library_720p.log" \
  "${OUTPUT_DIR}/capture_library/webrtc_first_qoe_capture_library_720p.log"
copy_file capture_qoe_summary \
  "${CAPTURE_LIBRARY_SOURCE_DIR}/capture_qoe_summary.txt" \
  "${OUTPUT_DIR}/capture_library/capture_qoe_summary.txt"

if [[ "${INCLUDE_LOGS}" == "1" ]]; then
  copy_dir_if_exists smoke_logs "${SMOKE_VERIFY_DIR}/logs" "${OUTPUT_DIR}/smoke/logs"
  copy_dir_if_exists qoe_logs "${QOE_VERIFY_DIR}/logs" "${OUTPUT_DIR}/qoe/logs"
  copy_dir_if_exists production_logs "${PRODUCTION_VERIFY_DIR}/logs" "${OUTPUT_DIR}/production/logs"
  copy_dir_if_exists production_soak_cycles "${PRODUCTION_SOAK_DIR}/cycles" "${OUTPUT_DIR}/production_soak/cycles"
fi

write_summary "metadata=${METADATA_FILE}"
write_summary "files=${FILES_FILE}"
write_summary "manifest=${MANIFEST_FILE}"
write_summary "missing_count=${missing_count}"

if [[ "${missing_count}" -eq 0 ]]; then
  write_summary "phase2_evidence_bundle_status=complete_inputs_present"
else
  write_summary "phase2_evidence_bundle_status=incomplete_inputs"
fi

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

if [[ "${REQUIRE_COMPLETE}" == "1" && "${missing_count}" -ne 0 ]]; then
  exit 1
fi
