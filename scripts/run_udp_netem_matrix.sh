#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-/root/output}"
RUNS="${RUNS:-3}"
BASE_PORT_START="${BASE_PORT_START:-42000}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_udp_netem_matrix}"
BUILD_DEMOS="${BUILD_DEMOS:-1}"
SCENARIO_FILE="${SCENARIO_FILE:-${SDK_ROOT}/scripts/udp_netem_scenarios.json}"

mkdir -p "${LOG_DIR}"
rm -f "${LOG_DIR}/metrics.jsonl"

if [[ "${BUILD_DEMOS}" != "0" ]]; then
  "${SDK_ROOT}/scripts/build_udp_demos.sh" >/dev/null
fi

run_scenarios() {
  python3 - "$SCENARIO_FILE" "$RUNS" "$BASE_PORT_START" <<'PY'
import json
import sys
from pathlib import Path

scenario_file = Path(sys.argv[1])
runs = int(sys.argv[2])
base_port_start = int(sys.argv[3])
scenarios = json.loads(scenario_file.read_text(encoding="utf-8"))
index = 0
for run in range(1, runs + 1):
    for scenario in scenarios:
        netem = scenario.get("netem", {})
        expect = scenario.get("expect", {})
        drop = ",".join(str(x) for x in netem.get("drop_seqs", []))
        reorder = ",".join(str(x) for x in netem.get("reorder_seqs", []))
        fields = [
            str(run),
            scenario["name"],
            str(base_port_start + index * 10),
            drop,
            reorder,
            str(netem.get("reorder_delay_ms", 120)),
            str(netem.get("delay_ms", 0)),
            str(netem.get("jitter_ms", 0)),
            str(netem.get("jitter_every_n", 0)),
            str(expect.get("min_feedback", 1)),
            str(expect.get("min_rr", 1)),
            str(expect.get("min_rate_caps", 1)),
            str(expect.get("min_pli", 1)),
            str(expect.get("min_nack", 1)),
            str(expect.get("min_retransmitted", 1)),
            str(expect.get("min_frames", 3)),
            str(expect.get("min_keyframes", 1)),
            str(expect.get("max_frame_gap_ms", 34)),
            str(expect.get("min_retransmit_ratio", 1.0)),
            "1" if expect.get("rate_cap", True) else "0",
            "1" if expect.get("reorder", False) else "0",
            "1" if expect.get("delay", False) else "0",
            "1" if expect.get("jitter", False) else "0",
        ]
        print("|".join(fields))
        index += 1
PY
}

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

scenario_count="$(python3 - "$SCENARIO_FILE" <<'PY'
import json
import sys
from pathlib import Path
print(len(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))))
PY
)"

while IFS="|" read -r run name base_port drop_seqs reorder_seqs reorder_delay_ms delay_ms jitter_ms jitter_every_n min_feedback min_rr min_rate_caps min_pli min_nack min_retransmitted min_frames min_keyframes max_frame_gap_ms min_retransmit_ratio expect_rate_cap expect_reorder expect_delay expect_jitter; do
  log_file="${LOG_DIR}/${run}_${name}.log"
  summary_file="${LOG_DIR}/${run}_${name}.summary.json"

  echo "netem run=${run} scenario=${name} drop=${drop_seqs:-none} reorder=${reorder_seqs:-none} reorder_delay_ms=${reorder_delay_ms} delay_ms=${delay_ms} jitter_ms=${jitter_ms} jitter_every_n=${jitter_every_n}"

  BASE_PORT="${base_port}" \
  PREFIX="${PREFIX}" \
  DROP_RTP_SEQS="${drop_seqs}" \
  REORDER_RTP_SEQS="${reorder_seqs}" \
  REORDER_DELAY_MS="${reorder_delay_ms}" \
  DELAY_MS="${delay_ms}" \
  JITTER_MS="${jitter_ms}" \
  JITTER_EVERY_N="${jitter_every_n}" \
    "${SDK_ROOT}/scripts/run_udp_loopback_demo.sh" >"${log_file}" 2>&1

  metrics_args=(
    --log "${log_file}"
    --summary "${summary_file}"
    --jsonl "${LOG_DIR}/metrics.jsonl"
    --scenario "${name}"
    --run "${run}"
    --drop-count "$(python3 - "${drop_seqs}" <<'PY'
import sys
items = [x for x in sys.argv[1].split(",") if x]
print(len(items))
PY
)"
    --reorder-count "$(python3 - "${reorder_seqs}" <<'PY'
import sys
items = [x for x in sys.argv[1].split(",") if x]
print(len(items))
PY
)"
    --delay-ms "${delay_ms}"
    --jitter-ms "${jitter_ms}"
    --jitter-every-n "${jitter_every_n}"
    --min-feedback "${min_feedback}"
    --min-rr "${min_rr}"
    --min-rate-caps "${min_rate_caps}"
    --min-pli "${min_pli}"
    --min-nack "${min_nack}"
    --min-retransmitted "${min_retransmitted}"
    --min-frames "${min_frames}"
    --min-keyframes "${min_keyframes}"
    --max-frame-gap-ms "${max_frame_gap_ms}"
    --min-retransmit-ratio "${min_retransmit_ratio}"
  )
  if [[ "${expect_rate_cap}" == "1" ]]; then
    metrics_args+=(--expect-rate-cap)
  fi
  if [[ "${expect_reorder}" == "1" ]]; then
    metrics_args+=(--expect-reorder)
  fi
  if [[ "${expect_delay}" == "1" ]]; then
    metrics_args+=(--expect-delay)
  fi
  if [[ "${expect_jitter}" == "1" ]]; then
    metrics_args+=(--expect-jitter)
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
  require_line "udp_receiver .*nack_sent=[1-9][0-9]* pli_sent=[1-9][0-9]* frames=${min_frames}" \
    "${log_file}" "receiver did not NACK, send PLI, and recover expected frames"
done < <(run_scenarios)

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
    "receiver_keyframes": aggregate(["derived", "keyframes"]),
    "max_frame_gap_ms": aggregate(["derived", "max_frame_gap_ms"]),
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

echo "udp netem matrix passed runs=${RUNS} scenarios=${scenario_count} logs=${LOG_DIR} metrics=${LOG_DIR}/metrics.jsonl summary=${LOG_DIR}/summary.json"
