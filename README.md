# WebRTC QoS SDK

一个面向 Linux native C/S 架构的 WebRTC-first QoS SDK。它不是完整 WebRTC Client、PeerConnection 或 SFU，而是把 WebRTC 里已经成熟的弱网 QoS 能力裁剪出来，放到业务自定义 UDP 传输里使用。

## 这个项目解决什么

很多业务已经有自己的 UDP socket、房间协议、鉴权、调度和服务端链路，但又不想自己维护 RTP/RTCP、NACK、pacing、jitter buffer、带宽估计和弱网恢复策略。

这个 SDK 的目标是：

- 业务继续掌控自己的 UDP socket 和传输协议。
- SDK 提供 sender / server / receiver 三个角色 facade。
- QoS 核心复用 WebRTC 的成熟模块，而不是重新造一套 RTP/RTCP/NACK/pacer。
- 对外集成面尽量小：接入方只需要把 UDP 收发接到 `TransportOutput` 和角色输入接口，再按角色调用 `VideoPushClient`、`ServerQosRouter`、`VideoPlayClient`。

## 我们做什么，不做什么

做：

- WebRTC RTP/RTCP packet build/parse。
- H264 RTP packetization / depacketization。
- TWCC、SR/RR、PLI、NACK。
- WebRTC NackRequester、PacingController、GoogCC、video jitter buffer adapter。
- sender / server / receiver 三角色 facade。
- 多 track / 多 SSRC 基线，shared source cap，per-track snapshot。
- P5 可观测性：文件日志、metrics、alerts、debug bundle、release evidence、completion audit。
- 最小 UDP 外部样板，验证业务只接 UDP 和 facade 也能跑通。

不做：

- 不做完整 PeerConnection。
- 不做 ICE / DTLS / SRTP / SCTP / SDP signaling。
- 不做 SFU 产品。
- 不做 P5 以前的多接收端 fanout 产品化。
- 不保留自研 RTP/RTCP/NACK/pacing/video jitter public API。
- 当前不支持 RTX、FEC、ULPFEC、FlexFEC、RED。

## 当前结果

P5 生产门禁已经完成，最终状态：

- `phase5_production_gate_status=pass`
- `phase5_completion_status=complete`
- `phase5_completion_audit=pass`

核心弱网效果：

| 场景 | QoS 表现 | QoE 表现 |
| --- | --- | --- |
| 720p baseline | RTP drop / NACK / retransmission 都为 `0`，renderer proxy max latency `350ms` | `32/32 pass`，`playable_ratio_min=0.9833`，`avg_psnr_y_min=31.749`，`avg_ssim_y_min=0.8137` |
| 720p 弱网降级恢复 | 弱网窗口内降到 `10.3279 AU/s`、`109.672 RTP pps`、`<=750kbps`、`10fps`，恢复时间 `0ms` | `32/32 pass`，`playable_ratio_min=0.9625`，`avg_psnr_y_min=31.815`，`avg_ssim_y_min=0.8166`，decode/freeze/render drop 都为 `0` |
| RTP 丢包恢复矩阵 | burst loss：`19` 个 RTP drop 触发 `19` 个 NACK 和 `19` 次重传；dead-zone：`33` 个 RTP drop 后仍恢复 | protocol/facade 层 `playable_ratio=1`，用于证明 NACK/重传链路有效 |

完整场景参数、延迟、丢包、抖动和 QoS/QoE 明细见：

- [弱网场景 QoS/QoE 结果](docs/weak_network_qos_qoe_results.md)

当前机器没有 GPU / 显示环境，也没有真实生产采集素材库，所以 P5 对 real renderer 和 capture library 使用显式 policy skip：

- `real_renderer_status=skipped_by_policy`
- `policy=p5_no_gpu_display_environment`
- `capture_manifest_verification=skipped_by_policy`
- `policy=p5_no_production_capture_data`

严格生产验收时，把 skip 关掉，并使用真实显示环境和真实采集素材：

```bash
P5_SKIP_REAL_RENDERER=0 \
P5_SKIP_CAPTURE_LIBRARY=0 \
SOAK_MINUTES=120 \
MIN_PRODUCTION_SOAK_MINUTES=120 \
scripts/run_phase5_production_gate.sh
```

## 最小集成方式

业务侧只需要把自己的 UDP socket 接到 SDK 的 `TransportOutput` 回调：

```cpp
webrtc_qos::VideoPushClientConfig push_config;
push_config.session = session;
push_config.transport_output =
    [&](const webrtc_qos::TransportPacketView& packet) {
      return SendUdp(server_addr, EncodeWirePacket(packet));
    };

auto push = webrtc_qos::CreateVideoPushClient(push_config);
push->Start();
```

server 和 play 也是同一个模式：

```cpp
server_config.sender_output = SendUdpToSender;
server_config.receiver_output = SendUdpToReceiver;
play_config.transport_output = SendUdpToServer;

auto server = webrtc_qos::CreateServerQosRouter(server_config);
auto play = webrtc_qos::CreateVideoPlayClient(play_config);
```

业务输入 H264 Annex-B access unit，SDK 输出 RTP/RTCP/control bytes。业务收到 UDP 包后，按包类型投递给对应角色：

- sender 收 server 反馈：`push->OnTransportFeedback()` 或 `push->OnSenderRateCap()`。
- server 收 sender 上行：`server->OnSenderRtp()` 或 `server->OnSenderRtcp()`。
- server 收 receiver 反馈：`server->OnReceiverRtcp()`。
- receiver 收 server 下行：`play->OnRtpPacket()` 或 `play->OnRtcpPacket()`。

详细代码看：

- [最小 UDP 集成最佳实践](docs/minimal_udp_integration_best_practice.md)
- [最小 UDP 外部样板](examples/minimal_udp_app)

## 发布内容

默认发布 sender / play / server 三类角色库，以及裁剪后的 WebRTC QoS 模块库。接入方可以按角色链接，也可以直接使用角色 bundle，避免自己关心底层 archive 组合。

完整库清单和 CMake target 见 [完整实现说明](IMPLEMENTATION_GUIDE.md)。

## 快速构建

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
cmake --install build --prefix /root/output
```

默认要求仓库内 `dist/linux-x86_64` 已包含 WebRTC modules。新机器上先参考：

- [WebRTC 子模块拆分编译说明](docs/webrtc_module_split_build.md)

## 验证入口

实现门禁：

```bash
scripts/run_phase5_implementation_gate.sh
```

P5 生产门禁：

```bash
P5_SKIP_REAL_RENDERER=1 \
P5_SKIP_CAPTURE_LIBRARY=1 \
SOAK_MINUTES=10 \
MIN_PRODUCTION_SOAK_MINUTES=10 \
scripts/run_phase5_production_gate.sh
```

完成度审计：

```bash
PHASE5_GATE_DIR=/path/to/phase5_gate \
REQUIRE_PRODUCTION_EVIDENCE=1 \
scripts/verify_phase5_completion_audit.sh
```

## 详细文档

- [完整实现说明](IMPLEMENTATION_GUIDE.md)
- [弱网场景 QoS/QoE 结果](docs/weak_network_qos_qoe_results.md)
- [mediasoup-cpp plainclient WebRTC QoS SDK 重构方案](docs/mediasoup_plainclient_webrtc_qos_refactor.md)
- [WebRTC QoS 总览与 SDK 设计说明](docs/webrtc_qos_overview.md)
- [WebRTC 边界声明](docs/webrtc_boundary_statement.md)
- [QoS 测试与验证方法](docs/qos_test_validation_methodology.md)
- [推拉客户端 SDK 集成说明](docs/sdk_push_play_integration.md)
- [Phase-5 生产集成化、可观测性与日志体系计划](webrtc_first_phase5_plan.md)
