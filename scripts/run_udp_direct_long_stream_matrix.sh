#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_udp_direct_long_stream_matrix}"
BASE_PORT="${BASE_PORT:-51000}"
FRAMES="${FRAMES:-300}"
WIDTH="${WIDTH:-320}"
HEIGHT="${HEIGHT:-180}"
BITRATE="${BITRATE:-1200000}"
MATRIX_CONTENTS="${MATRIX_CONTENTS:-motion}"
MATRIX_RUNS="${MATRIX_RUNS:-1}"
MIN_RECONFIGS_WALKING="${MIN_RECONFIGS_WALKING:-4}"
MIN_RECONFIGS_BANDWIDTH="${MIN_RECONFIGS_BANDWIDTH:-4}"
MIN_RECONFIGS_JITTER="${MIN_RECONFIGS_JITTER:-3}"

rm -rf "${LOG_DIR}"
mkdir -p "${LOG_DIR}"
: >"${LOG_DIR}/metrics.jsonl"

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

  echo "running udp direct case ${name} content=${content} run=${run}"
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
  DROP_EVERY=0 \
  DELAY_MS=0 \
  JITTER_MS=0 \
  JITTER_EVERY_N=0 \
  RATE_CAP_BPS=500000 \
  RATE_CAP_AT_PACKET=0 \
  MAX_FRAME_GAP_MS=5000 \
  MAX_COMPLETION_GAP_MS="${max_completion_gap_ms}" \
  MIN_PSNR_AVG=1 \
    bash "${SDK_ROOT}/scripts/run_udp_direct_long_stream_smoke.sh" \
      >"${case_dir}.stdout" 2>&1

  python3 - "${case_dir}/summary.json" "${LOG_DIR}/metrics.jsonl" \
    "${name}" "${profile}" "${content}" "${run}" "${network_seed}" \
    "${min_completed}" "${min_decoded}" "${min_target_max}" "${min_fps_max}" \
    "${min_reconfigs}" "${max_gap_ms}" "${max_completion_gap_ms}" \
    "${min_psnr_avg}" "${min_psnr_min}" "${min_phase_changes}" \
    "${min_rate_caps}" "${min_nack}" "${min_retransmitted}" <<'PY'
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
check(sender["retransmitted"] >= thresholds["min_retransmitted"],
      "sender_retransmitted_low")
check(sender.get("max_encode_gap_ms", 0) <= 250, "sender_encode_gap_high")
check(sender.get("enqueue_dropped_aus", 0) == 0, "enqueue_dropped_aus")
check(receiver["direct_profile"] == profile, "direct_profile_mismatch")
check(receiver["direct_network_seed"] == network_seed,
      "direct_network_seed_mismatch")
check(receiver["direct_phase_changes"] >= thresholds["min_phase_changes"],
      "direct_phase_changes_low")
check(receiver["direct_impaired_packets"] > 0,
      "direct_impaired_packets_missing")
check(receiver["direct_last_cap_bps"] == 4294967295,
      "direct_cap_did_not_recover")
check(receiver["direct_rate_caps"] >= thresholds["min_rate_caps"],
      "direct_rate_caps_low")
check(receiver["direct_twcc"] > 0, "direct_twcc_missing")
check(receiver["direct_rr"] > 0, "direct_rr_missing")
check(receiver["completed"] >= thresholds["min_completed"],
      "completed_frames_low")
check(receiver["decoded"] >= thresholds["min_decoded"], "decoded_frames_low")
check(receiver["errors"] == 0, "decode_errors")
check(receiver["quality"] >= thresholds["min_decoded"], "quality_samples_low")
check(receiver["psnr_avg"] >= thresholds["min_psnr_avg"], "psnr_avg_low")
check(receiver["psnr_min"] >= thresholds["min_psnr_min"], "psnr_min_low")
check(receiver["gap"] <= thresholds["max_gap_ms"], "max_frame_gap_high")
check(receiver.get("completion_gap", 0) <= thresholds["max_completion_gap_ms"],
      "max_completion_gap_high")
check(receiver["nack"] >= thresholds["min_nack"], "nack_low")
check(receiver["downlink_reports"] > 0, "downlink_reports_missing")
if profile == "walking_dead_zone":
    check(receiver["direct_dropped"] > 0, "walking_drop_missing")
    check(receiver["direct_delayed"] > 0 or receiver["direct_jittered"] > 0,
          "walking_delay_or_jitter_missing")
    check(receiver.get("pli_sent", 0) > 0, "walking_pli_missing")
    check(sender.get("pli_feedback", 0) > 0, "walking_sender_pli_missing")
if profile == "bandwidth_cliff_recover":
    check(receiver["direct_delayed"] > 0 or receiver["direct_jittered"] > 0,
          "bandwidth_delay_or_jitter_missing")
if profile == "jitter_loss_recover":
    check(receiver["direct_jittered"] > 0, "jitter_missing")
    check(receiver["direct_dropped"] > 0, "jitter_loss_missing")

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
    "gap={gap} completion_gap={completion_gap} psnr_avg={psnr_avg:.2f}".format(
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
        completion_gap=receiver.get("completion_gap", 0),
        psnr_avg=receiver["psnr_avg"],
    )
)
PY
}

case_index=0
for content in ${MATRIX_CONTENTS}; do
  min_psnr_avg_strict=30.0
  min_psnr_min_strict=16.0
  min_psnr_avg_jitter=28.0
  min_psnr_min_jitter=15.0
  for run in $(seq 1 "${MATRIX_RUNS}"); do
    run_case "walking_dead_zone_${content}_run${run}" walking_dead_zone \
      "$((BASE_PORT + case_index * 100))" "${content}" "${run}" \
      160 160 160 100000 8 "${MIN_RECONFIGS_WALKING}" 2500 1200 \
      "${min_psnr_avg_strict}" "${min_psnr_min_strict}" 4 4 1 1
    case_index=$((case_index + 1))
    run_case "bandwidth_cliff_recover_${content}_run${run}" bandwidth_cliff_recover \
      "$((BASE_PORT + case_index * 100))" "${content}" "${run}" \
      160 160 160 200000 8 "${MIN_RECONFIGS_BANDWIDTH}" 1800 750 \
      "${min_psnr_avg_strict}" "${min_psnr_min_strict}" 4 4 0 0
    case_index=$((case_index + 1))
    run_case "jitter_loss_recover_${content}_run${run}" jitter_loss_recover \
      "$((BASE_PORT + case_index * 100))" "${content}" "${run}" \
      200 200 200 500000 15 "${MIN_RECONFIGS_JITTER}" 1400 500 \
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
    "pli_sent": sum(row["receiver"].get("pli_sent", 0) for row in rows),
    "pli_feedback": sum(row["sender"].get("pli_feedback", 0) for row in rows),
    "forced_keyframes": sum(row["sender"].get("forced_keyframes", 0) for row in rows),
    "retransmitted": sum(row["sender"]["retransmitted"] for row in rows),
    "max_encode_gap_ms": max(row["sender"].get("max_encode_gap_ms", 0) for row in rows),
    "pacer_drop_aus": sum(row["sender"].get("pacer_drop_aus", 0) for row in rows),
    "enqueue_dropped_aus": sum(row["sender"].get("enqueue_dropped_aus", 0) for row in rows),
    "source_frame_skips": sum(row["sender"].get("source_frame_skips", 0) for row in rows),
    "direct_dropped": sum(row["receiver"]["direct_dropped"] for row in rows),
    "direct_delayed": sum(row["receiver"]["direct_delayed"] for row in rows),
    "direct_jittered": sum(row["receiver"]["direct_jittered"] for row in rows),
}
Path(sys.argv[2]).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
print(json.dumps(summary, indent=2, sort_keys=True))
if failures:
    raise SystemExit(1)
PY
