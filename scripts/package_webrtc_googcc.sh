#!/usr/bin/env bash
set -euo pipefail

WEBRTC_SRC="${WEBRTC_SRC:-/root/src}"
WEBRTC_OUT="${WEBRTC_OUT:-out/qos_min}"
PREFIX="${PREFIX:-/root/output}"
DEPOT_TOOLS="${DEPOT_TOOLS:-/root/depot_tools}"
PY311_BIN="${PY311_BIN:-/root/py311bin}"
NINJA_JOBS="${NINJA_JOBS:-2}"
LIBATOMIC_DIR="${LIBATOMIC_DIR:-/usr/lib/gcc/x86_64-redhat-linux/10}"
LIBSTDCXX_NONSHARED="${LIBSTDCXX_NONSHARED:-/opt/rh/gcc-toolset-12/root/usr/lib/gcc/x86_64-redhat-linux/12/libstdc++_nonshared.a}"

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

gn gen "${OUT_DIR}" --args="${GN_ARGS}"

if [[ -d "${LIBATOMIC_DIR}" ]]; then
  export LIBRARY_PATH="${LIBATOMIC_DIR}${LIBRARY_PATH:+:${LIBRARY_PATH}}"
fi

ninja -C "${OUT_DIR}" \
  sdk_qos \
  sdk_qos:webrtc_qos_googcc_adapter_complete \
  sdk_qos:webrtc_qos_video_jitter_adapter_complete \
  sdk_qos:webrtc_qos_video_jitter_smoke \
  -j"${NINJA_JOBS}"

GOOGCC_COMPLETE_ARCHIVE="${OUT_DIR}/obj/sdk_qos/libwebrtc_qos_googcc_adapter_complete.a"
GOOGCC_OUTPUT_ARCHIVE="${PREFIX}/lib/libwebrtc_qos_googcc_adapter.a"
VIDEO_JITTER_COMPLETE_ARCHIVE="${OUT_DIR}/obj/sdk_qos/libwebrtc_qos_video_jitter_adapter_complete.a"
VIDEO_JITTER_OUTPUT_ARCHIVE="${PREFIX}/lib/libwebrtc_qos_video_jitter_adapter.a"

mkdir -p "${PREFIX}/lib" "${PREFIX}/include/webrtc_qos" "${PREFIX}/demo"
cp "${GOOGCC_COMPLETE_ARCHIVE}" "${GOOGCC_OUTPUT_ARCHIVE}"
cp "${VIDEO_JITTER_COMPLETE_ARCHIVE}" "${VIDEO_JITTER_OUTPUT_ARCHIVE}"
if [[ -f "${LIBSTDCXX_NONSHARED}" ]]; then
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR}"' EXIT
  (
    cd "${TMP_DIR}"
    "${LLVM_AR}" x "${LIBSTDCXX_NONSHARED}" functexcept80.o
    if [[ -f functexcept80.o ]]; then
      "${LLVM_AR}" q "${GOOGCC_OUTPUT_ARCHIVE}" functexcept80.o
      "${LLVM_AR}" q "${VIDEO_JITTER_OUTPUT_ARCHIVE}" functexcept80.o
    fi
  )
fi
"${LLVM_AR}" s "${GOOGCC_OUTPUT_ARCHIVE}"
"${LLVM_AR}" s "${VIDEO_JITTER_OUTPUT_ARCHIVE}"
cp "${WEBRTC_SRC}/sdk_qos/googcc_adapter.h" \
  "${PREFIX}/include/webrtc_qos/googcc_adapter.h"
cp "${WEBRTC_SRC}/sdk_qos/video_jitter_adapter.h" \
  "${PREFIX}/include/webrtc_qos/video_jitter_adapter.h"
cp "${OUT_DIR}/webrtc_qos_googcc_smoke" \
  "${PREFIX}/demo/webrtc_qos_googcc_smoke"
cp "${OUT_DIR}/webrtc_qos_video_jitter_smoke" \
  "${PREFIX}/demo/webrtc_qos_video_jitter_smoke"

file "${GOOGCC_OUTPUT_ARCHIVE}"
file "${VIDEO_JITTER_OUTPUT_ARCHIVE}"
"${PREFIX}/demo/webrtc_qos_googcc_smoke"
"${PREFIX}/demo/webrtc_qos_video_jitter_smoke"
