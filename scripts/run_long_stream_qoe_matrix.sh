#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
BUILD_DIR="${BUILD_DIR:-${SDK_ROOT}/build}"
PREFIX="${PREFIX:-/root/output}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_long_stream_qoe_matrix}"
CXX="${CXX:-g++}"
LIBATOMIC_DIR="${LIBATOMIC_DIR:-/usr/lib/gcc/x86_64-redhat-linux/10}"

mkdir -p "${LOG_DIR}"
rm -f "${LOG_DIR}/metrics.jsonl"

cmake --build "${BUILD_DIR}" --target long_stream_qoe_demo -j2 >/dev/null

WEBRTC_DEMO="${LOG_DIR}/long_stream_qoe_webrtc_demo"
webrtc_backend_available=0
if [[ -f "${PREFIX}/include/webrtc_qos/googcc_adapter.h" &&
      -f "${PREFIX}/include/webrtc_qos/video_jitter_adapter.h" &&
      -f "${PREFIX}/lib/libwebrtc_qos_googcc_adapter.a" &&
      -f "${PREFIX}/lib/libwebrtc_qos_googcc_bridge.a" &&
      -f "${PREFIX}/lib/libwebrtc_qos_video_jitter_adapter.a" &&
      -f "${PREFIX}/lib/libwebrtc_qos_video_jitter_bridge.a" &&
      -f "${BUILD_DIR}/libwebrtc_qos_ffmpeg_encoder.a" ]]; then
  "${CXX}" -std=c++20 -DWEBRTC_QOS_ENABLE_WEBRTC_BACKEND \
    -I"${SDK_ROOT}/include" \
    -I"${PREFIX}/include" \
    "${SDK_ROOT}/demo/long_stream_qoe/main.cc" \
    "${SDK_ROOT}/src/sender_qos_googcc_bridge.cc" \
    "${SDK_ROOT}/src/video_jitter_bridge.cc" \
    "${BUILD_DIR}/libwebrtc_qos_ffmpeg_encoder.a" \
    "${BUILD_DIR}/libwebrtc_qos.a" \
    "${PREFIX}/lib/libwebrtc_qos_googcc_adapter.a" \
    "${PREFIX}/lib/libwebrtc_qos_video_jitter_adapter.a" \
    -L"${LIBATOMIC_DIR}" \
    -lavcodec -lavutil -lpthread -ldl -lrt -latomic \
    -o "${WEBRTC_DEMO}"
  webrtc_backend_available=1
else
  echo "long_stream_qoe webrtc backend skipped: adapter archives or headers missing"
fi

scenarios=(walking_dead_zone jitter_loss_oscillation bandwidth_staircase)
strategies=(adaptive balanced bitrate_only fixed)
backends=(lightweight)
if [[ "${webrtc_backend_available}" == "1" ]]; then
  backends+=(webrtc)
fi

for backend in "${backends[@]}"; do
  if [[ "${backend}" == "webrtc" ]]; then
    demo="${WEBRTC_DEMO}"
  else
    demo="${BUILD_DIR}/long_stream_qoe_demo"
  fi
  for scenario in "${scenarios[@]}"; do
    for strategy in "${strategies[@]}"; do
      log_file="${LOG_DIR}/${scenario}_${backend}_${strategy}.log"
      summary_file="${LOG_DIR}/${scenario}_${backend}_${strategy}.summary.json"
      echo "long_stream_qoe scenario=${scenario} backend=${backend} strategy=${strategy}"
      "${demo}" \
        --scenario="${scenario}" \
        --backend="${backend}" \
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
    "metrics scenario={scenario} backend={backend} strategy={strategy} freeze={freeze} "
    "max_freeze_ms={max_freeze} drops={drops} frames={frames} "
    "duplicates={duplicates}".format(
        scenario=data.get("scenario"),
        backend=data.get("backend"),
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
  done
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

def phase_value(row, name, key, default=0.0):
    value = phase(row, name).get(key, default)
    return default if value is None else value

SCENARIO_EXPECTATIONS = {
    "walking_dead_zone": {
        "outage_bps_max": 250000.0,
        "poor_bps_max": 350000.0,
        "recovered_bps_min": 1800000.0,
        "outage_fps_max": 8.0,
        "poor_fps_max": 12.0,
        "recovered_fps_min": 24.0,
    },
    "jitter_loss_oscillation": {
        "outage_bps_max": 350000.0,
        "poor_bps_max": 450000.0,
        "recovered_bps_min": 1800000.0,
        "outage_fps_max": 12.0,
        "poor_fps_max": 12.0,
        "recovered_fps_min": 24.0,
    },
    "bandwidth_staircase": {
        "outage_bps_max": 450000.0,
        "poor_bps_max": 300000.0,
        "recovered_bps_min": 1800000.0,
        "outage_fps_max": 15.0,
        "poor_fps_max": 12.0,
        "recovered_fps_min": 24.0,
    },
}

def weak_phase_penalty(row):
    low_fps_penalty = max(0.0, 4.0 - phase_value(row, "outage", "receiver_fps")) * 20
    low_fps_penalty += max(0.0, 4.0 - phase_value(row, "poor", "receiver_fps")) * 20
    recovery_penalty = max(0.0, 20.0 - phase_value(row, "good_again", "receiver_fps")) * 10
    return low_fps_penalty + recovery_penalty

def adaptation_penalty(row):
    # QoS must react in both directions: reduce bitrate/FPS in weak phases and
    # recover when the route becomes good again. This keeps fixed or bitrate-only
    # strategies from winning merely because they look smooth in a synthetic run.
    outage_bps = phase_value(row, "outage", "target_bps_min")
    poor_bps = phase_value(row, "poor", "target_bps_min")
    recovered_bps = phase_value(row, "good_again", "target_bps_last")
    outage_fps = phase_value(row, "outage", "fps_min")
    poor_fps = phase_value(row, "poor", "fps_min")
    recovered_fps = phase_value(row, "good_again", "fps_last")
    expected = SCENARIO_EXPECTATIONS.get(
        row.get("scenario", "unknown"),
        SCENARIO_EXPECTATIONS["walking_dead_zone"],
    )
    penalty = 0.0
    penalty += max(0.0, outage_bps - expected["outage_bps_max"]) / 1000.0
    penalty += max(0.0, poor_bps - expected["poor_bps_max"]) / 1000.0
    penalty += max(0.0, expected["recovered_bps_min"] - recovered_bps) / 1000.0
    penalty += max(0.0, outage_fps - expected["outage_fps_max"]) * 20.0
    penalty += max(0.0, poor_fps - expected["poor_fps_max"]) * 20.0
    penalty += max(0.0, expected["recovered_fps_min"] - recovered_fps) * 20.0
    return penalty

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
        smoothness_score(row) + duplicate_penalty + drop_penalty + adaptation_penalty(row),
        3,
    )

for row in rows:
    row["smoothness_score"] = smoothness_score(row)
    row["balanced_qoe_score"] = balanced_qoe_score(row)

best_smoothness = min(rows, key=lambda row: row["smoothness_score"])
best_balanced = min(rows, key=lambda row: row["balanced_qoe_score"])

best_by_backend = {}
for backend in sorted({row.get("backend", "unknown") for row in rows}):
    backend_rows = [row for row in rows if row.get("backend", "unknown") == backend]
    best_by_backend[backend] = {
        "best_smoothness_strategy": min(
            backend_rows, key=lambda row: row["smoothness_score"]
        ).get("strategy"),
        "best_balanced_qoe_strategy": min(
            backend_rows, key=lambda row: row["balanced_qoe_score"]
        ).get("strategy"),
    }

scenarios = sorted({row.get("scenario", "unknown") for row in rows})
scenario_results = {}
for scenario in scenarios:
    scenario_rows = [row for row in rows if row.get("scenario", "unknown") == scenario]
    scenario_best_smoothness = min(scenario_rows, key=lambda row: row["smoothness_score"])
    scenario_best_balanced = min(
        scenario_rows, key=lambda row: row["balanced_qoe_score"]
    )
    scenario_results[scenario] = {
        "best_smoothness_backend": scenario_best_smoothness.get("backend", "unknown"),
        "best_smoothness_strategy": scenario_best_smoothness.get("strategy"),
        "best_smoothness_score": scenario_best_smoothness["smoothness_score"],
        "best_balanced_qoe_backend": scenario_best_balanced.get("backend", "unknown"),
        "best_balanced_qoe_strategy": scenario_best_balanced.get("strategy"),
        "best_balanced_qoe_score": scenario_best_balanced["balanced_qoe_score"],
    }

best_by_scenario_backend = {}
for scenario in scenarios:
    best_by_scenario_backend[scenario] = {}
    scenario_rows = [row for row in rows if row.get("scenario", "unknown") == scenario]
    for backend in sorted({row.get("backend", "unknown") for row in scenario_rows}):
        backend_rows = [
            row for row in scenario_rows if row.get("backend", "unknown") == backend
        ]
        best_by_scenario_backend[scenario][backend] = {
            "best_smoothness_strategy": min(
                backend_rows, key=lambda row: row["smoothness_score"]
            ).get("strategy"),
            "best_balanced_qoe_strategy": min(
                backend_rows, key=lambda row: row["balanced_qoe_score"]
            ).get("strategy"),
        }

summary = {
    "strategies": [
        {
            "scenario": row.get("scenario", "unknown"),
            "backend": row.get("backend", "unknown"),
            "strategy": row.get("strategy"),
            "smoothness_score": row["smoothness_score"],
            "balanced_qoe_score": row["balanced_qoe_score"],
            "adaptation_penalty": round(adaptation_penalty(row), 3),
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
            "outage_target_bps_min": phase(row, "outage").get("target_bps_min"),
            "poor_target_bps_min": phase(row, "poor").get("target_bps_min"),
            "recovered_target_bps_last": phase(row, "good_again").get(
                "target_bps_last"
            ),
            "outage_fps_min": phase(row, "outage").get("fps_min"),
            "poor_fps_min": phase(row, "poor").get("fps_min"),
            "recovered_fps_last": phase(row, "good_again").get("fps_last"),
        }
        for row in rows
    ],
    "best_smoothness_strategy": best_smoothness.get("strategy"),
    "best_smoothness_backend": best_smoothness.get("backend", "unknown"),
    "best_smoothness_score": best_smoothness["smoothness_score"],
    "best_balanced_qoe_strategy": best_balanced.get("strategy"),
    "best_balanced_qoe_backend": best_balanced.get("backend", "unknown"),
    "best_balanced_qoe_score": best_balanced["balanced_qoe_score"],
    "best_by_backend": best_by_backend,
    "scenario_results": scenario_results,
    "best_by_scenario_backend": best_by_scenario_backend,
    "scenario_expectations": SCENARIO_EXPECTATIONS,
    "objective_note": (
        "smoothness_score optimizes continuity only; balanced_qoe_score also "
        "penalizes duplicate output, network drops, weak-network non-adaptation, "
        "and failure to recover when the route becomes good again. This proves "
        "the best strategy only inside these scenarios and objective definition, "
        "not a global optimum."
    ),
}
summary_path.write_text(
    json.dumps(summary, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
print(
    "long stream qoe matrix passed scenarios={scenario_count} "
    "best_smoothness={smooth_backend}/{smooth} smoothness_score={smooth_score} "
    "best_balanced={balanced_backend}/{balanced} "
    "balanced_qoe_score={balanced_score}".format(
        scenario_count=len(scenarios),
        smooth_backend=summary["best_smoothness_backend"],
        smooth=summary["best_smoothness_strategy"],
        smooth_score=summary["best_smoothness_score"],
        balanced_backend=summary["best_balanced_qoe_backend"],
        balanced=summary["best_balanced_qoe_strategy"],
        balanced_score=summary["best_balanced_qoe_score"],
    )
)
PY

echo "long stream qoe matrix passed logs=${LOG_DIR} metrics=${LOG_DIR}/metrics.jsonl summary=${LOG_DIR}/summary.json"
