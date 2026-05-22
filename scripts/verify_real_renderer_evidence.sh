#!/usr/bin/env bash
set -euo pipefail

SUMMARY_FILE="${SUMMARY_FILE:-${1:-}}"
METRICS_FILE="${METRICS_FILE:-${2:-}}"
ALLOW_XVFB_RENDERER="${ALLOW_XVFB_RENDERER:-0}"
MIN_RENDERED_FRAMES="${MIN_RENDERED_FRAMES:-1}"

[[ -n "${SUMMARY_FILE}" ]] || {
  echo "real renderer summary path is required" >&2
  exit 2
}
[[ -n "${METRICS_FILE}" ]] || {
  echo "real renderer metrics path is required" >&2
  exit 2
}
[[ -s "${SUMMARY_FILE}" ]] || {
  echo "real renderer summary missing or empty: ${SUMMARY_FILE}" >&2
  exit 1
}
[[ -s "${METRICS_FILE}" ]] || {
  echo "real renderer metrics missing or empty: ${METRICS_FILE}" >&2
  exit 1
}

python3 - \
  "${SUMMARY_FILE}" \
  "${METRICS_FILE}" \
  "${ALLOW_XVFB_RENDERER}" \
  "${MIN_RENDERED_FRAMES}" <<'PY'
import csv
import sys

summary_path, metrics_path, allow_xvfb, min_rendered_frames = sys.argv[1:5]
min_rendered_frames = int(float(min_rendered_frames))


def read_summary(path):
    values = {}
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key] = value
    return values


def as_float(values, key, default=0.0):
    value = values.get(key, default)
    if value in ("", None):
        value = default
    try:
        return float(value)
    except (TypeError, ValueError):
        raise SystemExit(f"real renderer bad numeric field {key}={value!r}")


def read_metrics(path):
    with open(path, newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise SystemExit("real renderer metrics has no rows")
    fieldnames = set(rows[0].keys())
    if {"metric", "value"} <= fieldnames:
        return {
            row.get("metric", ""): row.get("value", "")
            for row in rows
            if row.get("metric")
        }
    if "frame" in fieldnames:
        return {
            "frame_rows": str(len(rows)),
            "rendered_frames": str(len(rows)),
        }
    raise SystemExit("real renderer metrics missing expected metric/value or frame header")


summary = read_summary(summary_path)
metrics = read_metrics(metrics_path)

if summary.get("real_renderer_status") != "pass":
    raise SystemExit("real renderer evidence did not pass")
backend = summary.get("renderer_backend", "")
if backend == "xvfb" and allow_xvfb != "1":
    raise SystemExit("real renderer evidence used xvfb backend")
if not backend:
    raise SystemExit("real renderer evidence missing renderer_backend")

rendered_frames = as_float(summary, "rendered_frames")
if rendered_frames < min_rendered_frames:
    raise SystemExit(
        "real renderer rendered frames below minimum: "
        f"{rendered_frames:g} < {min_rendered_frames}"
    )
frames = as_float(summary, "frames", rendered_frames)
if frames > 0 and rendered_frames != frames:
    raise SystemExit(
        "real renderer rendered_frames does not match frames: "
        f"{rendered_frames:g} != {frames:g}"
    )
late_frames = as_float(summary, "late_frames")
max_late_frames = as_float(summary, "max_late_frames")
if late_frames > max_late_frames:
    raise SystemExit(
        "real renderer late frames exceed budget: "
        f"{late_frames:g} > {max_late_frames:g}"
    )
max_present_gap = as_float(summary, "max_present_gap_ms")
max_present_gap_budget = as_float(summary, "max_present_gap_budget_ms")
if max_present_gap_budget > 0 and max_present_gap > max_present_gap_budget:
    raise SystemExit(
        "real renderer present gap exceeds budget: "
        f"{max_present_gap:g} > {max_present_gap_budget:g}"
    )
max_present_jitter = as_float(summary, "max_present_jitter_ms")
max_present_jitter_budget = as_float(summary, "max_present_jitter_budget_ms")
if max_present_jitter_budget > 0 and max_present_jitter > max_present_jitter_budget:
    raise SystemExit(
        "real renderer present jitter exceeds budget: "
        f"{max_present_jitter:g} > {max_present_jitter_budget:g}"
    )

for key in ("real_renderer_status", "rendered_frames", "late_frames"):
    if key in metrics and str(metrics[key]) != str(summary.get(key, "")):
        raise SystemExit(f"real renderer metrics mismatch for {key}")

print("real_renderer_evidence_verification=true")
print(f"renderer_backend={backend}")
print(f"rendered_frames={rendered_frames:g}")
print(f"late_frames={late_frames:g}")
print(f"max_present_gap_ms={max_present_gap:g}")
print(f"max_present_jitter_ms={max_present_jitter:g}")
PY
