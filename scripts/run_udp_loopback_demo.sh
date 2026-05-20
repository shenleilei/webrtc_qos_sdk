#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/root/output}"
BASE_PORT="${BASE_PORT:-41000}"
SENDER_PORT="${SENDER_PORT:-${BASE_PORT}}"
SERVER_PORT="${SERVER_PORT:-$((BASE_PORT + 1))}"
RECEIVER_PORT="${RECEIVER_PORT:-$((BASE_PORT + 2))}"
DROP_RTP_SEQ="${DROP_RTP_SEQ:-2}"
REORDER_RTP_SEQ="${REORDER_RTP_SEQ:-0}"
DELAY_MS="${DELAY_MS:-0}"

"${PREFIX}/demo/udp_receiver_demo" \
  "${RECEIVER_PORT}" 127.0.0.1 "${SERVER_PORT}" \
  > /tmp/webrtc_qos_udp_receiver.out 2>&1 &
receiver_pid=$!

"${PREFIX}/demo/udp_server_demo" \
  "${SERVER_PORT}" 127.0.0.1 "${RECEIVER_PORT}" \
  "--drop-rtp-seq=${DROP_RTP_SEQ}" \
  "--reorder-rtp-seq=${REORDER_RTP_SEQ}" \
  "--delay-ms=${DELAY_MS}" \
  > /tmp/webrtc_qos_udp_server.out 2>&1 &
server_pid=$!

cleanup() {
  kill "${receiver_pid}" "${server_pid}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 0.2

set +e
"${PREFIX}/demo/udp_sender_demo" \
  "${SENDER_PORT}" 127.0.0.1 "${SERVER_PORT}" \
  > /tmp/webrtc_qos_udp_sender.out 2>&1
sender_rc=$?

wait "${server_pid}"
server_rc=$?
wait "${receiver_pid}"
receiver_rc=$?
set -e
trap - EXIT

echo "--- udp_sender_demo ---"
cat /tmp/webrtc_qos_udp_sender.out
echo "--- udp_server_demo ---"
cat /tmp/webrtc_qos_udp_server.out
echo "--- udp_receiver_demo ---"
cat /tmp/webrtc_qos_udp_receiver.out

if [[ "${sender_rc}" -ne 0 || "${server_rc}" -ne 0 || "${receiver_rc}" -ne 0 ]]; then
  exit 1
fi
