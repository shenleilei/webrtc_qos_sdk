#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}"
BUILD_DIR="${BUILD_DIR:-/tmp/webrtc_qos_phase5_metrics_build.$$}"
METRICS_DIR="${METRICS_DIR:-/tmp/webrtc_qos_phase5_metrics.$$}"
FRAMES="${FRAMES:-36}"

cleanup() {
  if [[ "${KEEP_WORK_DIR:-0}" != "1" ]]; then
    rm -rf "${BUILD_DIR}" "${METRICS_DIR}"
  fi
}
trap cleanup EXIT

fail() {
  echo "phase5 metrics verification failed: $*" >&2
  exit 1
}

rm -rf "${BUILD_DIR}" "${METRICS_DIR}"
mkdir -p "${METRICS_DIR}"

cmake -S "${SDK_ROOT}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DWEBRTC_QOS_ENABLE_WEBRTC_FACADE=ON \
  -DWEBRTC_QOS_WEBRTC_MODULE_PREFIX="${PREFIX}" >/dev/null
cmake --build "${BUILD_DIR}" \
  --target webrtc_qos_webrtc_first_udp_demo -j2 >/dev/null

demo="${BUILD_DIR}/webrtc_qos_webrtc_first_udp_demo"
if ! output="$("${demo}" selftest "${FRAMES}" \
  --metrics-dir "${METRICS_DIR}" 2>&1)"; then
  echo "${output}" >&2
  fail "UDP selftest with metrics exited with non-zero status"
fi
printf '%s\n' "${output}"
grep -q "udp_selftest .*pass=true" <<<"${output}" ||
  fail "UDP selftest with metrics did not pass"

shopt -s nullglob
push_metrics=("${METRICS_DIR}"/webrtc_qos_udp_metrics.push.*.jsonl)
server_metrics=("${METRICS_DIR}"/webrtc_qos_udp_metrics.server.*.jsonl)
play_metrics=("${METRICS_DIR}"/webrtc_qos_udp_metrics.play.*.jsonl)
(( ${#push_metrics[@]} > 0 )) || fail "missing push metrics file"
(( ${#server_metrics[@]} > 0 )) || fail "missing server metrics file"
(( ${#play_metrics[@]} > 0 )) || fail "missing play metrics file"

python3 - "${METRICS_DIR}" <<'PY'
import json
import pathlib
import sys

metrics_dir = pathlib.Path(sys.argv[1])
required = {
    "ts_us",
    "role",
    "scope",
    "session_id",
    "stream_id",
    "transport_id",
    "source_id",
    "track_id",
    "sender_ssrc",
    "receiver_id",
    "googcc_target_bps",
    "pacing_bps",
    "sender_rate_cap_bps",
    "final_target_bps",
    "adaptation_target_bps",
    "adaptation_max_fps",
    "downlink_fraction_lost_q8",
    "downlink_video_drop_frames",
    "nack_count",
    "pli_count",
    "retransmission_count",
}
records = []
for path in metrics_dir.glob("*.jsonl"):
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            if not line.strip():
                continue
            obj = json.loads(line)
            missing = required - obj.keys()
            if missing:
                raise SystemExit(
                    f"{path}:{line_no}: missing fields: {sorted(missing)}"
                )
            if any(key in obj for key in ("payload", "annexb_bytes", "rtp_bytes")):
                raise SystemExit(f"{path}:{line_no}: media payload-like field found")
            records.append(obj)

if not records:
    raise SystemExit("no metrics records found")

roles = {record["role"] for record in records}
if roles != {"push", "server", "play"}:
    raise SystemExit(f"unexpected roles: {sorted(roles)}")

scopes = {(record["role"], record["scope"]) for record in records}
for expected in [
    ("push", "session"),
    ("push", "track"),
    ("server", "session"),
    ("play", "session"),
    ("play", "track"),
]:
    if expected not in scopes:
        raise SystemExit(f"missing metrics scope: {expected}")

push = [r for r in records if r["role"] == "push"]
push_tracks = [r for r in push if r["scope"] == "track"]
server = [r for r in records if r["role"] == "server"]
play = [r for r in records if r["role"] == "play"]

if min(r["adaptation_target_bps"] for r in push) > 600000:
    raise SystemExit("push metrics did not show weak-network bitrate downshift")
if max(r["adaptation_target_bps"] for r in push) < 1000000:
    raise SystemExit("push metrics did not show bitrate recovery")
if min(r["adaptation_max_fps"] for r in push) > 15:
    raise SystemExit("push metrics did not show FPS downshift")
if max(r["adaptation_max_fps"] for r in push) < 25:
    raise SystemExit("push metrics did not show FPS recovery")
if max(r["downlink_fraction_lost_q8"] for r in server) < 128:
    raise SystemExit("server metrics did not capture downlink loss")
if max(r["retransmission_count"] for r in server) <= 0:
    raise SystemExit("server metrics did not capture retransmission")
if max(r["nack_count"] for r in play) <= 0:
    raise SystemExit("play metrics did not capture NACK")

track_ids = {r["track_id"] for r in push_tracks if r["track_id"] != 0}
if len(track_ids) < 2:
    raise SystemExit(f"expected dual-track push metrics, got {sorted(track_ids)}")

print(
    "validated_metrics_records=%d roles=%s track_ids=%s"
    % (len(records), ",".join(sorted(roles)), ",".join(map(str, sorted(track_ids))))
)
PY

echo "phase5_metrics pass metrics_dir=${METRICS_DIR}"
