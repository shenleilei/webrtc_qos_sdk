# WebRTC QoS SDK Phase-1a Output

This directory is the install layout promised by `webrtc_qos_sdk_design.md`.

```text
output/
  include/webrtc_qos/
  lib/libwebrtc_qos.a
  lib/libwebrtc_qos_core.a
  lib/libwebrtc_qos_rtp.a
  lib/libwebrtc_qos_rtcp.a
  lib/libwebrtc_qos_feedback.a
  lib/libwebrtc_qos_transport.a
  lib/libwebrtc_qos_nack.a
  lib/libwebrtc_qos_pacer.a
  lib/libwebrtc_qos_video.a
  lib/libwebrtc_qos_googcc_bridge.a
  lib/libwebrtc_qos_googcc_adapter.a
  lib/libwebrtc_qos_video_jitter_bridge.a
  lib/libwebrtc_qos_video_jitter_adapter.a
  lib/cmake/WebRtcQosSdk/
  demo/
```

Current Phase-1a scope:

- H264 video only.
- Annex-B access unit input and output.
- RTP payload type `96`, clock `90000 Hz`.
- Single NALU and FU-A only.
- TWCC RTP header extension id `1`.
- SDK lightweight `SenderPacer`.
- `DOWNLINK_QUALITY_V1` and `SENDER_RATE_CAP_V1` binary helpers.
- No audio, NetEq, Opus, camera capture, renderer, ICE, DTLS, SRTP, SDP, or PeerConnection.

Implementation boundary:

- H264 RTP, Annex-B access unit output, TWCC RTP header extension, lightweight pacing, and custom control message helpers are implemented.
- Retransmission cache keeps RTP identity stable and assigns a new transport sequence number on resend.
- Standard RTCP helpers are provided for SR, RR, TWCC transport feedback, Generic NACK, and PLI.
- Lightweight NACK recovery is packaged separately as `libwebrtc_qos_nack.a`.
- Production transport integration is packaged separately as `libwebrtc_qos_transport.a` with public header `include/webrtc_qos/transport_port.h`.
- `include/webrtc_qos/production_transport_adapter.h` provides a production integration template that copies borrowed SDK payloads into owned messages and classifies them into media/control/reliable-control lanes.
- WebRTC `network_control/goog_cc` is packaged separately as `libwebrtc_qos_googcc_adapter.a` with public header `include/webrtc_qos/googcc_adapter.h`.
- The optional facade bridge is packaged separately as `libwebrtc_qos_googcc_bridge.a` with public header `include/webrtc_qos/sender_qos_googcc_bridge.h`.
- WebRTC H264 video jitter is packaged separately as `libwebrtc_qos_video_jitter_adapter.a` with public header `include/webrtc_qos/video_jitter_adapter.h`.
- The optional video jitter facade bridge is packaged separately as `libwebrtc_qos_video_jitter_bridge.a` with public header `include/webrtc_qos/video_jitter_bridge.h`.
- The video jitter adapter uses the minimal useful WebRTC closure: H264 parsers plus `modules/video_coding::PacketBuffer`. It does not link full `rtp_rtcp`, full `api/video:rtp_video_frame_assembler`, libyuv, protobuf, Perfetto, or WebRTC pacer.
- `SenderQosController` has a default lightweight estimator, and applications that need real GoogCC link `libwebrtc_qos_googcc_bridge.a` plus `libwebrtc_qos_googcc_adapter.a`.
- `VideoJitterPlayer` has a default lightweight implementation, and applications that need WebRTC-backed jitter link `libwebrtc_qos_video_jitter_bridge.a` plus `libwebrtc_qos_video_jitter_adapter.a`.

Link by role:

- Push client: `libwebrtc_qos_core.a`, `libwebrtc_qos_rtp.a`, `libwebrtc_qos_rtcp.a`, `libwebrtc_qos_feedback.a`, `libwebrtc_qos_nack.a`, `libwebrtc_qos_pacer.a`, `libwebrtc_qos_video.a`, `libwebrtc_qos_googcc_bridge.a`, `libwebrtc_qos_googcc_adapter.a`.
- Server relay: `libwebrtc_qos_rtp.a`, `libwebrtc_qos_rtcp.a`, `libwebrtc_qos_feedback.a`, `libwebrtc_qos_nack.a`.
- Play client: `libwebrtc_qos_core.a`, `libwebrtc_qos_rtp.a`, `libwebrtc_qos_rtcp.a`, `libwebrtc_qos_feedback.a`, `libwebrtc_qos_nack.a`, `libwebrtc_qos_video.a`, `libwebrtc_qos_video_jitter_bridge.a`, `libwebrtc_qos_video_jitter_adapter.a`.
- Prototype: `libwebrtc_qos.a` plus `libwebrtc_qos_googcc_bridge.a` / `libwebrtc_qos_googcc_adapter.a` / `libwebrtc_qos_video_jitter_bridge.a` / `libwebrtc_qos_video_jitter_adapter.a` if real WebRTC adapters are needed.

CMake role targets:

- `WebRtcQosSdk::role_transport`: production transport boundary only.
- `WebRtcQosSdk::role_server`: RTP/RTCP/feedback/NACK server relay helpers.
- `WebRtcQosSdk::role_push`: H264 sender, pacer, feedback, and WebRTC GoogCC.
- `WebRtcQosSdk::role_play`: receiver QoS, H264 video jitter, and WebRTC PacketBuffer adapter.
- `WebRtcQosSdk::role_prototype`: unified facade plus optional WebRTC adapters for quick prototypes.

Binary and ABI boundary:

- This bundle targets Linux x86_64, ELF64, System V ABI.
- Core SDK, WebRTC GoogCC, and WebRTC H264 jitter consumers link the selected
  SDK archives plus `pthread`, `dl`, `rt`, and `atomic`.
- FFmpeg encoder/decoder archives are optional demo/QoE validation pieces. The
  CMake package creates those targets only when the target machine can find
  `avcodec`, `avutil`, and `swscale`.
- This is not independent of every Linux version. Static `.a` archives still
  depend on the target server's libc/libstdc++ ABI at final link/runtime.
- `SenderQosController`, `TransportPort`, and `VideoJitterPlayer` provide
  out-of-line destructor/move definitions in the SDK archives so external
  applications do not generate incompatible lifecycle code from headers.
- Before publishing this directory, verify it from the root repository with
  `PREFIX=/path/to/dist/linux-x86_64 bash scripts/verify_cmake_package.sh`.

Current runnable scope:

- The standalone SDK demos run a process-local H264 RTP/QoS/jitter/retransmission loopback.
- The GoogCC smoke runs the WebRTC `network_control/goog_cc` adapter and verifies rate output.
- The video jitter smoke runs the WebRTC-backed H264 `PacketBuffer` adapter and verifies complete Annex-B access unit output.
- `output_integration_demo` is built only from this installed `include + lib` layout and verifies role-based small-library linking.
- `udp_sender_demo` / `udp_server_demo` / `udp_receiver_demo` run a real local UDP C/S chain with `DEMO_TRANSPORT_V1`, intentional packet loss/reorder/delay, NACK, server retransmission, RTCP SR/RR, uplink TWCC, sender rate cap, and WebRTC-backed video jitter output.
- `run_udp_netem_matrix.sh` repeatedly validates baseline/drop, reorder, delay, and reorder+delay scenarios and checks recovered frame count, NACK, retransmission, PLI forwarding, IDR resend, RR, and rate cap from logs.
- `run_udp_soak.sh` repeats the weak-network matrix by duration and reports pass/fail counts for local soak validation.
- `verify_role_linking.sh` compiles separate push/server/play toy applications and verifies role-based small-library linking.
- `transport_port_demo` verifies that production transport can replace `DEMO_TRANSPORT_V1` by implementing send/deliver callbacks and copying borrowed payloads before async send.
- `production_transport_demo` verifies the production adapter template: RTP uses the unreliable media lane, RTCP uses the unreliable control lane, and rate-cap/control messages use the reliable control lane.
- `verify_cmake_package.sh` verifies external CMake projects can use `find_package(WebRtcQosSdk)` and link module targets.
- Optional adapter archives are exposed as CMake imported targets when present, including `WebRtcQosSdk::webrtc_qos_googcc_adapter` and `WebRtcQosSdk::webrtc_qos_video_jitter_adapter`.
- The remaining production integration work is implementing `transport_port.h` on top of the business transport protocol and then raising soak/stress duration, bitrate, and frame count. WebRTC `NackRequester` is not part of the Phase-1a main closure; it can be evaluated later as an optional heavy adapter.

Run:

```bash
./webrtc_qos_sdk/scripts/verify_phase1a.sh
./webrtc_qos_sdk/scripts/verify_cmake_package.sh
./output/demo/qos_loopback_demo
./output/demo/capture_push_demo
./output/demo/receive_play_demo
./output/demo/transport_port_demo
./output/demo/production_transport_demo
./output/demo/webrtc_qos_googcc_smoke
./output/demo/webrtc_qos_video_jitter_smoke
./output/demo/output_integration_demo
./webrtc_qos_sdk/scripts/run_udp_loopback_demo.sh
REORDER_RTP_SEQ=4 DELAY_MS=30 ./webrtc_qos_sdk/scripts/run_udp_loopback_demo.sh
./webrtc_qos_sdk/scripts/run_udp_netem_matrix.sh
DURATION_SEC=60 MATRIX_RUNS=1 ./webrtc_qos_sdk/scripts/run_udp_soak.sh
./webrtc_qos_sdk/scripts/verify_role_linking.sh
```

`qos_loopback_demo` intentionally drops one RTP packet, triggers recovery, retransmits from cache, and still outputs two Annex-B access units.
`webrtc_qos_video_jitter_smoke` verifies Single NALU and FU-A H264 packets through the WebRTC-backed jitter adapter and outputs complete Annex-B access units.
`output_integration_demo` verifies synthetic H264 AU -> SDK RTP packetizer -> lightweight pacer -> server cache/NACK recovery -> SenderQosController/GoogCC bridge -> VideoJitterPlayer/WebRTC jitter bridge.
`run_udp_loopback_demo.sh` starts the three UDP processes and verifies sender -> server -> receiver behavior over loopback UDP, including the demo envelope mapping layer and configurable weak-network simulation.

Transport integration boundary:

```bash
./output/demo/transport_port_demo
./output/demo/production_transport_demo
```

Production transport code should implement the `TransportPort` send/deliver callbacks and map SDK message types to the business wire protocol. `TransportMessage::payload` is a borrowed view valid only during the callback, so async socket/reliable-channel code must copy it before returning. `DEMO_TRANSPORT_V1` is only the UDP demo envelope; it is not required by the SDK.

`ProductionTransportAdapter` is the recommended starting template for production integration. It keeps `TransportPort` as the SDK boundary, creates owned payload copies for async queues, and routes message types as follows: RTP to unreliable media, RTCP SR/RR/TWCC/NACK/PLI to unreliable control, and `DOWNLINK_QUALITY_V1` / `SENDER_RATE_CAP_V1` / `BYE` to reliable control.

Weak-network metrics:

```bash
RUNS=3 bash webrtc_qos_sdk/scripts/run_udp_netem_matrix.sh
```

The matrix writes `${LOG_DIR}/metrics.jsonl` and `${LOG_DIR}/summary.json`. These files track recovered frames, RTT, final target bitrate, NACK/retransmission success ratio, observed loss, reported loss, and jitter. Threshold failures make the matrix fail instead of only printing logs.
