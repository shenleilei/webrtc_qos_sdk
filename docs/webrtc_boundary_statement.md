# WebRTC 边界声明

本文档只回答一个问题：

```text
当前 SDK 里，哪些能力已经明确交给 WebRTC，
哪些能力仍然由我们自己承担，
以及后续应继续往哪个方向收敛。
```

这不是 marketing 文档，也不是 roadmap 文档，而是一份当前实现边界的说明。

## 1. 目标原则

当前项目的核心原则始终不变：

- **能用 WebRTC 做的，就优先用 WebRTC 做**
- **只有 transport plane 和 control plane 由我们自己做**
- **不要再造一套自研 media plane**

更具体地说：

### 我们自己做

- socket / UDP / QUIC
- 包收发
- C/S relay / router 拓扑
- session / source / receiver 管理
- receiver 订阅关系
- sender cap 控制消息
- 业务策略、权限、鉴权

### 尽量由 WebRTC 做

- sender / receiver 媒体语义
- track / SSRC
- RTP/RTCP
- NACK / PLI
- pacing
- GoogCC
- jitter / packet buffer

## 2. 当前实现的真实边界

当前代码已经不是“完全自研媒体栈”，但也**还没有**走到“完整原生 WebRTC
media-plane 直接接入”的终点。

更准确地说，当前处在一个中间态：

- **底层 QoS / RTP / RTCP / jitter 能力已经明显交给 WebRTC**
- **上层 sender/play/server 编排仍然有我们自己的 facade 和 glue**

## 3. 当前已经明确交给 WebRTC 的部分

以下能力当前已经直接依赖 WebRTC module 或 WebRTC adapter，而不是自研实现：

### 3.1 RTP / RTCP wire format

- RTP packet build / parse
- RTCP `SR / RR / TWCC / NACK / PLI`
- H264 RTP payload packetization / depacketization

对应：

- `libwebrtc_qos_webrtc_rtp_rtcp.a`
- `googcc_adapter.h`
- `rtcp_adapter.h`
- `rtp_packet_adapter.h`
- `h264_rtp_adapter.h`

### 3.2 Sender QoS

- uplink `GoogCC`
- `PacingController`
- probe / padding / retransmission priority

对应：

- `libwebrtc_qos_webrtc_googcc.a`
- `libwebrtc_qos_webrtc_pacing.a`

### 3.3 Receiver 恢复与 jitter

- `NackRequester`
- video jitter / packet buffer

对应：

- `libwebrtc_qos_webrtc_nack_requester.a`
- `libwebrtc_qos_webrtc_video_jitter.a`

## 4. 当前仍然由我们自己承担的部分

这部分是当前实现里最需要大家看清楚的地方。

### 4.1 Transport Plane

这部分明确仍然是我们的职责：

- `TransportOutput`
- 自定义 RTP/RTCP bytes 收发
- server relay / router
- UDP demo / 自定义 transport demo

当前没有把这些交给 WebRTC：

- `PeerConnection`
- `ICE`
- `DTLS`
- `SRTP`
- WebRTC socket ownership

### 4.2 Control Plane

这部分也仍然是我们的职责：

- `receiver_id`
- `source_id`
- `track_id`
- sender cap 控制消息
- receiver 订阅关系
- session / room / source 管理

### 4.3 当前多 track 编排仍然是我们自己在做

这点非常关键。

虽然当前 QoS 底座已经是 WebRTC 的，但 **当前这条默认 multi-track / multi-SSRC
能力基线，还不是“直接把 WebRTC 原生 sender/track/transceiver 对象模型拿来就用”**。

当前 multi-track 相关能力，仍然有我们自己的 orchestrating layer：

- `SessionConfig.video_tracks`
- `source_id / track_id / sender_ssrc`
- shared source-level `GoogCC / pacer`
- per-track packet history
- per-track adaptation / snapshot 查询
- server 侧按 sender SSRC 区分 track 身份

其中 track 数量的唯一来源就是 `SessionConfig.video_tracks` 本身，
而不是另一个“track_count 模式开关”。

对应代码：

- [session_config.h](../include/webrtc_qos/session_config.h)
- [types.h](../include/webrtc_qos/types.h)
- [video_push_client_webrtc.cc](../src/video_push_client_webrtc.cc)
- [video_play_client_webrtc.cc](../src/video_play_client_webrtc.cc)
- [server_qos_router_webrtc.cc](../src/server_qos_router_webrtc.cc)

所以，如果有人问：

```text
“现在的多 track QoS 是不是已经完全直接用了 WebRTC 暴露出来的高层接口？”
```

当前最准确的回答是：

```text
不是完全直接。
底层 QoS / RTP / RTCP / jitter 已经是 WebRTC，
但多 track 的 public model 和当前 source-level 编排，仍然有我们自己的 glue。
```

## 5. 当前没有引入的 WebRTC 高层对象模型

当前我们**没有**直接把下面这些完整引进来：

- `RTCPeerConnection`
- `RTCRtpTransceiver`
- `RTCRtpSender`
- `MediaStreamTrack`
- 浏览器式 signaling / SDP / transceiver lifecycle

这意味着：

- 我们现在**不是**完整 PeerConnection 路线
- 也**不是**浏览器对象模型的一比一镜像

## 6. Phase-4A 的当前结论

当前默认 multi-track 能力基线已经做到：

- multi-track / multi-SSRC public model 初步落地
- shared source-level `GoogCC / pacer`
- per-track push/play/server 状态隔离
- 外部 consumer 可验证
- 仓库内默认 loopback demo 和 UDP selftest 也会同时覆盖 single-track 与
  dual-track 两组场景，并在输出中显式报告 `decoded_tracks`
- 现有 single-track smoke/qoe/production 短时门禁未回归

当前仍未做到：

- 完整原生 WebRTC media-plane 对象模型直接接入
- multi-receiver fanout support 层
- 更系统化的 multi-track QoE / soak 门禁

## 7. 后续收敛方向

后续继续推进时，边界应该继续向这个方向收敛：

1. transport plane 仍然由我们自己做
2. control plane 仍然由我们自己做
3. media plane 尽量进一步向 WebRTC 原生 sender / receiver / track 语义靠拢

换句话说，后面不应该：

- 再引回自研 RTP/RTCP/pacer/jitter
- 把 Phase-4 做成一套更重的自定义 media-plane

而应该：

- 在保持 C/S 自定义 transport 的前提下
- 尽量减少我们自己对 sender / track / receiver 媒体编排的重新发明

## 8. 一句话结论

当前仓库的真实边界可以概括成：

```text
QoS / RTP / RTCP / jitter 底座已经明显交给 WebRTC，
transport 与 control plane 仍由我们自己掌握，
多 track 的 media-plane 编排还处在“我们自己的 glue + WebRTC 底层能力”阶段，
后续应继续朝“保留原生 WebRTC media-plane”收敛。
```
