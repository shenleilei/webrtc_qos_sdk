#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SOURCE_EVIDENCE_BUNDLE_DIR="${SOURCE_EVIDENCE_BUNDLE_DIR:-${PHASE2_EVIDENCE_BUNDLE_DIR:-${EVIDENCE_BUNDLE_DIR:-}}}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${SDK_ROOT}/artifacts/phase5_phase2_evidence_import}"
BUNDLE_OUTPUT_DIR="${BUNDLE_OUTPUT_DIR:-${OUTPUT_ROOT}/phase2_evidence_bundle}"
AUDIT_OUTPUT_DIR="${AUDIT_OUTPUT_DIR:-${OUTPUT_ROOT}/phase2_completion_audit}"
LOG_DIR="${LOG_DIR:-${OUTPUT_ROOT}/logs}"
SUMMARY_FILE="${SUMMARY_FILE:-${OUTPUT_ROOT}/phase2_production_gate_summary.txt}"
IMPORT_REPORT_JSON="${IMPORT_REPORT_JSON:-${OUTPUT_ROOT}/phase2_external_evidence_import.json}"
IMPORT_REPORT_SUMMARY="${IMPORT_REPORT_SUMMARY:-${OUTPUT_ROOT}/phase2_external_evidence_import.txt}"
FILES_FILE="${FILES_FILE:-${OUTPUT_ROOT}/files.txt}"
MANIFEST_FILE="${MANIFEST_FILE:-${OUTPUT_ROOT}/manifest.sha256}"

MIN_PRODUCTION_SOAK_MINUTES="${MIN_PRODUCTION_SOAK_MINUTES:-120}"
ALLOW_XVFB_RENDERER="${ALLOW_XVFB_RENDERER:-0}"
ALLOW_FIXTURE_CAPTURE="${ALLOW_FIXTURE_CAPTURE:-0}"
REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES:-indoor_face outdoor_walking low_light_noise screen_text high_motion scene_cut}"
EXPECTED_GIT_HEAD="${EXPECTED_GIT_HEAD:-$(git -C "${SDK_ROOT}" rev-parse HEAD 2>/dev/null || true)}"
REQUIRE_GIT_HEAD_MATCH="${REQUIRE_GIT_HEAD_MATCH:-1}"

fail() {
  echo "phase5 phase2 evidence import failed: $*" >&2
  exit 1
}

write_summary() {
  printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

write_manifest() {
  (
    cd "${OUTPUT_ROOT}"
    find . -type f \
      ! -path './manifest.sha256' \
      ! -path './files.txt' \
      | sed 's#^\./##' \
      | sort >"${FILES_FILE}"
    while IFS= read -r file; do
      sha256sum "${file}"
    done <"${FILES_FILE}" >"${MANIFEST_FILE}"
  )
}

verify_evidence_bundle_manifest_consistency() {
  local dir="$1"
  local label="$2"
  python3 - "${dir}" "${label}" <<'PY'
import os
import sys

bundle_dir, label = sys.argv[1:3]
files_path = os.path.join(bundle_dir, "files.txt")
manifest_path = os.path.join(bundle_dir, "manifest.sha256")

with open(files_path, "r", encoding="utf-8") as handle:
    files = [line.strip() for line in handle if line.strip()]
with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest_files = []
    for line_no, line in enumerate(handle, 1):
        line = line.rstrip("\n")
        if len(line) < 67:
            raise SystemExit(f"{label} manifest line {line_no} is too short")
        digest, rel = line.split(None, 1)
        if len(digest) != 64 or not all(
            ch in "0123456789abcdefABCDEF" for ch in digest
        ):
            raise SystemExit(f"{label} manifest line {line_no} has invalid sha256")
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
    raise SystemExit(f"{label} files.txt is not sorted")
if files != manifest_files:
    raise SystemExit(f"{label} files.txt and manifest.sha256 file sets differ")
if files != actual_files:
    raise SystemExit(f"{label} files.txt does not match actual files")
PY
}

[[ -n "${SOURCE_EVIDENCE_BUNDLE_DIR}" ]] ||
  fail "set PHASE2_EVIDENCE_BUNDLE_DIR or SOURCE_EVIDENCE_BUNDLE_DIR"

python3 - "${MIN_PRODUCTION_SOAK_MINUTES}" <<'PY'
import sys

min_soak_minutes = float(sys.argv[1])
phase5_minimum = 120.0
if min_soak_minutes < phase5_minimum:
    raise SystemExit(
        "MIN_PRODUCTION_SOAK_MINUTES=%g<%g"
        % (min_soak_minutes, phase5_minimum)
    )
PY

[[ -d "${SOURCE_EVIDENCE_BUNDLE_DIR}" ]] ||
  fail "missing source evidence bundle dir: ${SOURCE_EVIDENCE_BUNDLE_DIR}"
[[ -s "${SOURCE_EVIDENCE_BUNDLE_DIR}/manifest.sha256" ]] ||
  fail "missing source manifest: ${SOURCE_EVIDENCE_BUNDLE_DIR}/manifest.sha256"
[[ -s "${SOURCE_EVIDENCE_BUNDLE_DIR}/files.txt" ]] ||
  fail "missing source files list: ${SOURCE_EVIDENCE_BUNDLE_DIR}/files.txt"

source_real="$(cd "${SOURCE_EVIDENCE_BUNDLE_DIR}" && pwd -P)"
output_parent="$(dirname "${OUTPUT_ROOT}")"
mkdir -p "${output_parent}"
output_real_parent="$(cd "${output_parent}" && pwd -P)"
output_real="${output_real_parent}/$(basename "${OUTPUT_ROOT}")"
case "${source_real}" in
  "${output_real}"| "${output_real}/"*)
    fail "source evidence bundle must not be inside output root: source=${source_real} output=${output_real}"
    ;;
esac

(
  cd "${SOURCE_EVIDENCE_BUNDLE_DIR}"
  sha256sum -c manifest.sha256 >/dev/null
)
verify_evidence_bundle_manifest_consistency "${SOURCE_EVIDENCE_BUNDLE_DIR}" \
  "source phase2 evidence bundle"

rm -rf "${OUTPUT_ROOT}"
mkdir -p "${OUTPUT_ROOT}" "${LOG_DIR}"
rm -f "${SUMMARY_FILE}" "${IMPORT_REPORT_JSON}" "${IMPORT_REPORT_SUMMARY}" \
  "${FILES_FILE}" "${MANIFEST_FILE}"

write_summary "phase2_production_gate=running"
write_summary "phase2_evidence_source=external_bundle"
write_summary "source_evidence_bundle=${SOURCE_EVIDENCE_BUNDLE_DIR}"
write_summary "output_root=${OUTPUT_ROOT}"
write_summary "min_production_soak_minutes=${MIN_PRODUCTION_SOAK_MINUTES}"
write_summary "expected_git_head=${EXPECTED_GIT_HEAD:-unknown}"
write_summary "require_git_head_match=${REQUIRE_GIT_HEAD_MATCH}"

cp -a "${SOURCE_EVIDENCE_BUNDLE_DIR}" "${BUNDLE_OUTPUT_DIR}"
(
  cd "${BUNDLE_OUTPUT_DIR}"
  sha256sum -c manifest.sha256 >/dev/null
)
verify_evidence_bundle_manifest_consistency "${BUNDLE_OUTPUT_DIR}" \
  "copied phase2 evidence bundle"

if ! env SDK_ROOT="${SDK_ROOT}" \
    OUTPUT_DIR="${AUDIT_OUTPUT_DIR}" \
    EVIDENCE_BUNDLE_DIR="${BUNDLE_OUTPUT_DIR}" \
    MIN_PRODUCTION_SOAK_MINUTES="${MIN_PRODUCTION_SOAK_MINUTES}" \
    ALLOW_XVFB_RENDERER="${ALLOW_XVFB_RENDERER}" \
    ALLOW_FIXTURE_CAPTURE="${ALLOW_FIXTURE_CAPTURE}" \
    REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES}" \
    "${SDK_ROOT}/scripts/verify_webrtc_first_phase2_completion_audit.sh" \
    >"${LOG_DIR}/phase2_completion_audit.log" 2>&1; then
  write_summary "phase2_production_gate_status=fail"
  write_summary "completion_audit=${AUDIT_OUTPUT_DIR}"
  if [[ -s "${AUDIT_OUTPUT_DIR}/phase2_completion_audit_metrics.prom" ]]; then
    write_summary "completion_audit_metrics=${AUDIT_OUTPUT_DIR}/phase2_completion_audit_metrics.prom"
  fi
  write_manifest
  tail -n 80 "${LOG_DIR}/phase2_completion_audit.log" >&2 || true
  exit 1
fi

if ! env SUMMARY_FILE="${BUNDLE_OUTPUT_DIR}/real_renderer/real_renderer_summary.txt" \
    METRICS_FILE="${BUNDLE_OUTPUT_DIR}/real_renderer/real_renderer_metrics.csv" \
    ALLOW_XVFB_RENDERER="${ALLOW_XVFB_RENDERER}" \
    "${SDK_ROOT}/scripts/verify_real_renderer_evidence.sh" \
    >"${LOG_DIR}/real_renderer_evidence.log" 2>&1; then
  write_summary "phase2_production_gate_status=fail"
  write_summary "real_renderer_evidence_log=${LOG_DIR}/real_renderer_evidence.log"
  write_manifest
  tail -n 80 "${LOG_DIR}/real_renderer_evidence.log" >&2 || true
  exit 1
fi

if ! env CAPTURE_MANIFEST_SUMMARY="${BUNDLE_OUTPUT_DIR}/capture_library/capture_manifest_summary.txt" \
    CAPTURE_QOE_CSV="${BUNDLE_OUTPUT_DIR}/capture_library/webrtc_first_qoe_capture_library_720p.csv" \
    CAPTURE_QOE_SUMMARY="${BUNDLE_OUTPUT_DIR}/capture_library/capture_qoe_summary.txt" \
    ALLOW_FIXTURE_CAPTURE="${ALLOW_FIXTURE_CAPTURE}" \
    REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES}" \
    "${SDK_ROOT}/scripts/verify_capture_library_evidence.sh" \
    >"${LOG_DIR}/capture_library_evidence.log" 2>&1; then
  write_summary "phase2_production_gate_status=fail"
  write_summary "capture_library_evidence_log=${LOG_DIR}/capture_library_evidence.log"
  write_manifest
  tail -n 80 "${LOG_DIR}/capture_library_evidence.log" >&2 || true
  exit 1
fi

python3 - \
  "${BUNDLE_OUTPUT_DIR}" \
  "${AUDIT_OUTPUT_DIR}/phase2_completion_audit_summary.txt" \
  "${IMPORT_REPORT_JSON}" \
  "${IMPORT_REPORT_SUMMARY}" \
  "${EXPECTED_GIT_HEAD}" \
  "${REQUIRE_GIT_HEAD_MATCH}" \
  "${MIN_PRODUCTION_SOAK_MINUTES}" \
  "${ALLOW_FIXTURE_CAPTURE}" \
  "${SOURCE_EVIDENCE_BUNDLE_DIR}" \
  "${OUTPUT_ROOT}" <<'PY'
import json
import os
import shlex
import sys

(
    bundle_dir,
    audit_summary,
    report_json,
    report_summary,
    expected_git_head,
    require_git_head_match,
    min_soak_minutes,
    allow_fixture_capture,
    source_bundle,
    output_root,
) = sys.argv[1:11]


def rel(path):
    return os.path.relpath(path, output_root)


def read_kv(path):
    values = {}
    if not os.path.exists(path):
        return values
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            try:
                parts = shlex.split(value)
                value = parts[0] if parts else ""
            except ValueError:
                value = value.strip("'\"")
            values[key] = value
    return values


def has_line(path, expected):
    if not os.path.exists(path):
        return False
    with open(path, "r", encoding="utf-8") as fh:
        return any(line.strip() == expected for line in fh)


def has_prefix(path, prefix):
    if not os.path.exists(path):
        return False
    with open(path, "r", encoding="utf-8") as fh:
        return any(line.startswith(prefix) for line in fh)


def parse_number(value):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return value
    if number.is_integer():
        return int(number)
    return number


def has_file(path):
    return os.path.isfile(path) and os.path.getsize(path) > 0


def valid_sha256(value):
    return isinstance(value, str) and len(value) == 64 and all(
        ch in "0123456789abcdefABCDEF" for ch in value
    )


def has_fixture_marker(path):
    if not os.path.exists(path):
        return False
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read().lower()
    return any(
        marker in text
        for marker in (
            "fixture",
            "artifacts/capture_library_phase2_fixture",
            "artifacts/capture_library_fixture",
        )
    )


phase5_min_soak_minutes = 120.0
configured_min_soak_minutes = float(min_soak_minutes)
if configured_min_soak_minutes < phase5_min_soak_minutes:
    raise SystemExit(
        "external phase2 evidence import minimum soak below phase5 minimum"
    )


metadata = read_kv(os.path.join(bundle_dir, "metadata.env"))
audit_metrics = os.path.join(
    os.path.dirname(audit_summary), "phase2_completion_audit_metrics.prom"
)
soak_metadata = read_kv(
    os.path.join(bundle_dir, "production_soak", "archive", "metadata.txt")
)
production_soak_dir = os.path.join(bundle_dir, "production_soak")
production_soak_summary = os.path.join(
    production_soak_dir, "webrtc_first_qoe_production_soak_summary.txt"
)
production_soak_csv = os.path.join(
    production_soak_dir, "webrtc_first_qoe_production_soak.csv"
)
production_soak_config = os.path.join(
    production_soak_dir, "webrtc_first_qoe_production_soak_config.env"
)
production_soak_archive = os.path.join(
    production_soak_dir, "webrtc_first_qoe_production_soak_archive.tar.gz"
)
real_renderer_summary = os.path.join(bundle_dir, "real_renderer", "real_renderer_summary.txt")
real_renderer_metrics = os.path.join(bundle_dir, "real_renderer", "real_renderer_metrics.csv")
capture_manifest_summary = os.path.join(
    bundle_dir, "capture_library", "capture_manifest_summary.txt"
)
capture_qoe_csv = os.path.join(
    bundle_dir, "capture_library", "webrtc_first_qoe_capture_library_720p.csv"
)
capture_qoe_summary = os.path.join(bundle_dir, "capture_library", "capture_qoe_summary.txt")
production_soak = read_kv(production_soak_summary)
production_soak_runtime = read_kv(production_soak_config)
production_soak_minutes = parse_number(
    production_soak_runtime.get("SOAK_MINUTES", "0")
)
real_renderer = read_kv(real_renderer_summary)
capture_manifest = read_kv(capture_manifest_summary)
capture_qoe = read_kv(capture_qoe_summary)
capture_fixture = has_fixture_marker(capture_manifest_summary)
observed_git_heads = []
for value in (
    metadata.get("GIT_HEAD"),
    metadata.get("git_head"),
    soak_metadata.get("sdk_git_commit"),
    soak_metadata.get("GIT_COMMIT"),
):
    if value and value not in observed_git_heads:
        observed_git_heads.append(value)

checks = {
    "bundle_manifest": os.path.exists(os.path.join(bundle_dir, "manifest.sha256")),
    "bundle_files_manifest_consistency": True,
    "bundle_git_worktree_clean": metadata.get("GIT_TRACKED_WORKTREE_CLEAN") == "1",
    "phase2_completion_audit": has_line(audit_summary, "phase2_completion_audit=pass")
    and has_line(audit_summary, "phase2_completion_status=complete"),
    "phase2_completion_audit_metrics": has_file(audit_metrics),
    "production_soak": has_prefix(audit_summary, "check=production_soak status=pass "),
    "real_renderer": has_prefix(audit_summary, "check=real_renderer status=pass "),
    "capture_library": has_prefix(audit_summary, "check=capture_library status=pass "),
    "capture_library_evidence": has_file(
        os.path.join(output_root, "logs", "capture_library_evidence.log")
    )
    and capture_manifest.get("capture_manifest_sha256")
    == capture_qoe.get("capture_manifest_sha256"),
    "evidence_bundle": has_prefix(audit_summary, "check=evidence_bundle status=pass "),
    "production_soak_raw_evidence": has_file(production_soak_summary)
    and has_file(production_soak_csv)
    and has_file(production_soak_config)
    and has_file(production_soak_archive)
    and isinstance(production_soak_minutes, (int, float))
    and production_soak_minutes >= configured_min_soak_minutes
    and production_soak_minutes >= phase5_min_soak_minutes,
    "real_renderer_raw_evidence": has_file(real_renderer_summary)
    and has_file(real_renderer_metrics)
    and real_renderer.get("real_renderer_status") == "pass",
    "real_renderer_rendered_frames": parse_number(
        real_renderer.get("rendered_frames", "0")
    )
    > 0,
    "capture_qoe_raw_evidence": has_file(capture_manifest_summary)
    and has_file(capture_qoe_csv)
    and has_file(capture_qoe_summary)
    and valid_sha256(capture_manifest.get("capture_manifest_sha256"))
    and capture_qoe.get("capture_qoe_verification") == "true",
}
if capture_fixture and allow_fixture_capture != "1":
    checks["capture_qoe_raw_evidence"] = False

git_match = bool(expected_git_head) and expected_git_head in observed_git_heads
if require_git_head_match == "1":
    checks["git_head_match"] = git_match
else:
    checks["git_head_match"] = bool(observed_git_heads)

import_status = "pass" if all(checks.values()) else "fail"
report = {
    "schema_version": 1,
    "source": "phase5_phase2_external_evidence_import",
    "import_status": import_status,
    "source_evidence_bundle": source_bundle,
    "expected_git_head": expected_git_head,
    "require_git_head_match": require_git_head_match == "1",
    "observed_git_heads": observed_git_heads,
    "git_head_match": git_match,
    "source_git_worktree_clean": metadata.get("GIT_TRACKED_WORKTREE_CLEAN") == "1",
    "requirements": {
        "min_production_soak_minutes": float(min_soak_minutes),
        "formal_capture_required": True,
        "real_renderer_required": True,
        "clean_tracked_worktree_required": True,
        "fixture_capture_allowed": allow_fixture_capture == "1",
    },
    "production_soak": {
        "summary": rel(production_soak_summary),
        "csv": rel(production_soak_csv),
        "config": rel(production_soak_config),
        "archive": rel(production_soak_archive),
        "soak_minutes": production_soak_minutes,
        "rows": parse_number(production_soak.get("rows", "0")),
        "pass_rows": parse_number(production_soak.get("pass_rows", "0")),
        "decode_errors": parse_number(production_soak.get("decode_errors", "0")),
        "freeze_count": parse_number(production_soak.get("freeze_count", "0")),
        "renderer_proxy_drop_frames": parse_number(
            production_soak.get("renderer_proxy_drop_frames", "0")
        ),
    },
    "real_renderer": {
        "summary": rel(real_renderer_summary),
        "metrics": rel(real_renderer_metrics),
        "status": real_renderer.get("real_renderer_status", ""),
        "backend": real_renderer.get("renderer_backend", ""),
        "rendered_frames": parse_number(real_renderer.get("rendered_frames", "0")),
        "late_frames": parse_number(real_renderer.get("late_frames", "0")),
        "max_present_gap_ms": parse_number(
            real_renderer.get("max_present_gap_ms", "0")
        ),
        "max_present_jitter_ms": parse_number(
            real_renderer.get("max_present_jitter_ms", "0")
        ),
    },
    "capture_library": {
        "manifest_summary": rel(capture_manifest_summary),
        "qoe_csv": rel(capture_qoe_csv),
        "qoe_summary": rel(capture_qoe_summary),
        "manifest_sha256": capture_manifest.get("capture_manifest_sha256", ""),
        "qoe_manifest_sha256": capture_qoe.get("capture_manifest_sha256", ""),
        "fixture": capture_fixture,
        "rows": parse_number(capture_qoe.get("rows", "0")),
        "pass_rows": parse_number(capture_qoe.get("pass_rows", "0")),
        "categories": capture_qoe.get("categories", ""),
        "required_categories": capture_qoe.get("required_categories", ""),
        "playable_ratio_min": parse_number(capture_qoe.get("playable_ratio_min", "0")),
        "avg_psnr_y_min": parse_number(capture_qoe.get("avg_psnr_y_min", "0")),
        "avg_ssim_y_min": parse_number(capture_qoe.get("avg_ssim_y_min", "0")),
        "decode_errors": parse_number(capture_qoe.get("decode_errors", "0")),
        "freeze_count": parse_number(capture_qoe.get("freeze_count", "0")),
        "renderer_proxy_drop_frames": parse_number(
            capture_qoe.get("renderer_proxy_drop_frames", "0")
        ),
    },
    "checks": [
        {"check": name, "status": "pass" if passed else "fail"}
        for name, passed in sorted(checks.items())
    ],
    "artifacts": {
        "phase2_evidence_bundle": rel(bundle_dir),
        "phase2_evidence_metadata": rel(os.path.join(bundle_dir, "metadata.env")),
        "phase2_completion_audit": rel(audit_summary),
        "phase2_completion_audit_metrics": rel(audit_metrics),
        "phase2_completion_audit_log": rel(
            os.path.join(output_root, "logs", "phase2_completion_audit.log")
        ),
        "production_soak_summary": rel(production_soak_summary),
        "production_soak_csv": rel(production_soak_csv),
        "production_soak_config": rel(production_soak_config),
        "production_soak_archive": rel(production_soak_archive),
        "real_renderer_summary": rel(real_renderer_summary),
        "real_renderer_metrics": rel(real_renderer_metrics),
        "real_renderer_evidence_log": rel(
            os.path.join(output_root, "logs", "real_renderer_evidence.log")
        ),
        "capture_manifest_summary": rel(capture_manifest_summary),
        "capture_qoe_csv": rel(capture_qoe_csv),
        "capture_qoe_summary": rel(capture_qoe_summary),
        "capture_library_evidence_log": rel(
            os.path.join(output_root, "logs", "capture_library_evidence.log")
        ),
    },
}

with open(report_json, "w", encoding="utf-8") as fh:
    json.dump(report, fh, indent=2, sort_keys=True)
    fh.write("\n")
with open(report_summary, "w", encoding="utf-8") as fh:
    fh.write(f"import_status={import_status}\n")
    fh.write(f"source_evidence_bundle={source_bundle}\n")
    fh.write(f"expected_git_head={expected_git_head or 'unknown'}\n")
    fh.write(f"observed_git_heads={','.join(observed_git_heads) or 'none'}\n")
    fh.write(f"git_head_match={'true' if git_match else 'false'}\n")
    fh.write(
        "source_git_worktree_clean="
        f"{'true' if metadata.get('GIT_TRACKED_WORKTREE_CLEAN') == '1' else 'false'}\n"
    )
    for name, passed in sorted(checks.items()):
        fh.write(f"check={name} status={'pass' if passed else 'fail'}\n")
    fh.write(f"phase2_completion_audit_metrics={rel(audit_metrics)}\n")
    fh.write(f"production_soak_csv={rel(production_soak_csv)}\n")
    fh.write(f"production_soak_archive={rel(production_soak_archive)}\n")
    fh.write(f"real_renderer_metrics={rel(real_renderer_metrics)}\n")
    fh.write(
        "real_renderer_rendered_frames="
        f"{real_renderer.get('rendered_frames', '0')}\n"
    )
    fh.write(
        "capture_manifest_sha256="
        f"{capture_manifest.get('capture_manifest_sha256', '')}\n"
    )
    fh.write(
        "capture_qoe_manifest_sha256="
        f"{capture_qoe.get('capture_manifest_sha256', '')}\n"
    )
    fh.write(f"capture_qoe_csv={rel(capture_qoe_csv)}\n")

if import_status != "pass":
    failed = ",".join(name for name, passed in checks.items() if not passed)
    raise SystemExit(f"external phase2 evidence import failed checks: {failed}")
PY

write_summary "step=phase2_completion_audit status=pass log=${LOG_DIR}/phase2_completion_audit.log"
write_summary "phase2_external_evidence_import=${IMPORT_REPORT_JSON}"
write_summary "phase2_external_evidence_import_summary=${IMPORT_REPORT_SUMMARY}"
write_summary "phase2_production_gate_status=pass"
write_summary "evidence_bundle=${BUNDLE_OUTPUT_DIR}"
write_summary "completion_audit=${AUDIT_OUTPUT_DIR}"
write_summary "completion_audit_metrics=${AUDIT_OUTPUT_DIR}/phase2_completion_audit_metrics.prom"
write_summary "manifest=${MANIFEST_FILE}"
write_manifest

echo "phase5_phase2_evidence_import pass output_root=${OUTPUT_ROOT}"
