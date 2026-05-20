#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-/root/output}"
DURATION_SEC="${DURATION_SEC:-60}"
MATRIX_RUNS="${MATRIX_RUNS:-1}"
MAX_FAILURES="${MAX_FAILURES:-0}"
BASE_PORT_START="${BASE_PORT_START:-43000}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_udp_soak}"
BUILD_DEMOS="${BUILD_DEMOS:-1}"

mkdir -p "${LOG_DIR}"

if [[ "${BUILD_DEMOS}" != "0" ]]; then
  "${SDK_ROOT}/scripts/build_udp_demos.sh" >/dev/null
fi

start_sec=$(date +%s)
deadline_sec=$((start_sec + DURATION_SEC))
iteration=0
passed=0
failed=0

while [[ "$(date +%s)" -lt "${deadline_sec}" ]]; do
  iteration=$((iteration + 1))
  iter_log_dir="${LOG_DIR}/iter_${iteration}"
  iter_log="${LOG_DIR}/iter_${iteration}.log"
  iter_base_port=$((BASE_PORT_START + iteration * 100))
  mkdir -p "${iter_log_dir}"

  echo "soak iteration=${iteration} duration_sec=${DURATION_SEC} matrix_runs=${MATRIX_RUNS}"
  set +e
  PREFIX="${PREFIX}" \
  SDK_ROOT="${SDK_ROOT}" \
  RUNS="${MATRIX_RUNS}" \
  BASE_PORT_START="${iter_base_port}" \
  LOG_DIR="${iter_log_dir}" \
  BUILD_DEMOS=0 \
    "${SDK_ROOT}/scripts/run_udp_netem_matrix.sh" >"${iter_log}" 2>&1
  rc=$?
  set -e

  if [[ "${rc}" -eq 0 ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "soak iteration failed: ${iteration}" >&2
    cat "${iter_log}" >&2
    if [[ "${failed}" -gt "${MAX_FAILURES}" ]]; then
      echo "udp soak failed passed=${passed} failed=${failed} logs=${LOG_DIR}" >&2
      exit 1
    fi
  fi
done

elapsed_sec=$(($(date +%s) - start_sec))
if [[ "${iteration}" -eq 0 ]]; then
  echo "udp soak did not run any iteration; increase DURATION_SEC" >&2
  exit 1
fi

echo "udp soak passed iterations=${iteration} matrix_runs=${MATRIX_RUNS} elapsed_sec=${elapsed_sec} passed=${passed} failed=${failed} logs=${LOG_DIR}"
