#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
BUILD_DIR="${BUILD_DIR:-${SDK_ROOT}/build}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_dynamic_qos_matrix}"
SCENARIO_FILE="${SCENARIO_FILE:-${SDK_ROOT}/scripts/dynamic_qos_scenarios.json}"

mkdir -p "${LOG_DIR}"

cmake --build "${BUILD_DIR}" --target dynamic_qos_demo -j2 >/dev/null

log_file="${LOG_DIR}/dynamic_qos.log"
"${BUILD_DIR}/dynamic_qos_demo" >"${log_file}" 2>&1

python3 "${SDK_ROOT}/scripts/collect_dynamic_qos_metrics.py" \
  --log "${log_file}" \
  --scenarios "${SCENARIO_FILE}" \
  --summary "${LOG_DIR}/summary.json" \
  --jsonl "${LOG_DIR}/metrics.jsonl"

echo "dynamic qos matrix passed logs=${LOG_DIR} metrics=${LOG_DIR}/metrics.jsonl summary=${LOG_DIR}/summary.json"
