#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WEBRTC_PREFIX="${WEBRTC_PREFIX:-${SDK_ROOT}/dist/linux-x86_64}"
CAPTURE_LIBRARY_DIR="${CAPTURE_LIBRARY_DIR:-${SDK_ROOT}/capture_library}"
CAPTURE_LIBRARY_MANIFEST="${CAPTURE_LIBRARY_MANIFEST:-${CAPTURE_LIBRARY_DIR}/manifest.csv}"
WORK_DIR="${WORK_DIR:-/tmp/webrtc_qos_capture_library.$$}"
OUTPUT_DIR="${OUTPUT_DIR:-${SDK_ROOT}/artifacts/webrtc_first_qoe_capture_library_720p}"

FRAMES="${FRAMES:-45}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
START_BITRATE_BPS="${START_BITRATE_BPS:-1500000}"
MIN_BITRATE_BPS="${MIN_BITRATE_BPS:-300000}"
MAX_BITRATE_BPS="${MAX_BITRATE_BPS:-2800000}"
MIN_PLAYABLE_RATIO="${MIN_PLAYABLE_RATIO:-0.8}"
MIN_AVG_PSNR_Y="${MIN_AVG_PSNR_Y:-20.0}"
MIN_AVG_SSIM_Y="${MIN_AVG_SSIM_Y:-0.80}"
MAX_WEAK_SEND_RPS="${MAX_WEAK_SEND_RPS:-15.0}"
MAX_WEAK_RTP_PPS="${MAX_WEAK_RTP_PPS:-210.0}"
MAX_WEAK_TARGET_BPS="${MAX_WEAK_TARGET_BPS:-750000}"
MAX_WEAK_ENCODER_FPS="${MAX_WEAK_ENCODER_FPS:-10}"
MAX_RECOVERY_TIME_MS="${MAX_RECOVERY_TIME_MS:-1000}"
RENDERER_PROXY_TARGET_DELAY_MS="${RENDERER_PROXY_TARGET_DELAY_MS:-350}"
MAX_RENDERER_PROXY_LATE_MS="${MAX_RENDERER_PROXY_LATE_MS:-150}"
MAX_RENDERER_PROXY_LATENCY_MS="${MAX_RENDERER_PROXY_LATENCY_MS:-500}"
MAX_RENDERER_PROXY_LATE_FRAMES="${MAX_RENDERER_PROXY_LATE_FRAMES:-0}"
MAX_RENDERER_PROXY_DROP_FRAMES="${MAX_RENDERER_PROXY_DROP_FRAMES:-0}"
MAX_RENDERER_PROXY_GAP_MS="${MAX_RENDERER_PROXY_GAP_MS:-150}"
SEEDS="${SEEDS:-1}"
SCENARIOS="${SCENARIOS:-baseline weak_network_low_rps_low_bitrate walking_dead_zone_recover oscillating_edge_recover}"
REQUIRE_CAPTURE_MANIFEST="${REQUIRE_CAPTURE_MANIFEST:-0}"
REQUIRE_CAPTURE_CATEGORY_COVERAGE="${REQUIRE_CAPTURE_CATEGORY_COVERAGE:-${REQUIRE_CAPTURE_MANIFEST}}"
REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES:-indoor_face outdoor_walking low_light_noise screen_text high_motion scene_cut}"
MIN_CAPTURE_FRAMES="${MIN_CAPTURE_FRAMES:-${FRAMES}}"
MIN_CAPTURE_SECONDS="${MIN_CAPTURE_SECONDS:-1.5}"
ALLOW_DUPLICATE_CAPTURE_PATHS="${ALLOW_DUPLICATE_CAPTURE_PATHS:-0}"
CAPTURE_MANIFEST_SUMMARY="${CAPTURE_MANIFEST_SUMMARY:-${OUTPUT_DIR}/capture_manifest_summary.txt}"

mkdir -p "${OUTPUT_DIR}" "${WORK_DIR}"

if [[ ! -d "${CAPTURE_LIBRARY_DIR}" ]]; then
  echo "capture library directory not found: ${CAPTURE_LIBRARY_DIR}" >&2
  echo "set CAPTURE_LIBRARY_DIR to a directory containing .mp4/.mov/.mkv/.webm/.yuv/.i420 files" >&2
  exit 2
fi

capture_sources_tsv="${WORK_DIR}/capture_sources.tsv"
if [[ -f "${CAPTURE_LIBRARY_MANIFEST}" || "${REQUIRE_CAPTURE_MANIFEST}" == "1" ]]; then
  if [[ "${REQUIRE_CAPTURE_CATEGORY_COVERAGE}" != "1" ]]; then
    REQUIRED_CAPTURE_CATEGORIES=""
  fi
  SDK_ROOT="${SDK_ROOT}" \
  CAPTURE_LIBRARY_DIR="${CAPTURE_LIBRARY_DIR}" \
  CAPTURE_LIBRARY_MANIFEST="${CAPTURE_LIBRARY_MANIFEST}" \
  REQUIRED_CAPTURE_CATEGORIES="${REQUIRED_CAPTURE_CATEGORIES}" \
  CAPTURE_WIDTH="${WIDTH}" \
  CAPTURE_HEIGHT="${HEIGHT}" \
  MIN_CAPTURE_FRAMES="${MIN_CAPTURE_FRAMES}" \
  MIN_CAPTURE_SECONDS="${MIN_CAPTURE_SECONDS}" \
  ALLOW_DUPLICATE_CAPTURE_PATHS="${ALLOW_DUPLICATE_CAPTURE_PATHS}" \
  RESOLVED_CAPTURE_LIST="${capture_sources_tsv}" \
  SUMMARY_FILE="${CAPTURE_MANIFEST_SUMMARY}" \
    "${SDK_ROOT}/scripts/verify_capture_library_manifest.sh"
else
  : >"${capture_sources_tsv}"
  while IFS= read -r -d '' source_path; do
    base="$(basename "${source_path}")"
    label="${base%.*}"
    label="$(printf '%s' "${label}" | sed 's/[^A-Za-z0-9_.-]/_/g')"
    printf 'uncategorized\t%s\t%s\n' "${label}" "${source_path}" \
      >>"${capture_sources_tsv}"
  done < <(find "${CAPTURE_LIBRARY_DIR}" -maxdepth 1 -type f \
    \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mkv' -o -iname '*.webm' \
       -o -iname '*.yuv' -o -iname '*.i420' \) -print0 | sort -z)
fi

content_modes=()
while IFS=$'\t' read -r category label source_path; do
  if [[ -z "${category}" || -z "${label}" || -z "${source_path}" ]]; then
    continue
  fi
  base="$(basename "${source_path}")"
  content_label="${category}_${label}"
  ext="${base##*.}"
  ext_lower="$(printf '%s' "${ext}" | tr '[:upper:]' '[:lower:]')"
  i420_path="${source_path}"
  if [[ "${ext_lower}" == "yuv" || "${ext_lower}" == "i420" ]]; then
    i420_path="${WORK_DIR}/${content_label}_${WIDTH}x${HEIGHT}.${ext_lower}"
    cp "${source_path}" "${i420_path}"
  else
    i420_path="${WORK_DIR}/${content_label}_${WIDTH}x${HEIGHT}_${FRAMES}.i420"
    ffmpeg -nostdin -hide_banner -loglevel error -y -i "${source_path}" \
      -vf "scale=${WIDTH}:${HEIGHT}:flags=bicubic,fps=30" \
      -frames:v "${FRAMES}" -pix_fmt yuv420p -f rawvideo "${i420_path}"
  fi
  content_modes+=("capture_i420:${content_label}:${i420_path}")
done <"${capture_sources_tsv}"

if [[ "${#content_modes[@]}" -eq 0 ]]; then
  echo "capture library has no supported files: ${CAPTURE_LIBRARY_DIR}" >&2
  exit 2
fi

printf -v content_modes_joined '%s ' "${content_modes[@]}"
content_modes_joined="${content_modes_joined% }"

SDK_ROOT="${SDK_ROOT}" \
WEBRTC_PREFIX="${WEBRTC_PREFIX}" \
WORK_DIR="${WORK_DIR}/ffmpeg_qoe" \
OUTPUT_DIR="${OUTPUT_DIR}" \
OUTPUT_BASENAME="webrtc_first_qoe_capture_library_720p" \
FRAMES="${FRAMES}" \
WIDTH="${WIDTH}" \
HEIGHT="${HEIGHT}" \
START_BITRATE_BPS="${START_BITRATE_BPS}" \
MIN_BITRATE_BPS="${MIN_BITRATE_BPS}" \
MAX_BITRATE_BPS="${MAX_BITRATE_BPS}" \
MIN_PLAYABLE_RATIO="${MIN_PLAYABLE_RATIO}" \
MIN_AVG_PSNR_Y="${MIN_AVG_PSNR_Y}" \
MIN_AVG_SSIM_Y="${MIN_AVG_SSIM_Y}" \
MAX_WEAK_SEND_RPS="${MAX_WEAK_SEND_RPS}" \
MAX_WEAK_RTP_PPS="${MAX_WEAK_RTP_PPS}" \
MAX_WEAK_TARGET_BPS="${MAX_WEAK_TARGET_BPS}" \
MAX_WEAK_ENCODER_FPS="${MAX_WEAK_ENCODER_FPS}" \
MAX_RECOVERY_TIME_MS="${MAX_RECOVERY_TIME_MS}" \
RENDERER_PROXY_TARGET_DELAY_MS="${RENDERER_PROXY_TARGET_DELAY_MS}" \
MAX_RENDERER_PROXY_LATE_MS="${MAX_RENDERER_PROXY_LATE_MS}" \
MAX_RENDERER_PROXY_LATENCY_MS="${MAX_RENDERER_PROXY_LATENCY_MS}" \
MAX_RENDERER_PROXY_LATE_FRAMES="${MAX_RENDERER_PROXY_LATE_FRAMES}" \
MAX_RENDERER_PROXY_DROP_FRAMES="${MAX_RENDERER_PROXY_DROP_FRAMES}" \
MAX_RENDERER_PROXY_GAP_MS="${MAX_RENDERER_PROXY_GAP_MS}" \
SEEDS="${SEEDS}" \
CONTENT_MODES="${content_modes_joined}" \
SCENARIOS="${SCENARIOS}" \
"${SDK_ROOT}/scripts/run_webrtc_first_ffmpeg_qoe.sh"
