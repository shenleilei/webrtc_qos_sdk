#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WEBRTC_PREFIX="${WEBRTC_PREFIX:-${SDK_ROOT}/dist/linux-x86_64}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/webrtc_first_qoe_production_soak}"
CYCLE_DIR="${CYCLE_DIR:-${OUTPUT_DIR}/cycles}"
SOAK_RUN_ID="${SOAK_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
SOAK_ARCHIVE="${SOAK_ARCHIVE:-1}"
SOAK_ARCHIVE_DIR="${SOAK_ARCHIVE_DIR:-${OUTPUT_DIR}/archive}"
SOAK_ARCHIVE_TARBALL="${SOAK_ARCHIVE_TARBALL:-${OUTPUT_DIR}/webrtc_first_qoe_production_soak_archive.tar.gz}"

SOAK_CYCLES="${SOAK_CYCLES:-3}"
SOAK_MINUTES="${SOAK_MINUTES:-0}"
SOAK_STOP_ON_FAILURE="${SOAK_STOP_ON_FAILURE:-1}"
FRAMES_PER_CYCLE="${FRAMES_PER_CYCLE:-120}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
START_BITRATE_BPS="${START_BITRATE_BPS:-1500000}"
MIN_BITRATE_BPS="${MIN_BITRATE_BPS:-300000}"
MAX_BITRATE_BPS="${MAX_BITRATE_BPS:-2800000}"
MIN_PLAYABLE_RATIO="${MIN_PLAYABLE_RATIO:-0.8}"
MIN_AVG_PSNR_Y="${MIN_AVG_PSNR_Y:-20.0}"
MIN_AVG_SSIM_Y="${MIN_AVG_SSIM_Y:-0.80}"
MAX_WEAK_SEND_RPS="${MAX_WEAK_SEND_RPS:-15.0}"
MAX_WEAK_RTP_PPS="${MAX_WEAK_RTP_PPS:-210.0}"
MAX_WEAK_TARGET_BPS="${MAX_WEAK_TARGET_BPS:-750000}"
MAX_WEAK_ENCODER_FPS="${MAX_WEAK_ENCODER_FPS:-10}"
MAX_RECOVERY_TIME_MS="${MAX_RECOVERY_TIME_MS:-1000}"
RENDERER_PROXY_TARGET_DELAY_MS="${RENDERER_PROXY_TARGET_DELAY_MS:-350}"
MAX_RENDERER_PROXY_LATE_MS="${MAX_RENDERER_PROXY_LATE_MS:-150}"
MAX_RENDERER_PROXY_LATENCY_MS="${MAX_RENDERER_PROXY_LATENCY_MS:-500}"
MAX_RENDERER_PROXY_LATE_FRAMES="${MAX_RENDERER_PROXY_LATE_FRAMES:-0}"
MAX_RENDERER_PROXY_DROP_FRAMES="${MAX_RENDERER_PROXY_DROP_FRAMES:-0}"
MAX_RENDERER_PROXY_GAP_MS="${MAX_RENDERER_PROXY_GAP_MS:-150}"
SEEDS="${SEEDS:-1}"
CONTENT_MODES="${CONTENT_MODES:-block_motion camera_pan scene_cut low_light_noise}"
SCENARIOS="${SCENARIOS:-baseline weak_network_low_rps_low_bitrate walking_dead_zone_recover oscillating_edge_recover}"

mkdir -p "${OUTPUT_DIR}" "${CYCLE_DIR}"

SUMMARY_CSV="${OUTPUT_DIR}/webrtc_first_qoe_production_soak.csv"
SUMMARY_TXT="${OUTPUT_DIR}/webrtc_first_qoe_production_soak_summary.txt"
CONFIG_ENV="${OUTPUT_DIR}/webrtc_first_qoe_production_soak_config.env"
rm -f "${SUMMARY_CSV}" "${SUMMARY_TXT}" "${CONFIG_ENV}"

write_config_snapshot() {
  {
    printf 'SOAK_RUN_ID=%q\n' "${SOAK_RUN_ID}"
    printf 'SDK_ROOT=%q\n' "${SDK_ROOT}"
    printf 'WEBRTC_PREFIX=%q\n' "${WEBRTC_PREFIX}"
    printf 'OUTPUT_DIR=%q\n' "${OUTPUT_DIR}"
    printf 'CYCLE_DIR=%q\n' "${CYCLE_DIR}"
    printf 'SOAK_CYCLES=%q\n' "${SOAK_CYCLES}"
    printf 'SOAK_MINUTES=%q\n' "${SOAK_MINUTES}"
    printf 'SOAK_STOP_ON_FAILURE=%q\n' "${SOAK_STOP_ON_FAILURE}"
    printf 'FRAMES_PER_CYCLE=%q\n' "${FRAMES_PER_CYCLE}"
    printf 'WIDTH=%q\n' "${WIDTH}"
    printf 'HEIGHT=%q\n' "${HEIGHT}"
    printf 'START_BITRATE_BPS=%q\n' "${START_BITRATE_BPS}"
    printf 'MIN_BITRATE_BPS=%q\n' "${MIN_BITRATE_BPS}"
    printf 'MAX_BITRATE_BPS=%q\n' "${MAX_BITRATE_BPS}"
    printf 'MIN_PLAYABLE_RATIO=%q\n' "${MIN_PLAYABLE_RATIO}"
    printf 'MIN_AVG_PSNR_Y=%q\n' "${MIN_AVG_PSNR_Y}"
    printf 'MIN_AVG_SSIM_Y=%q\n' "${MIN_AVG_SSIM_Y}"
    printf 'MAX_WEAK_SEND_RPS=%q\n' "${MAX_WEAK_SEND_RPS}"
    printf 'MAX_WEAK_RTP_PPS=%q\n' "${MAX_WEAK_RTP_PPS}"
    printf 'MAX_WEAK_TARGET_BPS=%q\n' "${MAX_WEAK_TARGET_BPS}"
    printf 'MAX_WEAK_ENCODER_FPS=%q\n' "${MAX_WEAK_ENCODER_FPS}"
    printf 'MAX_RECOVERY_TIME_MS=%q\n' "${MAX_RECOVERY_TIME_MS}"
    printf 'RENDERER_PROXY_TARGET_DELAY_MS=%q\n' "${RENDERER_PROXY_TARGET_DELAY_MS}"
    printf 'MAX_RENDERER_PROXY_LATE_MS=%q\n' "${MAX_RENDERER_PROXY_LATE_MS}"
    printf 'MAX_RENDERER_PROXY_LATENCY_MS=%q\n' "${MAX_RENDERER_PROXY_LATENCY_MS}"
    printf 'MAX_RENDERER_PROXY_LATE_FRAMES=%q\n' "${MAX_RENDERER_PROXY_LATE_FRAMES}"
    printf 'MAX_RENDERER_PROXY_DROP_FRAMES=%q\n' "${MAX_RENDERER_PROXY_DROP_FRAMES}"
    printf 'MAX_RENDERER_PROXY_GAP_MS=%q\n' "${MAX_RENDERER_PROXY_GAP_MS}"
    printf 'SEEDS=%q\n' "${SEEDS}"
    printf 'CONTENT_MODES=%q\n' "${CONTENT_MODES}"
    printf 'SCENARIOS=%q\n' "${SCENARIOS}"
  } >"${CONFIG_ENV}"
}

write_config_snapshot

start_epoch="$(date +%s)"
start_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
deadline_epoch="${start_epoch}"
if [[ "${SOAK_MINUTES}" -gt 0 ]]; then
  deadline_epoch="$((start_epoch + SOAK_MINUTES * 60))"
fi

cycle=1
overall_ok=1
while :; do
  now_epoch="$(date +%s)"
  if [[ "${SOAK_MINUTES}" -gt 0 ]]; then
    if [[ "${cycle}" -gt 1 && "${now_epoch}" -ge "${deadline_epoch}" ]]; then
      break
    fi
  elif [[ "${cycle}" -gt "${SOAK_CYCLES}" ]]; then
    break
  fi

  cycle_basename="webrtc_first_qoe_production_soak_cycle_${cycle}"
  cycle_csv="${CYCLE_DIR}/${cycle_basename}.csv"
  cycle_log="${CYCLE_DIR}/${cycle_basename}.log"
  echo "production_soak cycle=${cycle} frames=${FRAMES_PER_CYCLE} scenarios=${SCENARIOS} content_modes=${CONTENT_MODES}" | tee -a "${SUMMARY_TXT}"

  if ! SDK_ROOT="${SDK_ROOT}" \
      WEBRTC_PREFIX="${WEBRTC_PREFIX}" \
      OUTPUT_DIR="${CYCLE_DIR}" \
      OUTPUT_BASENAME="${cycle_basename}" \
      FRAMES="${FRAMES_PER_CYCLE}" \
      WIDTH="${WIDTH}" \
      HEIGHT="${HEIGHT}" \
      START_BITRATE_BPS="${START_BITRATE_BPS}" \
      MIN_BITRATE_BPS="${MIN_BITRATE_BPS}" \
      MAX_BITRATE_BPS="${MAX_BITRATE_BPS}" \
      MIN_PLAYABLE_RATIO="${MIN_PLAYABLE_RATIO}" \
      MIN_AVG_PSNR_Y="${MIN_AVG_PSNR_Y}" \
      MIN_AVG_SSIM_Y="${MIN_AVG_SSIM_Y}" \
      MAX_WEAK_SEND_RPS="${MAX_WEAK_SEND_RPS}" \
      MAX_WEAK_RTP_PPS="${MAX_WEAK_RTP_PPS}" \
      MAX_WEAK_TARGET_BPS="${MAX_WEAK_TARGET_BPS}" \
      MAX_WEAK_ENCODER_FPS="${MAX_WEAK_ENCODER_FPS}" \
      MAX_RECOVERY_TIME_MS="${MAX_RECOVERY_TIME_MS}" \
      RENDERER_PROXY_TARGET_DELAY_MS="${RENDERER_PROXY_TARGET_DELAY_MS}" \
      MAX_RENDERER_PROXY_LATE_MS="${MAX_RENDERER_PROXY_LATE_MS}" \
      MAX_RENDERER_PROXY_LATENCY_MS="${MAX_RENDERER_PROXY_LATENCY_MS}" \
      MAX_RENDERER_PROXY_LATE_FRAMES="${MAX_RENDERER_PROXY_LATE_FRAMES}" \
      MAX_RENDERER_PROXY_DROP_FRAMES="${MAX_RENDERER_PROXY_DROP_FRAMES}" \
      MAX_RENDERER_PROXY_GAP_MS="${MAX_RENDERER_PROXY_GAP_MS}" \
      SEEDS="${SEEDS}" \
      CONTENT_MODES="${CONTENT_MODES}" \
      SCENARIOS="${SCENARIOS}" \
      "${SDK_ROOT}/scripts/run_webrtc_first_ffmpeg_qoe.sh" >"${cycle_log}" 2>&1; then
    overall_ok=0
    echo "production_soak cycle=${cycle} status=failed" | tee -a "${SUMMARY_TXT}"
    if [[ "${SOAK_STOP_ON_FAILURE}" -eq 1 ]]; then
      break
    fi
  else
    echo "production_soak cycle=${cycle} status=passed" | tee -a "${SUMMARY_TXT}"
  fi

  if [[ -s "${cycle_csv}" ]]; then
    if [[ ! -s "${SUMMARY_CSV}" ]]; then
      head -n 1 "${cycle_csv}" | sed 's/^/cycle,/' >"${SUMMARY_CSV}"
      tail -n +2 "${cycle_csv}" | sed "s/^/${cycle},/" >>"${SUMMARY_CSV}"
    else
      tail -n +2 "${cycle_csv}" | sed "s/^/${cycle},/" >>"${SUMMARY_CSV}"
    fi
  fi

  cycle=$((cycle + 1))
done

if [[ ! -s "${SUMMARY_CSV}" ]]; then
  echo "production_soak no cycle CSV was produced" >&2
  exit 1
fi

MIN_BITRATE_BPS="${MIN_BITRATE_BPS}" \
MAX_WEAK_SEND_RPS="${MAX_WEAK_SEND_RPS}" \
MAX_WEAK_RTP_PPS="${MAX_WEAK_RTP_PPS}" \
MAX_WEAK_TARGET_BPS="${MAX_WEAK_TARGET_BPS}" \
MAX_WEAK_ENCODER_FPS="${MAX_WEAK_ENCODER_FPS}" \
python3 - "${SUMMARY_CSV}" "${SUMMARY_TXT}" <<'PY'
import csv
import os
import sys

csv_path, summary_path = sys.argv[1], sys.argv[2]
rows = list(csv.DictReader(open(csv_path, newline="")))
if not rows:
    raise SystemExit("production_soak summary has no rows")

def f(row, key):
    value = row.get(key, "")
    return float(value) if value not in ("", None) else 0.0

failed = [row for row in rows if row.get("pass") != "true"]
decode_errors = sum(f(row, "decode_errors") for row in rows)
freeze_count = sum(f(row, "freeze_count") for row in rows)
renderer_late = sum(f(row, "renderer_proxy_late_frames") for row in rows)
renderer_drop = sum(f(row, "renderer_proxy_drop_frames") for row in rows)
push_queue_full = sum(f(row, "push_queue_full") for row in rows)
cycles = sorted({int(float(row["cycle"])) for row in rows})
recoverable_scenarios = {
    "bandwidth_cliff_recover",
    "weak_network_low_rps_low_bitrate",
    "walking_dead_zone_recover",
    "oscillating_edge_recover",
}
recoverable_rows = [
    row for row in rows if row.get("scenario", "") in recoverable_scenarios
]
full_recovery_values = [
    f(row, "full_recovery_time_ms")
    for row in recoverable_rows
    if f(row, "full_recovery_time_ms") >= 0
]
weak_low_scenarios = {
    "bandwidth_cliff_recover",
    "weak_network_low_rps_low_bitrate",
    "sustained_low_bandwidth_low_rps",
    "weak_start_low_bandwidth_low_rps",
    "walking_dead_zone_recover",
    "oscillating_edge_recover",
}
weak_low_rows = [row for row in rows if row.get("scenario", "") in weak_low_scenarios]
max_weak_send_rps = float(os.environ["MAX_WEAK_SEND_RPS"])
max_weak_rtp_pps = float(os.environ["MAX_WEAK_RTP_PPS"])
max_weak_target_bps = int(float(os.environ["MAX_WEAK_TARGET_BPS"]))
if max_weak_target_bps <= 0:
    min_bitrate_bps = int(float(os.environ["MIN_BITRATE_BPS"]))
    max_weak_target_bps = max(min_bitrate_bps * 2, min_bitrate_bps)
max_weak_encoder_fps = int(float(os.environ["MAX_WEAK_ENCODER_FPS"]))
weak_low_failures = []
for row in weak_low_rows:
    row_failures = []
    if max_weak_send_rps > 0 and f(row, "bad_send_rps") > max_weak_send_rps:
        row_failures.append("bad_send_rps=%g>%g" % (f(row, "bad_send_rps"), max_weak_send_rps))
    if max_weak_rtp_pps > 0 and f(row, "bad_rtp_pps") > max_weak_rtp_pps:
        row_failures.append("bad_rtp_pps=%g>%g" % (f(row, "bad_rtp_pps"), max_weak_rtp_pps))
    if f(row, "max_bad_target_bps") <= 0 or f(row, "max_bad_target_bps") > max_weak_target_bps:
        row_failures.append(
            "max_bad_target_bps=%g>%d" % (f(row, "max_bad_target_bps"), max_weak_target_bps)
        )
    if f(row, "max_bad_encoder_fps") <= 0 or f(row, "max_bad_encoder_fps") > max_weak_encoder_fps:
        row_failures.append(
            "max_bad_encoder_fps=%g>%d" % (f(row, "max_bad_encoder_fps"), max_weak_encoder_fps)
        )
    if row_failures:
        weak_low_failures.append("%s/%s: %s" % (row.get("cycle", "?"), row.get("scenario", "?"), "; ".join(row_failures)))

summary = {
    "cycles": len(cycles),
    "rows": len(rows),
    "pass_rows": len(rows) - len(failed),
    "playable_ratio_min": min(f(row, "playable_ratio") for row in rows),
    "avg_psnr_y_min": min(f(row, "avg_psnr_y") for row in rows),
    "avg_ssim_y_min": min(f(row, "avg_ssim_y") for row in rows),
    "decode_errors": decode_errors,
    "freeze_count": freeze_count,
    "renderer_proxy_late_frames": renderer_late,
    "renderer_proxy_drop_frames": renderer_drop,
    "renderer_proxy_max_latency_ms": max(f(row, "renderer_proxy_max_latency_ms") for row in rows),
    "renderer_proxy_max_gap_ms": max(f(row, "renderer_proxy_max_gap_ms") for row in rows),
    "renderer_proxy_max_jitter_ms": max(f(row, "renderer_proxy_max_jitter_ms") for row in rows),
    "push_queue_full": push_queue_full,
    "bad_send_rps_max": max(f(row, "bad_send_rps") for row in rows),
    "bad_rtp_pps_max": max(f(row, "bad_rtp_pps") for row in rows),
    "max_bad_target_bps_max": max(f(row, "max_bad_target_bps") for row in rows),
    "max_bad_encoder_fps_max": max(f(row, "max_bad_encoder_fps") for row in rows),
    "weak_low_rows": len(weak_low_rows),
    "weak_low_bad_send_rps_max": max((f(row, "bad_send_rps") for row in weak_low_rows), default=0),
    "weak_low_bad_rtp_pps_max": max((f(row, "bad_rtp_pps") for row in weak_low_rows), default=0),
    "weak_low_target_bps_max": max((f(row, "max_bad_target_bps") for row in weak_low_rows), default=0),
    "weak_low_encoder_fps_max": max((f(row, "max_bad_encoder_fps") for row in weak_low_rows), default=0),
    "weak_low_max_send_rps": max_weak_send_rps,
    "weak_low_max_rtp_pps": max_weak_rtp_pps,
    "weak_low_max_target_bps": max_weak_target_bps,
    "weak_low_max_encoder_fps": max_weak_encoder_fps,
    "recoverable_rows": len(recoverable_rows),
    "full_recovery_time_ms_max": max(full_recovery_values) if full_recovery_values else -1,
}

with open(summary_path, "a", newline="") as out:
    out.write("production_soak_summary\n")
    for key, value in summary.items():
        out.write(f"{key}={value}\n")

for key, value in summary.items():
    print(f"{key}={value}")

if weak_low_failures:
    raise SystemExit("production_soak weak low-RPS/bitrate failures: %s" % weak_low_failures[:8])

if failed or decode_errors or freeze_count or renderer_late or renderer_drop or push_queue_full:
    raise SystemExit(1)
PY

if [[ "${overall_ok}" -ne 1 ]]; then
  exit 1
fi

if [[ "${SOAK_ARCHIVE}" == "1" ]]; then
  mkdir -p "${SOAK_ARCHIVE_DIR}"
  python3 "${SDK_ROOT}/scripts/verify_recovery_time_distribution.py" \
    --summary "${SOAK_ARCHIVE_DIR}/recovery_distribution_summary.txt" \
    --min-samples 1 \
    --max-target-p95-ms 1000 \
    --max-fps-p95-ms 1000 \
    --max-full-p95-ms 1000 \
    --max-target-ms 1000 \
    --max-fps-ms 1000 \
    --max-full-ms 1000 \
    --require-pass \
    "${SUMMARY_CSV}" >/dev/null
  end_epoch="$(date +%s)"
  end_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  metadata_file="${SOAK_ARCHIVE_DIR}/metadata.txt"
  git_commit="$(git -C "${SDK_ROOT}" rev-parse HEAD 2>/dev/null || true)"
  git_branch="$(git -C "${SDK_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  git_dirty="unknown"
  if git -C "${SDK_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "${SDK_ROOT}" diff --quiet --ignore-submodules -- &&
       git -C "${SDK_ROOT}" diff --cached --quiet --ignore-submodules --; then
      git_dirty="false"
    else
      git_dirty="true"
    fi
  fi
  {
    echo "soak_run_id=${SOAK_RUN_ID}"
    echo "start_utc=${start_utc}"
    echo "end_utc=${end_utc}"
    echo "duration_sec=$((end_epoch - start_epoch))"
    echo "hostname=$(hostname 2>/dev/null || true)"
    echo "uname=$(uname -a 2>/dev/null || true)"
    echo "sdk_root=${SDK_ROOT}"
    echo "sdk_git_commit=${git_commit:-unknown}"
    echo "sdk_git_branch=${git_branch:-unknown}"
    echo "sdk_git_dirty=${git_dirty}"
    echo "webrtc_prefix=${WEBRTC_PREFIX}"
    echo "summary_csv=${SUMMARY_CSV}"
    echo "summary_txt=${SUMMARY_TXT}"
  } >"${metadata_file}"
  cp "${CONFIG_ENV}" "${SOAK_ARCHIVE_DIR}/config.env"
  git -C "${SDK_ROOT}" status --short >"${SOAK_ARCHIVE_DIR}/git_status.txt" 2>/dev/null || true
  {
    echo "summary_csv=$(basename "${SUMMARY_CSV}")"
    echo "summary_txt=$(basename "${SUMMARY_TXT}")"
    echo "config_env=$(basename "${CONFIG_ENV}")"
    echo "cycles_dir=$(basename "${CYCLE_DIR}")"
    echo "archive_dir=$(basename "${SOAK_ARCHIVE_DIR}")"
  } >"${SOAK_ARCHIVE_DIR}/files.txt"
  (
    cd "${OUTPUT_DIR}"
    find "$(basename "${CYCLE_DIR}")" -type f -print
    printf '%s\n' "$(basename "${SUMMARY_CSV}")"
    printf '%s\n' "$(basename "${SUMMARY_TXT}")"
    printf '%s\n' "$(basename "${CONFIG_ENV}")"
    find "$(basename "${SOAK_ARCHIVE_DIR}")" -maxdepth 1 -type f \
      ! -name manifest.sha256 -print
  ) | sort | (
    cd "${OUTPUT_DIR}"
    xargs sha256sum
  ) >"${SOAK_ARCHIVE_DIR}/manifest.sha256"
  tar -C "${OUTPUT_DIR}" -czf "${SOAK_ARCHIVE_TARBALL}" \
    "$(basename "${SUMMARY_CSV}")" \
    "$(basename "${SUMMARY_TXT}")" \
    "$(basename "${CONFIG_ENV}")" \
    "$(basename "${CYCLE_DIR}")" \
    "$(basename "${SOAK_ARCHIVE_DIR}")"
fi

echo "wrote ${SUMMARY_CSV}"
