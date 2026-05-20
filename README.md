# WebRTC QoS SDK Phase-1a

This is the first implementation slice for `webrtc_qos_sdk_design.md`.

The current scope is intentionally narrow:

- H264 video only.
- Annex-B access unit input and output.
- RTP payload type `96`, 90 kHz clock, `packetization-mode=1`.
- Single NALU and FU-A only.
- SDK lightweight sender pacer.
- Sender-side QoS facade with `uplink_twcc`, RTCP RR RTT, and sender rate cap inputs.
- Receiver-side jitter and downlink quality facade.
- No audio, NetEq, Opus, capture device, renderer, ICE, DTLS, SRTP, SDP, or PeerConnection.

Build:

```bash
cmake -S webrtc_qos_sdk -B webrtc_qos_sdk/build -DCMAKE_BUILD_TYPE=Release
cmake --build webrtc_qos_sdk/build
cmake --install webrtc_qos_sdk/build --prefix output
```

Full Phase-1a verification:

```bash
bash webrtc_qos_sdk/scripts/verify_phase1a.sh
```

CMake package consumer verification:

```bash
bash webrtc_qos_sdk/scripts/verify_cmake_package.sh
```

Installed layout:

```text
output/
  include/webrtc_qos/
  lib/
    libwebrtc_qos.a
    libwebrtc_qos_core.a
    libwebrtc_qos_rtp.a
    libwebrtc_qos_rtcp.a
    libwebrtc_qos_feedback.a
    libwebrtc_qos_transport.a
    libwebrtc_qos_nack.a
    libwebrtc_qos_googcc_adapter.a
    libwebrtc_qos_video_jitter_adapter.a
    libwebrtc_qos_googcc_bridge.a
    libwebrtc_qos_video_jitter_bridge.a
    libwebrtc_qos_pacer.a
    libwebrtc_qos_video.a
  demo/
```

Library boundaries:

- `libwebrtc_qos_core.a`: shared types and H264 Annex-B helpers.
- `libwebrtc_qos_rtp.a`: lightweight RTP parse/serialize with TWCC header extension support.
- `libwebrtc_qos_rtcp.a`: RTCP SR/RR/TWCC/NACK/PLI helpers.
- `libwebrtc_qos_feedback.a`: downlink quality, sender rate cap, and sender QoS facade.
- `libwebrtc_qos_transport.a`: production transport integration port; applications map SDK message types to their own wire protocol.
- `production_transport_adapter.h`: production integration template that copies borrowed SDK payloads into owned messages and routes them to media/control/reliable-control lanes.
- `libwebrtc_qos_nack.a`: lightweight RTP gap detection, NACK candidates, and retransmission cache.
- `libwebrtc_qos_googcc_adapter.a`: distributable WebRTC `network_control/goog_cc` adapter.
- `libwebrtc_qos_video_jitter_adapter.a`: distributable WebRTC video jitter adapter using the minimal H264 `PacketBuffer` closure.
- `libwebrtc_qos_googcc_bridge.a`: optional facade bridge from `SenderQosController` to `GoogCcAdapter`.
- `libwebrtc_qos_video_jitter_bridge.a`: optional facade bridge from `VideoJitterPlayer` to `VideoJitterAdapter`.
- `libwebrtc_qos_pacer.a`: SDK lightweight sender pacer.
- `libwebrtc_qos_video.a`: H264 video sender, receiver, and jitter player.
- `libwebrtc_qos.a`: facade archive containing all Phase-1a SDK objects for simple single-library linking.

Optional integration sets:

- Push client: `core`, `rtp`, `rtcp`, `feedback`, `nack`, `pacer`, `video`, `googcc_bridge`, `googcc_adapter`.
- Server relay: `rtp`, `rtcp`, `feedback`, `transport`, `nack`.
- Play client: `core`, `rtp`, `rtcp`, `feedback`, `nack`, `video`, `video_jitter_bridge`, `video_jitter_adapter`.
- Simple single-library prototype: `libwebrtc_qos.a` plus `libwebrtc_qos_googcc_bridge.a`, `libwebrtc_qos_googcc_adapter.a`, `libwebrtc_qos_video_jitter_bridge.a`, and `libwebrtc_qos_video_jitter_adapter.a` as needed.

The intent is not to ship one monolithic WebRTC archive. Each WebRTC capability that survives trimming gets its own adapter archive and public header, and the application links only the pieces it needs.

Current integration boundary:

- The facade SDK and standalone demos already run the H264 RTP/QoS/jitter/retransmission loopback.
- `SenderQosController` keeps a default lightweight estimator for builds that do not link WebRTC.
- `libwebrtc_qos_googcc_bridge.a` is packaged and smoke-tested; it connects the `SenderQosController` facade to `GoogCcAdapter` when applications opt in.
- `libwebrtc_qos_video_jitter_bridge.a` is packaged and smoke-tested; it connects the `VideoJitterPlayer` facade to `VideoJitterAdapter` when applications opt in.
- WebRTC `NackRequester` was dependency-audited and is intentionally not in Phase-1a; `libwebrtc_qos_nack.a` is the Phase-1a recovery module.

Build and package the WebRTC adapter libraries:

```bash
bash webrtc_qos_sdk/scripts/package_webrtc_googcc.sh
```

The packaging script builds the WebRTC `//sdk_qos` GN target with:

- no protobuf, Perfetto, examples, tools, Rust, gRPC, Opus, NetEq, full WebRTC RTP/RTCP, full WebRTC video frame assembler, libyuv, or WebRTC pacer in the shipped adapter dependency paths;
- `use_custom_libcxx=false`, `use_lld=false`, `use_safe_libstdcxx=false`;
- a complete non-thin archive suitable for redistribution.

The video jitter adapter intentionally does not link `api/video:rtp_video_frame_assembler` directly. That full target pulls unrelated WebRTC media infrastructure for this Phase-1a H264-only scope. The shipped adapter keeps the useful WebRTC pieces: H264 parsing and `modules/video_coding::PacketBuffer`, then normalizes output to complete Annex-B access units.

External link check:

```bash
g++ -std=c++20 -Ioutput/include app.cc \
  output/lib/libwebrtc_qos_googcc_adapter.a \
  -lpthread -ldl -lrt -latomic
```

Video jitter adapter link check:

```bash
g++ -std=c++20 -Ioutput/include app.cc \
  output/lib/libwebrtc_qos_video_jitter_adapter.a \
  -lpthread -ldl -lrt -latomic
```

Quick loopback check:

```bash
./webrtc_qos_sdk/build/qos_loopback_demo
```

Protocol selftest:

```bash
./webrtc_qos_sdk/build/webrtc_qos_selftest
```

WebRTC adapter smoke checks:

```bash
./output/demo/webrtc_qos_googcc_smoke
./output/demo/webrtc_qos_video_jitter_smoke
```

Installed-output integration check:

```bash
bash webrtc_qos_sdk/scripts/build_output_integration_demo.sh
./output/demo/output_integration_demo
```

This integration demo compiles only against `output/include` and `output/lib`. It links the small libraries by role, runs synthetic H264 Annex-B access units through `VideoSender`, SDK lightweight `SenderPacer`, server-side retransmission cache, `SenderQosController` with the GoogCC bridge, receiver QoS observation, and `VideoJitterPlayer` with the WebRTC video jitter bridge, then verifies NACK-style recovery and complete Annex-B AU output.

Real UDP C/S demo:

```bash
bash webrtc_qos_sdk/scripts/build_udp_demos.sh
bash webrtc_qos_sdk/scripts/run_udp_loopback_demo.sh
```

The UDP demo starts `udp_sender_demo`, `udp_server_demo`, and `udp_receiver_demo` as separate processes on local UDP ports. It intentionally drops one RTP packet at the server, triggers receiver NACK, retransmits from the server cache, feeds uplink TWCC back to the sender, and verifies two complete Annex-B frames at the receiver.

The UDP demo uses `DEMO_TRANSPORT_V1` as a scoped demo envelope carrying `session_id`, `stream_id`, `sender_ssrc`, and `receiver_id` outside RTP/RTCP payloads. It also supports weak-network parameters:

```bash
DROP_RTP_SEQ=2 REORDER_RTP_SEQ=4 DELAY_MS=30 \
  bash webrtc_qos_sdk/scripts/run_udp_loopback_demo.sh
```

Role-based link verification:

```bash
bash webrtc_qos_sdk/scripts/verify_role_linking.sh
```

This compiles separate push/server/play toy applications against `/root/output/include + /root/output/lib` and links only the small libraries required by each role.

CMake consumers can either link individual module targets or use role targets:

- `WebRtcQosSdk::role_transport`
- `WebRtcQosSdk::role_server`
- `WebRtcQosSdk::role_push`
- `WebRtcQosSdk::role_play`
- `WebRtcQosSdk::role_prototype`

`verify_cmake_package.sh` builds external consumers for each role target through `find_package(WebRtcQosSdk CONFIG REQUIRED)`.

Transport integration boundary:

```bash
./output/demo/transport_port_demo
./output/demo/production_transport_demo
```

Production transport code should implement the `TransportPort` send/deliver callbacks and map SDK message types to the business wire protocol. `TransportMessage::payload` is a borrowed view valid only during the callback, so async socket/reliable-channel code must copy it before returning. `DEMO_TRANSPORT_V1` is only the UDP demo envelope; it is not required by the SDK.

`ProductionTransportAdapter` is the recommended starting template for production integration. It keeps `TransportPort` as the SDK boundary, copies payloads into `OwnedTransportMessage`, and classifies messages as:

- RTP: unreliable media.
- RTCP SR/RR/TWCC/NACK/PLI: unreliable control.
- `DOWNLINK_QUALITY_V1` / `SENDER_RATE_CAP_V1` / `BYE`: reliable control.

UDP weak-network matrix:

```bash
RUNS=3 bash webrtc_qos_sdk/scripts/run_udp_netem_matrix.sh
```

This runs baseline/drop, reorder, delay, and reorder+delay scenarios repeatedly and checks TWCC, RTCP RR, NACK, retransmission, PLI forwarding, IDR resend, sender rate cap, and recovered frame count from the logs.
It also writes machine-readable metrics:

- `${LOG_DIR}/metrics.jsonl`: one JSON object per scenario run.
- `${LOG_DIR}/summary.json`: aggregate min/max/avg values for frames, RTT, final bitrate, retransmission success ratio, observed loss, reported loss, and jitter.
- Threshold failures include missing feedback/RR/rate-cap/PLI/NACK/retransmission, insufficient recovered frames, missing reorder/delay observation, and failed rate-cap application.

The predefined weak-network scenario file is `scripts/udp_netem_scenarios.json`. It currently covers:

- `baseline_single_loss`: one RTP loss.
- `burst_loss`: two close RTP losses.
- `reorder_only`: out-of-order RTP arrival.
- `delay_only`: fixed downlink delay.
- `jitter_periodic`: periodic extra delay.
- `mixed_loss_reorder_delay_jitter`: burst loss, reorder, fixed delay, and periodic jitter combined.

Each scenario carries its expected metrics threshold, so the matrix validates behavior against explicit expectations instead of only grepping for log lines.

UDP soak entry:

```bash
DURATION_SEC=60 MATRIX_RUNS=1 bash webrtc_qos_sdk/scripts/run_udp_soak.sh
```

This repeatedly runs the weak-network matrix for the requested duration, stores per-iteration logs, and reports pass/fail counts.

`verify_phase1a.sh` runs the build/install path, standalone demos, WebRTC adapter smokes, output integration demo, UDP weak-network matrix, short soak, role-linking check, GN dependency checks, and required artifact checks.

`verify_cmake_package.sh` verifies external projects can consume `/root/output` via `find_package(WebRtcQosSdk CONFIG REQUIRED)` and link module targets such as `WebRtcQosSdk::webrtc_qos_transport`.
It also verifies optional WebRTC adapter targets such as `WebRtcQosSdk::webrtc_qos_googcc_adapter` and `WebRtcQosSdk::webrtc_qos_video_jitter_adapter` when those archives are present.

The loopback demo intentionally drops one RTP packet, triggers a NACK-style recovery event, retransmits from the server-side cache with the original RTP sequence number and a new transport sequence number, and still outputs two Annex-B access units.

Implementation boundary in this slice:

- H264 Annex-B parsing, RTP packetization/depacketization, TWCC RTP header extension, lightweight pacer, wire-format helpers, and loopback demos are implemented.
- Retransmission cache keeps RTP identity stable and assigns a new transport sequence number on resend.
- Standard RTCP helpers are provided for SR, RR, TWCC transport feedback, Generic NACK, and PLI.
- `libwebrtc_qos_nack.a` packages the Phase-1a lightweight NACK and retransmission recovery path without WebRTC task queue dependencies.
- WebRTC `sdk_qos` now packages `network_control/goog_cc` as `libwebrtc_qos_googcc_adapter.a` with a clean public C++ header.
- WebRTC `sdk_qos` now packages H264 video jitter as `libwebrtc_qos_video_jitter_adapter.a` with a clean public C++ header.
- `libwebrtc_qos_googcc_bridge.a` packages the optional facade bridge from `SenderQosController` to `GoogCcAdapter`.
- `libwebrtc_qos_video_jitter_bridge.a` packages the optional facade bridge from `VideoJitterPlayer` to `VideoJitterAdapter`.
- `output_integration_demo` proves an application can consume the installed `include + lib` layout without depending on the source tree.
- `transport_port_demo` proves the business transport boundary can be implemented without the UDP demo envelope.
- `production_transport_demo` proves the recommended production adapter template owns payload copies before async transport queues and separates media/control/reliable-control lanes.
- `udp_*_demo` proves the same small libraries work across a real local UDP C/S chain.
- `udp_*_demo` also verifies `PLI -> server forward -> sender IDR resend -> receiver keyframe output`.
- `run_udp_netem_matrix.sh` proves the UDP C/S chain survives repeated drop/reorder/delay scenarios and catches duplicate-frame regressions.
- `run_udp_soak.sh` repeats the weak-network matrix by duration and provides the local soak/stress entry point before replacing `DEMO_TRANSPORT_V1`.
- `verify_role_linking.sh` proves role-based integration can avoid a monolithic `libwebrtc.a`.
