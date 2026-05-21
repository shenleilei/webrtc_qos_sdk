#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_udp_long_stream_matrix}"
BASE_PORT="${BASE_PORT:-49000}"
FRAMES="${FRAMES:-210}"
WIDTH="${WIDTH:-320}"
HEIGHT="${HEIGHT:-180}"
BITRATE="${BITRATE:-1200000}"
MATRIX_CONTENTS="${MATRIX_CONTENTS:-motion}"
MATRIX_RUNS="${MATRIX_RUNS:-1}"
MIN_RECONFIGS_WALKING="${MIN_RECONFIGS_WALKING:-10}"
MIN_RECONFIGS_BANDWIDTH="${MIN_RECONFIGS_BANDWIDTH:-8}"
MIN_RECONFIGS_JITTER="${MIN_RECONFIGS_JITTER:-4}"

rm -rf "${LOG_DIR}"
mkdir -p "${LOG_DIR}"

run_case() {
  local name="$1"
  local profile="$2"
  local base_port="$3"
  local content="$4"
  local run="$5"
  local expect_frames="$6"
  local min_completed="$7"
  local min_decoded="$8"
  local min_target_max="$9"
  local min_fps_max="${10}"
  local min_reconfigs="${11}"
  local max_gap_ms="${12}"
  local max_completion_gap_ms="${13}"
  local min_psnr_avg="${14}"
  local min_psnr_min="${15}"
  local min_phase_changes="${16}"
  local min_rate_caps="${17}"
  local min_nack="${18}"
  local min_retransmitted="${19}"
  local case_dir="${LOG_DIR}/${name}"
  local network_seed="${run}"

  echo "running udp long stream case ${name} content=${content} run=${run}"
  SDK_ROOT="${SDK_ROOT}" \
  BASE_PORT="${base_port}" \
  LOG_DIR="${case_dir}" \
  PROFILE="${profile}" \
  FRAMES="${FRAMES}" \
  EXPECT_FRAMES="${expect_frames}" \
  WIDTH="${WIDTH}" \
  HEIGHT="${HEIGHT}" \
  BITRATE="${BITRATE}" \
  CONTENT="${content}" \
  NETWORK_SEED="${network_seed}" \
  JITTER_MS=0 \
  JITTER_EVERY_N=0 \
    bash "${SDK_ROOT}/scripts/run_udp_long_stream_smoke.sh" \
      >"${case_dir}.stdout" 2>&1

  python3 - "${case_dir}/summary.json" "${LOG_DIR}/metrics.jsonl" \
    "${name}" "${profile}" "${content}" "${run}" \
    "${network_seed}" \
    "${min_completed}" "${min_decoded}" \
    "${min_target_max}" "${min_fps_max}" "${min_reconfigs}" \
    "${max_gap_ms}" "${max_completion_gap_ms}" \
    "${min_psnr_avg}" "${min_psnr_min}" \
    "${min_phase_changes}" "${min_rate_caps}" "${min_nack}" \
    "${min_retransmitted}" <<'PY'
import json
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
jsonl_path = Path(sys.argv[2])
name = sys.argv[3]
profile = sys.argv[4]
content = sys.argv[5]
run = int(sys.argv[6])
network_seed = int(sys.argv[7])
thresholds = {
    "min_completed": int(sys.argv[8]),
    "min_decoded": int(sys.argv[9]),
    "min_target_max": int(sys.argv[10]),
    "min_fps_max": int(sys.argv[11]),
    "min_reconfigs": int(sys.argv[12]),
    "max_gap_ms": int(sys.argv[13]),
    "max_completion_gap_ms": int(sys.argv[14]),
    "min_psnr_avg": float(sys.argv[15]),
    "min_psnr_min": float(sys.argv[16]),
    "min_phase_changes": int(sys.argv[17]),
    "min_rate_caps": int(sys.argv[18]),
    "min_nack": int(sys.argv[19]),
    "min_retransmitted": int(sys.argv[20]),
}
summary = json.loads(summary_path.read_text(encoding="utf-8"))
sender = summary["sender"]
server = summary["server"]
receiver = summary["receiver"]
failures = []

def check(condition, message):
    if not condition:
        failures.append(message)

check(sender["twcc"] > 0, "missing_sender_twcc")
check(sender["rr"] > 0, "missing_sender_rr")
check(sender["rate_caps"] >= thresholds["min_rate_caps"], "rate_caps_low")
check(sender["encoder_reconfigs"] >= thresholds["min_reconfigs"],
      "encoder_reconfigs_low")
check(sender["adapt_target_min"] <= thresholds["min_target_max"],
      "sender_did_not_downshift_bitrate")
check(sender["adapt_fps_min"] <= thresholds["min_fps_max"],
      "sender_did_not_downshift_fps")
check(sender["adapt_fps_last"] >= 30, "sender_fps_did_not_recover")
check(sender["adapt_target_last"] >= 1000000,
      "sender_bitrate_did_not_recover")
check(server["profile"] == profile, "server_profile_mismatch")
check(server.get("network_seed", network_seed) == network_seed,
      "server_network_seed_mismatch")
check(server["phase_changes"] >= thresholds["min_phase_changes"],
      "phase_changes_low")
check(server["impaired_packets"] > 0, "no_impaired_packets")
check(server["last_cap_bps"] == 4294967295, "server_cap_did_not_recover")
check(server["rate_caps"] >= thresholds["min_rate_caps"],
      "server_rate_caps_low")
check(server["twcc_sent"] > 0, "server_twcc_missing")
check(server["rr_sent"] > 0, "server_rr_missing")
check(server["quality_reports"] > 0, "server_quality_reports_missing")
check(server["retransmitted"] >= thresholds["min_retransmitted"],
      "retransmitted_low")
check(receiver["completed"] >= thresholds["min_completed"],
      "completed_frames_low")
check(receiver["decoded"] >= thresholds["min_decoded"], "decoded_frames_low")
check(receiver["errors"] == 0, "decode_errors")
check(receiver["quality"] >= thresholds["min_decoded"],
      "quality_samples_low")
check(receiver["psnr_avg"] >= thresholds["min_psnr_avg"], "psnr_avg_low")
check(receiver["psnr_min"] >= thresholds["min_psnr_min"], "psnr_min_low")
check(receiver["gap"] <= thresholds["max_gap_ms"], "max_frame_gap_high")
check(receiver.get("completion_gap", 0) <= thresholds["max_completion_gap_ms"],
      "max_completion_gap_high")
check(receiver["nack"] >= thresholds["min_nack"], "nack_low")
check(receiver["downlink_reports"] > 0, "downlink_reports_missing")

summary["case"] = name
summary["content"] = content
summary["run"] = run
summary["network_seed"] = network_seed
summary["thresholds"] = thresholds
summary["validation_failures"] = failures
with jsonl_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(summary, sort_keys=True) + "\n")
if failures:
    print(json.dumps(summary, indent=2, sort_keys=True), file=sys.stderr)
    raise SystemExit(f"{name} failed: {', '.join(failures)}")
print(
    "case={case} content={content} run={run} completed={completed} decoded={decoded} "
    "seed={seed} target_min={target_min} fps_min={fps_min} target_last={target_last} "
    "gap={gap} psnr_avg={psnr_avg:.2f}".format(
        case=name,
        content=content,
        run=run,
        seed=network_seed,
        completed=receiver["completed"],
        decoded=receiver["decoded"],
        target_min=sender["adapt_target_min"],
        fps_min=sender["adapt_fps_min"],
        target_last=sender["adapt_target_last"],
        gap=receiver["gap"],
        psnr_avg=receiver["psnr_avg"],
    )
)
PY
}

: >"${LOG_DIR}/metrics.jsonl"
case_index=0
for content in ${MATRIX_CONTENTS}; do
  min_psnr_avg_strict=35.0
  min_psnr_min_strict=18.0
  min_psnr_avg_jitter=30.0
  min_psnr_min_jitter=18.0
  max_gap_bandwidth=400
  max_completion_gap_jitter=400
  if [[ "${content}" == "detail_motion" ]]; then
    min_psnr_min_strict=16.0
    min_psnr_min_jitter=16.0
  fi
  for run in $(seq 1 "${MATRIX_RUNS}"); do
    run_case "walking_dead_zone_${content}_run${run}" walking_dead_zone \
      "$((BASE_PORT + case_index * 100))" "${content}" "${run}" \
      80 100 100 100000 8 "${MIN_RECONFIGS_WALKING}" 800 600 \
      "${min_psnr_avg_strict}" "${min_psnr_min_strict}" 4 4 1 1
    case_index=$((case_index + 1))
    run_case "bandwidth_cliff_recover_${content}_run${run}" bandwidth_cliff_recover \
      "$((BASE_PORT + case_index * 100))" "${content}" "${run}" \
      100 100 100 200000 8 "${MIN_RECONFIGS_BANDWIDTH}" "${max_gap_bandwidth}" 300 \
      "${min_psnr_avg_strict}" "${min_psnr_min_strict}" 4 4 1 1
    case_index=$((case_index + 1))
    run_case "jitter_loss_recover_${content}_run${run}" jitter_loss_recover \
      "$((BASE_PORT + case_index * 100))" "${content}" "${run}" \
      100 120 120 500000 15 "${MIN_RECONFIGS_JITTER}" 500 "${max_completion_gap_jitter}" \
      "${min_psnr_avg_jitter}" "${min_psnr_min_jitter}" 3 4 1 1
    case_index=$((case_index + 1))
  done
done

python3 - "${LOG_DIR}/metrics.jsonl" "${LOG_DIR}/summary.json" <<'PY'
import json
import sys
from pathlib import Path

rows = [
    json.loads(line)
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
failures = [
    {"case": row["case"], "failures": row["validation_failures"]}
    for row in rows
    if row["validation_failures"]
]
summary = {
    "cases": len(rows),
    "contents": sorted({row["content"] for row in rows}),
    "runs": sorted({row["run"] for row in rows}),
    "network_seeds": sorted({row.get("network_seed", row["run"]) for row in rows}),
    "validation_failures": failures,
    "all_passed": not failures,
    "min_sender_target_bps": min(row["sender"]["adapt_target_min"] for row in rows),
    "max_sender_target_last_bps": max(row["sender"]["adapt_target_last"] for row in rows),
    "min_sender_fps": min(row["sender"]["adapt_fps_min"] for row in rows),
    "max_sender_fps_last": max(row["sender"]["adapt_fps_last"] for row in rows),
    "decode_errors": sum(row["receiver"]["errors"] for row in rows),
    "completed_frames": sum(row["receiver"]["completed"] for row in rows),
    "decoded_frames": sum(row["receiver"]["decoded"] for row in rows),
    "max_frame_gap_ms": max(row["receiver"]["gap"] for row in rows),
    "max_completion_gap_ms": max(row["receiver"].get("completion_gap", 0) for row in rows),
    "psnr_avg_min": min(row["receiver"]["psnr_avg"] for row in rows),
    "psnr_min_min": min(row["receiver"]["psnr_min"] for row in rows),
    "rate_caps": sum(row["sender"]["rate_caps"] for row in rows),
    "nack_sent": sum(row["receiver"]["nack"] for row in rows),
    "retransmitted": sum(row["server"]["retransmitted"] for row in rows),
}
Path(sys.argv[2]).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
print(json.dumps(summary, indent=2, sort_keys=True))
if failures:
    raise SystemExit(1)
PY
