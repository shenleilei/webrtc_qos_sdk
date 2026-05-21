#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/root/output}"
REQUIRE_ALL="${REQUIRE_ALL:-1}"

required_archives=(
  "${PREFIX}/lib/libwebrtc_qos_webrtc_googcc.a"
  "${PREFIX}/lib/libwebrtc_qos_webrtc_nack_requester.a"
  "${PREFIX}/lib/libwebrtc_qos_webrtc_pacing.a"
  "${PREFIX}/lib/libwebrtc_qos_webrtc_rtp_rtcp.a"
  "${PREFIX}/lib/libwebrtc_qos_webrtc_video_jitter.a"
)

if [[ "${REQUIRE_ALL}" == "1" ]]; then
  required_archives+=(
    "${PREFIX}/lib/libwebrtc_qos_transport_packet_history.a"
  )
fi

required_headers=(
  "${PREFIX}/include/webrtc_qos/googcc_adapter.h"
  "${PREFIX}/include/webrtc_qos/h264_rtp_adapter.h"
  "${PREFIX}/include/webrtc_qos/nack_requester_adapter.h"
  "${PREFIX}/include/webrtc_qos/pacing_adapter.h"
  "${PREFIX}/include/webrtc_qos/rtcp_adapter.h"
  "${PREFIX}/include/webrtc_qos/rtp_packet_adapter.h"
  "${PREFIX}/include/webrtc_qos/video_jitter_adapter.h"
)

for path in "${required_archives[@]}" "${required_headers[@]}"; do
  if [[ ! -f "${path}" ]]; then
    echo "missing WebRTC module artifact: ${path}" >&2
    exit 1
  fi
done

for archive in "${required_archives[@]}"; do
  if ! file "${archive}" | grep -q 'current ar archive'; then
    echo "not a static archive: ${archive}" >&2
    exit 1
  fi
done

pacing_smoke="${PREFIX}/demo/webrtc_qos_pacing_adapter_smoke"
if [[ ! -x "${pacing_smoke}" ]]; then
  echo "missing executable pacing smoke: ${pacing_smoke}" >&2
  exit 1
fi
pacing_output="$("${pacing_smoke}")"
echo "${pacing_output}"
if ! grep -q "probe_emitted=2" <<<"${pacing_output}"; then
  echo "pacing smoke did not verify probe packet emission" >&2
  exit 1
fi
if ! grep -q "probe_bytes=800" <<<"${pacing_output}"; then
  echo "pacing smoke did not verify probe byte accounting" >&2
  exit 1
fi
if ! grep -q "padding_emitted=" <<<"${pacing_output}"; then
  echo "pacing smoke did not verify padding packet emission" >&2
  exit 1
fi
padding_emitted="$(sed -n 's/.*padding_emitted=\([0-9][0-9]*\).*/\1/p' <<<"${pacing_output}")"
padding_bytes="$(sed -n 's/.*padding_bytes=\([0-9][0-9]*\).*/\1/p' <<<"${pacing_output}")"
if [[ -z "${padding_emitted}" || "${padding_emitted}" -le 0 ]]; then
  echo "pacing smoke did not emit padding packets" >&2
  exit 1
fi
if [[ -z "${padding_bytes}" || "${padding_bytes}" -le 0 ]]; then
  echo "pacing smoke did not account padding bytes" >&2
  exit 1
fi

echo "WebRTC module verification passed prefix=${PREFIX}"
