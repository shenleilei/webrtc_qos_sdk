#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_udp_long_stream_720p_profile}"
MATRIX_CONTENTS="${MATRIX_CONTENTS:-motion}"
MATRIX_RUNS="${MATRIX_RUNS:-1}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
BITRATE="${BITRATE:-2500000}"
FRAMES="${FRAMES:-210}"

export SDK_ROOT
export LOG_DIR
export MATRIX_CONTENTS
export MATRIX_RUNS
export WIDTH
export HEIGHT
export BITRATE
export FRAMES
export MIN_RECONFIGS_WALKING="${MIN_RECONFIGS_WALKING:-6}"
export MIN_RECONFIGS_BANDWIDTH="${MIN_RECONFIGS_BANDWIDTH:-4}"
export MIN_RECONFIGS_JITTER="${MIN_RECONFIGS_JITTER:-3}"

exec "${SDK_ROOT}/scripts/run_udp_long_stream_matrix.sh"
