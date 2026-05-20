#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-/root/output}"
RUNS="${RUNS:-3}"
BASE_PORT_START="${BASE_PORT_START:-42000}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_udp_netem_matrix}"
BUILD_DEMOS="${BUILD_DEMOS:-1}"

mkdir -p "${LOG_DIR}"

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

echo "udp netem matrix passed runs=${RUNS} scenarios=${#SCENARIOS[@]} logs=${LOG_DIR}"
