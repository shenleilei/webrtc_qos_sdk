#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/webrtc_first_phase2_completion_audit}"
SUMMARY_FILE="${SUMMARY_FILE:-${OUTPUT_DIR}/phase2_completion_audit_summary.txt}"
EVIDENCE_BUNDLE_DIR="${EVIDENCE_BUNDLE_DIR:-}"

SMOKE_SUMMARY="${SMOKE_SUMMARY:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_smoke/phase2_verify_summary.txt}"
QOE_SUMMARY="${QOE_SUMMARY:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_qoe/phase2_verify_summary.txt}"
PRODUCTION_SOAK_DIR="${PRODUCTION_SOAK_DIR:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_production/production_soak}"
REAL_RENDERER_SUMMARY="${REAL_RENDERER_SUMMARY:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_production/real_renderer/real_renderer_summary.txt}"
CAPTURE_MANIFEST_SUMMARY="${CAPTURE_MANIFEST_SUMMARY:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_production/capture_library/capture_manifest_summary.txt}"
CAPTURE_QOE_CSV="${CAPTURE_QOE_CSV:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_production/capture_library/webrtc_first_qoe_capture_library_720p.csv}"
CAPTURE_QOE_SUMMARY="${CAPTURE_QOE_SUMMARY:-${OUTPUT_DIR}/capture_qoe_summary.txt}"

MIN_PRODUCTION_SOAK_MINUTES="${MIN_PRODUCTION_SOAK_MINUTES:-120}"
MIN_PRODUCTION_ROWS="${MIN_PRODUCTION_ROWS:-1}"
MIN_CAPTURE_QOE_ROWS="${MIN_CAPTURE_QOE_ROWS:-1}"
MIN_CAPTURE_PLAYABLE_RATIO="${MIN_CAPTURE_PLAYABLE_RATIO:-0.8}"
MIN_CAPTURE_AVG_PSNR_Y="${MIN_CAPTURE_AVG_PSNR_Y:-20.0}"
MIN_CAPTURE_AVG_SSIM_Y="${MIN_CAPTURE_AVG_SSIM_Y:-0.80}"
ALLOW_XVFB_RENDERER="${ALLOW_XVFB_RENDERER:-0}"
ALLOW_FIXTURE_CAPTURE="${ALLOW_FIXTURE_CAPTURE:-0}"
REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES:-indoor_face outdoor_walking low_light_noise screen_text high_motion scene_cut}"

mkdir -p "${OUTPUT_DIR}"
rm -f "${SUMMARY_FILE}"

if [[ -n "${EVIDENCE_BUNDLE_DIR}" ]]; then
  SMOKE_SUMMARY="${EVIDENCE_BUNDLE_DIR}/smoke/phase2_verify_summary.txt"
  QOE_SUMMARY="${EVIDENCE_BUNDLE_DIR}/qoe/phase2_verify_summary.txt"
  PRODUCTION_SOAK_DIR="${EVIDENCE_BUNDLE_DIR}/production_soak"
  REAL_RENDERER_SUMMARY="${EVIDENCE_BUNDLE_DIR}/real_renderer/real_renderer_summary.txt"
  CAPTURE_MANIFEST_SUMMARY="${EVIDENCE_BUNDLE_DIR}/capture_library/capture_manifest_summary.txt"
  CAPTURE_QOE_CSV="${EVIDENCE_BUNDLE_DIR}/capture_library/webrtc_first_qoe_capture_library_720p.csv"
  CAPTURE_QOE_SUMMARY="${EVIDENCE_BUNDLE_DIR}/capture_library/capture_qoe_summary.txt"
fi

write_summary() {
  printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

has_line() {
  local file="$1"
  local pattern="$2"
  [[ -f "${file}" ]] && grep -Eq "${pattern}" "${file}"
}

kv_value() {
  local file="$1"
  local key="$2"
  [[ -f "${file}" ]] || return 0
  sed -n "s/^${key}=//p" "${file}" | tail -n 1
}

failures=0

audit_fail() {
  local name="$1"
  local reason="$2"
  write_summary "check=${name} status=fail reason=${reason}"
  failures=$((failures + 1))
}

audit_pass() {
  local name="$1"
  local detail="$2"
  write_summary "check=${name} status=pass ${detail}"
}

audit_warn() {
  local name="$1"
  local detail="$2"
  write_summary "check=${name} status=warn ${detail}"
}

write_summary "phase2_completion_audit=running"
write_summary "sdk_root=${SDK_ROOT}"
write_summary "output_dir=${OUTPUT_DIR}"
write_summary "evidence_bundle_dir=${EVIDENCE_BUNDLE_DIR}"
write_summary "min_production_soak_minutes=${MIN_PRODUCTION_SOAK_MINUTES}"

if [[ -n "${EVIDENCE_BUNDLE_DIR}" ]]; then
  if [[ ! -f "${EVIDENCE_BUNDLE_DIR}/manifest.sha256" || ! -f "${EVIDENCE_BUNDLE_DIR}/files.txt" ]]; then
    audit_fail evidence_bundle "missing_manifest bundle=${EVIDENCE_BUNDLE_DIR}"
  elif (cd "${EVIDENCE_BUNDLE_DIR}" && sha256sum -c manifest.sha256 >/dev/null); then
    audit_pass evidence_bundle "bundle=${EVIDENCE_BUNDLE_DIR}"
  else
    audit_fail evidence_bundle "sha256_mismatch bundle=${EVIDENCE_BUNDLE_DIR}"
  fi
fi

if has_line "${SMOKE_SUMMARY}" '^phase2_verify_status=pass$'; then
  audit_pass smoke_gate "summary=${SMOKE_SUMMARY}"
else
  audit_fail smoke_gate "missing_or_not_pass summary=${SMOKE_SUMMARY}"
fi

if has_line "${QOE_SUMMARY}" '^phase2_verify_status=pass$' &&
    has_line "${QOE_SUMMARY}" '^step=low_rps_low_bitrate_qoe status=pass' &&
    has_line "${QOE_SUMMARY}" '^step=recovery_time_distribution status=pass'; then
  audit_pass qoe_gate "summary=${QOE_SUMMARY}"
else
  audit_fail qoe_gate "missing_qoe_or_recovery_pass summary=${QOE_SUMMARY}"
fi

production_summary="${PRODUCTION_SOAK_DIR}/webrtc_first_qoe_production_soak_summary.txt"
production_config="${PRODUCTION_SOAK_DIR}/webrtc_first_qoe_production_soak_config.env"
production_archive="${PRODUCTION_SOAK_DIR}/webrtc_first_qoe_production_soak_archive.tar.gz"
production_soak_minutes="$(kv_value "${production_config}" SOAK_MINUTES)"
production_rows="$(kv_value "${production_summary}" rows)"
production_pass_rows="$(kv_value "${production_summary}" pass_rows)"
production_decode_errors="$(kv_value "${production_summary}" decode_errors)"
production_freeze_count="$(kv_value "${production_summary}" freeze_count)"
production_renderer_drops="$(kv_value "${production_summary}" renderer_proxy_drop_frames)"

if [[ ! -f "${production_summary}" || ! -f "${production_config}" ]]; then
  if [[ -n "${EVIDENCE_BUNDLE_DIR}" ]]; then
    audit_fail production_soak "missing_in_bundle summary=${production_summary}"
  elif [[ -f "${SDK_ROOT}/artifacts/webrtc_first_phase2_verify/production_soak/webrtc_first_qoe_production_soak_summary.txt" ]]; then
    audit_fail production_soak "full_production_summary_missing only_short_smoke_found=${SDK_ROOT}/artifacts/webrtc_first_phase2_verify/production_soak"
  else
    audit_fail production_soak "missing summary=${production_summary}"
  fi
else
  production_archive_verifier_output=""
  production_archive_verifier_status=0
  if ! production_archive_verifier_output="$(env SDK_ROOT="${SDK_ROOT}" \
      OUTPUT_DIR="${PRODUCTION_SOAK_DIR}" \
      MIN_SOAK_ROWS="${MIN_PRODUCTION_ROWS}" \
      MIN_SOAK_CYCLES=1 \
      REQUIRE_SOAK_TARBALL=1 \
      "${SDK_ROOT}/scripts/verify_webrtc_first_qoe_production_soak_archive.sh" 2>&1)"; then
    production_archive_verifier_status=1
  fi
  production_threshold_output=""
  production_status=0
  if ! production_threshold_output="$(python3 - "${MIN_PRODUCTION_SOAK_MINUTES}" "${MIN_PRODUCTION_ROWS}" \
      "${production_soak_minutes:-0}" "${production_rows:-0}" \
      "${production_pass_rows:-0}" "${production_decode_errors:-0}" \
      "${production_freeze_count:-0}" "${production_renderer_drops:-0}" <<'PY'
import sys

min_minutes = float(sys.argv[1])
min_rows = float(sys.argv[2])
soak_minutes = float(sys.argv[3] or 0)
rows = float(sys.argv[4] or 0)
pass_rows = float(sys.argv[5] or 0)
decode_errors = float(sys.argv[6] or 0)
freeze_count = float(sys.argv[7] or 0)
renderer_drops = float(sys.argv[8] or 0)

errors = []
if soak_minutes < min_minutes:
    errors.append("SOAK_MINUTES=%g<%g" % (soak_minutes, min_minutes))
if rows < min_rows:
    errors.append("rows=%g<%g" % (rows, min_rows))
if pass_rows != rows:
    errors.append("pass_rows=%g rows=%g" % (pass_rows, rows))
if decode_errors != 0:
    errors.append("decode_errors=%g" % decode_errors)
if freeze_count != 0:
    errors.append("freeze_count=%g" % freeze_count)
if renderer_drops != 0:
    errors.append("renderer_proxy_drop_frames=%g" % renderer_drops)

if errors:
    print(";".join(errors))
    raise SystemExit(1)
print("ok")
PY
  )"; then
    production_status=1
  fi
  if [[ "${production_status}" -eq 0 &&
      "${production_archive_verifier_status}" -eq 0 &&
      -f "${production_archive}" ]]; then
    audit_pass production_soak "summary=${production_summary} SOAK_MINUTES=${production_soak_minutes} rows=${production_rows}"
  else
    reason="failed_thresholds"
    if [[ "${production_status}" -ne 0 ]]; then
      reason="threshold_not_met:${production_threshold_output}"
    elif [[ "${production_archive_verifier_status}" -ne 0 ]]; then
      reason="archive_verifier_failed:${production_archive_verifier_output}"
    elif [[ ! -f "${production_archive}" ]]; then
      reason="missing_archive"
    fi
    audit_fail production_soak "${reason} summary=${production_summary} SOAK_MINUTES=${production_soak_minutes:-missing} rows=${production_rows:-missing}"
  fi
fi

if [[ -f "${REAL_RENDERER_SUMMARY}" ]]; then
  renderer_status="$(kv_value "${REAL_RENDERER_SUMMARY}" real_renderer_status)"
  renderer_backend="$(kv_value "${REAL_RENDERER_SUMMARY}" renderer_backend)"
  if [[ "${renderer_status}" == "pass" ]]; then
    if [[ "${renderer_backend}" == "xvfb" && "${ALLOW_XVFB_RENDERER}" != "1" ]]; then
      audit_fail real_renderer "xvfb_only_not_real_display summary=${REAL_RENDERER_SUMMARY}"
    else
      audit_pass real_renderer "summary=${REAL_RENDERER_SUMMARY} backend=${renderer_backend:-unknown}"
    fi
  else
    audit_fail real_renderer "status=${renderer_status:-missing} summary=${REAL_RENDERER_SUMMARY}"
  fi
else
  if [[ -n "${EVIDENCE_BUNDLE_DIR}" ]]; then
    audit_fail real_renderer "missing_in_bundle summary=${REAL_RENDERER_SUMMARY}"
  else
    best_renderer="$(find "${SDK_ROOT}/artifacts" -path '*/real_renderer_summary.txt' -type f 2>/dev/null | sort | tail -n 1 || true)"
    if [[ -n "${best_renderer}" ]]; then
    audit_fail real_renderer "production_renderer_missing best_seen=${best_renderer}"
    else
      audit_fail real_renderer "missing summary=${REAL_RENDERER_SUMMARY}"
    fi
  fi
fi

if [[ -f "${CAPTURE_MANIFEST_SUMMARY}" ]]; then
  capture_verified="$(kv_value "${CAPTURE_MANIFEST_SUMMARY}" capture_manifest_verification)"
  capture_dir="$(kv_value "${CAPTURE_MANIFEST_SUMMARY}" capture_library_dir)"
  capture_manifest="$(kv_value "${CAPTURE_MANIFEST_SUMMARY}" capture_manifest)"
  capture_entries="$(kv_value "${CAPTURE_MANIFEST_SUMMARY}" entries)"
  capture_categories="$(kv_value "${CAPTURE_MANIFEST_SUMMARY}" categories)"
  capture_fixture=0
  if grep -Eiq 'fixture|artifacts/capture_library_phase2_fixture|artifacts/capture_library_fixture' "${CAPTURE_MANIFEST_SUMMARY}"; then
    capture_fixture=1
  fi
  category_missing=0
  for category in ${REQUIRED_CAPTURE_CATEGORIES}; do
    if ! grep -Eq "(^|,)${category}(,|$)" <<<"${capture_categories}"; then
      category_missing=1
    fi
  done
  capture_qoe_output=""
  capture_qoe_status=0
  if ! capture_qoe_output="$(env CAPTURE_QOE_CSV="${CAPTURE_QOE_CSV}" \
      MIN_CAPTURE_QOE_ROWS="${MIN_CAPTURE_QOE_ROWS}" \
      MIN_PLAYABLE_RATIO="${MIN_CAPTURE_PLAYABLE_RATIO}" \
      MIN_AVG_PSNR_Y="${MIN_CAPTURE_AVG_PSNR_Y}" \
      MIN_AVG_SSIM_Y="${MIN_CAPTURE_AVG_SSIM_Y}" \
      REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES}" \
      SUMMARY_FILE="${CAPTURE_QOE_SUMMARY}" \
      "${SDK_ROOT}/scripts/verify_capture_library_qoe_csv.sh" 2>&1)"; then
    capture_qoe_status=1
  fi
  if [[ "${capture_verified}" == "true" &&
      "${category_missing}" -eq 0 &&
      "${capture_entries:-0}" -gt 0 &&
      "${capture_qoe_status}" -eq 0 ]]; then
    if [[ "${capture_fixture}" -eq 1 && "${ALLOW_FIXTURE_CAPTURE}" != "1" ]]; then
      audit_fail capture_library "fixture_library_not_formal dir=${capture_dir} manifest=${capture_manifest}"
    else
      audit_pass capture_library "summary=${CAPTURE_MANIFEST_SUMMARY} qoe_csv=${CAPTURE_QOE_CSV} entries=${capture_entries} categories=${capture_categories}"
    fi
  else
    reason="manifest_not_valid"
    if [[ "${capture_qoe_status}" -ne 0 ]]; then
      reason="qoe_not_valid:${capture_qoe_output}"
    fi
    audit_fail capture_library "${reason} entries=${capture_entries:-missing} categories=${capture_categories:-missing} summary=${CAPTURE_MANIFEST_SUMMARY} qoe_csv=${CAPTURE_QOE_CSV}"
  fi
else
  if [[ -n "${EVIDENCE_BUNDLE_DIR}" ]]; then
    audit_fail capture_library "missing_in_bundle summary=${CAPTURE_MANIFEST_SUMMARY}"
  else
    best_capture="$(find "${SDK_ROOT}/artifacts" -path '*/capture_manifest_summary.txt' -type f 2>/dev/null | sort | tail -n 1 || true)"
    if [[ -n "${best_capture}" ]]; then
      audit_fail capture_library "production_capture_missing best_seen=${best_capture}"
    else
      audit_fail capture_library "missing summary=${CAPTURE_MANIFEST_SUMMARY}"
    fi
  fi
fi

if [[ "${failures}" -eq 0 ]]; then
  write_summary "phase2_completion_audit=pass"
  write_summary "phase2_completion_status=complete"
  exit 0
fi

audit_warn next_required_actions "run_VERIFY_LEVEL_production_with_SOAK_MINUTES_ge_${MIN_PRODUCTION_SOAK_MINUTES}_REQUIRE_REAL_RENDERER_1_REQUIRE_CAPTURE_LIBRARY_1"
write_summary "phase2_completion_audit=fail"
write_summary "phase2_completion_status=incomplete"
write_summary "failure_count=${failures}"
exit 1
