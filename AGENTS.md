# WebRTC QoS SDK Agent Guide

This repository is a Linux native, WebRTC-first QoS SDK prototype for a
custom C/S transport. It is not a full WebRTC client, not a PeerConnection
stack, and not a complete SFU.

## Read This First

Use these files as the primary source of truth:

1. `webrtc_first_phase3_plan.md`
2. `webrtc_first_phase2_master_plan.md`
3. `README.md`
4. `docs/sdk_push_play_integration.md`
5. `docs/webrtc_qos_overview.md`
6. `docs/qos_test_validation_methodology.md`

## Current Architecture

There are three public role facades:

- `VideoPushClient`
- `VideoPlayClient`
- `ServerQosRouter`

The SDK reuses WebRTC modules for:

- H264 RTP packetization/depacketization
- RTP/RTCP wire format
- GoogCC
- PacingController
- NackRequester
- video jitter / packet buffer

The business side still owns:

- sockets / UDP / QUIC / transport I/O
- session / stream / receiver mapping
- media fanout topology
- auth / lifecycle / routing policy
- renderer / decode QoE harness

## Important Boundaries

### Retransmission

- Current recovery is `NACK + original RTP retransmission`.
- This is not RFC4588 RTX.
- FEC is not supported.

### Multi-Receiver

- Multi-receiver feedback semantics are supported in `ServerQosRouter`.
- `receiver_id` is a business routing identity, not an RTCP sender SSRC.
- RTCP identities are split via:
  - `session.rtcp.receiver_feedback_ssrc`
  - `session.rtcp.server_feedback_ssrc`
- The SDK does not maintain a receiver registry or auto-broadcast sender RTP to
  all receivers.
- `receiver_output` is a single packet callback. Business code must fan out
  sender media to multiple downstream receivers if the topology is 1 -> N.

### Compound RTCP

- The SDK currently only promises support for:
  - `SR`
  - `RR`
  - `TWCC`
  - `NACK`
  - `PLI`
- Unsupported RTCP packets are counted and dropped by the server path.

## Phase-3 Status

The core Phase-3 logic work is implemented:

- sender retransmission re-enters WebRTC pacer
- RTCP SR excludes original-packet retransmission
- RTCP sender SSRC is split from business `receiver_id`
- unsupported compound RTCP packets are observable
- outward naming uses `retransmission`, not `rtx`

The remaining gaps are external formal-evidence items:

- `SOAK_MINUTES >= 120` production soak
- real renderer `pass`
- formal `capture_library/manifest.csv` and business capture assets

## Build

Default source build:

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j2
cmake --install build --prefix dist/linux-x86_64
```

If WebRTC module archives are missing, package them first:

```bash
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 REQUIRE_ALL=1 NINJA_JOBS=2 \
  scripts/package_webrtc_modules.sh
```

## Most Important Verification Commands

Runtime and package semantics:

```bash
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_cmake_package.sh
```

Core smoke:

```bash
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_webrtc_first_pacing_probe.sh

PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_webrtc_first_roles.sh
```

Aggregated verification:

```bash
VERIFY_LEVEL=smoke PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_webrtc_first_phase2.sh

VERIFY_LEVEL=qoe PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_webrtc_first_phase2.sh

VERIFY_LEVEL=production PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_webrtc_first_phase2.sh
```

Notes:

- The default local `VERIFY_LEVEL=production` path is a short production-smoke
  runner/archive check, not a formal 120-minute soak.
- Formal completion still requires explicit `SOAK_MINUTES >= 120`,
  `REQUIRE_REAL_RENDERER=1`, and `REQUIRE_CAPTURE_LIBRARY=1`.

## Key Files

- `src/video_push_client_webrtc.cc`
- `src/video_play_client_webrtc.cc`
- `src/server_qos_router_webrtc.cc`
- `src/compound_rtcp.h`
- `scripts/verify_cmake_package.sh`
- `scripts/verify_webrtc_first_phase2.sh`
- `scripts/run_webrtc_first_ffmpeg_qoe.sh`
- `scripts/run_webrtc_first_qoe_production_soak.sh`

## Do Not Regress

- Do not reintroduce self-made RTP/RTCP/NACK/pacer/jitter public fallbacks.
- Do not call the current retransmission path `RTX`.
- Do not collapse RTCP sender SSRC back into business `receiver_id`.
- Do not count retransmission traffic into sender media SR packet/octet totals.
- Do not assume `ServerQosRouter` itself manages multi-receiver media fanout.
