#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/webrtc_first_phase2_completion_audit}"
SUMMARY_FILE="${SUMMARY_FILE:-${OUTPUT_DIR}/phase2_completion_audit_summary.txt}"
PHASE2_COMPLETION_AUDIT_METRICS_PROM="${PHASE2_COMPLETION_AUDIT_METRICS_PROM:-${OUTPUT_DIR}/phase2_completion_audit_metrics.prom}"
EVIDENCE_BUNDLE_DIR="${EVIDENCE_BUNDLE_DIR:-}"

SMOKE_SUMMARY="${SMOKE_SUMMARY:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_smoke/phase2_verify_summary.txt}"
QOE_SUMMARY="${QOE_SUMMARY:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_qoe/phase2_verify_summary.txt}"
PRODUCTION_SOAK_DIR="${PRODUCTION_SOAK_DIR:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_production/production_soak}"
REAL_RENDERER_SUMMARY="${REAL_RENDERER_SUMMARY:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_production/real_renderer/real_renderer_summary.txt}"
REAL_RENDERER_METRICS="${REAL_RENDERER_METRICS:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_production/real_renderer/real_renderer_metrics.csv}"
CAPTURE_MANIFEST_SUMMARY="${CAPTURE_MANIFEST_SUMMARY:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_production/capture_library/capture_manifest_summary.txt}"
CAPTURE_QOE_CSV="${CAPTURE_QOE_CSV:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_production/capture_library/webrtc_first_qoe_capture_library_720p.csv}"
CAPTURE_QOE_SUMMARY="${CAPTURE_QOE_SUMMARY:-${SDK_ROOT}/artifacts/webrtc_first_phase2_verify_production/capture_library/capture_qoe_summary.txt}"

MIN_PRODUCTION_SOAK_MINUTES="${MIN_PRODUCTION_SOAK_MINUTES:-120}"
MIN_PRODUCTION_ROWS="${MIN_PRODUCTION_ROWS:-1}"
MIN_CAPTURE_QOE_ROWS="${MIN_CAPTURE_QOE_ROWS:-1}"
MIN_CAPTURE_PLAYABLE_RATIO="${MIN_CAPTURE_PLAYABLE_RATIO:-0.8}"
MIN_CAPTURE_AVG_PSNR_Y="${MIN_CAPTURE_AVG_PSNR_Y:-20.0}"
MIN_CAPTURE_AVG_SSIM_Y="${MIN_CAPTURE_AVG_SSIM_Y:-0.80}"
ALLOW_XVFB_RENDERER="${ALLOW_XVFB_RENDERER:-0}"
ALLOW_FIXTURE_CAPTURE="${ALLOW_FIXTURE_CAPTURE:-0}"
P5_SKIP_REAL_RENDERER="${P5_SKIP_REAL_RENDERER:-0}"
P5_SKIP_CAPTURE_LIBRARY="${P5_SKIP_CAPTURE_LIBRARY:-0}"
REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES:-indoor_face outdoor_walking low_light_noise screen_text high_motion scene_cut}"

mkdir -p "${OUTPUT_DIR}"
rm -f "${SUMMARY_FILE}" "${PHASE2_COMPLETION_AUDIT_METRICS_PROM}"

if [[ -n "${EVIDENCE_BUNDLE_DIR}" ]]; then
  SMOKE_SUMMARY="${EVIDENCE_BUNDLE_DIR}/smoke/phase2_verify_summary.txt"
  QOE_SUMMARY="${EVIDENCE_BUNDLE_DIR}/qoe/phase2_verify_summary.txt"
  PRODUCTION_SOAK_DIR="${EVIDENCE_BUNDLE_DIR}/production_soak"
  REAL_RENDERER_SUMMARY="${EVIDENCE_BUNDLE_DIR}/real_renderer/real_renderer_summary.txt"
  REAL_RENDERER_METRICS="${EVIDENCE_BUNDLE_DIR}/real_renderer/real_renderer_metrics.csv"
  CAPTURE_MANIFEST_SUMMARY="${EVIDENCE_BUNDLE_DIR}/capture_library/capture_manifest_summary.txt"
  CAPTURE_QOE_CSV="${EVIDENCE_BUNDLE_DIR}/capture_library/webrtc_first_qoe_capture_library_720p.csv"
  CAPTURE_QOE_SUMMARY="${EVIDENCE_BUNDLE_DIR}/capture_library/capture_qoe_summary.txt"
fi

write_summary() {
  printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

is_sha256() {
  [[ "$1" =~ ^[0-9a-fA-F]{64}$ ]]
}

write_audit_metrics() {
  python3 - "${SUMMARY_FILE}" "${PHASE2_COMPLETION_AUDIT_METRICS_PROM}" <<'PY'
import collections
import re
import sys

summary_path, metrics_path = sys.argv[1:3]
audit_status = "unknown"
completion_status = "unknown"
checks = []
check_re = re.compile(r"^check=([^ ]+) status=([^ ]+)(?: |$)")
with open(summary_path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        match = check_re.match(line)
        if match:
            checks.append(match.groups())
            continue
        if line.startswith("phase2_completion_audit="):
            audit_status = line.split("=", 1)[1]
        elif line.startswith("phase2_completion_status="):
            completion_status = line.split("=", 1)[1]


def prom_escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def prom_labels(**labels):
    items = [
        f'{key}="{prom_escape(value)}"'
        for key, value in sorted(labels.items())
        if value is not None and value != ""
    ]
    return "{" + ",".join(items) + "}" if items else ""


status_counts = collections.Counter(status for _, status in checks)
important_status = {
    "production_soak": "missing",
    "real_renderer": "missing",
    "capture_library": "missing",
    "evidence_bundle": "not_required",
}
for check, status in checks:
    if check in important_status:
        important_status[check] = status

with open(metrics_path, "w", encoding="utf-8") as fh:
    fh.write("# HELP webrtc_qos_phase2_completion_audit_info Phase-2 completion audit status marker.\n")
    fh.write("# TYPE webrtc_qos_phase2_completion_audit_info gauge\n")
    fh.write(
        "webrtc_qos_phase2_completion_audit_info"
        f"{prom_labels(audit_status=audit_status, completion_status=completion_status, source='phase2_completion_audit')} 1\n"
    )
    fh.write("# HELP webrtc_qos_phase2_completion_audit_checks_total Phase-2 completion audit check count by status.\n")
    fh.write("# TYPE webrtc_qos_phase2_completion_audit_checks_total gauge\n")
    for status in ("pass", "warn", "fail"):
        fh.write(
            "webrtc_qos_phase2_completion_audit_checks_total"
            f"{prom_labels(status=status)} {status_counts.get(status, 0)}\n"
        )
    fh.write("# HELP webrtc_qos_phase2_completion_audit_check_status Phase-2 completion audit observed check status.\n")
    fh.write("# TYPE webrtc_qos_phase2_completion_audit_check_status gauge\n")
    for check, status in checks:
        fh.write(
            "webrtc_qos_phase2_completion_audit_check_status"
            f"{prom_labels(check=check, status=status)} 1\n"
        )
    fh.write("# HELP webrtc_qos_phase2_completion_audit_production_evidence_status Phase-2 completion audit production evidence status marker.\n")
    fh.write("# TYPE webrtc_qos_phase2_completion_audit_production_evidence_status gauge\n")
    for check, status in important_status.items():
        fh.write(
            "webrtc_qos_phase2_completion_audit_production_evidence_status"
            f"{prom_labels(check=check, status=status)} 1\n"
        )

text = open(metrics_path, "r", encoding="utf-8").read()
for required_text in (
    "# TYPE webrtc_qos_phase2_completion_audit_info gauge",
    "webrtc_qos_phase2_completion_audit_info",
    "webrtc_qos_phase2_completion_audit_checks_total",
    "webrtc_qos_phase2_completion_audit_check_status",
    "webrtc_qos_phase2_completion_audit_production_evidence_status",
):
    if required_text not in text:
        raise SystemExit(f"phase2 completion audit metrics missing {required_text}")

line_re = re.compile(
    r"^([A-Za-z_:][A-Za-z0-9_:]*)(\{([^{}]*)\})?\s+"
    r"([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|[+-]?Inf|NaN)$"
)
label_re = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)="((?:\\.|[^"\\])*)"')
records = []
for line_no, line in enumerate(text.splitlines(), 1):
    if not line.strip() or line.startswith("#"):
        continue
    match = line_re.match(line)
    if not match:
        raise SystemExit(
            f"phase2 completion audit metrics line {line_no} is invalid: {line}"
        )
    labels = {}
    raw_labels = match.group(3) or ""
    position = 0
    while position < len(raw_labels):
        label_match = label_re.match(raw_labels, position)
        if not label_match:
            raise SystemExit(
                f"phase2 completion audit metrics line {line_no} has invalid labels"
            )
        labels[label_match.group(1)] = label_match.group(2)
        position = label_match.end()
        if position < len(raw_labels):
            if raw_labels[position] != ",":
                raise SystemExit(
                    f"phase2 completion audit metrics line {line_no} has malformed labels"
                )
            position += 1
    records.append({
        "name": match.group(1),
        "labels": labels,
        "value": float(match.group(4)),
    })
if not records:
    raise SystemExit("phase2 completion audit metrics file has no samples")
PY
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

verify_evidence_bundle_manifest_consistency() {
  python3 - "${EVIDENCE_BUNDLE_DIR}" <<'PY'
import os
import sys

bundle_dir = sys.argv[1]
files_path = os.path.join(bundle_dir, "files.txt")
manifest_path = os.path.join(bundle_dir, "manifest.sha256")

with open(files_path, "r", encoding="utf-8") as handle:
    files = [line.strip() for line in handle if line.strip()]
with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest_files = []
    for line_no, line in enumerate(handle, 1):
        line = line.rstrip("\n")
        if len(line) < 67:
            raise SystemExit(
                f"phase2 evidence bundle manifest line {line_no} is too short"
            )
        digest, rel = line.split(None, 1)
        if len(digest) != 64 or not all(
            ch in "0123456789abcdefABCDEF" for ch in digest
        ):
            raise SystemExit(
                f"phase2 evidence bundle manifest line {line_no} has invalid sha256"
            )
        manifest_files.append(rel.lstrip("*"))

actual_files = []
for root, _, names in os.walk(bundle_dir):
    for name in names:
        path = os.path.join(root, name)
        rel = os.path.relpath(path, bundle_dir)
        if rel in {"manifest.sha256", "files.txt"}:
            continue
        actual_files.append(rel)
actual_files.sort()

if files != sorted(files):
    raise SystemExit("phase2 evidence bundle files.txt is not sorted")
if files != manifest_files:
    raise SystemExit(
        "phase2 evidence bundle files.txt and manifest.sha256 file sets differ"
    )
if files != actual_files:
    raise SystemExit("phase2 evidence bundle files.txt does not match actual files")
PY
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

min_soak_config_output=""
min_soak_config_status=0
if ! min_soak_config_output="$(python3 - "${MIN_PRODUCTION_SOAK_MINUTES}" <<'PY'
import sys

min_soak_minutes = float(sys.argv[1])
phase5_minimum = 120.0
if min_soak_minutes < phase5_minimum:
    print("MIN_PRODUCTION_SOAK_MINUTES=%g<%g" % (min_soak_minutes, phase5_minimum))
    raise SystemExit(1)
print("ok")
PY
)"
then
  min_soak_config_status=1
fi
if [[ "${min_soak_config_status}" -eq 0 && "${min_soak_config_output}" == "ok" ]]; then
  audit_pass production_soak_minimum_config "MIN_PRODUCTION_SOAK_MINUTES=${MIN_PRODUCTION_SOAK_MINUTES}"
else
  audit_fail production_soak_minimum_config "${min_soak_config_output}"
fi

if [[ -n "${EVIDENCE_BUNDLE_DIR}" ]]; then
  if [[ ! -f "${EVIDENCE_BUNDLE_DIR}/manifest.sha256" || ! -f "${EVIDENCE_BUNDLE_DIR}/files.txt" ]]; then
    audit_fail evidence_bundle "missing_manifest bundle=${EVIDENCE_BUNDLE_DIR}"
  elif (cd "${EVIDENCE_BUNDLE_DIR}" && sha256sum -c manifest.sha256 >/dev/null) &&
      verify_evidence_bundle_manifest_consistency; then
    audit_pass evidence_bundle "bundle=${EVIDENCE_BUNDLE_DIR}"
  else
    audit_fail evidence_bundle "manifest_mismatch bundle=${EVIDENCE_BUNDLE_DIR}"
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
production_csv="${PRODUCTION_SOAK_DIR}/webrtc_first_qoe_production_soak.csv"
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
  production_evidence_output=""
  production_evidence_status=0
  if ! production_evidence_output="$(env SDK_ROOT="${SDK_ROOT}" \
      PRODUCTION_SOAK_DIR="${PRODUCTION_SOAK_DIR}" \
      PRODUCTION_SOAK_SUMMARY="${production_summary}" \
      PRODUCTION_SOAK_CSV="${production_csv}" \
      PRODUCTION_SOAK_CONFIG="${production_config}" \
      PRODUCTION_SOAK_ARCHIVE="${production_archive}" \
      MIN_PRODUCTION_SOAK_MINUTES="${MIN_PRODUCTION_SOAK_MINUTES}" \
      MIN_PRODUCTION_ROWS="${MIN_PRODUCTION_ROWS}" \
      MIN_PRODUCTION_CYCLES=1 \
      REQUIRE_PRODUCTION_SOAK_ARCHIVE=1 \
      "${SDK_ROOT}/scripts/verify_webrtc_first_qoe_production_soak_evidence.sh" 2>&1)"; then
    production_evidence_status=1
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
      "${production_evidence_status}" -eq 0 &&
      -f "${production_archive}" ]]; then
    audit_pass production_soak "summary=${production_summary} SOAK_MINUTES=${production_soak_minutes} rows=${production_rows}"
  else
    reason="failed_thresholds"
    if [[ "${production_status}" -ne 0 ]]; then
      reason="threshold_not_met:${production_threshold_output}"
    elif [[ "${production_evidence_status}" -ne 0 ]]; then
      reason="evidence_not_valid:${production_evidence_output}"
    elif [[ ! -f "${production_archive}" ]]; then
      reason="missing_archive"
    fi
    audit_fail production_soak "${reason} summary=${production_summary} SOAK_MINUTES=${production_soak_minutes:-missing} rows=${production_rows:-missing}"
  fi
fi

if [[ "${P5_SKIP_REAL_RENDERER}" == "1" ]]; then
  if [[ -f "${REAL_RENDERER_SUMMARY}" ]] &&
      [[ -f "${REAL_RENDERER_METRICS}" ]] &&
      [[ "$(kv_value "${REAL_RENDERER_SUMMARY}" real_renderer_status)" == "skipped_by_policy" ]]; then
    audit_pass real_renderer "policy=skipped_by_p5_no_gpu_display_environment summary=${REAL_RENDERER_SUMMARY} metrics=${REAL_RENDERER_METRICS}"
  else
    audit_fail real_renderer "missing_policy_skip_summary summary=${REAL_RENDERER_SUMMARY} metrics=${REAL_RENDERER_METRICS}"
  fi
elif [[ -f "${REAL_RENDERER_SUMMARY}" ]]; then
  real_renderer_output=""
  real_renderer_status=0
  if ! real_renderer_output="$(env \
      SUMMARY_FILE="${REAL_RENDERER_SUMMARY}" \
      METRICS_FILE="${REAL_RENDERER_METRICS}" \
      ALLOW_XVFB_RENDERER="${ALLOW_XVFB_RENDERER}" \
      "${SDK_ROOT}/scripts/verify_real_renderer_evidence.sh" 2>&1)"; then
    real_renderer_status=1
  fi
  if [[ "${real_renderer_status}" -eq 0 ]]; then
    renderer_backend="$(kv_value "${REAL_RENDERER_SUMMARY}" renderer_backend)"
    rendered_frames="$(kv_value "${REAL_RENDERER_SUMMARY}" rendered_frames)"
    audit_pass real_renderer "summary=${REAL_RENDERER_SUMMARY} metrics=${REAL_RENDERER_METRICS} backend=${renderer_backend:-unknown} rendered_frames=${rendered_frames:-unknown}"
  else
    audit_fail real_renderer "evidence_not_valid:${real_renderer_output} summary=${REAL_RENDERER_SUMMARY} metrics=${REAL_RENDERER_METRICS}"
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

if [[ "${P5_SKIP_CAPTURE_LIBRARY}" == "1" ]]; then
  if [[ -f "${CAPTURE_MANIFEST_SUMMARY}" ]] &&
      [[ "$(kv_value "${CAPTURE_MANIFEST_SUMMARY}" capture_manifest_verification)" == "skipped_by_policy" ]] &&
      [[ -f "${CAPTURE_QOE_CSV}" ]] &&
      [[ -f "${CAPTURE_QOE_SUMMARY}" ]] &&
      [[ "$(kv_value "${CAPTURE_QOE_SUMMARY}" capture_qoe_verification)" == "skipped_by_policy" ]]; then
    audit_pass capture_library "policy=skipped_by_p5_no_production_data summary=${CAPTURE_MANIFEST_SUMMARY} qoe_csv=${CAPTURE_QOE_CSV} qoe_summary=${CAPTURE_QOE_SUMMARY}"
  else
    audit_fail capture_library "missing_policy_skip_summary summary=${CAPTURE_MANIFEST_SUMMARY} qoe_csv=${CAPTURE_QOE_CSV} qoe_summary=${CAPTURE_QOE_SUMMARY}"
  fi
elif [[ -f "${CAPTURE_MANIFEST_SUMMARY}" ]]; then
  capture_verified="$(kv_value "${CAPTURE_MANIFEST_SUMMARY}" capture_manifest_verification)"
  capture_dir="$(kv_value "${CAPTURE_MANIFEST_SUMMARY}" capture_library_dir)"
  capture_manifest="$(kv_value "${CAPTURE_MANIFEST_SUMMARY}" capture_manifest)"
  capture_manifest_sha256="$(kv_value "${CAPTURE_MANIFEST_SUMMARY}" capture_manifest_sha256)"
  capture_media_sha256="$(kv_value "${CAPTURE_MANIFEST_SUMMARY}" capture_media_sha256)"
  capture_entries="$(kv_value "${CAPTURE_MANIFEST_SUMMARY}" entries)"
  capture_categories="$(kv_value "${CAPTURE_MANIFEST_SUMMARY}" categories)"
  capture_fixture=0
  if grep -Eiq 'fixture|artifacts/capture_library_phase2_fixture|artifacts/capture_library_fixture' "${CAPTURE_MANIFEST_SUMMARY}"; then
    capture_fixture=1
  fi
  capture_evidence_output=""
  capture_evidence_status=0
  if ! capture_evidence_output="$(env \
      CAPTURE_MANIFEST_SUMMARY="${CAPTURE_MANIFEST_SUMMARY}" \
      CAPTURE_QOE_CSV="${CAPTURE_QOE_CSV}" \
      CAPTURE_QOE_SUMMARY="${CAPTURE_QOE_SUMMARY}" \
      MIN_CAPTURE_QOE_ROWS="${MIN_CAPTURE_QOE_ROWS}" \
      MIN_PLAYABLE_RATIO="${MIN_CAPTURE_PLAYABLE_RATIO}" \
      MIN_AVG_PSNR_Y="${MIN_CAPTURE_AVG_PSNR_Y}" \
      MIN_AVG_SSIM_Y="${MIN_CAPTURE_AVG_SSIM_Y}" \
      MAX_DECODE_ERRORS=0 \
      MAX_FREEZE_COUNT=0 \
      MAX_RENDERER_PROXY_DROP_FRAMES=0 \
      REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES}" \
      ALLOW_FIXTURE_CAPTURE="${ALLOW_FIXTURE_CAPTURE}" \
      "${SDK_ROOT}/scripts/verify_capture_library_evidence.sh" 2>&1)"; then
    capture_evidence_status=1
  fi
  if [[ "${capture_verified}" == "true" &&
      "${capture_entries:-0}" -gt 0 &&
      "${capture_evidence_status}" -eq 0 ]]; then
    if [[ "${capture_fixture}" -eq 1 && "${ALLOW_FIXTURE_CAPTURE}" != "1" ]]; then
      audit_fail capture_library "fixture_library_not_formal dir=${capture_dir} manifest=${capture_manifest}"
    else
      audit_pass capture_library "summary=${CAPTURE_MANIFEST_SUMMARY} qoe_csv=${CAPTURE_QOE_CSV} manifest_sha256=${capture_manifest_sha256} media_sha256=${capture_media_sha256} entries=${capture_entries} categories=${capture_categories}"
    fi
  else
    reason="manifest_not_valid"
    if [[ "${capture_evidence_status}" -ne 0 ]]; then
      reason="evidence_not_valid:${capture_evidence_output}"
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
  write_summary "phase2_completion_audit_metrics=${PHASE2_COMPLETION_AUDIT_METRICS_PROM}"
  write_audit_metrics
  exit 0
fi

audit_warn next_required_actions "run_VERIFY_LEVEL_production_with_SOAK_MINUTES_ge_120_and_real_renderer_capture_evidence_or_explicit_P5_SKIP_POLICY"
write_summary "phase2_completion_audit=fail"
write_summary "phase2_completion_status=incomplete"
write_summary "failure_count=${failures}"
write_summary "phase2_completion_audit_metrics=${PHASE2_COMPLETION_AUDIT_METRICS_PROM}"
write_audit_metrics
exit 1
