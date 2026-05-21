#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
BUILD_DIR="${BUILD_DIR:-${SDK_ROOT}/build}"
BASE_PORT="${BASE_PORT:-47000}"
SENDER_PORT="${SENDER_PORT:-${BASE_PORT}}"
SERVER_PORT="${SERVER_PORT:-$((BASE_PORT + 1))}"
RECEIVER_PORT="${RECEIVER_PORT:-$((BASE_PORT + 2))}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_udp_long_stream_smoke}"
WIDTH="${WIDTH:-320}"
HEIGHT="${HEIGHT:-180}"
FRAMES="${FRAMES:-90}"
EXPECT_FRAMES="${EXPECT_FRAMES:-$((FRAMES * 2 / 3))}"
BITRATE="${BITRATE:-1200000}"
CONTENT="${CONTENT:-motion}"
DROP_EVERY="${DROP_EVERY:-0}"
DELAY_MS="${DELAY_MS:-0}"
JITTER_MS="${JITTER_MS:-20}"
JITTER_EVERY_N="${JITTER_EVERY_N:-17}"
PROFILE="${PROFILE:-none}"
NETWORK_SEED="${NETWORK_SEED:-0}"

mkdir -p "${LOG_DIR}"

cmake --build "${BUILD_DIR}" --target \
  udp_long_sender_demo \
  udp_long_server_demo \
  udp_long_receiver_demo \
  -j"$(nproc)" >/dev/null

"${BUILD_DIR}/udp_long_receiver_demo" \
  "${RECEIVER_PORT}" 127.0.0.1 "${SERVER_PORT}" \
  "--width=${WIDTH}" \
  "--height=${HEIGHT}" \
  "--content=${CONTENT}" \
  "--expect-frames=${EXPECT_FRAMES}" \
  >"${LOG_DIR}/receiver.log" 2>&1 &
receiver_pid=$!

"${BUILD_DIR}/udp_long_server_demo" \
  "${SERVER_PORT}" 127.0.0.1 "${RECEIVER_PORT}" \
  "--drop-every=${DROP_EVERY}" \
  "--delay-ms=${DELAY_MS}" \
  "--jitter-ms=${JITTER_MS}" \
  "--jitter-every-n=${JITTER_EVERY_N}" \
  "--network-seed=${NETWORK_SEED}" \
  "--profile=${PROFILE}" \
  >"${LOG_DIR}/server.log" 2>&1 &
server_pid=$!

cleanup() {
  kill "${receiver_pid}" "${server_pid}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 0.2

set +e
"${BUILD_DIR}/udp_long_sender_demo" \
  "${SENDER_PORT}" 127.0.0.1 "${SERVER_PORT}" \
  "--frames=${FRAMES}" \
  "--width=${WIDTH}" \
  "--height=${HEIGHT}" \
  "--bitrate=${BITRATE}" \
  "--content=${CONTENT}" \
  >"${LOG_DIR}/sender.log" 2>&1
sender_rc=$?

wait "${server_pid}"
server_rc=$?
wait "${receiver_pid}"
receiver_rc=$?
set -e
trap - EXIT

cat "${LOG_DIR}/sender.log"
cat "${LOG_DIR}/server.log"
cat "${LOG_DIR}/receiver.log"

if [[ "${sender_rc}" -ne 0 || "${server_rc}" -ne 0 || "${receiver_rc}" -ne 0 ]]; then
  echo "udp long stream smoke failed sender=${sender_rc} server=${server_rc} receiver=${receiver_rc}" >&2
  exit 1
fi

python3 - "${LOG_DIR}/sender.log" "${LOG_DIR}/server.log" \
  "${LOG_DIR}/receiver.log" "${LOG_DIR}/summary.json" <<'PY'
import json
import re
import sys
from pathlib import Path

sender_text = Path(sys.argv[1]).read_text(encoding="utf-8")
server_text = Path(sys.argv[2]).read_text(encoding="utf-8")
receiver_text = Path(sys.argv[3]).read_text(encoding="utf-8")
summary_path = Path(sys.argv[4])

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
    r"applied_fps=(?P<applied_fps>\d+)",
    sender_text,
)
server_match = re.search(
    r"udp_long_server rtp_in=(?P<rtp_in>\d+) forwarded=(?P<forwarded>\d+) "
    r"dropped=(?P<dropped>\d+) retransmitted=(?P<retransmitted>\d+) "
    r"twcc_sent=(?P<twcc_sent>\d+) rr_sent=(?P<rr_sent>\d+) "
    r"quality_reports=(?P<quality_reports>\d+) rate_caps=(?P<rate_caps>\d+) "
    r"profile=(?P<profile>[A-Za-z0-9_]+) "
    r"(?:network_seed=(?P<network_seed>\d+) )?"
    r"phase_changes=(?P<phase_changes>\d+) "
    r"phase_packets=(?P<phase_packets>\d+) "
    r"impaired_packets=(?P<impaired_packets>\d+) "
    r"min_cap_bps=(?P<min_cap_bps>\d+) "
    r"max_limited_cap_bps=(?P<max_limited_cap_bps>\d+) "
    r"last_cap_bps=(?P<last_cap_bps>\d+)",
    server_text,
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
    r"nack_sent=(?P<nack>\d+) downlink_reports=(?P<downlink_reports>\d+)",
    receiver_text,
)
if not sender_match:
    raise SystemExit("missing sender summary line")
if not server_match:
    raise SystemExit("missing server summary line")
if not receiver_match:
    raise SystemExit("missing receiver summary line")

def parse(match):
    parsed = {
        key: (
            value
            if key == "profile"
            else float(value)
            if key.startswith("psnr")
            else int(value)
        )
        for key, value in match.groupdict().items()
        if value is not None
    }
    return parsed

summary = {
    "sender": parse(sender_match),
    "server": parse(server_match),
    "receiver": parse(receiver_match),
}
if summary["sender"]["twcc"] <= 0 or summary["sender"]["rr"] <= 0:
    raise SystemExit("sender did not receive TWCC/RR feedback")
if summary["server"]["twcc_sent"] <= 0 or summary["server"]["rr_sent"] <= 0:
    raise SystemExit("server did not generate TWCC/RR feedback")
if summary["server"]["quality_reports"] <= 0:
    raise SystemExit("server did not receive receiver downlink quality reports")
if summary["receiver"]["downlink_reports"] <= 0:
    raise SystemExit("receiver did not send downlink quality reports")
if summary["receiver"]["completed"] > summary["sender"]["frames"]:
    raise SystemExit("receiver emitted duplicate completed frames")
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
print(
    "udp long stream smoke passed frames={completed} decoded={decoded} "
    "psnr_avg={psnr_avg:.3f} max_gap_ms={gap} completion_gap_ms={completion_gap} twcc={twcc} rr={rr} "
    "rate_caps={rate_caps}".format(
        completed=summary["receiver"]["completed"],
        decoded=summary["receiver"]["decoded"],
        psnr_avg=summary["receiver"]["psnr_avg"],
        gap=summary["receiver"]["gap"],
        completion_gap=summary["receiver"].get("completion_gap", 0),
        twcc=summary["sender"]["twcc"],
        rr=summary["sender"]["rr"],
        rate_caps=summary["sender"]["rate_caps"],
    )
)
PY
