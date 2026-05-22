# WebRTC QoS 总览与 SDK 设计说明

本文档面向第一次接触本项目的读者。目标是先建立共同语言，再解释我们为什么不做完整 WebRTC Client，而是做一套运行在自定义 C/S 传输上的 WebRTC-first QoS SDK。

## 1. 这套东西解决什么问题

在实时音视频里，业务通常最怕 4 类问题：

- 带宽突然下降后，发送端还按原码率猛发，结果排队、卡顿、丢包连锁放大
- 链路抖动和乱序存在时，接收端不能稳定组帧，画面时好时坏
- 丢包发生后，没有及时重传或关键帧恢复，参考链被污染，后续长时间花屏
- 网络恢复后，发送端回升太慢或太快，体验依然不稳定

WebRTC 在这些问题上已经积累了成熟能力：

- 拥塞控制：`GoogCC`
- 收包反馈：`TWCC`、`RTCP RR`
- 发包节奏控制：`PacingController`
- 丢包恢复：`NACK / PLI`
- 视频接收缓冲：`PacketBuffer / video jitter`

我们的目标不是重新发明这些模块，而是把它们放进业务自己的 C/S 架构里使用。

## 2. 为什么不直接上完整 WebRTC Client

我们当前系统边界不是典型浏览器 P2P，而是：

- Linux native
- C/S 架构
- 业务自己掌握 socket、鉴权、会话映射、服务端策略
- 当前阶段只做 H264 视频 QoS/jitter 闭环

因此完整 `PeerConnection / ICE / DTLS / SRTP / SDP / STUN / TURN` 并不是当前必需能力。

我们的结论是：

- 传输、路由、会话、安全，业务自己掌握
- RTP/RTCP、QoS、恢复、jitter，尽量复用 WebRTC 原生能力
- 不交付完整 `libwebrtc.a`
- 不保留旧自研 RTP/RTCP/NACK/pacer/jitter 作为 fallback

## 3. WebRTC QoS 基础知识

### 3.1 拥塞控制

拥塞控制的目标不是“尽量发满”，而是：

- 在弱网进入时尽快下探
- 在网络恢复时稳定回升
- 避免队列积压把延迟拖爆

我们当前 sender 侧的核心输入输出是：

- 输入：
  - sender -> server 的 `TWCC`
  - sender <- server 的 `RTCP RR RTT`
  - 业务 route change
- 输出：
  - `target_bitrate_bps`
  - `pacing_bitrate_bps`
  - `request_keyframe`
  - `max_fps`

### 3.2 TWCC

`TWCC` 的作用是把“每个包什么时候发、什么时候到”反馈给 sender，让拥塞控制看到更细粒度的到达情况。

我们当前固定：

- header extension：`transport-wide-cc-01`
- extension id：`1`
- feedback 周期：`50ms`

为什么这么做：

- 周期太长，GoogCC 对突发带宽变化反应慢
- 周期太短，RTCP 开销增大，而且在当前 C/S 架构里没有必要压得比 `50ms` 更低

### 3.3 RTCP SR/RR

`SR/RR` 的角色和 `TWCC` 不一样。

- `TWCC` 看 packet arrival
- `RR` 主要给 sender 估 RTT

我们当前固定：

- `SR/RR` 周期：`1000ms`

为什么这么做：

- RTT 不是每个包都要更新
- 1 秒一级的 RTT 对 sender 侧控制和日志已经够用

### 3.4 Pacing

即使码率目标算对了，如果“发包节奏”不对，还是会出现瞬时爆发、排队和抖动。

我们当前直接复用 WebRTC `PacingController`，它负责：

- packet priority
- probe cluster
- retransmission 优先
- padding 生成

### 3.5 NACK / PLI

- `NACK`
  表示“我缺了哪些 RTP sequence number，请重传”
- `PLI`
  表示“当前参考链已经不可信，请尽快给一个关键帧”

我们当前的恢复策略是：

- receiver 优先发 `NACK`
- server 本地 history 命中时，优先本地重传
- server history miss 时，把 miss 的 packet ids 转发给 sender
- sender 收到 `PLI` 后，设置 `request_keyframe`

### 3.6 Jitter Buffer

视频包到达顺序不一定等于发送顺序。

接收侧必须处理：

- 乱序
- 抖动
- 分片重组
- Access Unit 完整性

我们当前复用 WebRTC H264 packet buffer / jitter 路径，输出完整 Annex-B AU 给业务解码器。

## 4. 我们支持什么，不支持什么

### 4.1 当前支持

- H264 only
- `packetization-mode=1`
- `Single NALU + FU-A`
- `profile-level-id=42e01f`
- `90000 Hz` RTP clock
- `TWCC + RTCP SR/RR + NACK + PLI`
- `NACK + 原 RTP 包重传`
- sender `GoogCC`
- WebRTC `PacingController`
- WebRTC `NackRequester`
- WebRTC video jitter/packet buffer
- C/S 自定义 RTP/RTCP/UDP bytes 边界
- sender / server / play 三角色 facade
- 当前工作区已落下第一条 Phase-4A 多 track 切片：
  一个 source 下多个 `track_id / sender_ssrc`、shared uplink `GoogCC / pacer`、
  per-track snapshot/adaptation 查询

### 4.2 当前不支持

- `PeerConnection`
- `ICE / DTLS / SRTP / SDP`
- 浏览器信令栈
- 音频闭环验收
- H264 之外的 codec
- `STAP-A`
- `B` 帧
- `RFC4588 RTX`
- `FEC / ULPFEC / FlexFEC / RED`
- 任意 RTCP block 的透明 relay
- 业务侧直接操作 WebRTC 内部对象

### 4.3 为什么这么取舍

因为当前阶段的目标是：

- 先把 H264 视频 QoS/jitter 闭环做稳
- 先证明弱网进入、恢复、持续弱网、弱网起步、多接收端策略这些关键行为
- 把复杂度压在真正影响体验的地方，而不是完整会话层

## 5. 当前整体架构

### 5.1 总体链路

```text
Encoded H264 Annex-B AU
  -> VideoPushClient
      -> WebRTC H264 packetizer
      -> WebRTC RTP/RTCP
      -> WebRTC GoogCC
      -> WebRTC PacingController
  -> business transport bytes
  -> ServerQosRouter
      -> uplink TWCC / RR / NACK / PLI route
      -> local packet history / local retransmission
      -> sender rate cap
  -> business transport bytes
  -> VideoPlayClient
      -> WebRTC RTP/RTCP
      -> WebRTC NackRequester
      -> WebRTC video jitter
      -> Annex-B AU
  -> decoder / renderer / QoE harness
```

### 5.2 分层架构

```text
业务层
  负责：
  - socket / UDP / QUIC
  - session / stream / receiver 映射
  - 安全鉴权
  - 上层编码器 / 解码器 / renderer / QoE

SDK facade 层
  负责：
  - push / play / server 三角色接口
  - 业务参数转 WebRTC 输入
  - WebRTC 输出转 bytes / cap / metrics

WebRTC 能力层
  负责：
  - GoogCC
  - pacing
  - RTP/RTCP
  - NACK/PLI
  - video jitter
```

### 5.3 子架构

#### Push 子架构

```text
Annex-B AU
  -> H264 RTP payload
  -> RTP packet bytes
  -> pacer queue
  -> send bytes
  <- TWCC / RR / NACK / PLI / SenderRateCap
```

#### Play 子架构

```text
RTP bytes
  -> parse RTP
  -> NackRequester
  -> video jitter / packet buffer
  -> Annex-B AU callback
  -> RTCP NACK / PLI callback
```

#### Server 子架构

```text
sender RTP
  -> local packet history
  -> receiver relay
  -> uplink TWCC

receiver RTCP / downlink quality
  -> local retransmission or forward NACK/PLI
  -> worst receiver selection
  -> SenderRateCap
```

## 6. 为什么关键参数这么配

### 6.1 H264 参数

当前固定：

- `payload_type = 96`
- `clock_rate_hz = 90000`
- `profile-level-id = 42e01f`
- `max_width = 1280`
- `max_height = 720`
- `max_fps = 30`
- `allow_stapa = false`
- `allow_b_frames = false`
- `require_sps_pps_before_idr = true`

原因：

- `720p30` 是当前复杂度和效果的合理平衡点
- 禁 `STAP-A` 和 `B` 帧可以明显降低收发两端复杂度
- `SPS/PPS + IDR` 规则能减少解码器恢复歧义

### 6.2 sender 初始码率窗口

当前固定：

- `start_bitrate_bps = 1200000`
- `min_bitrate_bps = 300000`
- `max_bitrate_bps = 2500000`

原因：

- `1.2Mbps` 对 `720p30 H264` 是一个相对稳妥的起点
- `300kbps` 作为下限，可以让 sender 在极弱网时继续维持最低可运行视频流
- `2.5Mbps` 给恢复阶段留足空间，但不至于一上来就太激进

### 6.3 Pacing 参数

当前 SDK facade 运行时使用：

- `kMaxPacingQueueBytes = 2MB`
- `kMaxPacingQueueTimeMs = 1500ms`
- pacing floor 约等于 `final_target_bps * 2.5`

而 raw `PacingAdapterConfig` 默认值仍是：

- `max_queue_bytes = 512KB`
- `max_queue_time_ms = 500ms`

为什么 facade 更宽：

- facade 还要承接 sender 侧 probe、padding 和 sender 侧重传
- 弱网/恢复切换时，过紧的队列上限会更容易触发 `QueueFull`
- 当前上层 harness 里已经明确把 `push_queue_full` 当成失败指标，所以更宽的 queue 限制是为了减少“测试假阳性”，不是放弃实时性

为什么仍要保留 `ResetPacerQueue()`：

- 当 rate cap 明显下降时，旧高码率队列如果继续排队，只会污染实时链路
- 这时应该清队列、请求下一次关键帧、重建节奏

### 6.4 TWCC / SR/RR 参数

当前固定：

- `TWCC feedback_interval_ms = 50`
- `SR/RR interval_ms = 1000`

原因：

- `50ms` 足够让拥塞控制看到弱网转场
- `1000ms` 足够给 sender 稳定估 RTT

### 6.5 rate cap 语义

当前 public API 只定义：

- 有限上限
- 不限速 `kUnlimitedRateCapBps`

当前不把 `cap_bps == 0` 定义成“暂停发送”。

原因：

- sender 端当前设计目标是“码率控制”，不是“业务暂停控制”
- 如果需要 pause / resume，应该走更高层控制消息

### 6.6 packet history 参数

当前 sender 侧和 server 侧都保留 packet history。

sender 侧：

- `hold_ms = 3000`
- `max_hold_ms = 10000`

server 侧：

- `hold_ms = 1000`
- `max_hold_ms = 3000`

原因：

- server 优先处理短 RTT、本地快速重传，所以保留窗口可以更短
- sender 侧要兜住 server history miss，因此窗口要更长

## 7. 当前仍未闭合的事项

这套 SDK 当前已经能证明主方向成立，但下面这些点还不能写成“已经正式完成”：

- 当前恢复链路支持的是 `NACK + 原 RTP 包重传`，不是 `RFC4588 RTX`。
- compound RTCP 当前只承诺 `SR / RR / TWCC / NACK / PLI`；遇到其它 block 时，server 会显式累计 unsupported RTCP packet 计数并默认 drop。
- 多 track 当前只完成了第一条实现切片：public model、shared sender QoS、per-track play isolation 已落地；多 track 的更系统化 QoE/soak 门禁和更广泛的文档收口还在继续推进。
- 正式验收闭环还缺 `SOAK_MINUTES>=120` 的 production soak、真实 renderer `pass` 和正式 `capture_library/manifest.csv`。

上面这些未完成项的收敛计划，见 [Phase-3 逻辑正确性收敛计划](../webrtc_first_phase3_plan.md) 和 [Phase-2 主实施文档](../webrtc_first_phase2_master_plan.md)。

## 8. 适用场景

这套 SDK 当前最适合：

- Linux native 推流客户端
- Linux native 播放客户端
- 自定义 UDP / QUIC 传输
- C/S 实时视频系统
- 自建 relay / QoS router
- 需要 sender 弱网下探和恢复回升的实时流

不适合：

- 想直接拿浏览器互通的完整 WebRTC client
- 想把 PeerConnection 全家桶一起交付
- 需要立即上线完整音视频 + 浏览器信令体系

## 9. 当前文档导航

建议按这个顺序读：

1. 本文
2. [推拉客户端 SDK 集成说明](sdk_push_play_integration.md)
3. [WebRTC 子模块拆分编译说明](webrtc_module_split_build.md)
4. [Phase-2 主实施文档](../webrtc_first_phase2_master_plan.md)
5. [Phase-3 逻辑正确性收敛计划](../webrtc_first_phase3_plan.md)

如果你关心“为什么可信、怎么验证”，继续看后续的 `QoS 测试与验证方法` 文档。
