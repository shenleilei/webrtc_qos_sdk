#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-/root/output}"
RUNS="${RUNS:-3}"
BASE_PORT_START="${BASE_PORT_START:-42000}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_udp_netem_matrix}"
BUILD_DEMOS="${BUILD_DEMOS:-1}"

mkdir -p "${LOG_DIR}"
rm -f "${LOG_DIR}/metrics.jsonl"

if [[ "${BUILD_DEMOS}" != "0" ]]; then
  "${SDK_ROOT}/scripts/build_udp_demos.sh" >/dev/null
fi

SCENARIOS=(
  "baseline_drop:2:0:0"
  "reorder:2:4:0"
  "delay:2:0:30"
  "reorder_delay:2:4:30"
)

require_line() {
  local pattern="$1"
  local file="$2"
  local message="$3"
  if ! grep -Eq "${pattern}" "${file}"; then
    echo "netem matrix check failed: ${message}" >&2
    echo "--- ${file} ---" >&2
    cat "${file}" >&2
    exit 1
  fi
}

scenario_index=0
for run in $(seq 1 "${RUNS}"); do
  for scenario in "${SCENARIOS[@]}"; do
    IFS=":" read -r name drop_seq reorder_seq delay_ms <<<"${scenario}"
    base_port=$((BASE_PORT_START + scenario_index * 10))
    log_file="${LOG_DIR}/${run}_${name}.log"

    echo "netem run=${run} scenario=${name} drop=${drop_seq} reorder=${reorder_seq} delay_ms=${delay_ms}"
    BASE_PORT="${base_port}" \
    PREFIX="${PREFIX}" \
    DROP_RTP_SEQ="${drop_seq}" \
    REORDER_RTP_SEQ="${reorder_seq}" \
    DELAY_MS="${delay_ms}" \
      "${SDK_ROOT}/scripts/run_udp_loopback_demo.sh" >"${log_file}" 2>&1

    metrics_args=(
      --log "${log_file}"
      --summary "${LOG_DIR}/${run}_${name}.summary.json"
      --jsonl "${LOG_DIR}/metrics.jsonl"
      --scenario "${name}"
      --run "${run}"
      --drop-seq "${drop_seq}"
      --reorder-seq "${reorder_seq}"
      --delay-ms "${delay_ms}"
      --expect-rate-cap
    )
    if [[ "${reorder_seq}" != "0" ]]; then
      metrics_args+=(--expect-reorder)
    fi
    if [[ "${delay_ms}" != "0" ]]; then
      metrics_args+=(--expect-delay)
    fi
    python3 "${SDK_ROOT}/scripts/collect_udp_metrics.py" "${metrics_args[@]}"

    require_line "udp_sender sent=[0-9]+ feedback=[1-9][0-9]* rr=[1-9][0-9]* rate_caps=[1-9][0-9]* pli_received=[1-9][0-9]* idr_resends=[1-9][0-9]*" \
      "${log_file}" "sender did not consume TWCC/RR/rate cap/PLI or resend IDR"
    require_line "final_target_bps=1000000" \
      "${log_file}" "sender rate cap did not affect final target"
    require_line "udp_server .*dropped=[1-9][0-9]*" \
      "${log_file}" "server did not apply configured packet drop"
    require_line "udp_server .*retransmitted=[1-9][0-9]*" \
      "${log_file}" "server did not retransmit from cache"
    require_line "udp_server .*rr_sent=[1-9][0-9]* rate_caps=[1-9][0-9]* pli_forwarded=[1-9][0-9]*" \
      "${log_file}" "server did not send RR/rate cap or forward PLI"
    require_line "udp_receiver .*nack_sent=[1-9][0-9]* pli_sent=[1-9][0-9]* frames=3" \
      "${log_file}" "receiver did not NACK, send PLI, and recover three frames"

    if [[ "${reorder_seq}" != "0" ]]; then
      require_line "udp_server .*reordered=[1-9][0-9]*" \
        "${log_file}" "server did not apply configured reorder"
    fi
    if [[ "${delay_ms}" != "0" ]]; then
      require_line "udp_server .*delayed=[1-9][0-9]*" \
        "${log_file}" "server did not apply configured delay"
    fi

    scenario_index=$((scenario_index + 1))
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
    raise SystemExit("no metrics rows collected")

def values(path):
    out = []
    for row in rows:
        cur = row
        for key in path:
            cur = cur.get(key, {})
        if isinstance(cur, (int, float)):
            out.append(cur)
    return out

def aggregate(path):
    vals = values(path)
    return {
        "min": min(vals) if vals else 0,
        "max": max(vals) if vals else 0,
        "avg": sum(vals) / len(vals) if vals else 0,
    }

summary = {
    "runs": len(rows),
    "scenarios": sorted(set(row.get("scenario", "unknown") for row in rows)),
    "threshold_failures": [
        {
            "scenario": row.get("scenario"),
            "run": row.get("run"),
            "failures": row.get("thresholds", {}).get("failures", []),
        }
        for row in rows
        if not row.get("thresholds", {}).get("ok", False)
    ],
    "receiver_frames": aggregate(["receiver", "frames"]),
    "sender_rtt_ms": aggregate(["sender", "rtt_ms"]),
    "sender_final_target_bps": aggregate(["sender", "final_target_bps"]),
    "retransmission_success_ratio": aggregate(
        ["derived", "retransmission_success_ratio"]
    ),
    "observed_loss_fraction": aggregate(["derived", "observed_loss_fraction"]),
    "max_reported_loss_q8": aggregate(["derived", "max_reported_loss_q8"]),
    "max_reported_jitter_frames": aggregate(
        ["derived", "max_reported_jitter_frames"]
    ),
}
summary_path.write_text(
    json.dumps(summary, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
if summary["threshold_failures"]:
    print(json.dumps(summary, indent=2, sort_keys=True), file=sys.stderr)
    raise SystemExit("metric threshold failures")
print(
    "metrics summary runs={runs} frames_min={frames_min} "
    "rtt_max={rtt_max} final_bps_min={final_bps_min}".format(
        runs=summary["runs"],
        frames_min=summary["receiver_frames"]["min"],
        rtt_max=summary["sender_rtt_ms"]["max"],
        final_bps_min=summary["sender_final_target_bps"]["min"],
    )
)
PY

echo "udp netem matrix passed runs=${RUNS} scenarios=${#SCENARIOS[@]} logs=${LOG_DIR} metrics=${LOG_DIR}/metrics.jsonl summary=${LOG_DIR}/summary.json"
