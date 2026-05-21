#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WEBRTC_PREFIX="${WEBRTC_PREFIX:-${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/webrtc_first_low_rps_low_bitrate_check}"
FACADE_OUTPUT_DIR="${FACADE_OUTPUT_DIR:-${OUTPUT_DIR}/facade}"
QOE_OUTPUT_DIR="${QOE_OUTPUT_DIR:-${OUTPUT_DIR}/ffmpeg_qoe}"
SUMMARY_FILE="${SUMMARY_FILE:-${OUTPUT_DIR}/webrtc_first_low_rps_low_bitrate_summary.txt}"

RUN_FACADE="${RUN_FACADE:-1}"
RUN_FFMPEG_QOE="${RUN_FFMPEG_QOE:-1}"

FACADE_FRAMES="${FACADE_FRAMES:-36}"
QOE_FRAMES="${QOE_FRAMES:-20}"
QOE_WIDTH="${QOE_WIDTH:-320}"
QOE_HEIGHT="${QOE_HEIGHT:-180}"
QOE_CONTENT_MODE="${QOE_CONTENT_MODE:-block_motion}"

MAX_WEAK_SEND_RPS="${MAX_WEAK_SEND_RPS:-15.0}"
MAX_FACADE_WEAK_RTP_PPS="${MAX_FACADE_WEAK_RTP_PPS:-45.0}"
MAX_QOE_WEAK_RTP_PPS="${MAX_QOE_WEAK_RTP_PPS:-180.0}"
MAX_FACADE_WEAK_TARGET_BPS="${MAX_FACADE_WEAK_TARGET_BPS:-600000}"
MAX_QOE_WEAK_TARGET_BPS="${MAX_QOE_WEAK_TARGET_BPS:-600000}"
MAX_WEAK_ENCODER_FPS="${MAX_WEAK_ENCODER_FPS:-10}"
MIN_QOE_PLAYABLE_RATIO="${MIN_QOE_PLAYABLE_RATIO:-0.75}"
MIN_QOE_AVG_PSNR_Y="${MIN_QOE_AVG_PSNR_Y:-15}"
MIN_QOE_AVG_SSIM_Y="${MIN_QOE_AVG_SSIM_Y:-0.70}"

mkdir -p "${OUTPUT_DIR}"

if [[ "${RUN_FACADE}" == "1" ]]; then
  PREFIX="${WEBRTC_PREFIX}" \
  OUTPUT_DIR="${FACADE_OUTPUT_DIR}" \
  FRAMES="${FACADE_FRAMES}" \
    bash "${SDK_ROOT}/scripts/run_webrtc_first_facade_matrix.sh"
fi

if [[ "${RUN_FFMPEG_QOE}" == "1" ]]; then
  WEBRTC_PREFIX="${WEBRTC_PREFIX}" \
  SDK_ROOT="${SDK_ROOT}" \
  OUTPUT_DIR="${QOE_OUTPUT_DIR}" \
  OUTPUT_BASENAME="webrtc_first_ffmpeg_qoe_low_rps_low_bitrate" \
  FRAMES="${QOE_FRAMES}" \
  WIDTH="${QOE_WIDTH}" \
  HEIGHT="${QOE_HEIGHT}" \
  SCENARIOS="weak_network_low_rps_low_bitrate" \
  CONTENT_MODES="${QOE_CONTENT_MODE}" \
  START_BITRATE_BPS="${START_BITRATE_BPS:-800000}" \
  MIN_BITRATE_BPS="${MIN_BITRATE_BPS:-200000}" \
  MAX_BITRATE_BPS="${MAX_BITRATE_BPS:-1200000}" \
  MIN_PLAYABLE_RATIO="${MIN_QOE_PLAYABLE_RATIO}" \
  MIN_AVG_PSNR_Y="${MIN_QOE_AVG_PSNR_Y}" \
  MIN_AVG_SSIM_Y="${MIN_QOE_AVG_SSIM_Y}" \
  MAX_WEAK_SEND_RPS="${MAX_WEAK_SEND_RPS}" \
  MAX_WEAK_RTP_PPS="${MAX_QOE_WEAK_RTP_PPS}" \
  MAX_WEAK_TARGET_BPS="${MAX_QOE_WEAK_TARGET_BPS}" \
  MAX_WEAK_ENCODER_FPS="${MAX_WEAK_ENCODER_FPS}" \
    bash "${SDK_ROOT}/scripts/run_webrtc_first_ffmpeg_qoe.sh"
fi

RUN_FACADE="${RUN_FACADE}" \
RUN_FFMPEG_QOE="${RUN_FFMPEG_QOE}" \
FACADE_CSV="${FACADE_OUTPUT_DIR}/webrtc_first_facade_matrix.csv" \
QOE_CSV="${QOE_OUTPUT_DIR}/webrtc_first_ffmpeg_qoe_low_rps_low_bitrate.csv" \
SUMMARY_FILE="${SUMMARY_FILE}" \
MAX_WEAK_SEND_RPS="${MAX_WEAK_SEND_RPS}" \
MAX_FACADE_WEAK_RTP_PPS="${MAX_FACADE_WEAK_RTP_PPS}" \
MAX_QOE_WEAK_RTP_PPS="${MAX_QOE_WEAK_RTP_PPS}" \
MAX_FACADE_WEAK_TARGET_BPS="${MAX_FACADE_WEAK_TARGET_BPS}" \
MAX_QOE_WEAK_TARGET_BPS="${MAX_QOE_WEAK_TARGET_BPS}" \
MAX_WEAK_ENCODER_FPS="${MAX_WEAK_ENCODER_FPS}" \
python3 - <<'PY'
import csv
import os

SCENARIO = "weak_network_low_rps_low_bitrate"


def load_row(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    for row in rows:
        if row["scenario"] == SCENARIO:
            return row
    raise RuntimeError(f"{SCENARIO} not found in {path}")


def as_float(row, key):
    return float(row.get(key, "0") or "0")


def as_int(row, key):
    return int(float(row.get(key, "0") or "0"))


def check_row(label, row, max_rtp_pps, max_target_bps):
    bad_send_rps = as_float(row, "bad_send_rps")
    bad_rtp_pps = as_float(row, "bad_rtp_pps")
    max_bad_target_bps = as_int(row, "max_bad_target_bps")
    max_bad_encoder_fps = as_int(row, "max_bad_encoder_fps")
    ok = (
        row.get("pass") == "true"
        and bad_send_rps <= float(os.environ["MAX_WEAK_SEND_RPS"])
        and bad_rtp_pps <= max_rtp_pps
        and max_bad_target_bps <= max_target_bps
        and max_bad_encoder_fps <= int(os.environ["MAX_WEAK_ENCODER_FPS"])
    )
    if not ok:
        raise RuntimeError(f"{label} low-RPS low-bitrate gate failed: {row}")
    return {
        f"{label}_pass": row.get("pass"),
        f"{label}_bad_send_rps": f"{bad_send_rps:g}",
        f"{label}_bad_rtp_pps": f"{bad_rtp_pps:g}",
        f"{label}_max_bad_target_bps": str(max_bad_target_bps),
        f"{label}_max_bad_encoder_fps": str(max_bad_encoder_fps),
        f"{label}_recovery_send_rps": f"{as_float(row, 'recovery_send_rps'):g}",
        f"{label}_max_recovery_target_bps": str(as_int(row, "max_recovery_target_bps")),
        f"{label}_max_recovery_encoder_fps": str(
            as_int(row, "max_recovery_encoder_fps")
        ),
    }


summary = {"low_rps_low_bitrate_check": "true"}

if os.environ["RUN_FACADE"] == "1":
    row = load_row(os.environ["FACADE_CSV"])
    summary.update(
        check_row(
            "facade",
            row,
            float(os.environ["MAX_FACADE_WEAK_RTP_PPS"]),
            int(os.environ["MAX_FACADE_WEAK_TARGET_BPS"]),
        )
    )

if os.environ["RUN_FFMPEG_QOE"] == "1":
    row = load_row(os.environ["QOE_CSV"])
    summary.update(
        check_row(
            "ffmpeg_qoe",
            row,
            float(os.environ["MAX_QOE_WEAK_RTP_PPS"]),
            int(os.environ["MAX_QOE_WEAK_TARGET_BPS"]),
        )
    )
    summary["ffmpeg_qoe_avg_psnr_y"] = f"{as_float(row, 'avg_psnr_y'):g}"
    summary["ffmpeg_qoe_avg_ssim_y"] = f"{as_float(row, 'avg_ssim_y'):g}"
    summary["ffmpeg_qoe_playable_ratio"] = f"{as_float(row, 'playable_ratio'):g}"

with open(os.environ["SUMMARY_FILE"], "w", encoding="utf-8") as f:
    for key in sorted(summary):
        f.write(f"{key}={summary[key]}\n")

for key in sorted(summary):
    print(f"{key}={summary[key]}")
PY
