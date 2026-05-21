#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SUMMARY_FILE="${SUMMARY_FILE:-${SDK_ROOT}/artifacts/webrtc_first_recovery_distribution/recovery_distribution_summary.txt}"
MIN_RECOVERY_SAMPLES="${MIN_RECOVERY_SAMPLES:-1}"
MAX_TARGET_RECOVERY_P95_MS="${MAX_TARGET_RECOVERY_P95_MS:-1000}"
MAX_FPS_RECOVERY_P95_MS="${MAX_FPS_RECOVERY_P95_MS:-1000}"
MAX_FULL_RECOVERY_P95_MS="${MAX_FULL_RECOVERY_P95_MS:-1000}"
MAX_TARGET_RECOVERY_MS="${MAX_TARGET_RECOVERY_MS:-1000}"
MAX_FPS_RECOVERY_MS="${MAX_FPS_RECOVERY_MS:-1000}"
MAX_FULL_RECOVERY_MS="${MAX_FULL_RECOVERY_MS:-1000}"
RECOVERABLE_SCENARIOS="${RECOVERABLE_SCENARIOS:-bandwidth_cliff_recover,weak_network_low_rps_low_bitrate,walking_dead_zone_recover,oscillating_edge_recover}"

if [[ "$#" -eq 0 ]]; then
  echo "usage: $0 <qoe.csv> [more.csv ...]" >&2
  exit 2
fi

mkdir -p "$(dirname "${SUMMARY_FILE}")"

python3 "${SDK_ROOT}/scripts/verify_recovery_time_distribution.py" \
  --summary "${SUMMARY_FILE}" \
  --recoverable-scenarios "${RECOVERABLE_SCENARIOS}" \
  --min-samples "${MIN_RECOVERY_SAMPLES}" \
  --max-target-p95-ms "${MAX_TARGET_RECOVERY_P95_MS}" \
  --max-fps-p95-ms "${MAX_FPS_RECOVERY_P95_MS}" \
  --max-full-p95-ms "${MAX_FULL_RECOVERY_P95_MS}" \
  --max-target-ms "${MAX_TARGET_RECOVERY_MS}" \
  --max-fps-ms "${MAX_FPS_RECOVERY_MS}" \
  --max-full-ms "${MAX_FULL_RECOVERY_MS}" \
  --require-pass \
  "$@"
