#!/usr/bin/env bash
set -euo pipefail

CAPTURE_QOE_CSV="${CAPTURE_QOE_CSV:-${1:-}}"
MIN_CAPTURE_QOE_ROWS="${MIN_CAPTURE_QOE_ROWS:-1}"
MIN_PLAYABLE_RATIO="${MIN_PLAYABLE_RATIO:-0.8}"
MIN_AVG_PSNR_Y="${MIN_AVG_PSNR_Y:-20.0}"
MIN_AVG_SSIM_Y="${MIN_AVG_SSIM_Y:-0.80}"
MAX_DECODE_ERRORS="${MAX_DECODE_ERRORS:-0}"
MAX_FREEZE_COUNT="${MAX_FREEZE_COUNT:-0}"
MAX_RENDERER_PROXY_DROP_FRAMES="${MAX_RENDERER_PROXY_DROP_FRAMES:-0}"
REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES:-indoor_face outdoor_walking low_light_noise screen_text high_motion scene_cut}"
SUMMARY_FILE="${SUMMARY_FILE:-}"

[[ -n "${CAPTURE_QOE_CSV}" ]] || {
  echo "capture QoE CSV path is required" >&2
  exit 2
}
[[ -s "${CAPTURE_QOE_CSV}" ]] || {
  echo "capture QoE CSV missing or empty: ${CAPTURE_QOE_CSV}" >&2
  exit 1
}

CAPTURE_QOE_CSV="${CAPTURE_QOE_CSV}" \
MIN_CAPTURE_QOE_ROWS="${MIN_CAPTURE_QOE_ROWS}" \
MIN_PLAYABLE_RATIO="${MIN_PLAYABLE_RATIO}" \
MIN_AVG_PSNR_Y="${MIN_AVG_PSNR_Y}" \
MIN_AVG_SSIM_Y="${MIN_AVG_SSIM_Y}" \
MAX_DECODE_ERRORS="${MAX_DECODE_ERRORS}" \
MAX_FREEZE_COUNT="${MAX_FREEZE_COUNT}" \
MAX_RENDERER_PROXY_DROP_FRAMES="${MAX_RENDERER_PROXY_DROP_FRAMES}" \
REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES}" \
SUMMARY_FILE="${SUMMARY_FILE}" \
python3 - <<'PY'
import csv
import os
import sys

path = os.environ["CAPTURE_QOE_CSV"]
min_rows = int(os.environ["MIN_CAPTURE_QOE_ROWS"])
min_playable = float(os.environ["MIN_PLAYABLE_RATIO"])
min_psnr = float(os.environ["MIN_AVG_PSNR_Y"])
min_ssim = float(os.environ["MIN_AVG_SSIM_Y"])
max_decode_errors = float(os.environ["MAX_DECODE_ERRORS"])
max_freeze_count = float(os.environ["MAX_FREEZE_COUNT"])
max_renderer_drops = float(os.environ["MAX_RENDERER_PROXY_DROP_FRAMES"])
required_categories = [
    item for item in os.environ["REQUIRED_CAPTURE_CATEGORIES"].split() if item
]
summary_file = os.environ.get("SUMMARY_FILE", "")

with open(path, newline="", encoding="utf-8") as fh:
    rows = list(csv.DictReader(fh))

if len(rows) < min_rows:
    raise SystemExit(f"capture QoE rows below minimum: {len(rows)} < {min_rows}")


def f(row, key):
    value = row.get(key, "")
    if value in ("", None):
        return 0.0
    try:
        return float(value)
    except ValueError:
        raise SystemExit(f"bad numeric value {key}={value!r}")


def category_of(row):
    category = row.get("category", "")
    if category:
        return category
    content = row.get("content_mode", "")
    if content.startswith("capture_i420:"):
        label = content.split(":", 2)[1]
        for required in sorted(required_categories, key=len, reverse=True):
            if label == required or label.startswith(required + "_"):
                return required
    scenario = row.get("scenario", "")
    for required in sorted(required_categories, key=len, reverse=True):
        if scenario == required or scenario.startswith(required + "_"):
            return required
    return ""


failed_rows = [row for row in rows if row.get("pass") != "true"]
decode_errors = sum(f(row, "decode_errors") for row in rows)
freeze_count = sum(f(row, "freeze_count") for row in rows)
renderer_drops = sum(f(row, "renderer_proxy_drop_frames") for row in rows)
playable_min = min(f(row, "playable_ratio") for row in rows)
psnr_min = min(f(row, "avg_psnr_y") for row in rows)
ssim_min = min(f(row, "avg_ssim_y") for row in rows)
categories = {category_of(row) for row in rows}
categories.discard("")
missing_categories = [item for item in required_categories if item not in categories]

errors = []
if failed_rows:
    errors.append(f"pass_false_rows={len(failed_rows)}")
if decode_errors > max_decode_errors:
    errors.append(f"decode_errors={decode_errors:g}>{max_decode_errors:g}")
if freeze_count > max_freeze_count:
    errors.append(f"freeze_count={freeze_count:g}>{max_freeze_count:g}")
if renderer_drops > max_renderer_drops:
    errors.append(f"renderer_proxy_drop_frames={renderer_drops:g}>{max_renderer_drops:g}")
if playable_min < min_playable:
    errors.append(f"playable_ratio_min={playable_min:g}<{min_playable:g}")
if psnr_min < min_psnr:
    errors.append(f"avg_psnr_y_min={psnr_min:g}<{min_psnr:g}")
if ssim_min < min_ssim:
    errors.append(f"avg_ssim_y_min={ssim_min:g}<{min_ssim:g}")
if missing_categories:
    errors.append("missing_categories=" + ",".join(missing_categories))

summary = {
    "capture_qoe_verification": "true" if not errors else "false",
    "capture_qoe_csv": path,
    "rows": str(len(rows)),
    "pass_rows": str(len(rows) - len(failed_rows)),
    "categories": ",".join(sorted(categories)),
    "required_categories": ",".join(required_categories),
    "playable_ratio_min": f"{playable_min:g}",
    "avg_psnr_y_min": f"{psnr_min:g}",
    "avg_ssim_y_min": f"{ssim_min:g}",
    "decode_errors": f"{decode_errors:g}",
    "freeze_count": f"{freeze_count:g}",
    "renderer_proxy_drop_frames": f"{renderer_drops:g}",
    "min_playable_ratio": f"{min_playable:g}",
    "min_avg_psnr_y": f"{min_psnr:g}",
    "min_avg_ssim_y": f"{min_ssim:g}",
}

lines = [f"{key}={summary[key]}" for key in sorted(summary)]
if summary_file:
    with open(summary_file, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
for line in lines:
    print(line)

if errors:
    raise SystemExit("capture QoE verification failed: " + ";".join(errors))
PY
