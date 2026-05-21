#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_long_stream_qoe_720p_stability}"
MATRIX_RUNS="${MATRIX_RUNS:-3}"
MATRIX_CONTENTS="${MATRIX_CONTENTS:-motion low_motion detail_motion}"
MATRIX_SCENARIOS="${MATRIX_SCENARIOS:-walking_dead_zone jitter_loss_oscillation bandwidth_staircase rtt_jitter_spike_recover loss_burst_recover}"
MATRIX_STRATEGIES="${MATRIX_STRATEGIES:-adaptive}"
MATRIX_BACKENDS="${MATRIX_BACKENDS:-webrtc}"
LONG_STREAM_DEMO_ARGS="${LONG_STREAM_DEMO_ARGS:---width=1280 --height=720 --start-bitrate=2500000 --max-bitrate=5000000 --recovered-route-start-bps=3500000}"

export SDK_ROOT
export LOG_DIR
export MATRIX_RUNS
export MATRIX_CONTENTS
export MATRIX_SCENARIOS
export MATRIX_STRATEGIES
export MATRIX_BACKENDS
export LONG_STREAM_DEMO_ARGS

exec "${SDK_ROOT}/scripts/run_long_stream_qoe_matrix.sh"
