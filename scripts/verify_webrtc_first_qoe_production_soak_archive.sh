#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/webrtc_first_qoe_production_soak}"
SUMMARY_CSV="${SUMMARY_CSV:-${OUTPUT_DIR}/webrtc_first_qoe_production_soak.csv}"
SUMMARY_TXT="${SUMMARY_TXT:-${OUTPUT_DIR}/webrtc_first_qoe_production_soak_summary.txt}"
CONFIG_ENV="${CONFIG_ENV:-${OUTPUT_DIR}/webrtc_first_qoe_production_soak_config.env}"
SOAK_ARCHIVE_DIR="${SOAK_ARCHIVE_DIR:-${OUTPUT_DIR}/archive}"
SOAK_ARCHIVE_TARBALL="${SOAK_ARCHIVE_TARBALL:-${OUTPUT_DIR}/webrtc_first_qoe_production_soak_archive.tar.gz}"
REQUIRE_SOAK_TARBALL="${REQUIRE_SOAK_TARBALL:-1}"
REQUIRE_CLEAN_GIT_WORKTREE="${REQUIRE_CLEAN_GIT_WORKTREE:-1}"
MIN_SOAK_CYCLES="${MIN_SOAK_CYCLES:-1}"
MIN_SOAK_ROWS="${MIN_SOAK_ROWS:-1}"

for path in "${SUMMARY_CSV}" "${SUMMARY_TXT}" "${CONFIG_ENV}" \
    "${SOAK_ARCHIVE_DIR}/metadata.txt" \
    "${SOAK_ARCHIVE_DIR}/config.env" \
    "${SOAK_ARCHIVE_DIR}/git_status.txt" \
    "${SOAK_ARCHIVE_DIR}/recovery_distribution_summary.txt" \
    "${SOAK_ARCHIVE_DIR}/files.txt" \
    "${SOAK_ARCHIVE_DIR}/manifest.sha256"; do
  if [[ ! -s "${path}" ]]; then
    echo "missing production soak archive file: ${path}" >&2
    exit 1
  fi
done

if [[ "${REQUIRE_SOAK_TARBALL}" == "1" && ! -s "${SOAK_ARCHIVE_TARBALL}" ]]; then
  echo "missing production soak archive tarball: ${SOAK_ARCHIVE_TARBALL}" >&2
  exit 1
fi

(
  cd "${OUTPUT_DIR}"
  sha256sum -c "${SOAK_ARCHIVE_DIR}/manifest.sha256" >/dev/null
)

verify_archive_manifest_consistency() {
  python3 - "${OUTPUT_DIR}" "${SOAK_ARCHIVE_DIR}" <<'PY'
import os
import sys

output_dir, archive_dir = sys.argv[1:3]
archive_rel = os.path.relpath(archive_dir, output_dir)
files_path = os.path.join(archive_dir, "files.txt")
manifest_path = os.path.join(archive_dir, "manifest.sha256")

with open(files_path, "r", encoding="utf-8") as handle:
    files = [line.strip() for line in handle if line.strip()]
with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest_files = []
    for line_no, line in enumerate(handle, 1):
        line = line.rstrip("\n")
        if len(line) < 67:
            raise SystemExit(
                f"production soak archive manifest line {line_no} is too short"
            )
        digest, rel = line.split(None, 1)
        if len(digest) != 64 or not all(
            ch in "0123456789abcdefABCDEF" for ch in digest
        ):
            raise SystemExit(
                f"production soak archive manifest line {line_no} has invalid sha256"
            )
        manifest_files.append(rel.lstrip("*"))

actual_files = []
for rel_root in ("cycles", archive_rel):
    root_path = os.path.join(output_dir, rel_root)
    if not os.path.isdir(root_path):
        continue
    for root, _, names in os.walk(root_path):
        for name in names:
            rel = os.path.relpath(os.path.join(root, name), output_dir)
            if rel in {
                os.path.join(archive_rel, "manifest.sha256"),
                os.path.join(archive_rel, "files.txt"),
            }:
                continue
            actual_files.append(rel)
for name in (
    "webrtc_first_qoe_production_soak.csv",
    "webrtc_first_qoe_production_soak_summary.txt",
    "webrtc_first_qoe_production_soak_config.env",
):
    if os.path.isfile(os.path.join(output_dir, name)):
        actual_files.append(name)
actual_files = sorted(set(actual_files))

if files != sorted(files):
    raise SystemExit("production soak archive files.txt is not sorted")
if files != manifest_files:
    raise SystemExit(
        "production soak archive files.txt and manifest.sha256 file sets differ"
    )
if files != actual_files:
    raise SystemExit(
        "production soak archive files.txt does not match actual archive files"
    )
PY
}

verify_archive_manifest_consistency

SUMMARY_CSV="${SUMMARY_CSV}" \
SUMMARY_TXT="${SUMMARY_TXT}" \
CONFIG_ENV="${CONFIG_ENV}" \
METADATA_TXT="${SOAK_ARCHIVE_DIR}/metadata.txt" \
GIT_STATUS_TXT="${SOAK_ARCHIVE_DIR}/git_status.txt" \
REQUIRE_CLEAN_GIT_WORKTREE="${REQUIRE_CLEAN_GIT_WORKTREE}" \
MIN_SOAK_CYCLES="${MIN_SOAK_CYCLES}" \
MIN_SOAK_ROWS="${MIN_SOAK_ROWS}" \
python3 - <<'PY'
import csv
import os
import shlex

summary_csv = os.environ["SUMMARY_CSV"]
summary_txt = os.environ["SUMMARY_TXT"]
config_env = os.environ["CONFIG_ENV"]
metadata_txt = os.environ["METADATA_TXT"]
git_status_txt = os.environ["GIT_STATUS_TXT"]
require_clean_git_worktree = os.environ["REQUIRE_CLEAN_GIT_WORKTREE"] == "1"
min_cycles = int(os.environ["MIN_SOAK_CYCLES"])
min_rows = int(os.environ["MIN_SOAK_ROWS"])

with open(summary_csv, newline="") as f:
    rows = list(csv.DictReader(f))
if len(rows) < min_rows:
    raise SystemExit("production soak rows below minimum: %d < %d" % (len(rows), min_rows))

def f(row, key):
    value = row.get(key, "")
    return float(value) if value not in ("", None) else 0.0

def read_config(path):
    config = {}
    with open(path, encoding="utf-8") as cfg:
        for line in cfg:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            parts = shlex.split(value)
            config[key] = parts[0] if parts else ""
    return config

config = read_config(config_env)
metadata = read_config(metadata_txt)

tracked_clean = metadata.get("sdk_git_tracked_worktree_clean", "")
if require_clean_git_worktree and tracked_clean != "true":
    raise SystemExit(
        "production soak archive was not generated from a clean tracked worktree: %s"
        % (tracked_clean or "missing")
    )

with open(git_status_txt, encoding="utf-8") as git_status_fh:
    git_status_text = git_status_fh.read().strip()
if require_clean_git_worktree and git_status_text != "tracked_changes=0":
    raise SystemExit("production soak archive git_status.txt has tracked changes")

cycles = sorted({int(float(row["cycle"])) for row in rows})
if len(cycles) < min_cycles:
    raise SystemExit(
        "production soak cycles below minimum: %d < %d" % (len(cycles), min_cycles)
    )

failed = [row for row in rows if row.get("pass") != "true"]
if failed:
    raise SystemExit("production soak has failed rows: %d" % len(failed))

hard_failures = {
    "decode_errors": sum(f(row, "decode_errors") for row in rows),
    "freeze_count": sum(f(row, "freeze_count") for row in rows),
    "renderer_proxy_late_frames": sum(f(row, "renderer_proxy_late_frames") for row in rows),
    "renderer_proxy_drop_frames": sum(f(row, "renderer_proxy_drop_frames") for row in rows),
    "push_queue_full": sum(f(row, "push_queue_full") for row in rows),
}
bad = {key: value for key, value in hard_failures.items() if value}
if bad:
    raise SystemExit("production soak hard failures: %s" % bad)

weak_low_scenarios = {
    "bandwidth_cliff_recover",
    "weak_network_low_rps_low_bitrate",
    "sustained_low_bandwidth_low_rps",
    "weak_start_low_bandwidth_low_rps",
    "walking_dead_zone_recover",
    "oscillating_edge_recover",
}
weak_low_rows = [row for row in rows if row.get("scenario", "") in weak_low_scenarios]
max_weak_send_rps = float(config.get("MAX_WEAK_SEND_RPS", "15.0"))
max_weak_rtp_pps = float(config.get("MAX_WEAK_RTP_PPS", "210.0"))
max_weak_target_bps = int(float(config.get("MAX_WEAK_TARGET_BPS", "0") or "0"))
if max_weak_target_bps <= 0:
    min_bitrate_bps = int(float(config.get("MIN_BITRATE_BPS", "300000") or "300000"))
    max_weak_target_bps = max(min_bitrate_bps * 2, min_bitrate_bps)
max_weak_encoder_fps = int(float(config.get("MAX_WEAK_ENCODER_FPS", "10") or "10"))
weak_failures = []
for row in weak_low_rows:
    row_failures = []
    if max_weak_send_rps > 0 and f(row, "bad_send_rps") > max_weak_send_rps:
        row_failures.append("bad_send_rps=%g>%g" % (f(row, "bad_send_rps"), max_weak_send_rps))
    if max_weak_rtp_pps > 0 and f(row, "bad_rtp_pps") > max_weak_rtp_pps:
        row_failures.append("bad_rtp_pps=%g>%g" % (f(row, "bad_rtp_pps"), max_weak_rtp_pps))
    if f(row, "max_bad_target_bps") <= 0 or f(row, "max_bad_target_bps") > max_weak_target_bps:
        row_failures.append("max_bad_target_bps=%g>%d" % (f(row, "max_bad_target_bps"), max_weak_target_bps))
    if f(row, "max_bad_encoder_fps") <= 0 or f(row, "max_bad_encoder_fps") > max_weak_encoder_fps:
        row_failures.append("max_bad_encoder_fps=%g>%d" % (f(row, "max_bad_encoder_fps"), max_weak_encoder_fps))
    if row_failures:
        weak_failures.append("%s/%s: %s" % (row.get("cycle", "?"), row.get("scenario", "?"), "; ".join(row_failures)))
if weak_failures:
    raise SystemExit("production soak weak low-RPS/bitrate failures: %s" % weak_failures[:8])

summary_text = open(summary_txt, encoding="utf-8").read()
if "production_soak_summary" not in summary_text:
    raise SystemExit("production soak summary marker missing")

print("production_soak_archive_verification=true")
print("cycles=%d" % len(cycles))
print("rows=%d" % len(rows))
print("playable_ratio_min=%g" % min(f(row, "playable_ratio") for row in rows))
print("avg_psnr_y_min=%g" % min(f(row, "avg_psnr_y") for row in rows))
print("avg_ssim_y_min=%g" % min(f(row, "avg_ssim_y") for row in rows))
print("renderer_proxy_max_gap_ms=%g" % max(f(row, "renderer_proxy_max_gap_ms") for row in rows))
print("renderer_proxy_max_jitter_ms=%g" % max(f(row, "renderer_proxy_max_jitter_ms") for row in rows))
print("sdk_git_tracked_worktree_clean=%s" % (tracked_clean or "missing"))
print("weak_low_rows=%d" % len(weak_low_rows))
print("weak_low_bad_send_rps_max=%g" % max((f(row, "bad_send_rps") for row in weak_low_rows), default=0))
print("weak_low_bad_rtp_pps_max=%g" % max((f(row, "bad_rtp_pps") for row in weak_low_rows), default=0))
print("weak_low_target_bps_max=%g" % max((f(row, "max_bad_target_bps") for row in weak_low_rows), default=0))
print("weak_low_encoder_fps_max=%g" % max((f(row, "max_bad_encoder_fps") for row in weak_low_rows), default=0))
PY

python3 "${SDK_ROOT}/scripts/verify_recovery_time_distribution.py" \
  --min-samples 1 \
  --max-target-p95-ms 1000 \
  --max-fps-p95-ms 1000 \
  --max-full-p95-ms 1000 \
  --max-target-ms 1000 \
  --max-fps-ms 1000 \
  --max-full-ms 1000 \
  --require-pass \
  "${SUMMARY_CSV}"
