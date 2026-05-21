#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
BUILD_DIR="${BUILD_DIR:-${SDK_ROOT}/build}"
BASE_PORT="${BASE_PORT:-49000}"
SENDER_PORT="${SENDER_PORT:-${BASE_PORT}}"
RECEIVER_PORT="${RECEIVER_PORT:-$((BASE_PORT + 1))}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_udp_direct_long_stream_smoke}"
WIDTH="${WIDTH:-320}"
HEIGHT="${HEIGHT:-180}"
FRAMES="${FRAMES:-90}"
EXPECT_FRAMES="${EXPECT_FRAMES:-$((FRAMES * 2 / 3))}"
BITRATE="${BITRATE:-1200000}"
CONTENT="${CONTENT:-motion}"
DROP_EVERY="${DROP_EVERY:-17}"
RATE_CAP_BPS="${RATE_CAP_BPS:-500000}"
RATE_CAP_AT_PACKET="${RATE_CAP_AT_PACKET:-20}"
DELAY_MS="${DELAY_MS:-0}"
JITTER_MS="${JITTER_MS:-0}"
JITTER_EVERY_N="${JITTER_EVERY_N:-0}"
NETWORK_SEED="${NETWORK_SEED:-0}"
PROFILE="${PROFILE:-none}"
MAX_FRAME_GAP_MS="${MAX_FRAME_GAP_MS:-1000}"
MIN_PSNR_AVG="${MIN_PSNR_AVG:-25}"

mkdir -p "${LOG_DIR}"

cmake --build "${BUILD_DIR}" --target \
  udp_long_sender_demo \
  udp_long_receiver_demo \
  -j"$(nproc)" >/dev/null

"${BUILD_DIR}/udp_long_receiver_demo" \
  "${RECEIVER_PORT}" 127.0.0.1 "${SENDER_PORT}" \
  "--width=${WIDTH}" \
  "--height=${HEIGHT}" \
  "--content=${CONTENT}" \
  "--expect-frames=${EXPECT_FRAMES}" \
  --direct-feedback \
  "--drop-every=${DROP_EVERY}" \
  "--delay-ms=${DELAY_MS}" \
  "--jitter-ms=${JITTER_MS}" \
  "--jitter-every-n=${JITTER_EVERY_N}" \
  "--network-seed=${NETWORK_SEED}" \
  "--profile=${PROFILE}" \
  "--max-frame-gap-ms=${MAX_FRAME_GAP_MS}" \
  "--min-psnr-avg=${MIN_PSNR_AVG}" \
  "--rate-cap-bps=${RATE_CAP_BPS}" \
  "--rate-cap-at-packet=${RATE_CAP_AT_PACKET}" \
  >"${LOG_DIR}/receiver.log" 2>&1 &
receiver_pid=$!

cleanup() {
  kill "${receiver_pid}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 0.2

set +e
"${BUILD_DIR}/udp_long_sender_demo" \
  "${SENDER_PORT}" 127.0.0.1 "${RECEIVER_PORT}" \
  "--frames=${FRAMES}" \
  "--width=${WIDTH}" \
  "--height=${HEIGHT}" \
  "--bitrate=${BITRATE}" \
  "--content=${CONTENT}" \
  >"${LOG_DIR}/sender.log" 2>&1
sender_rc=$?

wait "${receiver_pid}"
receiver_rc=$?
set -e
trap - EXIT

cat "${LOG_DIR}/sender.log"
cat "${LOG_DIR}/receiver.log"

if [[ "${sender_rc}" -ne 0 || "${receiver_rc}" -ne 0 ]]; then
  echo "udp direct long stream smoke failed sender=${sender_rc} receiver=${receiver_rc}" >&2
  exit 1
fi

python3 - "${LOG_DIR}/sender.log" "${LOG_DIR}/receiver.log" \
  "${LOG_DIR}/summary.json" "${PROFILE}" "${DROP_EVERY}" <<'PY'
import json
import re
import sys
from pathlib import Path

sender_text = Path(sys.argv[1]).read_text(encoding="utf-8")
receiver_text = Path(sys.argv[2]).read_text(encoding="utf-8")
summary_path = Path(sys.argv[3])
profile = sys.argv[4]
drop_every = int(sys.argv[5])

sender_match = re.search(
    r"udp_long_sender frames=(?P<frames>\d+) "
    r"encoded_frames=(?P<encoded_frames>\d+) sent_packets=(?P<sent>\d+) "
    r"sent_bytes=(?P<bytes>\d+) pacer_drops=(?P<pacer_drops>\d+) "
    r"(?:forced_keyframes=(?P<forced_keyframes>\d+) )?"
    r"twcc_feedback=(?P<twcc>\d+) rr=(?P<rr>\d+) "
    r"rate_caps=(?P<rate_caps>\d+) final_target_bps=(?P<target>\d+) "
    r"pacing_bps=(?P<pacing>\d+) rtt_ms=(?P<rtt>\d+) "
    r"adapt_target_min=(?P<adapt_target_min>\d+) "
    r"adapt_target_max=(?P<adapt_target_max>\d+) "
    r"adapt_target_last=(?P<adapt_target_last>\d+) "
    r"adapt_fps_min=(?P<adapt_fps_min>\d+) "
    r"adapt_fps_max=(?P<adapt_fps_max>\d+) "
    r"adapt_fps_last=(?P<adapt_fps_last>\d+) "
    r"encoder_reconfigs=(?P<encoder_reconfigs>\d+) "
    r"applied_bitrate_bps=(?P<applied_bitrate_bps>\d+) "
    r"applied_fps=(?P<applied_fps>\d+) "
    r"nack_feedback=(?P<nack_feedback>\d+) "
    r"retransmitted=(?P<retransmitted>\d+)",
    sender_text,
)
receiver_match = re.search(
    r"udp_long_receiver rtp=(?P<rtp>\d+) completed_frames=(?P<completed>\d+) "
    r"decoded_frames=(?P<decoded>\d+) decode_errors=(?P<errors>\d+) "
    r"quality_samples=(?P<quality>\d+) psnr_avg=(?P<psnr_avg>[0-9.]+) "
    r"psnr_min=(?P<psnr_min>[0-9.]+) "
    r"(?:max_completion_gap_ms=(?P<completion_gap>\d+) )?"
    r"max_frame_gap_ms=(?P<gap>\d+) "
    r"(?:max_frame_gap_from_ms=(?P<gap_from>\d+) "
    r"max_frame_gap_to_ms=(?P<gap_to>\d+) )?"
    r"nack_sent=(?P<nack>\d+) downlink_reports=(?P<downlink_reports>\d+) "
    r"direct_twcc_sent=(?P<direct_twcc>\d+) "
    r"direct_rr_sent=(?P<direct_rr>\d+) "
    r"direct_rate_caps=(?P<direct_rate_caps>\d+) "
    r"direct_dropped=(?P<direct_dropped>\d+) "
    r"direct_delayed=(?P<direct_delayed>\d+) "
    r"direct_jittered=(?P<direct_jittered>\d+) "
    r"direct_released=(?P<direct_released>\d+) "
    r"direct_profile=(?P<direct_profile>[A-Za-z0-9_]+) "
    r"direct_network_seed=(?P<direct_network_seed>\d+) "
    r"direct_phase_changes=(?P<direct_phase_changes>\d+) "
    r"direct_phase_packets=(?P<direct_phase_packets>\d+) "
    r"direct_impaired_packets=(?P<direct_impaired_packets>\d+) "
    r"direct_min_cap_bps=(?P<direct_min_cap_bps>\d+) "
    r"direct_max_limited_cap_bps=(?P<direct_max_limited_cap_bps>\d+) "
    r"direct_last_cap_bps=(?P<direct_last_cap_bps>\d+)",
    receiver_text,
)
if not sender_match:
    raise SystemExit("missing sender summary line")
if not receiver_match:
    raise SystemExit("missing receiver summary line")

def parse(match):
    out = {}
    for key, value in match.groupdict().items():
        if value is None:
            continue
        out[key] = value if key == "direct_profile" else (
            float(value) if key.startswith("psnr") else int(value)
        )
    return out

summary = {
    "sender": parse(sender_match),
    "receiver": parse(receiver_match),
}
sender = summary["sender"]
receiver = summary["receiver"]
failures = []
if sender["twcc"] <= 0:
    failures.append("sender_twcc_missing")
if sender["rr"] <= 0:
    failures.append("sender_rr_missing")
if sender["rate_caps"] <= 0:
    failures.append("sender_rate_cap_missing")
if receiver["direct_twcc"] <= 0 or receiver["direct_rr"] <= 0:
    failures.append("receiver_direct_feedback_missing")
if receiver["direct_rate_caps"] <= 0:
    failures.append("receiver_direct_rate_cap_missing")
if (profile == "none" and drop_every > 0) and receiver["direct_dropped"] <= 0:
    failures.append("receiver_direct_drop_missing")
if receiver["nack"] <= 0 or sender["nack_feedback"] <= 0:
    failures.append("nack_feedback_missing")
if sender["retransmitted"] <= 0:
    failures.append("sender_retransmission_missing")
if receiver["errors"] != 0:
    failures.append("decode_errors")
if receiver["completed"] > sender["frames"]:
    failures.append("duplicate_completed_frames")
if receiver["psnr_avg"] < 25.0:
    failures.append("psnr_avg_low")
if receiver.get("completion_gap", 0) > 1000:
    failures.append("completion_gap_high")
if failures:
    summary["validation_failures"] = failures
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    raise SystemExit("udp direct validation failed: " + ", ".join(failures))
summary["validation_failures"] = []
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
print(
    "udp direct long stream smoke passed frames={completed} decoded={decoded} "
    "psnr_avg={psnr_avg:.3f} completion_gap_ms={completion_gap} "
    "twcc={twcc} rr={rr} rate_caps={rate_caps} nack={nack} rtx={rtx}".format(
        completed=receiver["completed"],
        decoded=receiver["decoded"],
        psnr_avg=receiver["psnr_avg"],
        completion_gap=receiver.get("completion_gap", 0),
        twcc=sender["twcc"],
        rr=sender["rr"],
        rate_caps=sender["rate_caps"],
        nack=receiver["nack"],
        rtx=sender["retransmitted"],
    )
)
PY
