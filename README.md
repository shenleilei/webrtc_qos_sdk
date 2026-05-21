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
    libwebrtc_qos_ffmpeg_encoder.a  # optional, when FFmpeg/libx264 is present
    libwebrtc_qos_ffmpeg_decoder.a  # optional, when FFmpeg/libavcodec is present
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
- `libwebrtc_qos_ffmpeg_encoder.a`: optional basic FFmpeg/libx264 H264 encoder adapter. It is deliberately outside the core SDK closure.
- `libwebrtc_qos_ffmpeg_decoder.a`: optional FFmpeg H264 decoder adapter used by QoE validation to prove receiver Annex-B AU output is actually decodable.
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

Real UDP long-stream QoE smoke:

```bash
bash webrtc_qos_sdk/scripts/run_udp_long_stream_smoke.sh
```

This starts three independent local UDP processes: `udp_long_sender_demo`, `udp_long_server_demo`, and `udp_long_receiver_demo`. The server process is intentionally minimal: it is a local UDP relay/test harness for forwarding RTP, producing sender-side TWCC/RR feedback, injecting deterministic weak-network phases, and retransmitting from a cache after receiver NACK. It is not a production SFU, not a long-term server SDK target, and not a Linux `tc/netem` deployment. The optimization focus is endpoint SDK behavior on the sender and receiver.

The feedback topology in this smoke is:

- `sender -> server`: H264 RTP plus periodic RTCP SR.
- `server -> sender`: standard RTCP TWCC generated from sender uplink RTP arrivals, RTCP RR generated from sender SR, and `SENDER_RATE_CAP_V1` when receiver downlink quality indicates impairment.
- `server -> receiver`: RTP forwarding with optional drop/delay/jitter and server-side retransmission from cache.
- `receiver -> server`: `DOWNLINK_QUALITY_V1` reports, RTCP NACK for missing RTP sequence numbers, and BYE.

The default smoke uses real FFmpeg/libx264 encoding, live encoder bitrate/FPS reconfiguration from `SenderQosController::GetEncoderAdaptation`, RTP packetization, SDK pacer, real UDP sockets, server retransmission cache, receiver jitter assembly, FFmpeg H264 decode, source-aligned PSNR, max frame gap, and hard checks that TWCC/RR/downlink-quality feedback crossed process boundaries. It intentionally exercises periodic downlink jitter by default:

```bash
LOG_DIR=/tmp/webrtc_qos_udp_long_stream_smoke \
  bash webrtc_qos_sdk/scripts/run_udp_long_stream_smoke.sh
```

Latest local result:

| Metric | Value |
| --- | ---: |
| Source frames | 90 |
| Sender encoded frames | 90 |
| Sender RTP packets | 296 |
| Sender TWCC feedback packets | 296 |
| Sender RTCP RR packets | 3 |
| Sender rate caps | 1 |
| Sender adaptation target min/max | 1200000 / 2500000 bps |
| Sender adaptation FPS min/max | 30 / 30 |
| Server RTP in / forwarded | 296 / 296 |
| Server retransmissions | 17 |
| Server downlink quality reports received | 5 |
| Receiver RTP packets | 313 |
| Receiver completed / decoded frames | 90 / 88 |
| Receiver decode errors | 0 |
| Receiver PSNR avg / min | 42.68 / 27.18 dB |
| Receiver max frame gap | 30 ms |
| Receiver NACK / downlink reports | 17 / 6 |

Real UDP long-stream dynamic weak-network matrix:

```bash
bash webrtc_qos_sdk/scripts/run_udp_long_stream_matrix.sh
MATRIX_CONTENTS="motion low_motion" MATRIX_RUNS=2 \
  bash webrtc_qos_sdk/scripts/run_udp_long_stream_matrix.sh
bash webrtc_qos_sdk/scripts/run_udp_long_stream_720p_profile.sh
bash webrtc_qos_sdk/scripts/run_udp_long_stream_720p_stability.sh
```

This matrix runs the same three-process UDP topology through media-time-driven weak-network phases. The server only supplies deterministic link impairment and standard feedback plumbing; the behavior under test is endpoint-side QoS: sender encoder bitrate/FPS adaptation, sender pacing, route-recovery handling, receiver jitter assembly, receiver NACK generation, interval downlink-quality reporting, and real decoder/PSNR output. The scenario is repeatable because impairment changes by RTP media time rather than wall clock.

Latest local 320x180 real UDP matrix result (`MATRIX_CONTENTS=motion`, `MATRIX_RUNS=1`):

| Scenario | Completed / decoded | Sender min target | Sender min FPS | Sender last target / FPS | Max frame gap | PSNR avg/min | NACK / RTX | Result |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `walking_dead_zone` | 156 / 154 | 90000 bps | 8 | 2500000 bps / 30 | 380 ms | 61.34 / 30.50 dB | 25 / 176 | PASS |
| `bandwidth_cliff_recover` | 154 / 150 | 180000 bps | 8 | 2500000 bps / 30 | 101 ms | 59.24 / 30.16 dB | 28 / 132 | PASS |
| `jitter_loss_recover` | 180 / 166 | 500000 bps | 15 | 2500000 bps / 30 | 230 ms | 60.55 / 24.08 dB | 13 / 64 | PASS |

Aggregate: 3/3 cases passed, `decode_errors=0`, completed frames `490`, decoded frames `470`, sender target reached as low as `90000 bps`, sender FPS reached as low as `8`, sender recovered to `2500000 bps / 30 fps` in every case, max frame gap stayed at or below `380 ms`, PSNR average floor was `59.24 dB`, and all server caps recovered to unlimited at the end of each profile.

Latest local 720p real UDP endpoint stability profile (`MATRIX_CONTENTS="motion low_motion detail_motion"`, `MATRIX_RUNS=3`, 1280x720, 2.5Mbps start):

`Max completion gap` is the receiver wall-clock interval between completed access units and is the primary low-latency QoE smoothness gate. `Max media gap` is the RTP media-time gap between completed frames; in this live profile it is recorded and bounded separately because the sender may intentionally skip old frames around recovery boundaries to keep latency low instead of preserving file-like continuity. `MATRIX_RUNS>1` now maps each run to a deterministic `network_seed`, so repeated runs shift drop/jitter positions instead of replaying the same impairment pattern.

| Scenario / content | Seeds | Completed / decoded | Sender min target | Sender min FPS | Sender last target floor / FPS | Max completion gap | Max media gap | PSNR avg/min floor | NACK / RTX |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `walking_dead_zone` / `motion` | 1,2,3 | 411 / 411 | 90000 bps | 5 | 1501936 bps / 30 | 456 ms | 666 ms | 57.72 / 24.21 dB | 138 / 988 |
| `bandwidth_cliff_recover` / `motion` | 1,2,3 | 461 / 457 | 180000 bps | 8 | 1530305 bps / 30 | 186 ms | 400 ms | 56.02 / 26.33 dB | 191 / 865 |
| `jitter_loss_recover` / `motion` | 1,2,3 | 549 / 537 | 500000 bps | 15 | 1776997 bps / 30 | 242 ms | 367 ms | 52.00 / 25.18 dB | 109 / 182 |
| `walking_dead_zone` / `low_motion` | 1,2,3 | 462 / 460 | 90000 bps | 5 | 1403619 bps / 30 | 575 ms | 667 ms | 70.77 / 23.76 dB | 118 / 909 |
| `bandwidth_cliff_recover` / `low_motion` | 1,2,3 | 477 / 475 | 180000 bps | 8 | 1417638 bps / 30 | 169 ms | 267 ms | 65.85 / 29.19 dB | 165 / 821 |
| `jitter_loss_recover` / `low_motion` | 1,2,3 | 555 / 550 | 500000 bps | 15 | 1404020 bps / 30 | 277 ms | 67 ms | 66.25 / 37.57 dB | 87 / 170 |
| `walking_dead_zone` / `detail_motion` | 1,2,3 | 447 / 447 | 90000 bps | 5 | 1563794 bps / 30 | 442 ms | 200 ms | 41.55 / 36.20 dB | 121 / 1103 |
| `bandwidth_cliff_recover` / `detail_motion` | 1,2,3 | 485 / 481 | 180000 bps | 8 | 1588013 bps / 30 | 247 ms | 267 ms | 38.23 / 16.18 dB | 165 / 881 |
| `jitter_loss_recover` / `detail_motion` | 1,2,3 | 567 / 554 | 500000 bps | 15 | 1748315 bps / 30 | 282 ms | 333 ms | 38.94 / 16.25 dB | 115 / 170 |

Aggregate: 27/27 seeded cases passed, `network_seeds=[1,2,3]`, `decode_errors=0`, completed frames `4414`, decoded frames `4372`, sender target reached as low as `90000 bps`, sender FPS reached as low as `5`, sender recovered to `30 fps`, sender recovered as high as `2500000 bps`, max completion gap stayed at or below `575 ms`, max media gap stayed at or below `667 ms`, PSNR average floor was `38.23 dB`, PSNR minimum floor was `16.18 dB`, NACK count was `1209`, and retransmissions were `6089`.

The key endpoint-side changes validated by this profile are: access units are enqueued to the pacer atomically so weak-network drops do not send half of a FU-A frame; the UDP long-stream sender uses a live low-latency pacer mode that can continue with P frames after stale P-frame drops; recovery keyframes are rate-limited instead of repeatedly injected during a recovery window; and the very weak `<100kbps` class drops to `5fps` before recovering to `30fps` when the route becomes healthy.

Boundary of these UDP long-stream tests: they prove real process separation, core feedback wiring, live encoder adaptation, weak-network downshift, good-network recovery, receiver jitter/NACK, and real H264 decode/PSNR in a local relay-assisted topology. The relay is intentionally minimal and exists only to provide feedback plumbing, seeded deterministic impairment, and retransmission cache behavior. These tests still do not prove production-global optimum because they do not yet use Linux `tc/netem`, real NIC queues, multiple concurrent play clients, real renderer freeze metrics, or the full 5-scenario strategy comparison in the real UDP topology.

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
./output/demo/dynamic_qos_demo
./output/demo/ffmpeg_encoder_demo
./output/demo/long_stream_qoe_demo --strategy=adaptive
```

Production transport code should implement the `TransportPort` send/deliver callbacks and map SDK message types to the business wire protocol. `TransportMessage::payload` is a borrowed view valid only during the callback, so async socket/reliable-channel code must copy it before returning. `DEMO_TRANSPORT_V1` is only the UDP demo envelope; it is not required by the SDK.

`ProductionTransportAdapter` is the recommended starting template for production integration. It keeps `TransportPort` as the SDK boundary, copies payloads into `OwnedTransportMessage`, and classifies messages as:

- RTP: unreliable media.
- RTCP SR/RR/TWCC/NACK/PLI: unreliable control.
- `DOWNLINK_QUALITY_V1` / `SENDER_RATE_CAP_V1` / `BYE`: reliable control.

`dynamic_qos_demo` runs multiple dynamic weak-network transitions, not a single happy-path case. It covers walking into an outage and recovering, bandwidth cliff below 100kbps, RTT/jitter spike, oscillating edge coverage, and burst loss recovery. It verifies that SDK encoder adaptation decisions reduce bitrate/FPS under impairment, suppress sender-side loss-driven IDR when the sender cap is too low to carry a useful keyframe, avoid RTT-only keyframe storms, and restore bitrate/FPS after the network becomes good again.

Dynamic QoS/QoE adaptation matrix:

```bash
bash webrtc_qos_sdk/scripts/run_dynamic_qos_matrix.sh
```

The matrix is driven by `scripts/dynamic_qos_scenarios.json` and writes:

- `${LOG_DIR}/metrics.jsonl`: one row per scenario phase with estimate bitrate, final bitrate, RTT, loss, encoder target bitrate, max FPS, and keyframe request.
- `${LOG_DIR}/summary.json`: aggregate FPS/bitrate range, keyframe count, threshold failures, and per-phase expected-vs-actual quantitative checks.
- Threshold checks cover explicit per-phase bitrate ranges, FPS ranges, keyframe expectation, degraded bitrate drop, and recovery bitrate rise.

Latest local dynamic QoS result:

| Scenario | Phase | Network | Expected encoder bps | Actual encoder bps | Expected FPS | Actual FPS | Expected keyframe | Actual keyframe | Result |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- | --- |
| walk_outage_recover | good | 10000kbps / 20ms / loss 0.0 | 2000000-2500000 | 2500000 | 30-30 | 30 | false | false | PASS |
| walk_outage_recover | outage | 80kbps / 1000ms / loss 0.45 | 80000-200000 | 156250 | 8-8 | 8 | false | false | PASS |
| walk_outage_recover | poor | 120kbps / 650ms / loss 0.25 | 80000-150000 | 80000 | 8-8 | 8 | false | false | PASS |
| walk_outage_recover | recovering | 1200kbps / 180ms / loss 0.03 | 800000-1200000 | 931187 | 15-30 | 15 | false | false | PASS |
| walk_outage_recover | good_again | 10000kbps / 40ms / loss 0.0 | 2000000-2500000 | 2500000 | 30-30 | 30 | false | false | PASS |
| bandwidth_cliff_recover | bandwidth_cliff | 90kbps / 80ms / loss 0.02 | 80000-150000 | 118549 | 8-8 | 8 | false | false | PASS |
| bandwidth_cliff_recover | recovered | 8000kbps / 30ms / loss 0.0 | 2000000-2500000 | 2500000 | 30-30 | 30 | false | false | PASS |
| rtt_jitter_spike_recover | rtt_spike | 700kbps / 900ms / loss 0.08 | 1000000-1500000 | 1305015 | 10-10 | 10 | false | false | PASS |
| rtt_jitter_spike_recover | recovered | 5000kbps / 45ms / loss 0.0 | 2000000-2500000 | 2500000 | 30-30 | 30 | false | false | PASS |
| oscillating_edge | poor_1 | 180kbps / 550ms / loss 0.18 | 700000-950000 | 857500 | 10-10 | 10 | false | false | PASS |
| oscillating_edge | poor_2 | 130kbps / 700ms / loss 0.22 | 700000-950000 | 857500 | 10-10 | 10 | true | true | PASS |
| oscillating_edge | good_3 | 5000kbps / 35ms / loss 0.0 | 2000000-2500000 | 2500000 | 30-30 | 30 | false | false | PASS |
| loss_burst_recover | loss_burst | 500kbps / 220ms / loss 0.60 | 120000-200000 | 156250 | 8-8 | 8 | false | false | PASS |
| loss_burst_recover | recovered | 6000kbps / 35ms / loss 0.0 | 2000000-2500000 | 2500000 | 30-30 | 30 | false | false | PASS |

The dynamic QoS summary from the latest run was: 5 scenarios, 19 phase rows, `encoder_bps` range `80000..2500000`, FPS range `8..30`, keyframe requests `1`, threshold failures `0`.

When FFmpeg/libx264 is available, `ffmpeg_encoder_demo` encodes generated I420 frames into real H264 Annex-B access units, feeds them into `VideoSender + SenderPacer`, then applies a degraded `EncoderAdaptation` decision to the encoder. This keeps real encoder proof separate from the core QoS library and avoids forcing FFmpeg into push/server/play roles that do not need it.

When FFmpeg's H264 decoder is available, the long-stream QoE matrix also decodes receiver Annex-B AUs before counting rendered receiver frames. The decoder runs in low-latency single-thread mode, receives the RTP timestamp as packet PTS, outputs I420 frames, and the matrix compares decoded PTS/RTP timestamp with the generated source I420 frame to produce PSNR. The demo also records frame latency from generated source frame to receiver AU output, plus a jitter-buffer residence proxy from first packet arrival to complete AU output. `decode_errors` only counts real FFmpeg send/receive failures; legal decoder buffering with no immediate output is not misclassified as a bad frame. `decode_errors`, `decoded_frames`, `quality_samples`, `psnr_avg`, `psnr_min`, `frame_latency_*`, and `jitter_buffer_*` are therefore hard QoE inputs, not log-only diagnostics.

Long-stream encoder QoE strategy matrix:

```bash
bash webrtc_qos_sdk/scripts/run_long_stream_qoe_matrix.sh
MATRIX_RUNS=2 bash webrtc_qos_sdk/scripts/run_long_stream_qoe_matrix.sh
bash webrtc_qos_sdk/scripts/run_long_stream_qoe_720p_profile.sh
bash webrtc_qos_sdk/scripts/run_long_stream_qoe_720p_stability.sh
```

This matrix is the first quantitative answer to whether the current QoS policy is merely "working" or actually preferable under a defined objective. It runs a real FFmpeg/libx264 H264 long stream through `VideoSender -> SenderPacer -> server-like cache/NACK -> VideoReceiver/VideoJitterPlayer` across multiple mobile weak-network transitions:

The long-stream runner is still an in-process SFU-like model, not a standalone production SFU process. It models the C/S server responsibilities needed for this phase: sender-side uplink TWCC generation, RTCP RR RTT input, downlink weak-network capacity/delay/jitter/loss, retransmission cache, NACK/PLI handling, and server-generated sender rate caps. The separate UDP demos prove the libraries can cross process boundaries on local sockets, but the long-stream QoE numbers below are not yet a `sender -> real SFU -> receiver` netem deployment result.

- `walking_dead_zone`: good network, sudden outage below 100kbps with high RTT/loss/jitter, poor edge coverage, then recovery to good network.
- `jitter_loss_oscillation`: moderate capacity with heavy jitter, periodic loss/reorder, then recovery.
- `bandwidth_staircase`: medium bandwidth, step-down to poor edge bandwidth, then recovery.
- `rtt_jitter_spike_recover`: high RTT and heavy jitter without explicit packet loss, then recovery.
- `loss_burst_recover`: burst packet loss with recovery, separated from the RTT/jitter-only case.

Each scenario is now tested against three generated content profiles, because QoS that passes on one easy synthetic picture is not enough:

- `motion`: baseline gradient plus a moving object.
- `low_motion`: low-detail, slow-motion content that should preserve quality and avoid unnecessary drops.
- `detail_motion`: stable high-detail texture plus motion, used to catch over-aggressive FPS/bitrate decisions without turning the input into an unrealistic per-frame flashing stress pattern.

The matrix now compares two backend families:

- `lightweight`: SDK fallback estimator plus SDK H264 jitter player.
- `webrtc`: WebRTC GoogCC bridge plus WebRTC H264 video jitter bridge, while keeping SDK pacer/NACK/server recovery.

For each backend, it compares:

- `adaptive`: current QoS decision applies bitrate and FPS reduction.
- `balanced`: bitrate adapts, FPS is kept at least 10fps.
- `bitrate_only`: bitrate adapts, FPS remains 30fps.
- `fixed`: no bitrate/FPS adaptation.

The script writes `${LOG_DIR}/metrics.jsonl` and `${LOG_DIR}/summary.json`. `MATRIX_RUNS=N` repeats every content/scenario pair with deterministic weak-network seeds (`network_seed=run`) so failures are reproducible and the summary can report both aggregate and worst-case behavior. It reports two objective functions rather than a single ambiguous "best":

- `smoothness_score`: freezes, max freeze duration, network drops, weak-phase receiver FPS, and recovery FPS.
- `balanced_qoe_score`: `smoothness_score` plus stronger penalties for duplicate output frames, network drops, render deadline misses, real FFmpeg H264 decode errors, decoded-frame gaps, low decoded-frame PSNR, high receiver frame latency, high jitter-buffer residence time, weak-network non-adaptation, slow adaptation response, and failure to recover target bitrate/FPS when the route becomes good again. This prevents a strategy that repeats low-information frames, misses the playout deadline, outputs undecodable frames, visibly degrades picture quality, builds seconds of queue, reacts too slowly, or refuses to adapt from being marked best just because it does not visibly freeze.

The matrix now has hard validation rules when the WebRTC backend is available:

- `webrtc/adaptive` must produce `decode_errors=0` in every run/content/scenario.
- `webrtc/adaptive` must produce one source-aligned PSNR sample for every receiver frame in every run/content/scenario.
- `webrtc/adaptive` must keep `psnr_avg >= 20.0 dB` and `psnr_min >= 14.0 dB` in every run/content/scenario.
- `webrtc/adaptive` must produce one frame-latency and jitter-buffer sample for every receiver frame, with `frame_latency_max_ms <= 1800` and `jitter_buffer_max_ms <= 1200`.
- `webrtc/adaptive` must keep `freeze_count <= 3` and `max_freeze_ms <= 2000` in every run/content/scenario.
- `webrtc/adaptive` must keep render deadline misses within `<= 3` frames and `<= 2%` of render candidates per run/content/scenario.
- `webrtc/adaptive` must meet per-run/per-content/per-scenario weak-network downshift and good-network recovery thresholds for bitrate and FPS.
- `webrtc/adaptive` must meet per-phase adaptation response-time thresholds after entering outage, poor, and good-again phases.
- `webrtc/adaptive` must be the best or tied-best `balanced_qoe_score` candidate in every run/content/scenario.
- The aggregate best `balanced_qoe_score` across all seeded cases must also be `webrtc/adaptive`.
- Negative controls such as `bitrate_only` and `fixed` are allowed to fail their individual demo thresholds, but their summaries are still collected and scored.

Latest local seeded long-stream QoE result (`MATRIX_RUNS=1`, 320x180, 3 content profiles, 5 scenarios, 15 cases per backend/strategy):

| Content | Scenario | WebRTC/adaptive score | Freeze / max ms | Drops | PSNR avg/min | Max latency/jitter ms | Decode errors |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| motion | walking_dead_zone | 0.000 | 0 / 0 | 0 | 58.57 / 23.66 | 1280 / 730 | 0 |
| motion | jitter_loss_oscillation | 30.000 | 0 / 0 | 10 | 58.06 / 29.31 | 445 / 420 | 0 |
| motion | bandwidth_staircase | 0.000 | 0 / 0 | 0 | 62.03 / 54.11 | 885 / 330 | 0 |
| motion | rtt_jitter_spike_recover | 0.000 | 0 / 0 | 0 | 59.44 / 24.49 | 710 / 415 | 0 |
| motion | loss_burst_recover | 33.000 | 0 / 0 | 11 | 61.02 / 25.95 | 455 / 320 | 0 |
| low_motion | walking_dead_zone | 241.000 | 1 / 1410 | 0 | 60.54 / 24.78 | 930 / 495 | 0 |
| low_motion | jitter_loss_oscillation | 30.000 | 0 / 0 | 10 | 59.96 / 26.69 | 430 / 410 | 0 |
| low_motion | bandwidth_staircase | 0.000 | 0 / 0 | 0 | 61.34 / 26.02 | 765 / 410 | 0 |
| low_motion | rtt_jitter_spike_recover | 0.000 | 0 / 0 | 0 | 61.24 / 25.84 | 680 / 350 | 0 |
| low_motion | loss_burst_recover | 36.000 | 0 / 0 | 12 | 62.33 / 28.20 | 445 / 250 | 0 |
| detail_motion | walking_dead_zone | 0.000 | 0 / 0 | 0 | 49.59 / 42.48 | 1445 / 485 | 0 |
| detail_motion | jitter_loss_oscillation | 43.336 | 0 / 0 | 10 | 46.36 / 15.33 | 950 / 435 | 0 |
| detail_motion | bandwidth_staircase | 0.000 | 0 / 0 | 0 | 49.58 / 41.90 | 1480 / 345 | 0 |
| detail_motion | rtt_jitter_spike_recover | 0.000 | 0 / 0 | 0 | 49.75 / 22.62 | 1305 / 535 | 0 |
| detail_motion | loss_burst_recover | 42.000 | 0 / 0 | 14 | 50.70 / 43.13 | 1060 / 410 | 0 |

Latest aggregate ranking:

| Backend/strategy | Aggregate balanced QoE | PSNR avg/min | Latency avg/max ms | Jitter-buffer avg/max ms | Decode errors | Drops | Deadline drops | Failed cases |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| webrtc/adaptive | 455.336 | 56.84 / 15.33 | 131.9 / 1480 | 41.1 / 730 | 0 | 67 | 0 | 0 |
| webrtc/balanced | 3342.996 | 56.85 / 15.33 | 138.8 / 1480 | 41.4 / 665 | 0 | 67 | 0 | 0 |
| lightweight/adaptive | 11001.106 | 27.47 / 14.30 | 103.0 / 1790 | 9.0 / 435 | 74 | 67 | 7 | 3 |
| lightweight/balanced | 14101.567 | 26.11 / 7.65 | 100.7 / 1795 | 8.5 / 240 | 80 | 64 | 3 | 0 |
| webrtc/bitrate_only | 41023.278 | 52.95 / 15.46 | 165.6 / 890 | 48.4 / 430 | 0 | 104 | 0 | 0 |
| lightweight/bitrate_only | 53477.620 | 25.98 / 14.30 | 135.9 / 1595 | 6.3 / 75 | 69 | 105 | 0 | 0 |
| lightweight/fixed | 146617.730 | 25.14 / 10.98 | 179.6 / 1800 | 5.5 / 105 | 64 | 8284 | 492 | 0 |
| webrtc/fixed | 166487.944 | 59.16 / 14.97 | 302.7 / 1800 | 48.1 / 1175 | 0 | 8565 | 1437 | 0 |

The current conclusion is deliberately bounded: this proves the best strategy only inside the defined scenario set, content set, candidate set, backend set, seed set, video profiles, and objective function. It does not prove a global production optimum. It does show that the target `webrtc` backend now closes the required control loops: periodic GoogCC process ticks, `data_in_flight`, probe clusters, route-change recovery with a server-declared healthy-route start bitrate, capacity-aware server `SENDER_RATE_CAP_V1`, smoothed loss-driven FPS adaptation, WebRTC H264 jitter output that survives real FFmpeg decoding with source-aligned PSNR checks, and receiver-side render deadline accounting. Under the current 3-content/5-scenario synthetic dynamic weak-network matrix, `webrtc/adaptive` is the best aggregate balanced-QoE candidate with `decode_errors=0` and `failed_cases=0`.

720p targeted profile status:

```bash
bash webrtc_qos_sdk/scripts/run_long_stream_qoe_720p_profile.sh
```

This profile intentionally raises the validation bar to 1280x720, start 2.5Mbps, max 5Mbps, and recovered-route start 3.5Mbps. The latest local run passed with `validation_failures=0`; `webrtc/adaptive` is the best aggregate balanced-QoE candidate. The important fix was making the server rate cap capacity-aware for all downlink capacities below the sender maximum, not only for sub-1Mbps links. Without that, the sender could recover to 5Mbps while the simulated server->receiver route could only carry 4Mbps.

| Content | Scenario | Freeze / max ms | Drops | Deadline drops | PSNR avg/min | Max latency/jitter ms | Decode errors |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| motion | walking_dead_zone | 0 / 0 | 0 | 0 | 54.92 / 24.99 | 1725 / 755 | 0 |
| motion | jitter_loss_oscillation | 0 / 0 | 10 | 0 | 54.39 / 26.57 | 940 / 695 | 0 |
| motion | bandwidth_staircase | 0 / 0 | 0 | 0 | 57.59 / 45.09 | 1700 / 435 | 0 |
| motion | rtt_jitter_spike_recover | 0 / 0 | 0 | 0 | 58.44 / 49.93 | 1420 / 735 | 0 |
| motion | loss_burst_recover | 0 / 0 | 15 | 0 | 58.44 / 45.96 | 1040 / 520 | 0 |
| low_motion | walking_dead_zone | 0 / 0 | 0 | 0 | 65.59 / 23.83 | 1490 / 345 | 0 |
| low_motion | jitter_loss_oscillation | 0 / 0 | 10 | 0 | 66.37 / 24.57 | 680 / 415 | 0 |
| low_motion | bandwidth_staircase | 0 / 0 | 0 | 0 | 70.51 / 48.58 | 1480 / 430 | 0 |
| low_motion | rtt_jitter_spike_recover | 0 / 0 | 0 | 0 | 69.72 / 24.01 | 955 / 505 | 0 |
| low_motion | loss_burst_recover | 1 / 1095 | 15 | 0 | 72.01 / 32.39 | 840 / 370 | 0 |
| detail_motion | walking_dead_zone | 2 / 1220 | 0 | 2 | 41.33 / 29.35 | 1720 / 740 | 0 |
| detail_motion | jitter_loss_oscillation | 0 / 0 | 12 | 0 | 32.92 / 15.19 | 990 / 640 | 0 |
| detail_motion | bandwidth_staircase | 1 / 1140 | 0 | 1 | 41.81 / 23.16 | 1790 / 860 | 0 |
| detail_motion | rtt_jitter_spike_recover | 1 / 1440 | 0 | 0 | 41.06 / 24.84 | 1550 / 730 | 0 |
| detail_motion | loss_burst_recover | 0 / 0 | 16 | 0 | 42.12 / 35.32 | 975 / 625 | 0 |

720p aggregate ranking:

| Backend/strategy | Aggregate balanced QoE | PSNR avg/min | Latency avg/max ms | Jitter-buffer avg/max ms | Decode errors | Drops | Deadline drops | Failed cases |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| webrtc/adaptive | 1553.297 | 55.52 / 15.19 | 194.9 / 1790 | 60.2 / 860 | 0 | 78 | 3 | 0 |
| webrtc/balanced | 4623.130 | 55.75 / 15.19 | 192.0 / 1790 | 60.2 / 860 | 0 | 78 | 3 | 0 |
| webrtc/bitrate_only | 41478.500 | 51.19 / 17.02 | 195.5 / 1280 | 61.7 / 615 | 0 | 95 | 1 | 0 |
| webrtc/fixed | 278640.500 | 58.19 / 39.31 | 141.3 / 1650 | 52.5 / 1190 | 0 | 46374 | 1001 | 0 |

This is still not a production-global optimum. The tightest 720p cases are `detail_motion/walking_dead_zone` and `detail_motion/bandwidth_staircase`: they pass, but their max latency is close to the 1800ms threshold and they can require render deadline drops. The most important fix after this profile was correcting video RTP timestamp generation to follow capture time at 90kHz rather than always incrementing as if the source were fixed 30fps. Without that, FPS downshift during weak-network phases made receiver/jitter timing less faithful and pushed the hardest `detail_motion/bandwidth_staircase` recovery case over the freeze/deadline gates.

720p multi-seed stability profile:

```bash
bash webrtc_qos_sdk/scripts/run_long_stream_qoe_720p_stability.sh
```

This profile fixes the candidate set to `webrtc/adaptive` and repeats the 720p content/scenario matrix across three deterministic network seeds. It is not a strategy comparison; it is a stability gate for checking whether the 720p single-run pass was accidental.

Latest local stability result (`MATRIX_RUNS=3`, 3 content profiles, 5 scenarios, 45 total cases):

| Backend/strategy | Cases | Aggregate balanced QoE | PSNR avg/min | Max latency/jitter ms | Decode errors | Drops | Deadline drops | Failed cases | Validation failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| webrtc/adaptive | 45 | 3668.548 | 56.140 / 15.673 | 1800 / 895 | 0 | 212 | 3 | 0 | 0 |

Important boundary samples from the stability run:

- The maximum frame latency still reaches the 1800ms gate in one seeded case, so latency margin is not yet generous.
- `detail_motion/bandwidth_staircase` remains the hardest recovery case after the RTP timestamp fix: worst seeded run is `run=2`, `freeze=1`, `max_freeze_ms=1765`, `render_deadline_drops=3`, `frame_latency_max_ms=1710`, `jitter_buffer_max_ms=895`, and `psnr_avg=42.341`.
- `detail_motion/rtt_jitter_spike_recover` can drop to `psnr_min ~= 15.67 dB`, which is above the current hard floor but still visually fragile.

The current 720p evidence is therefore stronger than a one-off demo pass: hard validation passes across 45 seeded cases with no decode errors, no duplicate output frames, no validation failures, and only 3 total render deadline drops. It still does not prove global optimum. The migration from in-process SFU-like validation to a real process topology has started: `run_udp_long_stream_smoke.sh` proves `sender -> server -> receiver` over UDP with real TWCC/RR/downlink-quality/NACK/rate-cap feedback and real H264 decode/PSNR, and `run_udp_long_stream_matrix.sh` now proves live encoder bitrate/FPS downshift and recovery across three real UDP weak-network profiles. The next proof step is to move the full seeded 720p QoE matrix into this real UDP topology with UDP/netem or an equivalent link emulator, then add longer mobile traces, multiple receive clients, renderer freeze metrics, and stricter recovery-margin metrics rather than only checking whether the current thresholds pass.

UDP weak-network matrix:

```bash
RUNS=3 bash webrtc_qos_sdk/scripts/run_udp_netem_matrix.sh
```

This runs baseline/drop, burst loss, reorder, delay, jitter, and mixed damage scenarios repeatedly and checks TWCC, RTCP RR, NACK, retransmission, PLI forwarding, IDR resend, sender rate cap, and recovered frame count from the logs.
It also writes machine-readable metrics:

- `${LOG_DIR}/metrics.jsonl`: one JSON object per scenario run.
- `${LOG_DIR}/summary.json`: aggregate min/max/avg values for frames, RTT, final bitrate, retransmission success ratio, observed loss, reported loss, and jitter.
- Threshold failures include missing feedback/RR/rate-cap/PLI/NACK/retransmission, insufficient recovered frames, missing keyframes, max frame gap above 34ms, missing reorder/delay/jitter observation, and failed rate-cap application.

Latest local UDP QoE/QoS result:

| Scenario | Observed impairment | Expected frames | Actual frames | Expected keyframes | Actual keyframes | Expected max frame gap | Actual max frame gap | Expected retransmit ratio | Actual retransmit ratio | Result |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| baseline_single_loss | drop=1 reorder=0 delay=0 jitter=0 | >=3 | 3 | >=1 | 3 | <=34ms | 33.33ms | >=1.0 | 1.00 | PASS |
| burst_loss | drop=2 reorder=0 delay=0 jitter=0 | >=3 | 3 | >=1 | 3 | <=34ms | 33.33ms | >=1.0 | 2.00 | PASS |
| reorder_only | drop=1 reorder=1 delay=0 jitter=0 | >=3 | 3 | >=1 | 3 | <=34ms | 33.33ms | >=1.0 | 1.00 | PASS |
| delay_only | drop=1 reorder=0 delay=2 jitter=0 | >=3 | 3 | >=1 | 3 | <=34ms | 33.33ms | >=1.0 | 1.50 | PASS |
| jitter_periodic | drop=1 reorder=0 delay=0 jitter=3 | >=3 | 3 | >=1 | 3 | <=34ms | 33.33ms | >=1.0 | 1.33 | PASS |
| mixed_loss_reorder_delay_jitter | drop=2 reorder=2 delay=1 jitter=3 | >=3 | 3 | >=1 | 3 | <=34ms | 33.33ms | >=1.0 | 1.67 | PASS |

This UDP Phase-1a QoE definition is intentionally minimal and measurable before a real renderer exists: the receiver must recover frames, output keyframes, keep RTP timestamp frame gaps within one 30fps frame interval, and complete retransmission-based recovery. The long-stream QoE matrix above already adds real H264 decode, PSNR, frame-latency proxy, and jitter-buffer residence proxy; after renderer integration these proxy metrics should be replaced or supplemented with real freeze duration, render queue depth, and glass-to-glass latency.

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
It also runs the dynamic QoS adaptation matrix and, when present, the FFmpeg/libx264 encoder demo plus the long-stream QoE strategy matrix.

`verify_cmake_package.sh` verifies external projects can consume `/root/output` via `find_package(WebRtcQosSdk CONFIG REQUIRED)` and link module targets such as `WebRtcQosSdk::webrtc_qos_transport`.
It also verifies optional WebRTC adapter targets such as `WebRtcQosSdk::webrtc_qos_googcc_adapter` and `WebRtcQosSdk::webrtc_qos_video_jitter_adapter` when those archives are present, plus optional FFmpeg encoder/decoder targets when FFmpeg is installed.

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
- `run_udp_long_stream_smoke.sh` proves a real three-process UDP long-stream path with H264 encode/decode, TWCC, RTCP RR, receiver downlink quality, NACK retransmission, sender rate cap, PSNR, and duplicate completed-frame rejection.
- `run_udp_long_stream_matrix.sh` proves real three-process dynamic weak-network adaptation with the server kept as a minimal relay/test harness: sender bitrate/FPS downshift under weak phases, cap removal and FPS recovery under good phases, receiver interval quality reporting, no decoder errors, seeded deterministic drop/jitter variation, and quantitative PSNR/completion-gap/media-gap gates.
- `run_udp_long_stream_720p_profile.sh` provides the faster 1280x720 endpoint QoS gate, while `run_udp_long_stream_720p_stability.sh` repeats it across 3 content profiles and 3 deterministic network seeds with live encoder reconfiguration, atomic access-unit pacing, NACK recovery, PSNR validation, and separate low-latency completion-gap versus media-gap accounting.
- `run_udp_netem_matrix.sh` proves the UDP C/S chain survives repeated drop/reorder/delay scenarios and catches duplicate-frame regressions.
- `run_dynamic_qos_matrix.sh` proves the sender adaptation surface reacts in both directions: it degrades under bandwidth/RTT/loss impairment and climbs back when the network recovers.
- `ffmpeg_encoder_demo` proves real H264 encoder output can enter the same Annex-B -> RTP -> pacer path used by synthetic/file demos.
- `libwebrtc_qos_ffmpeg_decoder.a` and `run_long_stream_qoe_matrix.sh` prove receiver Annex-B AU output can be decoded by a real H264 decoder before it is counted as a QoE receiver frame, and compute source-aligned I420 PSNR for objective picture quality.
- `run_long_stream_qoe_matrix.sh` compares adaptive, balanced, bitrate-only, and fixed strategies with real H264 output over dynamic weak-network transitions and separates smoothness-only scoring from balanced QoE scoring with decode-error and PSNR penalties.
- `run_udp_soak.sh` repeats the weak-network matrix by duration and provides the local soak/stress entry point before replacing `DEMO_TRANSPORT_V1`.
- `verify_role_linking.sh` proves role-based integration can avoid a monolithic `libwebrtc.a`.

Metric references:

- W3C WebRTC Stats defines receiver-side video freeze, total freeze duration, jitter buffer delay, packet discard, NACK, and sender-side target bitrate, FPS, encoded frames, keyframes, QP, encode time, packet send delay, and quality-limitation fields: https://www.w3.org/TR/webrtc-stats/
- LiveKit's connection-quality calculation is a useful SFU-side reference: its knowledge-base article describes packet loss, video layer delivery, and bitrates as the active quality components, with jitter/RTT currently disabled in that packet-score path: https://kb.livekit.io/articles/2455399507-how-is-connection-quality-determined
