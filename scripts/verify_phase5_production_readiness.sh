#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WEBRTC_PREFIX="${WEBRTC_PREFIX:-${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/phase5_production_readiness}"
SUMMARY_FILE="${SUMMARY_FILE:-${OUTPUT_DIR}/phase5_production_readiness_summary.txt}"
LOG_DIR="${LOG_DIR:-${OUTPUT_DIR}/logs}"
NEXT_REQUIRED_ACTIONS_FILE="${OUTPUT_DIR}/next_required_actions.txt"
NEXT_REQUIRED_ACTIONS_JSON="${OUTPUT_DIR}/next_required_actions.json"
READINESS_REPORT_JSON="${OUTPUT_DIR}/readiness_report.json"
CHECK_RECORDS_JSONL="${OUTPUT_DIR}/check_records.jsonl"
ACTION_RECORDS_JSONL="${OUTPUT_DIR}/action_records.jsonl"
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
: >"${NEXT_REQUIRED_ACTIONS_FILE}"
: >"${CHECK_RECORDS_JSONL}"
: >"${ACTION_RECORDS_JSONL}"

failures=0
skipped_count=0
action_count=0

write_summary() {
  printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

action_for_check() {
  local name="$1"
  case "${name}" in
    script_*)
      local script="${name#script_}"
      printf 'restore_or_make_executable script=scripts/%s before rerunning readiness' "${script}"
      ;;
    soak_config)
      printf 'set SOAK_MINUTES>=%s for the formal production gate' "${MIN_PRODUCTION_SOAK_MINUTES}"
      ;;
    webrtc_modules)
      printf 'build_or_install WebRTC modules and set PREFIX or WEBRTC_PREFIX, then run scripts/verify_webrtc_modules.sh with REQUIRE_ALL=1'
      ;;
    capture_manifest)
      printf 'provide formal capture library manifest.csv with required categories and set CAPTURE_LIBRARY_DIR/CAPTURE_LIBRARY_MANIFEST'
      ;;
    real_renderer)
      printf 'run on a host with a real display/GPU renderer and rerun scripts/verify_real_renderer_smoke.sh with REQUIRE_REAL_RENDERER=1'
      ;;
    *)
      printf 'fix check=%s and rerun scripts/verify_phase5_production_readiness.sh' "${name}"
      ;;
  esac
}

record_check_json() {
  local name="$1"
  local status="$2"
  local detail="$3"
  python3 - "${CHECK_RECORDS_JSONL}" "${name}" "${status}" "${detail}" <<'PY'
import json
import sys

path, name, status, detail = sys.argv[1:5]
record = {
    "check": name,
    "status": status,
    "detail": detail,
}
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, sort_keys=True) + "\n")
PY
}

record_action_json() {
  local name="$1"
  local status="$2"
  local reason="$3"
  local required="$4"
  python3 - "${ACTION_RECORDS_JSONL}" "${name}" "${status}" "${reason}" "${required}" <<'PY'
import json
import sys

path, name, status, reason, required = sys.argv[1:6]
record = {
    "action": name,
    "status": status,
    "reason": reason,
    "required": required,
}
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, sort_keys=True) + "\n")
PY
}

record_action() {
  local name="$1"
  local status="$2"
  local reason="$3"
  local required
  required="$(action_for_check "${name}")"
  printf 'action=%s status=%s reason=%s required=%s\n' \
    "${name}" "${status}" "${reason}" "${required}" \
    >>"${NEXT_REQUIRED_ACTIONS_FILE}"
  record_action_json "${name}" "${status}" "${reason}" "${required}"
  action_count=$((action_count + 1))
}

record_fail() {
  local name="$1"
  local reason="$2"
  write_summary "check=${name} status=fail reason=${reason}"
  record_check_json "${name}" "fail" "${reason}"
  record_action "${name}" "fail" "${reason}"
  failures=$((failures + 1))
}

record_pass() {
  local name="$1"
  local detail="$2"
  write_summary "check=${name} status=pass ${detail}"
  record_check_json "${name}" "pass" "${detail}"
}

record_skip() {
  local name="$1"
  local reason="$2"
  write_summary "check=${name} status=skipped ${reason}"
  record_check_json "${name}" "skipped" "${reason}"
  record_action "${name}" "skipped" "${reason}"
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

write_readiness_reports() {
  local readiness_status="$1"
  python3 - \
    "${READINESS_REPORT_JSON}" \
    "${NEXT_REQUIRED_ACTIONS_JSON}" \
    "${CHECK_RECORDS_JSONL}" \
    "${ACTION_RECORDS_JSONL}" \
    "${readiness_status}" \
    "${failures}" \
    "${skipped_count}" \
    "${action_count}" \
    "${SDK_ROOT}" \
    "${WEBRTC_PREFIX}" \
    "${SOAK_MINUTES}" \
    "${MIN_PRODUCTION_SOAK_MINUTES}" \
    "${ALLOW_XVFB_RENDERER}" \
    "${REAL_RENDERER_USE_XVFB}" \
    "${CAPTURE_LIBRARY_DIR}" \
    "${CAPTURE_LIBRARY_MANIFEST}" \
    "${REQUIRE_READY}" <<'PY'
import json
import os
import sys

(
    report_path,
    actions_path,
    checks_jsonl,
    actions_jsonl,
    readiness_status,
    failure_count,
    skipped_count,
    action_count,
    sdk_root,
    web_rtc_prefix,
    soak_minutes,
    min_soak_minutes,
    allow_xvfb_renderer,
    real_renderer_use_xvfb,
    capture_library_dir,
    capture_library_manifest,
    require_ready,
) = sys.argv[1:18]


def read_jsonl(path):
    records = []
    if not os.path.exists(path):
        return records
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records


def parse_number(value):
    try:
        number = float(value)
    except ValueError:
        return value
    if number.is_integer():
        return int(number)
    return number


checks = read_jsonl(checks_jsonl)
actions = read_jsonl(actions_jsonl)
actions_doc = {
    "schema_version": 1,
    "source": "phase5_production_readiness",
    "readiness_status": readiness_status,
    "action_count": len(actions),
    "actions": actions,
}
report = {
    "schema_version": 1,
    "source": "phase5_production_readiness",
    "readiness_status": readiness_status,
    "failure_count": int(failure_count),
    "skipped_count": int(skipped_count),
    "action_count": int(action_count),
    "requirements": {
        "sdk_root": sdk_root,
        "web_rtc_prefix": web_rtc_prefix,
        "soak_minutes": parse_number(soak_minutes),
        "min_production_soak_minutes": parse_number(min_soak_minutes),
        "allow_xvfb_renderer": allow_xvfb_renderer == "1",
        "real_renderer_use_xvfb": real_renderer_use_xvfb,
        "capture_library_dir": capture_library_dir,
        "capture_library_manifest": capture_library_manifest,
        "require_ready": require_ready == "1",
    },
    "checks": checks,
    "next_required_actions": actions,
}

for path, document in ((report_path, report), (actions_path, actions_doc)):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(document, fh, indent=2, sort_keys=True)
        fh.write("\n")
PY
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
    run_phase5_implementation_gate.sh \
    verify_phase5_implementation_gate.sh \
    verify_phase5_release_contract.sh \
    collect_phase5_debug_bundle.sh \
    verify_phase5_debug_bundle.sh \
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

if [[ "${failures}" -eq 0 && "${skipped_count}" -eq 0 ]]; then
  readiness_status="ready"
else
  readiness_status="not_ready"
fi

write_summary "failure_count=${failures}"
write_summary "skipped_count=${skipped_count}"
write_summary "action_count=${action_count}"
write_summary "next_required_actions_file=${NEXT_REQUIRED_ACTIONS_FILE}"
write_summary "next_required_actions_json=${NEXT_REQUIRED_ACTIONS_JSON}"
write_summary "readiness_report_json=${READINESS_REPORT_JSON}"
write_summary "check_records_jsonl=${CHECK_RECORDS_JSONL}"
write_summary "action_records_jsonl=${ACTION_RECORDS_JSONL}"
write_summary "phase5_production_readiness_status=${readiness_status}"
if [[ "${readiness_status}" != "ready" ]]; then
  write_summary "next_required_actions=fix_failed_checks_then_run_phase5_production_gate_with_SOAK_MINUTES_ge_${MIN_PRODUCTION_SOAK_MINUTES}"
fi
write_readiness_reports "${readiness_status}"
write_summary "files=${FILES_FILE}"
write_summary "manifest=${MANIFEST_FILE}"
write_manifest

if rg -q 'payload|annexb_bytes|rtp_bytes|token|secret|password' \
  "${SUMMARY_FILE}" \
  "${NEXT_REQUIRED_ACTIONS_FILE}" \
  "${NEXT_REQUIRED_ACTIONS_JSON}" \
  "${READINESS_REPORT_JSON}" \
  "${CHECK_RECORDS_JSONL}" \
  "${ACTION_RECORDS_JSONL}"; then
  echo "phase5 production readiness failed: sensitive field in summary" >&2
  exit 1
fi

if [[ "${REQUIRE_READY}" == "1" &&
    ( "${failures}" -ne 0 || "${skipped_count}" -ne 0 ) ]]; then
  exit 1
fi

echo "phase5_production_readiness status=$(if [[ "${failures}" -eq 0 && "${skipped_count}" -eq 0 ]]; then echo ready; else echo not_ready; fi) output_dir=${OUTPUT_DIR}"
