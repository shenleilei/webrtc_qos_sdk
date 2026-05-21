#!/usr/bin/env bash
set -euo pipefail

WEBRTC_SRC="${WEBRTC_SRC:-/root/src}"
WEBRTC_OUT="${WEBRTC_OUT:-out/qos_min}"
PREFIX="${PREFIX:-/root/output}"
SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEPOT_TOOLS="${DEPOT_TOOLS:-/root/depot_tools}"
PY311_BIN="${PY311_BIN:-/root/py311bin}"
NINJA_JOBS="${NINJA_JOBS:-2}"
REQUIRE_ALL="${REQUIRE_ALL:-0}"
APPLY_WEBRTC_PATCH="${APPLY_WEBRTC_PATCH:-0}"
WEBRTC_PATCH="${WEBRTC_PATCH:-${SDK_ROOT}/third_party/webrtc_patches/webrtc_qos_sdk.patch}"
LIBATOMIC_DIR="${LIBATOMIC_DIR:-/usr/lib/gcc/x86_64-redhat-linux/10}"
LIBSTDCXX_NONSHARED="${LIBSTDCXX_NONSHARED:-/opt/rh/gcc-toolset-12/root/usr/lib/gcc/x86_64-redhat-linux/12/libstdc++_nonshared.a}"

if [[ ! -d "${WEBRTC_SRC}" ]]; then
  echo "missing WEBRTC_SRC=${WEBRTC_SRC}" >&2
  exit 1
fi

if [[ "${WEBRTC_OUT}" = /* ]]; then
  OUT_DIR="${WEBRTC_OUT}"
else
  OUT_DIR="${WEBRTC_SRC}/${WEBRTC_OUT}"
fi

if command -v llvm-ar >/dev/null 2>&1; then
  LLVM_AR="$(command -v llvm-ar)"
elif [[ -x "${WEBRTC_SRC}/third_party/llvm-build/Release+Asserts/bin/llvm-ar" ]]; then
  LLVM_AR="${WEBRTC_SRC}/third_party/llvm-build/Release+Asserts/bin/llvm-ar"
else
  LLVM_AR="ar"
fi

export PATH="${PY311_BIN}:${DEPOT_TOOLS}:${PATH}"
export DEPOT_TOOLS_UPDATE=0

GN_ARGS='is_debug=false use_sysroot=false use_lld=false use_custom_libcxx=false use_custom_libcxx_for_host=false use_safe_libstdcxx=false use_llvm_libatomic=false rtc_include_tests=false rtc_build_examples=false rtc_build_tools=false rtc_enable_protobuf=false rtc_use_perfetto=false rtc_disable_trace_events=true rtc_rust=false enable_rust=false enable_rust_cxx=false enable_chromium_prelude=false rtc_enable_grpc=false'

cd "${WEBRTC_SRC}"
WEBRTC_COMMIT="$(git rev-parse HEAD)"
echo "WEBRTC_SRC=${WEBRTC_SRC}"
echo "WEBRTC_COMMIT=${WEBRTC_COMMIT}"
echo "WEBRTC_OUT=${OUT_DIR}"

if [[ ! -f "${WEBRTC_PATCH}" ]]; then
  echo "missing WebRTC SDK QoS patch: ${WEBRTC_PATCH}" >&2
  exit 1
fi

if ! git apply --check "${WEBRTC_PATCH}" >/dev/null 2>&1; then
  if [[ ! -f "${WEBRTC_SRC}/sdk_qos/BUILD.gn" ]]; then
    echo "WebRTC SDK QoS patch is not applied and cannot be applied cleanly" >&2
    echo "set APPLY_WEBRTC_PATCH=1 on a compatible clean WebRTC checkout" >&2
    exit 1
  fi
else
  if [[ "${APPLY_WEBRTC_PATCH}" == "1" ]]; then
    git apply "${WEBRTC_PATCH}"
  else
    echo "WebRTC SDK QoS patch is not applied" >&2
    echo "rerun with APPLY_WEBRTC_PATCH=1 to modify WEBRTC_SRC explicitly" >&2
    exit 1
  fi
fi

gn gen "${OUT_DIR}" --args="${GN_ARGS}"

if [[ -d "${LIBATOMIC_DIR}" ]]; then
  export LIBRARY_PATH="${LIBATOMIC_DIR}${LIBRARY_PATH:+:${LIBRARY_PATH}}"
fi

ninja -C "${OUT_DIR}" \
  sdk_qos \
  sdk_qos:webrtc_qos_googcc_adapter_complete \
  sdk_qos:webrtc_qos_h264_rtp_adapter_complete \
  sdk_qos:webrtc_qos_h264_rtp_adapter_smoke \
  sdk_qos:webrtc_qos_nack_requester_adapter_complete \
  sdk_qos:webrtc_qos_nack_requester_adapter_smoke \
  sdk_qos:webrtc_qos_pacing_adapter_complete \
  sdk_qos:webrtc_qos_pacing_adapter_smoke \
  sdk_qos:webrtc_qos_rtp_packet_adapter_complete \
  sdk_qos:webrtc_qos_rtp_packet_adapter_smoke \
  sdk_qos:webrtc_qos_rtcp_adapter_complete \
  sdk_qos:webrtc_qos_rtcp_adapter_smoke \
  sdk_qos:webrtc_qos_video_jitter_adapter_complete \
  sdk_qos:webrtc_qos_video_jitter_smoke \
  -j"${NINJA_JOBS}"

mkdir -p "${PREFIX}/lib" "${PREFIX}/include/webrtc_qos" "${PREFIX}/demo"

declare -A REQUIRED_ARCHIVES=(
  [webrtc_googcc]="${OUT_DIR}/obj/sdk_qos/libwebrtc_qos_googcc_adapter_complete.a"
  [webrtc_nack_requester]="${OUT_DIR}/obj/sdk_qos/libwebrtc_qos_nack_requester_adapter_complete.a"
  [webrtc_pacing]="${OUT_DIR}/obj/sdk_qos/libwebrtc_qos_pacing_adapter_complete.a"
  [webrtc_rtp_rtcp]="${OUT_DIR}/obj/sdk_qos/libwebrtc_qos_rtcp_adapter_complete.a"
  [webrtc_video_jitter]="${OUT_DIR}/obj/sdk_qos/libwebrtc_qos_video_jitter_adapter_complete.a"
)

declare -A OUTPUT_ARCHIVES=(
  [webrtc_googcc]="${PREFIX}/lib/libwebrtc_qos_webrtc_googcc.a"
  [webrtc_nack_requester]="${PREFIX}/lib/libwebrtc_qos_webrtc_nack_requester.a"
  [webrtc_pacing]="${PREFIX}/lib/libwebrtc_qos_webrtc_pacing.a"
  [webrtc_rtp_rtcp]="${PREFIX}/lib/libwebrtc_qos_webrtc_rtp_rtcp.a"
  [webrtc_video_jitter]="${PREFIX}/lib/libwebrtc_qos_webrtc_video_jitter.a"
)

for module in "${!REQUIRED_ARCHIVES[@]}"; do
  if [[ ! -f "${REQUIRED_ARCHIVES[${module}]}" ]]; then
    echo "missing built archive for ${module}: ${REQUIRED_ARCHIVES[${module}]}" >&2
    exit 1
  fi
  cp "${REQUIRED_ARCHIVES[${module}]}" "${OUTPUT_ARCHIVES[${module}]}"
done

H264_RTP_ARCHIVE="${OUT_DIR}/obj/sdk_qos/libwebrtc_qos_h264_rtp_adapter_complete.a"
if [[ ! -f "${H264_RTP_ARCHIVE}" ]]; then
  echo "missing built archive for webrtc_h264_rtp: ${H264_RTP_ARCHIVE}" >&2
  exit 1
fi
RTP_PACKET_ARCHIVE="${OUT_DIR}/obj/sdk_qos/libwebrtc_qos_rtp_packet_adapter_complete.a"
if [[ ! -f "${RTP_PACKET_ARCHIVE}" ]]; then
  echo "missing built archive for webrtc_rtp_packet: ${RTP_PACKET_ARCHIVE}" >&2
  exit 1
fi
TMP_H264_RTP_DIR="$(mktemp -d)"
(
  cd "${TMP_H264_RTP_DIR}"
  "${LLVM_AR}" x "${H264_RTP_ARCHIVE}"
  "${LLVM_AR}" x "${RTP_PACKET_ARCHIVE}"
  "${LLVM_AR}" q "${OUTPUT_ARCHIVES[webrtc_rtp_rtcp]}" ./*.o
)
rm -rf "${TMP_H264_RTP_DIR}"

if [[ -f "${LIBSTDCXX_NONSHARED}" ]]; then
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR}"' EXIT
  (
    cd "${TMP_DIR}"
    "${LLVM_AR}" x "${LIBSTDCXX_NONSHARED}" functexcept80.o
    if [[ -f functexcept80.o ]]; then
      for archive in "${OUTPUT_ARCHIVES[@]}"; do
        "${LLVM_AR}" q "${archive}" functexcept80.o
      done
    fi
  )
fi

for archive in "${OUTPUT_ARCHIVES[@]}"; do
  "${LLVM_AR}" s "${archive}"
  file "${archive}"
done

cp "${WEBRTC_SRC}/sdk_qos/googcc_adapter.h" \
  "${PREFIX}/include/webrtc_qos/googcc_adapter.h"
cp "${WEBRTC_SRC}/sdk_qos/h264_rtp_adapter.h" \
  "${PREFIX}/include/webrtc_qos/h264_rtp_adapter.h"
cp "${WEBRTC_SRC}/sdk_qos/nack_requester_adapter.h" \
  "${PREFIX}/include/webrtc_qos/nack_requester_adapter.h"
cp "${WEBRTC_SRC}/sdk_qos/pacing_adapter.h" \
  "${PREFIX}/include/webrtc_qos/pacing_adapter.h"
cp "${WEBRTC_SRC}/sdk_qos/rtcp_adapter.h" \
  "${PREFIX}/include/webrtc_qos/rtcp_adapter.h"
cp "${WEBRTC_SRC}/sdk_qos/rtp_packet_adapter.h" \
  "${PREFIX}/include/webrtc_qos/rtp_packet_adapter.h"
cp "${WEBRTC_SRC}/sdk_qos/video_jitter_adapter.h" \
  "${PREFIX}/include/webrtc_qos/video_jitter_adapter.h"
cp "${OUT_DIR}/webrtc_qos_googcc_smoke" \
  "${PREFIX}/demo/webrtc_qos_googcc_smoke"
cp "${OUT_DIR}/webrtc_qos_h264_rtp_adapter_smoke" \
  "${PREFIX}/demo/webrtc_qos_h264_rtp_adapter_smoke"
cp "${OUT_DIR}/webrtc_qos_nack_requester_adapter_smoke" \
  "${PREFIX}/demo/webrtc_qos_nack_requester_adapter_smoke"
cp "${OUT_DIR}/webrtc_qos_pacing_adapter_smoke" \
  "${PREFIX}/demo/webrtc_qos_pacing_adapter_smoke"
cp "${OUT_DIR}/webrtc_qos_rtp_packet_adapter_smoke" \
  "${PREFIX}/demo/webrtc_qos_rtp_packet_adapter_smoke"
cp "${OUT_DIR}/webrtc_qos_rtcp_adapter_smoke" \
  "${PREFIX}/demo/webrtc_qos_rtcp_adapter_smoke"
cp "${OUT_DIR}/webrtc_qos_video_jitter_smoke" \
  "${PREFIX}/demo/webrtc_qos_video_jitter_smoke"

"${PREFIX}/demo/webrtc_qos_googcc_smoke"
"${PREFIX}/demo/webrtc_qos_h264_rtp_adapter_smoke"
"${PREFIX}/demo/webrtc_qos_nack_requester_adapter_smoke"
"${PREFIX}/demo/webrtc_qos_pacing_adapter_smoke"
"${PREFIX}/demo/webrtc_qos_rtp_packet_adapter_smoke"
"${PREFIX}/demo/webrtc_qos_rtcp_adapter_smoke"
"${PREFIX}/demo/webrtc_qos_video_jitter_smoke"

echo "packaged available WebRTC modules to ${PREFIX}"
