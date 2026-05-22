#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WEBRTC_PREFIX="${WEBRTC_PREFIX:-${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}}"
PHASE5_BUILD_ID="${PHASE5_BUILD_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${SDK_ROOT}/artifacts/phase5_implementation_gate/${PHASE5_BUILD_ID}}"
LOG_DIR="${LOG_DIR:-${OUTPUT_ROOT}/logs}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${OUTPUT_ROOT}/artifacts}"
SUMMARY_FILE="${SUMMARY_FILE:-${OUTPUT_ROOT}/phase5_implementation_gate_summary.txt}"
METADATA_FILE="${METADATA_FILE:-${OUTPUT_ROOT}/metadata.txt}"
FILES_FILE="${FILES_FILE:-${OUTPUT_ROOT}/files.txt}"
MANIFEST_FILE="${MANIFEST_FILE:-${OUTPUT_ROOT}/manifest.sha256}"
PHASE5_IMPLEMENTATION_GATE_METRICS_PROM="${PHASE5_IMPLEMENTATION_GATE_METRICS_PROM:-${OUTPUT_ROOT}/phase5_implementation_gate_metrics.prom}"
TMP_ROOT="${TMP_ROOT:-/tmp/webrtc_qos_phase5_implementation_gate.${PHASE5_BUILD_ID}}"
KEEP_TMP_ROOT="${KEEP_TMP_ROOT:-0}"

FRAMES="${FRAMES:-36}"
RUN_NO_SELFMADE="${RUN_NO_SELFMADE:-1}"
RUN_PHASE5_LOGGING="${RUN_PHASE5_LOGGING:-1}"
RUN_PHASE5_METRICS="${RUN_PHASE5_METRICS:-1}"
RUN_PHASE5_ALERTS="${RUN_PHASE5_ALERTS:-1}"
RUN_PHASE5_ERROR_CONTRACT="${RUN_PHASE5_ERROR_CONTRACT:-1}"
RUN_PHASE5_MINIMAL_UDP_EXTERNAL_APP="${RUN_PHASE5_MINIMAL_UDP_EXTERNAL_APP:-1}"
RUN_PHASE5_RELEASE_CONTRACT="${RUN_PHASE5_RELEASE_CONTRACT:-1}"
RUN_PHASE5_DEBUG_BUNDLE="${RUN_PHASE5_DEBUG_BUNDLE:-1}"

rm -rf "${LOG_DIR}" "${ARTIFACT_DIR}" "${TMP_ROOT}"
mkdir -p "${OUTPUT_ROOT}" "${LOG_DIR}" "${ARTIFACT_DIR}" "${TMP_ROOT}"
rm -f "${SUMMARY_FILE}" "${METADATA_FILE}" "${FILES_FILE}" "${MANIFEST_FILE}" \
  "${PHASE5_IMPLEMENTATION_GATE_METRICS_PROM}"

write_summary() {
  printf '%s\n' "$*" | tee -a "${SUMMARY_FILE}"
}

require_script() {
  local path="$1"
  [[ -x "${path}" ]] || {
    echo "phase5 implementation gate failed: missing executable script: ${path}" >&2
    exit 1
  }
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

write_implementation_gate_metrics() {
  python3 - "${SUMMARY_FILE}" "${PHASE5_IMPLEMENTATION_GATE_METRICS_PROM}" <<'PY'
import collections
import re
import sys

summary_path, metrics_path = sys.argv[1:3]
status = "unknown"
step_order = []
latest_steps = {}
step_re = re.compile(r"^step=([^ ]+) status=([^ ]+)")
with open(summary_path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if line.startswith("phase5_implementation_gate_status="):
            status = line.split("=", 1)[1]
        match = step_re.match(line)
        if match:
            step, step_status = match.groups()
            if step not in latest_steps:
                step_order.append(step)
            latest_steps[step] = step_status


def prom_escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def prom_labels(**labels):
    items = [
        f'{key}="{prom_escape(value)}"'
        for key, value in sorted(labels.items())
        if value is not None and value != ""
    ]
    return "{" + ",".join(items) + "}" if items else ""


step_counts = collections.Counter(latest_steps.values())
debug_bundle_status = (
    latest_steps.get("verify_phase5_debug_bundle")
    or latest_steps.get("collect_phase5_debug_bundle")
    or latest_steps.get("phase5_debug_bundle")
    or "not_reached"
)
with open(metrics_path, "w", encoding="utf-8") as fh:
    fh.write("# HELP webrtc_qos_phase5_implementation_gate_info Phase-5 implementation gate status marker.\n")
    fh.write("# TYPE webrtc_qos_phase5_implementation_gate_info gauge\n")
    fh.write(
        "webrtc_qos_phase5_implementation_gate_info"
        f"{prom_labels(source='phase5_implementation_gate', status=status)} 1\n"
    )
    fh.write("# HELP webrtc_qos_phase5_implementation_gate_steps_total Phase-5 implementation gate step count by final status.\n")
    fh.write("# TYPE webrtc_qos_phase5_implementation_gate_steps_total gauge\n")
    for step_status in ("pass", "fail", "skipped", "running"):
        fh.write(
            "webrtc_qos_phase5_implementation_gate_steps_total"
            f"{prom_labels(status=step_status)} {step_counts.get(step_status, 0)}\n"
        )
    fh.write("# HELP webrtc_qos_phase5_implementation_gate_step_status Phase-5 implementation gate latest step status.\n")
    fh.write("# TYPE webrtc_qos_phase5_implementation_gate_step_status gauge\n")
    for step in step_order:
        fh.write(
            "webrtc_qos_phase5_implementation_gate_step_status"
            f"{prom_labels(status=latest_steps[step], step=step)} 1\n"
        )
    fh.write("# HELP webrtc_qos_phase5_implementation_gate_debug_bundle_status Phase-5 implementation gate debug bundle status marker.\n")
    fh.write("# TYPE webrtc_qos_phase5_implementation_gate_debug_bundle_status gauge\n")
    fh.write(
        "webrtc_qos_phase5_implementation_gate_debug_bundle_status"
        f"{prom_labels(status=debug_bundle_status)} 1\n"
    )
PY
}

run_step() {
  local name="$1"
  shift
  local log_file="${LOG_DIR}/${name}.log"
  write_summary "step=${name} status=running"
  if "$@" >"${log_file}" 2>&1; then
    write_summary "step=${name} status=pass log=${log_file}"
  else
    local status=$?
    write_summary "step=${name} status=fail exit=${status} log=${log_file}"
    write_summary "phase5_implementation_gate_status=fail"
    write_summary "phase5_implementation_gate_metrics=${PHASE5_IMPLEMENTATION_GATE_METRICS_PROM}"
    write_implementation_gate_metrics
    write_manifest
    tail -n 80 "${log_file}" >&2 || true
    exit "${status}"
  fi
}

skip_step() {
  local name="$1"
  local reason="$2"
  write_summary "step=${name} status=skipped ${reason}"
}

require_script "${SDK_ROOT}/scripts/verify_no_selfmade_media_stack.sh"
require_script "${SDK_ROOT}/scripts/verify_phase5_logging.sh"
require_script "${SDK_ROOT}/scripts/verify_phase5_metrics.sh"
require_script "${SDK_ROOT}/scripts/verify_phase5_alerts.sh"
require_script "${SDK_ROOT}/scripts/verify_phase5_error_contract.sh"
require_script "${SDK_ROOT}/scripts/verify_phase5_minimal_udp_external_app.sh"
require_script "${SDK_ROOT}/scripts/verify_phase5_release_contract.sh"
require_script "${SDK_ROOT}/scripts/collect_phase5_debug_bundle.sh"
require_script "${SDK_ROOT}/scripts/verify_phase5_debug_bundle.sh"

{
  printf 'PHASE5_BUILD_ID=%s\n' "${PHASE5_BUILD_ID}"
  printf 'SDK_ROOT=%s\n' "${SDK_ROOT}"
  printf 'WEBRTC_PREFIX=%s\n' "${WEBRTC_PREFIX}"
  printf 'OUTPUT_ROOT=%s\n' "${OUTPUT_ROOT}"
  printf 'LOG_DIR=%s\n' "${LOG_DIR}"
  printf 'ARTIFACT_DIR=%s\n' "${ARTIFACT_DIR}"
  printf 'TMP_ROOT=%s\n' "${TMP_ROOT}"
  printf 'KEEP_TMP_ROOT=%s\n' "${KEEP_TMP_ROOT}"
  printf 'FRAMES=%s\n' "${FRAMES}"
  printf 'RUN_NO_SELFMADE=%s\n' "${RUN_NO_SELFMADE}"
  printf 'RUN_PHASE5_LOGGING=%s\n' "${RUN_PHASE5_LOGGING}"
  printf 'RUN_PHASE5_METRICS=%s\n' "${RUN_PHASE5_METRICS}"
  printf 'RUN_PHASE5_ALERTS=%s\n' "${RUN_PHASE5_ALERTS}"
  printf 'RUN_PHASE5_ERROR_CONTRACT=%s\n' "${RUN_PHASE5_ERROR_CONTRACT}"
  printf 'RUN_PHASE5_MINIMAL_UDP_EXTERNAL_APP=%s\n' "${RUN_PHASE5_MINIMAL_UDP_EXTERNAL_APP}"
  printf 'RUN_PHASE5_RELEASE_CONTRACT=%s\n' "${RUN_PHASE5_RELEASE_CONTRACT}"
  printf 'RUN_PHASE5_DEBUG_BUNDLE=%s\n' "${RUN_PHASE5_DEBUG_BUNDLE}"
  printf 'COLLECTED_AT_UTC=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if git -C "${SDK_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'GIT_HEAD=%s\n' "$(git -C "${SDK_ROOT}" rev-parse HEAD)"
    printf 'GIT_BRANCH=%s\n' "$(git -C "${SDK_ROOT}" rev-parse --abbrev-ref HEAD)"
  fi
} >"${METADATA_FILE}"

write_summary "phase5_implementation_gate=running"
write_summary "sdk_root=${SDK_ROOT}"
write_summary "webrtc_prefix=${WEBRTC_PREFIX}"
write_summary "output_root=${OUTPUT_ROOT}"
write_summary "artifact_dir=${ARTIFACT_DIR}"
write_summary "tmp_root=${TMP_ROOT}"

if [[ "${RUN_NO_SELFMADE}" == "1" ]]; then
  run_step no_selfmade_media_stack \
    env SDK_ROOT="${SDK_ROOT}" PREFIX="${WEBRTC_PREFIX}" \
      "${SDK_ROOT}/scripts/verify_no_selfmade_media_stack.sh"
else
  skip_step no_selfmade_media_stack "RUN_NO_SELFMADE=${RUN_NO_SELFMADE}"
fi

if [[ "${RUN_PHASE5_LOGGING}" == "1" ]]; then
  run_step phase5_logging \
    env SDK_ROOT="${SDK_ROOT}" PREFIX="${WEBRTC_PREFIX}" KEEP_WORK_DIR=1 \
      BUILD_DIR="${TMP_ROOT}/logging_build" \
      LOG_DIR="${ARTIFACT_DIR}/logging/main" \
      ROTATION_LOG_DIR="${ARTIFACT_DIR}/logging/rotation" \
      QUEUE_LOG_DIR="${ARTIFACT_DIR}/logging/queue" \
      FRAMES="${FRAMES}" \
      "${SDK_ROOT}/scripts/verify_phase5_logging.sh"
else
  skip_step phase5_logging "RUN_PHASE5_LOGGING=${RUN_PHASE5_LOGGING}"
fi

if [[ "${RUN_PHASE5_METRICS}" == "1" ]]; then
  run_step phase5_metrics \
    env SDK_ROOT="${SDK_ROOT}" PREFIX="${WEBRTC_PREFIX}" KEEP_WORK_DIR=1 \
      BUILD_DIR="${TMP_ROOT}/metrics_build" \
      METRICS_DIR="${ARTIFACT_DIR}/metrics/main" \
      ROTATION_METRICS_DIR="${ARTIFACT_DIR}/metrics/rotation" \
      FRAMES="${FRAMES}" \
      "${SDK_ROOT}/scripts/verify_phase5_metrics.sh"
else
  skip_step phase5_metrics "RUN_PHASE5_METRICS=${RUN_PHASE5_METRICS}"
fi

if [[ "${RUN_PHASE5_ALERTS}" == "1" ]]; then
  run_step phase5_alerts \
    env SDK_ROOT="${SDK_ROOT}" PREFIX="${WEBRTC_PREFIX}" KEEP_WORK_DIR=1 \
      BUILD_DIR="${TMP_ROOT}/alerts_build" \
      INSTALL_PREFIX="${TMP_ROOT}/alerts_install" \
      WORK_DIR="${TMP_ROOT}/alerts_fixture" \
      ALERTS_DIR="${ARTIFACT_DIR}/alerts/main" \
      ROTATION_ALERTS_DIR="${ARTIFACT_DIR}/alerts/rotation" \
      LOG_DIR="${ARTIFACT_DIR}/alerts/logs" \
      FRAMES="${FRAMES}" \
      "${SDK_ROOT}/scripts/verify_phase5_alerts.sh"
else
  skip_step phase5_alerts "RUN_PHASE5_ALERTS=${RUN_PHASE5_ALERTS}"
fi

if [[ "${RUN_PHASE5_ERROR_CONTRACT}" == "1" ]]; then
  run_step phase5_error_contract \
    env SDK_ROOT="${SDK_ROOT}" PREFIX="${WEBRTC_PREFIX}" KEEP_WORK_DIR=1 \
      BUILD_DIR="${TMP_ROOT}/error_contract_build" \
      INSTALL_PREFIX="${TMP_ROOT}/error_contract_install" \
      WORK_DIR="${TMP_ROOT}/error_contract_fixture" \
      LOG_DIR="${ARTIFACT_DIR}/error_contract/logs" \
      ALERTS_DIR="${ARTIFACT_DIR}/error_contract/alerts" \
      "${SDK_ROOT}/scripts/verify_phase5_error_contract.sh"
else
  skip_step phase5_error_contract "RUN_PHASE5_ERROR_CONTRACT=${RUN_PHASE5_ERROR_CONTRACT}"
fi

if [[ "${RUN_PHASE5_MINIMAL_UDP_EXTERNAL_APP}" == "1" ]]; then
  run_step phase5_minimal_udp_external_app \
    env SDK_ROOT="${SDK_ROOT}" PREFIX="${WEBRTC_PREFIX}" KEEP_WORK_DIR=1 \
      SOURCE_BUILD_DIR="${TMP_ROOT}/minimal_source_build" \
      INSTALL_PREFIX="${TMP_ROOT}/minimal_install" \
      APP_BUILD_DIR="${TMP_ROOT}/minimal_app_build" \
      LOG_DIR="${ARTIFACT_DIR}/minimal_udp_external/logs" \
      METRICS_DIR="${ARTIFACT_DIR}/minimal_udp_external/metrics" \
      ALERTS_DIR="${ARTIFACT_DIR}/minimal_udp_external/alerts" \
      FRAMES="${FRAMES}" \
      "${SDK_ROOT}/scripts/verify_phase5_minimal_udp_external_app.sh"
else
  skip_step phase5_minimal_udp_external_app \
    "RUN_PHASE5_MINIMAL_UDP_EXTERNAL_APP=${RUN_PHASE5_MINIMAL_UDP_EXTERNAL_APP}"
fi

if [[ "${RUN_PHASE5_RELEASE_CONTRACT}" == "1" ]]; then
  run_step phase5_release_contract \
    env SDK_ROOT="${SDK_ROOT}" PREFIX="${WEBRTC_PREFIX}" KEEP_WORK_DIR=1 \
      BUILD_DIR="${TMP_ROOT}/release_contract_build" \
      INSTALL_PREFIX="${TMP_ROOT}/release_contract_install" \
      WORK_DIR="${TMP_ROOT}/release_contract_consumer" \
      LOG_DIR="${ARTIFACT_DIR}/release_contract/logs" \
      METRICS_DIR="${ARTIFACT_DIR}/release_contract/metrics" \
      ALERTS_DIR="${ARTIFACT_DIR}/release_contract/alerts" \
      "${SDK_ROOT}/scripts/verify_phase5_release_contract.sh"
else
  skip_step phase5_release_contract \
    "RUN_PHASE5_RELEASE_CONTRACT=${RUN_PHASE5_RELEASE_CONTRACT}"
fi

if [[ "${RUN_PHASE5_DEBUG_BUNDLE}" == "1" ]]; then
  run_step collect_phase5_debug_bundle \
    env SDK_ROOT="${SDK_ROOT}" PREFIX="${WEBRTC_PREFIX}" \
      BUILD_DIR="${TMP_ROOT}/debug_bundle_build" \
      WORK_DIR="${TMP_ROOT}/debug_bundle_work" \
      OUTPUT_DIR="${ARTIFACT_DIR}/debug_bundle" \
      FRAMES="${FRAMES}" \
      "${SDK_ROOT}/scripts/collect_phase5_debug_bundle.sh"
  run_step verify_phase5_debug_bundle \
    env BUNDLE_DIR="${ARTIFACT_DIR}/debug_bundle" \
      "${SDK_ROOT}/scripts/verify_phase5_debug_bundle.sh"
else
  skip_step phase5_debug_bundle "RUN_PHASE5_DEBUG_BUNDLE=${RUN_PHASE5_DEBUG_BUNDLE}"
fi

write_summary "phase5_implementation_gate_status=pass"
write_summary "phase5_debug_bundle=${ARTIFACT_DIR}/debug_bundle"
write_summary "phase5_logging_artifacts=${ARTIFACT_DIR}/logging"
write_summary "phase5_metrics_artifacts=${ARTIFACT_DIR}/metrics"
write_summary "phase5_alerts_artifacts=${ARTIFACT_DIR}/alerts"
write_summary "phase5_error_contract_artifacts=${ARTIFACT_DIR}/error_contract"
write_summary "phase5_minimal_udp_external_artifacts=${ARTIFACT_DIR}/minimal_udp_external"
write_summary "phase5_release_contract_artifacts=${ARTIFACT_DIR}/release_contract"
write_summary "phase5_implementation_gate_metrics=${PHASE5_IMPLEMENTATION_GATE_METRICS_PROM}"
write_summary "manifest=${MANIFEST_FILE}"
write_implementation_gate_metrics
write_manifest

if [[ "${KEEP_TMP_ROOT}" != "1" ]]; then
  rm -rf "${TMP_ROOT}"
fi

if [[ "${OUTPUT_ROOT}" == "${SDK_ROOT}/artifacts/phase5_implementation_gate/"* ]]; then
  ln -sfn "$(basename "${OUTPUT_ROOT}")" \
    "${SDK_ROOT}/artifacts/phase5_implementation_gate/latest"
fi

echo "phase5_implementation_gate pass output_root=${OUTPUT_ROOT}"
