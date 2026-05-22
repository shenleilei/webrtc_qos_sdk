# WebRTC-first Phase-4 计划：保留原生 Media Plane，自定义 Transport / Control Plane

## 1. 背景

Phase-2 把 SDK 主路径切回了 WebRTC-first。Phase-3 则把 sender
retransmission、RTCP identity、compound RTCP 边界和命名语义收口到了当前
可用状态。

但前面几期的一个隐含前提是：

- 我们只抽取 WebRTC 的若干能力模块
- 然后在 SDK 里自己包出一个较薄的单 track facade

这条路在单 track、单 sender SSRC、最小 C/S QoS 闭环阶段是成立的，但一旦进入：

- 多 track
- 多 sender SSRC
- 更完整的 sender / receiver 媒体语义

继续只抽零散模块、再由 SDK 自己重新拼一套媒体对象模型，就开始偏离最初方向。

本阶段重新明确目标：

- **transport plane 继续由我们自己做**
- **control plane 继续由我们自己做**
- **media plane 尽量保留 WebRTC 原生语义和原生能力**

换句话说，Phase-4 的目标不是把 SDK 做成完整 `PeerConnection`，也不是再做一套
自定义多轨媒体模型，而是：

```text
保留 WebRTC 的原生媒体发送/接收编排语义
只替换掉不符合我们 C/S 需求的 transport 与业务控制面
```

## 1.1 这次要纠正的问题

如果继续按“我们自己设计一套 source/track 系统”的思路走，会有两个风险：

1. 做成半套自研 media plane
   - 名字还叫 WebRTC-first
   - 实际上 sender / receiver / track / encoding 语义又被我们自己重新发明一遍

2. 走向半个 PeerConnection 外壳
   - 如果反过来把浏览器式对象模型全搬进来，又会把项目推向完整 WebRTC 会话层

Phase-4 必须避免这两个极端。

## 1.2 当前工作区状态

基于当前工作区实现，Phase-4A 的第一条最小切片已经落地：

- public model 已支持 `source_id / track_id / sender_ssrc`
- `SessionConfig.video_tracks` 已可描述一个 source 下多个 track
- `VideoPushClient` 已支持在一个实例内承载多个 sender SSRC，并保持 shared
  GoogCC / shared pacer
- `VideoPlayClient` 已支持按 sender SSRC 区分多个 track，并输出带
  `track_id / sender_ssrc` 的 AU
- `ServerQosRouter` 已支持按 sender SSRC 隔离 packet history / RR block /
  retransmission route
- `scripts/verify_webrtc_first_multitrack.sh` 已验证两 track 外部消费路径，
  且已接入 `scripts/verify_webrtc_first_roles.sh`

当前仍未完成的，不是“多 track 根本不能跑”，而是更完整的四期收尾项，例如：

- 更系统化的多 track QoE / soak 门禁
- 文档和集成说明的全面同步
- 对“保留原生 media-plane”这一原则的进一步实现收口

## 1.3 目标分层

Phase-4 之后，整个系统应尽量切成三层：

### A. Transport Plane：我们自己做

继续由业务侧掌握：

- socket / UDP / QUIC
- 包收发
- 连接生命周期
- 网络切路由
- relay / router 拓扑

### B. Control Plane：我们自己做

继续由业务侧掌握：

- session / room / source / receiver 管理
- receiver 订阅关系
- sender cap 控制消息
- 权限、鉴权、业务策略

### C. Media Plane：尽量由 WebRTC 做

尽量保留 WebRTC 原生语义和能力：

- sender / receiver
- track / SSRC
- encoding
- RTP/RTCP
- NACK / PLI
- pacing
- GoogCC
- jitter / packet buffer

这就是 Phase-4 的核心方向。

## 1.4 参考标准 WebRTC / 浏览器模型

W3C 官方模型里有三层不同概念：

1. **source**
   在 Media Capture and Streams 里，source 是真正产生媒体的东西。

2. **track**
   source 可以产生多个 `MediaStreamTrack`。

3. **sender / transceiver / encoding**
   一个 sender 绑定一个 track；
   一个 sender 又可以带多个 `sendEncodings`，对应 simulcast / 多 encoding。

因此标准 WebRTC 天然支持两条路线：

- **路线 A：多 track / 多 sender / 多 SSRC**
- **路线 B：单 track + 多 encodings / simulcast**

但当前 Phase-4 只推进路线 A。路线 B 只保留为未来备注，不进入当前实施目标。

## 2. Phase-4 原则

1. 不引入完整 PeerConnection 会话层。
   不做 ICE、DTLS、SRTP、SDP、STUN、TURN，不让 WebRTC 接管 socket。

2. 不重新发明 media plane。
   sender / receiver / track / encoding / SSRC 的媒体语义，优先贴近 WebRTC 原生模型。

3. transport/control 与 media 明确分离。
   我们只在外面包 transport adapter 和 control-plane adapter，不在里面再写一套
   自定义 sender/receiver 媒体编排模型。

4. 当前只做多 track，不做多 encoding 路线。
   如果未来业务明确需要“同一内容多层发送”，再单独开下一阶段讨论
   single-track simulcast / multi-encoding。

5. 保持当前单 track API 可用。
   现有单 track `VideoPushClient / VideoPlayClient / ServerQosRouter`
   不能直接废掉。Phase-4 应允许其继续工作，并在其上引入更贴近原生 media-plane
   的扩展接口或新 facade。

## 3. 当前模型的主要问题

### 3.1 历史上 facade 太薄，只有单 track 语义

在进入当前 Phase-4A 实现前，public model 写死为：

- 单 `sender_ssrc`
- 单主 H264 track
- 单 `VideoPushClient`
- 单 `VideoPlayClient`

这也是为什么必须推进当前这一轮多 track public model 扩展。

### 3.2 核心问题不是“WebRTC 不支持”，而是“我们没有把那层语义接进来”

原生 WebRTC 支持：

- 多 track
- 多 sender
- 多 SSRC
- 单 track 多 encodings

但当前 SDK 只抽取了：

- RTP/RTCP
- GoogCC
- PacingController
- NackRequester
- video jitter

没有把更上层的原生 media-plane 语义一起接进来。

### 3.3 当前 server 仍是最小 relay/router，不是完整媒体编排层

这本身没问题，但 Phase-4 必须明确：

- server 继续只做 transport/control-plane glue
- 不要在 server 里又长出一套偏自研的媒体对象模型

## 4. Phase-4 的正确方向

### 4.1 不是“重做一套 source/track 系统”

Phase-4 不应该先做一个很重的：

- `VideoSourcePublisher`
- `MultiTrackServerRouter`
- `MultiTrackVideoPlayer`

然后由这些自定义对象再去驱动 WebRTC 零散模块。

这种方式会让我们重新承担媒体层建模成本，和最初目标相反。

### 4.2 应该做的是：保留 WebRTC 原生 media-plane 语义

更贴近目标的做法是：

- sender 侧尽量保留原生 sender / track / encoding 语义
- receiver 侧尽量保留原生 receiver / track / decode pipeline 语义
- SDK 只负责：
  - 把 transport bytes 喂进 / 取出这些 media-plane 组件
  - 把业务侧的 session / source / receiver 管理映射到它们

### 4.3 第一阶段优先级

按你现在给的方向，Phase-4 第一小阶段应优先解决：

1. **多 track / 多 sender SSRC**
2. **仍然保留 source 级共享 uplink QoS/pacing**
3. **不做多 receiver fanout 工程化**

也就是：

```text
先把 1 source -> 多个 track / 多个 sender SSRC 这条媒体语义接进来
不急着把 receiver registry / fanout support 层做进 SDK
```

## 5. Phase-4 路线拆分

### 5.1 Phase-4A：多 Track / 多 Sender SSRC

适用场景：

- 一个 source 下存在多个语义独立的视频输出
- 每个输出应该有独立 track 身份
- 每个输出应有独立 sender SSRC
- 上层可能需要按 track 区分编码、解码和输出

目标：

- 把多 track / 多 sender SSRC 接入当前 SDK
- 继续复用 shared GoogCC / shared pacing
- 让 play 端输出带 track 身份

### 5.2 当前决定

你已经明确了当前第一小阶段先做：

- **Phase-4A：多 Track / 多 Sender SSRC**

并明确暂时不做：

- 多 receiver fanout 工程化
- 单 track + 多 encodings / simulcast

## 6. Phase-4A：多 Track / 多 Sender SSRC 设计目标

### 6.1 Public model 需要能表达多个 track

至少要能显式表达：

- `source_id`
- `track_id`
- `sender_ssrc`

当前 `TransportIds` 只够表达：

- `session_id`
- `stream_id`
- `transport_id`
- `sender_ssrc`
- `receiver_id`

Phase-4A 需要把 `source_id / track_id` 加进来，或者新增与之等价的媒体身份结构。

### 6.2 sender 侧不能变成多套独立 GoogCC

即使多个 track 存在，也应该保持：

- source 级共享 uplink GoogCC
- source 级共享 pacer
- source 级 shared sender cap

不应做成：

- track A 一套 sender QoS
- track B 一套 sender QoS

否则多个 track 会在同一路径上互相抢带宽。

### 6.3 每个 track 仍要有自己的媒体状态

每个 track 仍应至少有：

- 独立 sender SSRC
- 独立 RTP sequence state
- 独立 packetization state
- 独立 packet history
- 独立 SR media counters
- 独立 keyframe / adaptation visibility

### 6.4 play 侧输出必须带 track 身份

如果 receiver 同时收到多个 track，那么 decode 输出至少要带：

- `track_id`
- `sender_ssrc`

否则上层无法区分两个视频输出。

## 7. 当前最合理的实现边界

### 7.1 我们自己做的部分

- transport adapter
- business session / source / receiver 管理
- sender cap 控制消息
- track / source 到业务对象的映射
- receiver 订阅关系管理

### 7.2 尽量依赖 WebRTC 的部分

- track / sender / receiver 媒体语义
- RTCP / RTP
- NACK / PLI
- pacing
- GoogCC
- jitter / packet buffer
- 后续可能的 encoding/simulcast

### 7.3 当前明确不做的部分

- 完整 PeerConnection
- ICE / DTLS / SRTP / SDP
- 浏览器信令对象模型
- 多 receiver fanout support 层

## 8. 推荐工作包

### 8.1 P1：先把 public model 扩成多 track / 多 sender SSRC

动作：

- 扩展 `TransportIds` 或新增等价媒体身份结构
- 引入 `source_id / track_id`
- 把 sender / play / server 中依赖单 `sender_ssrc` 的路径抽出来

验收：

- 单 track 老路径不回归
- 两个 track 的 sender SSRC 不冲突
- 两个 track 的 packet history 不冲突

### 8.2 P1：sender 侧接入多 track，同时保持 shared QoS

动作：

- sender 侧支持多个 track
- 每个 track 独立 packetization / RTP state
- source 级共享 GoogCC / pacing / sender cap

验收：

- 两个 track 共存时，不出现两套独立拥塞控制抢同一路径
- source 级 final target bitrate 可用
- retransmission 仍通过 shared pacer 出队

### 8.3 P1：play 侧接入多 track 输出

动作：

- play 侧支持多个 sender SSRC
- decode/AU output 带 `track_id / sender_ssrc`
- jitter / retransmission / QoS 统计按 track 隔离

验收：

- 两个 track 同时接入时输出不会串
- track A 的 jitter/retransmission 不污染 track B

### 8.4 P2：多 receiver fanout helper 延后

这部分明确不作为当前必须项。

后续如果业务确认需要，再做：

- receiver registry
- subscription map
- sender RTP 自动 fanout 到多个 receiver

## 9. 测试与门禁计划

### 9.1 本阶段必补测试

1. multi-track sender SSRC isolation
   - track A / track B
   - 各自独立 sender SSRC
   - RTP sequence / history 不串

2. shared pacer / shared GoogCC under multi-track
   - 两个 track 共用 source-level controller
   - 不出现两套独立 sender QoS

3. per-track adaptation
   - 每个 track 可观察自己的 adaptation 状态
   - source 级 target 能正确作用到多 track

4. multi-track play isolation
   - receiver 收到两个 track
   - AU 输出带正确 `track_id / sender_ssrc`
   - jitter / retransmission 不串

5. docs / naming audit
   - 文档明确：
     - transport/control 是我们的
     - media plane 尽量保留 WebRTC
     - 当前做的是多 track，不是多 receiver fanout
     - 多 track 和多 encodings 不是一回事

### 9.2 现有门禁仍需保留

- `verify_cmake_package.sh`
- `verify_webrtc_first_pacing_probe.sh`
- `verify_webrtc_first_roles.sh`
- `verify_webrtc_first_phase2.sh` smoke/qoe/production
- production soak archive verifier
- capture library 和 real renderer gate

### 9.3 建议新增门禁

- `verify_multi_track_sender_model.sh`
- `verify_multi_track_shared_qos.sh`
- `verify_multi_track_play_output.sh`
- `run_multi_track_qoe_matrix.sh`

## 10. 完成判定

Phase-4A 完成不能只看“能发两个 SSRC”，至少要满足：

- 多 track / 多 sender SSRC 已进入明确 public model
- source 级 shared pacing / GoogCC 已落地
- per-track packet history / jitter / QoS 统计不会串
- 文档明确写清楚：
  - transport/control plane 是我们的
  - media plane 尽量保留 WebRTC 原生语义
  - 当前做的是多 track，不是多 receiver fanout

正式交付层面仍然需要：

- `SOAK_MINUTES>=120` 的 production soak
- real renderer `pass`
- formal capture library

## 11. 非目标

本阶段暂不做：

- 多 receiver fanout 工程化
- 单 track + 多 encodings / simulcast
- 完整 SFU 控制面
- PeerConnection / SDP / ICE / DTLS / SRTP
- 音频多轨
- 多 codec 协商
- RFC4588 RTX
- FEC / SVC / Simulcast 信令栈

## 12. 推荐执行顺序

1. 先把 transport/control-plane 与 media-plane 的边界写死。
2. 先把 public model 扩成多 track / 多 sender SSRC。
3. 再把 sender 侧多 track 接进 shared GoogCC / shared pacer。
4. 再做 play 侧多 track 输出。
5. 最后补 QoE、soak 和正式验收证据。

原因很简单：

- 边界不先写死，后面很容易又回到“自研半套 media plane”。
- public model 不先扩出来，多 track 只能继续停留在内部 hack。
- shared QoS 不先立住，多 track 从第一天就会带着错误的拥塞控制前提。
