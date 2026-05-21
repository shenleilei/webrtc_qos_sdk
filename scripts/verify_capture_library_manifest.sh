#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CAPTURE_LIBRARY_DIR="${CAPTURE_LIBRARY_DIR:-${SDK_ROOT}/capture_library}"
CAPTURE_LIBRARY_MANIFEST="${CAPTURE_LIBRARY_MANIFEST:-${CAPTURE_LIBRARY_DIR}/manifest.csv}"
REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES:-indoor_face outdoor_walking low_light_noise screen_text high_motion scene_cut}"
CAPTURE_WIDTH="${CAPTURE_WIDTH:-1280}"
CAPTURE_HEIGHT="${CAPTURE_HEIGHT:-720}"
MIN_CAPTURE_FRAMES="${MIN_CAPTURE_FRAMES:-45}"
MIN_CAPTURE_SECONDS="${MIN_CAPTURE_SECONDS:-1.5}"
ALLOW_DUPLICATE_CAPTURE_PATHS="${ALLOW_DUPLICATE_CAPTURE_PATHS:-0}"
RESOLVED_CAPTURE_LIST="${RESOLVED_CAPTURE_LIST:-}"
SUMMARY_FILE="${SUMMARY_FILE:-}"

CAPTURE_LIBRARY_DIR="${CAPTURE_LIBRARY_DIR}" \
CAPTURE_LIBRARY_MANIFEST="${CAPTURE_LIBRARY_MANIFEST}" \
REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES}" \
CAPTURE_WIDTH="${CAPTURE_WIDTH}" \
CAPTURE_HEIGHT="${CAPTURE_HEIGHT}" \
MIN_CAPTURE_FRAMES="${MIN_CAPTURE_FRAMES}" \
MIN_CAPTURE_SECONDS="${MIN_CAPTURE_SECONDS}" \
ALLOW_DUPLICATE_CAPTURE_PATHS="${ALLOW_DUPLICATE_CAPTURE_PATHS}" \
RESOLVED_CAPTURE_LIST="${RESOLVED_CAPTURE_LIST}" \
SUMMARY_FILE="${SUMMARY_FILE}" \
python3 - <<'PY'
import csv
import json
import os
import re
import subprocess
import sys

capture_dir = os.environ["CAPTURE_LIBRARY_DIR"]
manifest = os.environ["CAPTURE_LIBRARY_MANIFEST"]
required = [x for x in os.environ["REQUIRED_CAPTURE_CATEGORIES"].split() if x]
min_frames = int(os.environ["MIN_CAPTURE_FRAMES"])
capture_width = int(os.environ["CAPTURE_WIDTH"])
capture_height = int(os.environ["CAPTURE_HEIGHT"])
min_seconds = float(os.environ["MIN_CAPTURE_SECONDS"])
allow_duplicate_paths = os.environ["ALLOW_DUPLICATE_CAPTURE_PATHS"] == "1"
resolved_capture_list = os.environ.get("RESOLVED_CAPTURE_LIST", "")
summary_file = os.environ.get("SUMMARY_FILE", "")

supported_video = {".mp4", ".mov", ".mkv", ".webm"}
supported_raw = {".yuv", ".i420"}
frame_bytes = capture_width * capture_height * 3 // 2

if not os.path.isfile(manifest):
    raise SystemExit("capture manifest not found: %s" % manifest)

manifest_dir = os.path.dirname(os.path.abspath(manifest))
rows = []
with open(manifest, newline="", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    if reader.fieldnames is None:
        raise SystemExit("capture manifest is empty: %s" % manifest)
    required_columns = {"category", "path"}
    missing_columns = required_columns.difference(reader.fieldnames)
    if missing_columns:
        raise SystemExit(
            "capture manifest missing columns: %s"
            % ",".join(sorted(missing_columns))
        )
    for index, row in enumerate(reader, start=2):
        enabled = (row.get("enabled") or "1").strip().lower()
        if enabled in ("0", "false", "no", "off"):
            continue
        category = (row.get("category") or "").strip()
        if not category:
            raise SystemExit("capture manifest row %d has empty category" % index)
        if not re.match(r"^[A-Za-z0-9_.-]+$", category):
            raise SystemExit(
                "capture manifest row %d has unsafe category: %s" % (index, category)
            )
        raw_path = (row.get("path") or "").strip()
        if not raw_path:
            raise SystemExit("capture manifest row %d has empty path" % index)
        path = raw_path
        if not os.path.isabs(path):
            path = os.path.join(manifest_dir, raw_path)
            if not os.path.exists(path):
                path = os.path.join(capture_dir, raw_path)
        path = os.path.abspath(path)
        if not os.path.isfile(path):
            raise SystemExit(
                "capture manifest row %d path not found: %s" % (index, path)
            )
        label = (row.get("label") or os.path.splitext(os.path.basename(path))[0]).strip()
        label = re.sub(r"[^A-Za-z0-9_.-]", "_", label)
        if not label:
            raise SystemExit("capture manifest row %d has empty label" % index)
        rows.append({"category": category, "label": label, "path": path})

if not rows:
    raise SystemExit("capture manifest has no enabled rows: %s" % manifest)

seen_labels = set()
seen_paths = {}
categories = set()
errors = []
for row in rows:
    key = row["category"] + "/" + row["label"]
    if key in seen_labels:
        errors.append("duplicate category/label: %s" % key)
    seen_labels.add(key)
    real_path = os.path.realpath(row["path"])
    if not allow_duplicate_paths and real_path in seen_paths:
        errors.append(
            "duplicate capture path used by %s and %s"
            % (seen_paths[real_path], key)
        )
    seen_paths[real_path] = key
    categories.add(row["category"])

    ext = os.path.splitext(row["path"])[1].lower()
    if ext not in supported_video and ext not in supported_raw:
        errors.append("unsupported capture extension for %s: %s" % (key, row["path"]))
        continue
    if ext in supported_raw:
        size = os.path.getsize(row["path"])
        if size < frame_bytes * min_frames:
            errors.append(
                "raw capture too small for %d 720p I420 frames: %s"
                % (min_frames, row["path"])
            )
    else:
        try:
            output = subprocess.check_output(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-select_streams",
                    "v:0",
                    "-show_entries",
                    "stream=codec_type:format=duration",
                    "-of",
                    "json",
                    row["path"],
                ],
                stderr=subprocess.STDOUT,
            )
            metadata = json.loads(output.decode("utf-8"))
        except Exception as exc:
            errors.append("ffprobe failed for %s: %s" % (row["path"], exc))
            continue
        streams = metadata.get("streams") or []
        if not streams:
            errors.append("capture has no video stream: %s" % row["path"])
        duration = None
        try:
            duration = float((metadata.get("format") or {}).get("duration", "0"))
        except ValueError:
            duration = None
        if duration is not None and duration > 0 and duration < min_seconds:
            errors.append(
                "capture video shorter than %.3fs: %s duration=%.3fs"
                % (min_seconds, row["path"], duration)
            )

missing_categories = [x for x in required if x not in categories]
if missing_categories:
    errors.append("missing required capture categories: %s" % ",".join(missing_categories))

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)

if resolved_capture_list:
    with open(resolved_capture_list, "w", encoding="utf-8") as f:
        for row in rows:
            f.write("%s\t%s\t%s\n" % (row["category"], row["label"], row["path"]))

summary = {
    "capture_manifest_verification": "true",
    "capture_manifest": manifest,
    "capture_library_dir": capture_dir,
    "entries": str(len(rows)),
    "categories": ",".join(sorted(categories)),
    "required_categories": ",".join(required),
    "capture_width": str(capture_width),
    "capture_height": str(capture_height),
    "min_capture_frames": str(min_frames),
    "min_capture_seconds": str(min_seconds),
}
if summary_file:
    with open(summary_file, "w", encoding="utf-8") as f:
        for key in sorted(summary):
            f.write("%s=%s\n" % (key, summary[key]))

for key in sorted(summary):
    print("%s=%s" % (key, summary[key]))
PY
