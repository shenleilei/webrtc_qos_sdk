#!/usr/bin/env bash
set -euo pipefail

CAPTURE_MANIFEST_SUMMARY="${CAPTURE_MANIFEST_SUMMARY:-${1:-}}"
CAPTURE_QOE_CSV="${CAPTURE_QOE_CSV:-${2:-}}"
CAPTURE_QOE_SUMMARY="${CAPTURE_QOE_SUMMARY:-${3:-}}"
ALLOW_FIXTURE_CAPTURE="${ALLOW_FIXTURE_CAPTURE:-0}"
MIN_CAPTURE_QOE_ROWS="${MIN_CAPTURE_QOE_ROWS:-1}"
MIN_PLAYABLE_RATIO="${MIN_PLAYABLE_RATIO:-0.8}"
MIN_AVG_PSNR_Y="${MIN_AVG_PSNR_Y:-20.0}"
MIN_AVG_SSIM_Y="${MIN_AVG_SSIM_Y:-0.80}"
MAX_DECODE_ERRORS="${MAX_DECODE_ERRORS:-0}"
MAX_FREEZE_COUNT="${MAX_FREEZE_COUNT:-0}"
MAX_RENDERER_PROXY_DROP_FRAMES="${MAX_RENDERER_PROXY_DROP_FRAMES:-0}"
REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES:-indoor_face outdoor_walking low_light_noise screen_text high_motion scene_cut}"

[[ -n "${CAPTURE_MANIFEST_SUMMARY}" ]] || {
  echo "capture manifest summary path is required" >&2
  exit 2
}
[[ -n "${CAPTURE_QOE_CSV}" ]] || {
  echo "capture QoE CSV path is required" >&2
  exit 2
}
[[ -n "${CAPTURE_QOE_SUMMARY}" ]] || {
  echo "capture QoE summary path is required" >&2
  exit 2
}
[[ -s "${CAPTURE_MANIFEST_SUMMARY}" ]] || {
  echo "capture manifest summary missing or empty: ${CAPTURE_MANIFEST_SUMMARY}" >&2
  exit 1
}
[[ -s "${CAPTURE_QOE_CSV}" ]] || {
  echo "capture QoE CSV missing or empty: ${CAPTURE_QOE_CSV}" >&2
  exit 1
}
[[ -s "${CAPTURE_QOE_SUMMARY}" ]] || {
  echo "capture QoE summary missing or empty: ${CAPTURE_QOE_SUMMARY}" >&2
  exit 1
}

python3 - \
  "${CAPTURE_MANIFEST_SUMMARY}" \
  "${CAPTURE_QOE_CSV}" \
  "${CAPTURE_QOE_SUMMARY}" \
  "${ALLOW_FIXTURE_CAPTURE}" \
  "${MIN_CAPTURE_QOE_ROWS}" \
  "${MIN_PLAYABLE_RATIO}" \
  "${MIN_AVG_PSNR_Y}" \
  "${MIN_AVG_SSIM_Y}" \
  "${MAX_DECODE_ERRORS}" \
  "${MAX_FREEZE_COUNT}" \
  "${MAX_RENDERER_PROXY_DROP_FRAMES}" \
  "${REQUIRED_CAPTURE_CATEGORIES}" <<'PY'
import csv
import re
import sys

(
    manifest_summary_path,
    qoe_csv_path,
    qoe_summary_path,
    allow_fixture_capture,
    min_rows,
    min_playable,
    min_psnr,
    min_ssim,
    max_decode_errors,
    max_freeze_count,
    max_renderer_drops,
    required_categories_value,
) = sys.argv[1:13]

min_rows = int(float(min_rows))
min_playable = float(min_playable)
min_psnr = float(min_psnr)
min_ssim = float(min_ssim)
max_decode_errors = float(max_decode_errors)
max_freeze_count = float(max_freeze_count)
max_renderer_drops = float(max_renderer_drops)


def read_kv(path):
    values = {}
    text = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            text.append(line)
            line = line.strip()
            if not line or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key] = value
    return values, "".join(text)


def as_float(value, key):
    if value in ("", None):
        return 0.0
    try:
        return float(value)
    except (TypeError, ValueError):
        raise SystemExit(f"capture evidence bad numeric field {key}={value!r}")


def valid_sha256(value):
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(ch in "0123456789abcdefABCDEF" for ch in value)
    )


def tokens(value):
    return {
        token.strip()
        for token in str(value or "").replace(",", " ").split()
        if token.strip()
    }


def category_of(row, required_categories):
    category = row.get("category", "")
    if category:
        return category
    content = row.get("content_mode", "")
    if content.startswith("capture_i420:"):
        label = content.split(":", 2)[1]
        for required in sorted(required_categories, key=len, reverse=True):
            if label == required or label.startswith(required + "_"):
                return required
    for required in sorted(required_categories, key=len, reverse=True):
        if content == required or content.startswith(required + "_"):
            return required
    scenario = row.get("scenario", "")
    for required in sorted(required_categories, key=len, reverse=True):
        if scenario == required or scenario.startswith(required + "_"):
            return required
    return ""


def csv_float(row, key):
    return as_float(row.get(key, ""), key)


manifest, manifest_text = read_kv(manifest_summary_path)
qoe, _ = read_kv(qoe_summary_path)

if manifest.get("capture_manifest_verification") != "true":
    raise SystemExit("capture manifest summary did not verify")
manifest_sha = manifest.get("capture_manifest_sha256", "")
if not valid_sha256(manifest_sha):
    raise SystemExit("capture manifest summary missing sha256")
manifest_media_sha = manifest.get("capture_media_sha256", "")
if not valid_sha256(manifest_media_sha):
    raise SystemExit("capture manifest summary missing capture_media_sha256")
if qoe.get("capture_qoe_verification") != "true":
    raise SystemExit("capture QoE summary did not verify")
qoe_manifest_sha = qoe.get("capture_manifest_sha256", "")
if not valid_sha256(qoe_manifest_sha):
    raise SystemExit("capture QoE summary missing capture_manifest_sha256")
if qoe_manifest_sha != manifest_sha:
    raise SystemExit("capture QoE summary manifest sha256 mismatch")
qoe_media_sha = qoe.get("capture_media_sha256", "")
if not valid_sha256(qoe_media_sha):
    raise SystemExit("capture QoE summary missing capture_media_sha256")
if qoe_media_sha != manifest_media_sha:
    raise SystemExit("capture QoE summary media sha256 mismatch")

fixture_markers = (
    "fixture",
    "artifacts/capture_library_phase2_fixture",
    "artifacts/capture_library_fixture",
)
if allow_fixture_capture != "1" and any(
    marker in manifest_text.lower() for marker in fixture_markers
):
    raise SystemExit("capture evidence used fixture library")

required_categories = tokens(
    required_categories_value
    or qoe.get("required_categories")
    or manifest.get("required_categories")
    or "indoor_face,outdoor_walking,low_light_noise,screen_text,high_motion,scene_cut"
)
manifest_categories = tokens(manifest.get("categories", ""))
if not required_categories or not required_categories <= manifest_categories:
    raise SystemExit("capture manifest categories are incomplete")

with open(qoe_csv_path, newline="", encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle))
if len(rows) < min_rows:
    raise SystemExit(f"capture QoE rows below minimum: {len(rows)} < {min_rows}")

failed_rows = [row for row in rows if row.get("pass") != "true"]
decode_errors = sum(csv_float(row, "decode_errors") for row in rows)
freeze_count = sum(csv_float(row, "freeze_count") for row in rows)
renderer_drops = sum(csv_float(row, "renderer_proxy_drop_frames") for row in rows)
playable_min = min(csv_float(row, "playable_ratio") for row in rows)
psnr_min = min(csv_float(row, "avg_psnr_y") for row in rows)
ssim_min = min(csv_float(row, "avg_ssim_y") for row in rows)
csv_categories = {category_of(row, required_categories) for row in rows}
csv_categories.discard("")

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
if not required_categories <= csv_categories:
    errors.append(
        "missing_categories="
        + ",".join(sorted(required_categories.difference(csv_categories)))
    )
if errors:
    raise SystemExit("capture QoE CSV verification failed: " + ";".join(errors))

summary_expectations = {
    "rows": float(len(rows)),
    "pass_rows": float(len(rows) - len(failed_rows)),
    "playable_ratio_min": playable_min,
    "avg_psnr_y_min": psnr_min,
    "avg_ssim_y_min": ssim_min,
    "decode_errors": decode_errors,
    "freeze_count": freeze_count,
    "renderer_proxy_drop_frames": renderer_drops,
}
for key, expected in summary_expectations.items():
    observed = as_float(qoe.get(key), key)
    if abs(observed - expected) > 1e-6:
        raise SystemExit(
            f"capture QoE summary mismatch for {key}: {observed:g} != {expected:g}"
        )

qoe_categories = tokens(qoe.get("categories", ""))
if qoe_categories != csv_categories:
    raise SystemExit("capture QoE summary categories do not match CSV")
if not required_categories <= qoe_categories:
    raise SystemExit("capture QoE summary required categories are incomplete")

entries = as_float(manifest.get("entries", "0"), "entries")
if entries <= 0:
    raise SystemExit("capture manifest summary has no entries")

print("capture_library_evidence_verification=true")
print(f"capture_manifest_sha256={manifest_sha}")
print(f"capture_media_sha256={manifest_media_sha}")
print(f"rows={len(rows)}")
print(f"pass_rows={len(rows) - len(failed_rows)}")
print("categories=" + ",".join(sorted(csv_categories)))
print("required_categories=" + ",".join(sorted(required_categories)))
print(f"playable_ratio_min={playable_min:g}")
print(f"avg_psnr_y_min={psnr_min:g}")
print(f"avg_ssim_y_min={ssim_min:g}")
PY
