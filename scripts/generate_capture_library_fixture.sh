#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CAPTURE_LIBRARY_DIR="${CAPTURE_LIBRARY_DIR:-${SDK_ROOT}/artifacts/capture_library_fixture}"
WIDTH="${WIDTH:-320}"
HEIGHT="${HEIGHT:-180}"
FPS="${FPS:-30}"
DURATION_SECONDS="${DURATION_SECONDS:-2}"
BITRATE="${BITRATE:-900k}"
CRF="${CRF:-23}"
PRESET="${PRESET:-veryfast}"
OVERWRITE="${OVERWRITE:-1}"

mkdir -p "${CAPTURE_LIBRARY_DIR}"

manifest="${CAPTURE_LIBRARY_DIR}/manifest.csv"
if [[ "${OVERWRITE}" == "1" ]]; then
  rm -f "${CAPTURE_LIBRARY_DIR}"/*.mp4 "${manifest}"
fi

write_manifest_header() {
  printf 'category,label,path,enabled\n' >"${manifest}"
}

append_manifest_row() {
  local category="$1"
  local label="$2"
  local file="$3"
  printf '%s,%s,%s,1\n' "${category}" "${label}" "$(basename "${file}")" \
    >>"${manifest}"
}

make_video() {
  local category="$1"
  local label="$2"
  local source="$3"
  local filters="$4"
  local out="${CAPTURE_LIBRARY_DIR}/${category}_${label}.mp4"
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "${source}" \
    -vf "${filters},format=yuv420p" \
    -frames:v "$((FPS * DURATION_SECONDS))" \
    -r "${FPS}" \
    -an \
    -c:v libx264 \
    -profile:v baseline \
    -level:v 3.1 \
    -preset "${PRESET}" \
    -crf "${CRF}" \
    -b:v "${BITRATE}" \
    -pix_fmt yuv420p \
    "${out}"
  append_manifest_row "${category}" "${label}" "${out}"
}

write_manifest_header

make_video \
  "indoor_face" \
  "fixture_talking_head" \
  "testsrc2=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION_SECONDS}" \
  "drawbox=x=iw*0.36:y=ih*0.18:w=iw*0.28:h=ih*0.42:color=0xf0c090@0.85:t=fill,drawbox=x=iw*0.43:y=ih*0.30:w=iw*0.035:h=ih*0.04:color=black@0.9:t=fill,drawbox=x=iw*0.53:y=ih*0.30:w=iw*0.035:h=ih*0.04:color=black@0.9:t=fill,drawbox=x=iw*0.45:y=ih*0.47:w=iw*0.10:h=ih*0.025:color=0x6b2020@0.9:t=fill"

make_video \
  "outdoor_walking" \
  "fixture_pan_walk" \
  "testsrc2=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION_SECONDS}" \
  "hue=h=20*sin(2*PI*t):s=1.35,drawgrid=w=64:h=64:t=2:c=white@0.25,drawbox=x='mod(t*90\\,iw)':y=ih*0.48:w=iw*0.12:h=ih*0.30:color=0x1f4fff@0.75:t=fill"

make_video \
  "low_light_noise" \
  "fixture_dark_noise" \
  "testsrc2=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION_SECONDS}" \
  "eq=brightness=-0.42:contrast=1.2:saturation=0.45,noise=alls=28:allf=t+u"

make_video \
  "screen_text" \
  "fixture_screen_grid" \
  "testsrc=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION_SECONDS}" \
  "drawgrid=w=32:h=24:t=1:c=white@0.45,drawbox=x=iw*0.05:y=ih*0.10:w=iw*0.90:h=ih*0.12:color=white@0.85:t=fill,drawbox=x=iw*0.08:y=ih*0.14:w=iw*0.70:h=ih*0.035:color=black@0.9:t=fill,drawbox=x=iw*0.08:y=ih*0.32:w=iw*0.84:h=ih*0.035:color=white@0.9:t=fill,drawbox=x=iw*0.08:y=ih*0.44:w=iw*0.74:h=ih*0.035:color=white@0.9:t=fill,drawbox=x=iw*0.08:y=ih*0.56:w=iw*0.62:h=ih*0.035:color=white@0.9:t=fill"

make_video \
  "high_motion" \
  "fixture_fast_motion" \
  "testsrc2=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION_SECONDS}" \
  "hue=h=90*t:s=2,drawbox=x='mod(t*260\\,iw)':y='ih*0.2+sin(t*18)*ih*0.15':w=iw*0.18:h=ih*0.18:color=red@0.85:t=fill,drawbox=x='iw-mod(t*300\\,iw)':y='ih*0.62+cos(t*15)*ih*0.12':w=iw*0.16:h=ih*0.16:color=yellow@0.85:t=fill"

make_video \
  "scene_cut" \
  "fixture_scene_cut" \
  "smptebars=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION_SECONDS}" \
  "hue=h='if(gte(t,1),180,0)':s='if(gte(t,1),0.6,1.4)',drawbox=x='if(gte(t,1),iw*0.62,iw*0.12)':y=ih*0.22:w=iw*0.24:h=ih*0.42:color=0x00ff80@0.75:t=fill"

echo "capture_fixture_dir=${CAPTURE_LIBRARY_DIR}"
echo "capture_fixture_manifest=${manifest}"
echo "capture_fixture_categories=indoor_face,outdoor_walking,low_light_noise,screen_text,high_motion,scene_cut"
