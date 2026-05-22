#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PRODUCTION_SOAK_DIR="${PRODUCTION_SOAK_DIR:-${1:-${SDK_ROOT}/artifacts/webrtc_first_qoe_production_soak}}"
PRODUCTION_SOAK_SUMMARY="${PRODUCTION_SOAK_SUMMARY:-${SUMMARY_TXT:-${PRODUCTION_SOAK_DIR}/webrtc_first_qoe_production_soak_summary.txt}}"
PRODUCTION_SOAK_CSV="${PRODUCTION_SOAK_CSV:-${SUMMARY_CSV:-${PRODUCTION_SOAK_DIR}/webrtc_first_qoe_production_soak.csv}}"
PRODUCTION_SOAK_CONFIG="${PRODUCTION_SOAK_CONFIG:-${CONFIG_ENV:-${PRODUCTION_SOAK_DIR}/webrtc_first_qoe_production_soak_config.env}}"
PRODUCTION_SOAK_ARCHIVE_DIR="${PRODUCTION_SOAK_ARCHIVE_DIR:-${SOAK_ARCHIVE_DIR:-${PRODUCTION_SOAK_DIR}/archive}}"
PRODUCTION_SOAK_ARCHIVE="${PRODUCTION_SOAK_ARCHIVE:-${SOAK_ARCHIVE_TARBALL:-${PRODUCTION_SOAK_DIR}/webrtc_first_qoe_production_soak_archive.tar.gz}}"

MIN_PRODUCTION_SOAK_MINUTES="${MIN_PRODUCTION_SOAK_MINUTES:-120}"
MIN_PRODUCTION_ROWS="${MIN_PRODUCTION_ROWS:-1}"
MIN_PRODUCTION_CYCLES="${MIN_PRODUCTION_CYCLES:-1}"
REQUIRE_PRODUCTION_SOAK_ARCHIVE="${REQUIRE_PRODUCTION_SOAK_ARCHIVE:-1}"
REQUIRE_CLEAN_GIT_WORKTREE="${REQUIRE_CLEAN_GIT_WORKTREE:-1}"

MAX_DECODE_ERRORS="${MAX_DECODE_ERRORS:-0}"
MAX_FREEZE_COUNT="${MAX_FREEZE_COUNT:-0}"
MAX_RENDERER_PROXY_LATE_FRAMES="${MAX_RENDERER_PROXY_LATE_FRAMES:-0}"
MAX_RENDERER_PROXY_DROP_FRAMES="${MAX_RENDERER_PROXY_DROP_FRAMES:-0}"
MAX_PUSH_QUEUE_FULL="${MAX_PUSH_QUEUE_FULL:-0}"

for path in "${PRODUCTION_SOAK_SUMMARY}" "${PRODUCTION_SOAK_CSV}" \
    "${PRODUCTION_SOAK_CONFIG}"; do
  if [[ ! -s "${path}" ]]; then
    echo "production soak evidence missing or empty: ${path}" >&2
    exit 1
  fi
done

if [[ "${REQUIRE_PRODUCTION_SOAK_ARCHIVE}" == "1" ]]; then
  [[ -x "${SDK_ROOT}/scripts/verify_webrtc_first_qoe_production_soak_archive.sh" ]] || {
    echo "missing production soak archive verifier" >&2
    exit 1
  }
  env SDK_ROOT="${SDK_ROOT}" \
    OUTPUT_DIR="${PRODUCTION_SOAK_DIR}" \
    SUMMARY_TXT="${PRODUCTION_SOAK_SUMMARY}" \
    SUMMARY_CSV="${PRODUCTION_SOAK_CSV}" \
    CONFIG_ENV="${PRODUCTION_SOAK_CONFIG}" \
    SOAK_ARCHIVE_DIR="${PRODUCTION_SOAK_ARCHIVE_DIR}" \
    SOAK_ARCHIVE_TARBALL="${PRODUCTION_SOAK_ARCHIVE}" \
    REQUIRE_SOAK_TARBALL=1 \
    REQUIRE_CLEAN_GIT_WORKTREE="${REQUIRE_CLEAN_GIT_WORKTREE}" \
    MIN_SOAK_ROWS="${MIN_PRODUCTION_ROWS}" \
    MIN_SOAK_CYCLES="${MIN_PRODUCTION_CYCLES}" \
    "${SDK_ROOT}/scripts/verify_webrtc_first_qoe_production_soak_archive.sh" >/dev/null
fi

python3 - \
  "${PRODUCTION_SOAK_SUMMARY}" \
  "${PRODUCTION_SOAK_CSV}" \
  "${PRODUCTION_SOAK_CONFIG}" \
  "${PRODUCTION_SOAK_ARCHIVE}" \
  "${MIN_PRODUCTION_SOAK_MINUTES}" \
  "${MIN_PRODUCTION_ROWS}" \
  "${MIN_PRODUCTION_CYCLES}" \
  "${MAX_DECODE_ERRORS}" \
  "${MAX_FREEZE_COUNT}" \
  "${MAX_RENDERER_PROXY_LATE_FRAMES}" \
  "${MAX_RENDERER_PROXY_DROP_FRAMES}" \
  "${MAX_PUSH_QUEUE_FULL}" \
  "${REQUIRE_PRODUCTION_SOAK_ARCHIVE}" <<'PY'
import csv
import os
import shlex
import sys

(
    summary_path,
    csv_path,
    config_path,
    archive_path,
    min_soak_minutes,
    min_rows,
    min_cycles,
    max_decode_errors,
    max_freeze_count,
    max_renderer_late,
    max_renderer_drops,
    max_push_queue_full,
    require_archive,
) = sys.argv[1:14]

phase5_min_soak_minutes = 120.0
min_soak_minutes = float(min_soak_minutes)
min_rows = int(float(min_rows))
min_cycles = int(float(min_cycles))
max_decode_errors = float(max_decode_errors)
max_freeze_count = float(max_freeze_count)
max_renderer_late = float(max_renderer_late)
max_renderer_drops = float(max_renderer_drops)
max_push_queue_full = float(max_push_queue_full)

if min_soak_minutes < phase5_min_soak_minutes:
    raise SystemExit(
        "MIN_PRODUCTION_SOAK_MINUTES=%g<%g"
        % (min_soak_minutes, phase5_min_soak_minutes)
    )


def read_kv(path, shell_values=False):
    values = {}
    text = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            text.append(line)
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if shell_values:
                try:
                    parts = shlex.split(value)
                    value = parts[0] if parts else ""
                except ValueError:
                    value = value.strip("'\"")
            values[key] = value
    return values, "".join(text)


def as_float(value, key, default=0.0):
    if value in ("", None):
        value = default
    try:
        return float(value)
    except (TypeError, ValueError):
        raise SystemExit(f"production soak bad numeric field {key}={value!r}")


def row_float(row, key, default=0.0):
    return as_float(row.get(key, default), key, default)


def require_numeric_match(summary, key, expected, tolerance=1e-6):
    observed = as_float(summary.get(key), key)
    if abs(observed - expected) > tolerance:
        raise SystemExit(
            f"production soak summary mismatch for {key}: "
            f"{observed:g} != {expected:g}"
        )


summary, summary_text = read_kv(summary_path)
config, _ = read_kv(config_path, shell_values=True)
if "production_soak_summary" not in summary_text:
    raise SystemExit("production soak summary marker missing")

soak_minutes = as_float(config.get("SOAK_MINUTES"), "SOAK_MINUTES")
if soak_minutes < min_soak_minutes:
    raise SystemExit(
        "production soak SOAK_MINUTES below minimum: "
        f"{soak_minutes:g} < {min_soak_minutes:g}"
    )
if soak_minutes < phase5_min_soak_minutes:
    raise SystemExit(
        "production soak SOAK_MINUTES below phase5 minimum: "
        f"{soak_minutes:g} < {phase5_min_soak_minutes:g}"
    )

with open(csv_path, newline="", encoding="utf-8") as handle:
    reader = csv.DictReader(handle)
    rows = list(reader)
    fieldnames = set(reader.fieldnames or [])
required_columns = {
    "cycle",
    "scenario",
    "pass",
    "playable_ratio",
    "avg_psnr_y",
    "avg_ssim_y",
    "decode_errors",
    "freeze_count",
    "renderer_proxy_late_frames",
    "renderer_proxy_drop_frames",
    "renderer_proxy_max_latency_ms",
    "renderer_proxy_max_gap_ms",
    "renderer_proxy_max_jitter_ms",
    "push_queue_full",
    "bad_send_rps",
    "bad_rtp_pps",
    "max_bad_target_bps",
    "max_bad_encoder_fps",
    "full_recovery_time_ms",
}
missing_columns = sorted(required_columns - fieldnames)
if missing_columns:
    raise SystemExit(
        "production soak CSV missing columns: " + ",".join(missing_columns)
    )
if len(rows) < min_rows:
    raise SystemExit(f"production soak rows below minimum: {len(rows)} < {min_rows}")

cycles = sorted({int(row_float(row, "cycle")) for row in rows})
if len(cycles) < min_cycles:
    raise SystemExit(
        "production soak cycles below minimum: "
        f"{len(cycles)} < {min_cycles}"
    )

failed_rows = [row for row in rows if row.get("pass") != "true"]
decode_errors = sum(row_float(row, "decode_errors") for row in rows)
freeze_count = sum(row_float(row, "freeze_count") for row in rows)
renderer_late = sum(row_float(row, "renderer_proxy_late_frames") for row in rows)
renderer_drops = sum(row_float(row, "renderer_proxy_drop_frames") for row in rows)
push_queue_full = sum(row_float(row, "push_queue_full") for row in rows)
playable_min = min(row_float(row, "playable_ratio") for row in rows)
psnr_min = min(row_float(row, "avg_psnr_y") for row in rows)
ssim_min = min(row_float(row, "avg_ssim_y") for row in rows)

errors = []
if failed_rows:
    errors.append(f"pass_false_rows={len(failed_rows)}")
if decode_errors > max_decode_errors:
    errors.append(f"decode_errors={decode_errors:g}>{max_decode_errors:g}")
if freeze_count > max_freeze_count:
    errors.append(f"freeze_count={freeze_count:g}>{max_freeze_count:g}")
if renderer_late > max_renderer_late:
    errors.append(
        f"renderer_proxy_late_frames={renderer_late:g}>{max_renderer_late:g}"
    )
if renderer_drops > max_renderer_drops:
    errors.append(
        f"renderer_proxy_drop_frames={renderer_drops:g}>{max_renderer_drops:g}"
    )
if push_queue_full > max_push_queue_full:
    errors.append(f"push_queue_full={push_queue_full:g}>{max_push_queue_full:g}")

min_playable = as_float(config.get("MIN_PLAYABLE_RATIO", 0.8), "MIN_PLAYABLE_RATIO")
min_psnr = as_float(config.get("MIN_AVG_PSNR_Y", 20.0), "MIN_AVG_PSNR_Y")
min_ssim = as_float(config.get("MIN_AVG_SSIM_Y", 0.80), "MIN_AVG_SSIM_Y")
if playable_min < min_playable:
    errors.append(f"playable_ratio_min={playable_min:g}<{min_playable:g}")
if psnr_min < min_psnr:
    errors.append(f"avg_psnr_y_min={psnr_min:g}<{min_psnr:g}")
if ssim_min < min_ssim:
    errors.append(f"avg_ssim_y_min={ssim_min:g}<{min_ssim:g}")

weak_low_scenarios = {
    "bandwidth_cliff_recover",
    "weak_network_low_rps_low_bitrate",
    "sustained_low_bandwidth_low_rps",
    "weak_start_low_bandwidth_low_rps",
    "walking_dead_zone_recover",
    "oscillating_edge_recover",
}
weak_low_rows = [row for row in rows if row.get("scenario", "") in weak_low_scenarios]
max_weak_send_rps = as_float(config.get("MAX_WEAK_SEND_RPS", 15.0), "MAX_WEAK_SEND_RPS")
max_weak_rtp_pps = as_float(config.get("MAX_WEAK_RTP_PPS", 210.0), "MAX_WEAK_RTP_PPS")
max_weak_target_bps = int(
    as_float(config.get("MAX_WEAK_TARGET_BPS", 0), "MAX_WEAK_TARGET_BPS")
)
if max_weak_target_bps <= 0:
    min_bitrate_bps = int(as_float(config.get("MIN_BITRATE_BPS", 300000), "MIN_BITRATE_BPS"))
    max_weak_target_bps = max(min_bitrate_bps * 2, min_bitrate_bps)
max_weak_encoder_fps = int(
    as_float(config.get("MAX_WEAK_ENCODER_FPS", 10), "MAX_WEAK_ENCODER_FPS")
)
weak_failures = []
for row in weak_low_rows:
    row_failures = []
    if max_weak_send_rps > 0 and row_float(row, "bad_send_rps") > max_weak_send_rps:
        row_failures.append(
            "bad_send_rps=%g>%g"
            % (row_float(row, "bad_send_rps"), max_weak_send_rps)
        )
    if max_weak_rtp_pps > 0 and row_float(row, "bad_rtp_pps") > max_weak_rtp_pps:
        row_failures.append(
            "bad_rtp_pps=%g>%g"
            % (row_float(row, "bad_rtp_pps"), max_weak_rtp_pps)
        )
    if (
        row_float(row, "max_bad_target_bps") <= 0
        or row_float(row, "max_bad_target_bps") > max_weak_target_bps
    ):
        row_failures.append(
            "max_bad_target_bps=%g>%d"
            % (row_float(row, "max_bad_target_bps"), max_weak_target_bps)
        )
    if (
        row_float(row, "max_bad_encoder_fps") <= 0
        or row_float(row, "max_bad_encoder_fps") > max_weak_encoder_fps
    ):
        row_failures.append(
            "max_bad_encoder_fps=%g>%d"
            % (row_float(row, "max_bad_encoder_fps"), max_weak_encoder_fps)
        )
    if row_failures:
        weak_failures.append(
            "%s/%s: %s"
            % (row.get("cycle", "?"), row.get("scenario", "?"), "; ".join(row_failures))
        )
if weak_failures:
    errors.append("weak_low_failures=" + "|".join(weak_failures[:8]))
if errors:
    raise SystemExit("production soak CSV verification failed: " + ";".join(errors))

recoverable_scenarios = {
    "bandwidth_cliff_recover",
    "weak_network_low_rps_low_bitrate",
    "walking_dead_zone_recover",
    "oscillating_edge_recover",
}
recoverable_rows = [row for row in rows if row.get("scenario", "") in recoverable_scenarios]
full_recovery_values = [
    row_float(row, "full_recovery_time_ms")
    for row in recoverable_rows
    if row_float(row, "full_recovery_time_ms") >= 0
]

summary_expectations = {
    "cycles": float(len(cycles)),
    "rows": float(len(rows)),
    "pass_rows": float(len(rows) - len(failed_rows)),
    "playable_ratio_min": playable_min,
    "avg_psnr_y_min": psnr_min,
    "avg_ssim_y_min": ssim_min,
    "decode_errors": decode_errors,
    "freeze_count": freeze_count,
    "renderer_proxy_late_frames": renderer_late,
    "renderer_proxy_drop_frames": renderer_drops,
    "renderer_proxy_max_latency_ms": max(
        row_float(row, "renderer_proxy_max_latency_ms") for row in rows
    ),
    "renderer_proxy_max_gap_ms": max(
        row_float(row, "renderer_proxy_max_gap_ms") for row in rows
    ),
    "renderer_proxy_max_jitter_ms": max(
        row_float(row, "renderer_proxy_max_jitter_ms") for row in rows
    ),
    "push_queue_full": push_queue_full,
    "bad_send_rps_max": max(row_float(row, "bad_send_rps") for row in rows),
    "bad_rtp_pps_max": max(row_float(row, "bad_rtp_pps") for row in rows),
    "max_bad_target_bps_max": max(
        row_float(row, "max_bad_target_bps") for row in rows
    ),
    "max_bad_encoder_fps_max": max(
        row_float(row, "max_bad_encoder_fps") for row in rows
    ),
    "weak_low_rows": float(len(weak_low_rows)),
    "weak_low_bad_send_rps_max": max(
        (row_float(row, "bad_send_rps") for row in weak_low_rows), default=0.0
    ),
    "weak_low_bad_rtp_pps_max": max(
        (row_float(row, "bad_rtp_pps") for row in weak_low_rows), default=0.0
    ),
    "weak_low_target_bps_max": max(
        (row_float(row, "max_bad_target_bps") for row in weak_low_rows), default=0.0
    ),
    "weak_low_encoder_fps_max": max(
        (row_float(row, "max_bad_encoder_fps") for row in weak_low_rows), default=0.0
    ),
    "recoverable_rows": float(len(recoverable_rows)),
    "full_recovery_time_ms_max": max(full_recovery_values) if full_recovery_values else -1.0,
}
for key, expected in summary_expectations.items():
    require_numeric_match(summary, key, expected)

if require_archive == "1" and archive_path and not os.path.exists(archive_path):
    raise SystemExit(f"production soak archive pointer is missing: {archive_path}")

print("production_soak_evidence_verification=true")
print(f"soak_minutes={soak_minutes:g}")
print(f"cycles={len(cycles)}")
print(f"rows={len(rows)}")
print(f"pass_rows={len(rows) - len(failed_rows)}")
print(f"playable_ratio_min={playable_min:g}")
print(f"avg_psnr_y_min={psnr_min:g}")
print(f"avg_ssim_y_min={ssim_min:g}")
print(f"decode_errors={decode_errors:g}")
print(f"freeze_count={freeze_count:g}")
print(f"renderer_proxy_drop_frames={renderer_drops:g}")
print(f"archive={archive_path}")
PY
