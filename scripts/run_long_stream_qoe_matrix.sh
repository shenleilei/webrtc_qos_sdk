#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
BUILD_DIR="${BUILD_DIR:-${SDK_ROOT}/build}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_long_stream_qoe_matrix}"

mkdir -p "${LOG_DIR}"
rm -f "${LOG_DIR}/metrics.jsonl"

cmake --build "${BUILD_DIR}" --target long_stream_qoe_demo -j2 >/dev/null

strategies=(adaptive balanced bitrate_only fixed)
for strategy in "${strategies[@]}"; do
  log_file="${LOG_DIR}/${strategy}.log"
  summary_file="${LOG_DIR}/${strategy}.summary.json"
  echo "long_stream_qoe strategy=${strategy}"
  "${BUILD_DIR}/long_stream_qoe_demo" \
    --strategy="${strategy}" \
    --summary="${summary_file}" >"${log_file}" 2>&1
  python3 - "${summary_file}" "${LOG_DIR}/metrics.jsonl" <<'PY'
import json
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
jsonl_path = Path(sys.argv[2])
data = json.loads(summary_path.read_text(encoding="utf-8"))
with jsonl_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(data, sort_keys=True) + "\n")
print(
    "metrics strategy={strategy} freeze={freeze} max_freeze_ms={max_freeze} "
    "drops={drops} frames={frames} duplicates={duplicates}".format(
        strategy=data.get("strategy"),
        freeze=data.get("freeze_count"),
        max_freeze=data.get("max_freeze_ms"),
        drops=data.get("network_drops"),
        frames=data.get("receiver_frames"),
        duplicates=data.get("duplicate_frames"),
    )
)
PY
done

python3 - "${LOG_DIR}/metrics.jsonl" "${LOG_DIR}/summary.json" <<'PY'
import json
import sys
from pathlib import Path

metrics_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
rows = [
    json.loads(line)
    for line in metrics_path.read_text(encoding="utf-8").splitlines()
    if line.strip()
]
if not rows:
    raise SystemExit("no long stream metrics")

def phase(row, name):
    for item in row.get("phases", []):
        if item.get("name") == name:
            return item
    return {}

def weak_phase_penalty(row):
    outage = phase(row, "outage")
    poor = phase(row, "poor")
    recovered = phase(row, "good_again")
    low_fps_penalty = max(0.0, 4.0 - outage.get("receiver_fps", 0.0)) * 20
    low_fps_penalty += max(0.0, 4.0 - poor.get("receiver_fps", 0.0)) * 20
    recovery_penalty = max(0.0, 20.0 - recovered.get("receiver_fps", 0.0)) * 10
    return low_fps_penalty + recovery_penalty

def smoothness_score(row):
    freeze_penalty = row.get("freeze_count", 0) * 100
    freeze_penalty += row.get("max_freeze_ms", 0) / 10.0
    drop_penalty = row.get("network_drops", 0) * 1
    return round(freeze_penalty + drop_penalty + weak_phase_penalty(row), 3)

def balanced_qoe_score(row):
    # Smoothness alone can incorrectly reward a strategy that keeps outputting
    # repeated/low-information frames. Penalize duplicate output and drops to
    # approximate the quality side until a real renderer/decoder reports QP,
    # decode drops, and objective quality metrics.
    duplicate_penalty = row.get("duplicate_frames", 0) * 5
    drop_penalty = row.get("network_drops", 0) * 2
    return round(
        smoothness_score(row) + duplicate_penalty + drop_penalty,
        3,
    )

for row in rows:
    row["smoothness_score"] = smoothness_score(row)
    row["balanced_qoe_score"] = balanced_qoe_score(row)

best_smoothness = min(rows, key=lambda row: row["smoothness_score"])
best_balanced = min(rows, key=lambda row: row["balanced_qoe_score"])
summary = {
    "strategies": [
        {
            "strategy": row.get("strategy"),
            "smoothness_score": row["smoothness_score"],
            "balanced_qoe_score": row["balanced_qoe_score"],
            "freeze_count": row.get("freeze_count"),
            "max_freeze_ms": row.get("max_freeze_ms"),
            "network_drops": row.get("network_drops"),
            "duplicate_frames": row.get("duplicate_frames"),
            "receiver_frames": row.get("receiver_frames"),
            "outage_receiver_fps": phase(row, "outage").get("receiver_fps"),
            "poor_receiver_fps": phase(row, "poor").get("receiver_fps"),
            "recovered_receiver_fps": phase(row, "good_again").get(
                "receiver_fps"
            ),
        }
        for row in rows
    ],
    "best_smoothness_strategy": best_smoothness.get("strategy"),
    "best_smoothness_score": best_smoothness["smoothness_score"],
    "best_balanced_qoe_strategy": best_balanced.get("strategy"),
    "best_balanced_qoe_score": best_balanced["balanced_qoe_score"],
    "objective_note": (
        "smoothness_score optimizes continuity only; balanced_qoe_score also "
        "penalizes duplicate output and network drops. This proves the best "
        "strategy only inside this scenario and objective definition, not a "
        "global optimum."
    ),
}
summary_path.write_text(
    json.dumps(summary, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
print(
    "long stream qoe matrix passed best_smoothness={smooth} "
    "smoothness_score={smooth_score} best_balanced={balanced} "
    "balanced_qoe_score={balanced_score}".format(
        smooth=summary["best_smoothness_strategy"],
        smooth_score=summary["best_smoothness_score"],
        balanced=summary["best_balanced_qoe_strategy"],
        balanced_score=summary["best_balanced_qoe_score"],
    )
)
PY

echo "long stream qoe matrix passed logs=${LOG_DIR} metrics=${LOG_DIR}/metrics.jsonl summary=${LOG_DIR}/summary.json"
