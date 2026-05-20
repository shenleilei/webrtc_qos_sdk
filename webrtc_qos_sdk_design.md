# WebRTC QoS SDK 设计说明

## 1. 目标

本项目不是要交付一个完整的 `libwebrtc.a` 全家桶，而是要交付一个适合 Linux native 业务侧集成的 SDK。

本项目的基本前提是：

- 整体系统是 `C/S` 架构，不是典型 WebRTC `P2P` 架构
- 传输层第一阶段由业务侧自行实现
- WebRTC 主要复用其 `QoS`、`jitter buffer`、媒体缓冲和部分媒体处理能力

第一阶段固定为 `Phase-1a`：

- 只做 `H264` 视频 `QoS/jitter` 闭环
- sender `GoogCC` 只看 `sender -> server` 上行反馈
- receive_play 的下行质量只影响 server 生成 `sender_rate_cap`
- 音频整体推迟到 `Phase-1b`

## 2. 非目标

`Phase-1a` 不追求以下能力：

- 完整标准 WebRTC `PeerConnection`
- 完整 `ICE / DTLS / SRTP / SDP` 信令栈
- 浏览器兼容信令协议
- 将整个 WebRTC 源码树暴露给业务层
- 音频闭环验收

## 3. 总体结论

`Phase-1a` 固定路线如下：

- 对外提供一个自定义 facade SDK
- 底层按功能拆分复用 WebRTC 能力，不交付完整 `libwebrtc.a`
- 发送侧复用 WebRTC `network_control / goog_cc`
- 接收侧视频 jitter 复用 WebRTC `H264 parser + PacketBuffer` 最小闭包
- `NackRequester` 作为后续独立 adapter，不阻塞当前 Phase-1a 最小闭环
- 以 `C/S` 媒体链路为前提裁剪 WebRTC 能力边界
- 传输层第一阶段由业务侧自行实现
- SDK 面向自定义 `RTP/RTCP/UDP` 场景
- `play` 端必须接入 `qos + jitter`
- SDK 内置 `SenderPacer`

## 4. 为什么不直接交付完整 libwebrtc.a

不直接交付完整 `libwebrtc.a` 的主因是传输边界，而不是单纯构建体积。

第一阶段既然明确为“`C/S` 架构 + 传输层自研”，那就意味着：

- 不需要完整 `PeerConnection`
- 不需要完整 `ICE / DTLS / SRTP / SDP`
- 不需要 `STUN / TURN` 协商链路
- 不需要浏览器 `P2P` 会话建立状态机
- 不需要默认把 `DataChannel / SCTP` 作为第一阶段基础能力

## 5. 第一阶段交付目录

第一阶段交付目录固定如下：

```text
output/
  include/
    webrtc_qos/
      types.h
      sender_qos_controller.h
      sender_pacer.h
      receiver_qos_observer.h
      video_jitter_player.h
      googcc_adapter.h
      sender_qos_googcc_bridge.h
      video_jitter_adapter.h
      video_jitter_bridge.h
      video_sender.h
      video_receiver.h
      ffmpeg_h264_encoder.h
      ffmpeg_h264_decoder.h
      transport_feedback.h
  lib/
    libwebrtc_qos.a
    libwebrtc_qos_core.a
    libwebrtc_qos_rtp.a
    libwebrtc_qos_rtcp.a
    libwebrtc_qos_feedback.a
    libwebrtc_qos_nack.a
    libwebrtc_qos_pacer.a
    libwebrtc_qos_video.a
    libwebrtc_qos_googcc_adapter.a
    libwebrtc_qos_googcc_bridge.a
    libwebrtc_qos_video_jitter_adapter.a
    libwebrtc_qos_video_jitter_bridge.a
    libwebrtc_qos_ffmpeg_encoder.a
    libwebrtc_qos_ffmpeg_decoder.a
  demo/
    qos_loopback_demo
    capture_push_demo
    receive_play_demo
    webrtc_qos_googcc_smoke
    webrtc_qos_video_jitter_smoke
    output_integration_demo
    udp_sender_demo
    udp_server_demo
    udp_receiver_demo
```

`Phase-1a` 不要求公开：

- `audio_jitter_player.h`
- `video_capturer.h`
- `video_renderer.h`

## 6. C/S 架构下的能力边界

在 `C/S` 架构下，`Phase-1a` 客户端职责固定如下：

- `capture_push`：
  - 采集
  - 编码
  - 发 `RTP/RTCP`
  - 接收来自服务端的 QoS 控制反馈
- `receive_play`：
  - 收 `RTP/RTCP`
  - 视频 jitter buffer
  - 解码播放
  - 上报接收质量、丢包、RTT、NACK、PLI

服务端职责包括：

- 转发或分发媒体流
- 汇总接收侧反馈
- 生成 sender 可消费的上行 QoS 输入
- 生成多播放端策略上限

## 7. Phase-1a 媒体与协议固定规格

### 7.1 视频编码与封装范围

`Phase-1a` 视频能力固定为：

- `H264 only`
- 不支持 `VP8`
- 不支持 `VP9`
- 不支持 `AV1`

### 7.2 H264 RTP 子集

`Phase-1a` 的 `H264 RTP` 规则固定如下：

- 发送端 packetizer 输入格式：`Annex-B`
- RTP clock rate：`90000 Hz`
- RTP payload type：固定为动态类型 `96`
- H264 `profile-level-id`：固定为 `42e01f`
- `packetization-mode=1`
- 支持 `Single NALU`
- 支持 `FU-A`
- `STAP-A`：明确禁用
- `MTAP16/MTAP24/FU-B/STAP-B`：不支持
- 关键帧类型固定为 `IDR`
- GOP 只允许 `I/P`
- 禁用 `B` 帧
- 一个 access unit 对应一个 RTP timestamp
- `SPS/PPS/IDR` 使用同一个 RTP timestamp
- `SPS -> PPS -> IDR` 发送顺序固定
- marker bit 只打在该 access unit 最后一个 RTP 包上
- 发送端必须在每个 `IDR` access unit 中携带 `SPS/PPS`
- `SPS/PPS` 随每个 `IDR` 重发
- RTP 最大 payload size 固定为 `1200 bytes`

### 7.3 H264 能力边界

发送端第一阶段必须满足：

- 关键帧必须为 `IDR`
- 不得产生 `B` 帧
- 只产生 `I/P` 帧
- 码流可被 `Single NALU + FU-A` 完整承载
- 收到 `PLI` 后必须尽快输出下一个 `IDR`
- 编码输出必须统一转换为 `Annex-B` 后再进入 packetizer
- 不允许编码器运行时切换 H264 profile
- 不允许动态切换 H264 RTP payload type
- 发送前必须做 `SPS/profile/level/分辨率` 校验
- `profile-level-id` 不匹配 `42e01f` 时，直接报错并拒绝发送
- 检测到 `B` 帧时，直接报错并拒绝发送
- 分辨率超出 `1280x720` 时，直接报错并拒绝发送

接收端第一阶段必须满足：

- `video_jitter_player` 输出给解码器的格式固定为 `完整 Annex-B access unit`
- 输出帧必须保持原始 `RTP timestamp`
- 关键帧恢复路径下，若该 access unit 为 `IDR`，则输出必须包含必要的 `SPS/PPS/IDR`
- SDK wrapper 负责把组帧结果归一化为 `0x00000001 + NALU` 形式的完整 access unit
- 若 depacketizer 输出不包含关键帧所需参数集，SDK wrapper 必须从缓存的 `SPS/PPS` 中补齐 `IDR` 前置参数集
- SDK 不负责把输出转换为 `AVCC`

### 7.4 H264 level 与能力上限

`Phase-1a` 的工程目标固定为：

- `profile-level-id=42e01f`
- 分辨率目标：`1280x720`
- 帧率目标：`30fps`
- 目标发送码率范围：`300 kbps ~ 2500 kbps`

`1080p30` 不作为 `Phase-1a` 必须验收目标。

### 7.5 视频丢包恢复策略

第一阶段视频丢包恢复固定为：

- 丢包检测：SDK 轻量 `ReceiverQosObserver`
- 重传请求：`NACK`
- 解码链恢复：`PLI -> 请求 IDR`

第一阶段不要求：

- `FEC`
- `RTX` 专用重传 SSRC 机制
- `SVC/多层编码` 恢复策略

### 7.6 音频 phase 边界

第一阶段音频采用以下收敛策略：

- `Phase-1a`
  - 不作为必须验收项
  - 不要求 `NetEq`
  - 不要求 `Opus`
  - 不要求音频 demo
- `Phase-1b`
  - 固定音频为 `Opus`
  - 采样率：`48kHz`
  - 声道：`2`
  - RTP payload type：固定为 `111`
  - RTP timestamp rate：`48000`
  - decoder factory：使用 WebRTC/业务已有 `Opus` 解码器工厂
  - 引入 `NetEq`

## 8. QoS feedback 协议

### 8.1 固定 QoS 闭环拓扑

`Phase-1a` 固定采用以下路线：

- `sender -> server` 上行链路：
  - sender 发送 `RTP`
  - sender 定期发送 `RTCP SR`
  - server 作为上行唯一 `control receiver`
  - server 基于自己收到的 RTP 包生成 `uplink_twcc`
  - server 返回 `RTCP RR`
  - sender 侧 `GoogCC / network_control` 只消费来自 `server` 的 `uplink_twcc`
- `receive_play -> server` 下行链路：
  - receive_play 只向 server 上报 `downlink_quality / NACK / PLI`
  - `downlink_quality` 不直接喂给 sender `GoogCC`
- 多播放端策略：
  - 由 server 基于 `downlink_quality` 生成 `sender_rate_cap`
  - sender 最终码率使用 `min(googcc_target, sender_rate_cap)`

### 8.2 feedback 分类

第一阶段 feedback 方向固定如下：

- `sender -> server`
  - `RTP`
  - `RTCP SR`
- `server -> sender`
  - `uplink_twcc`
  - `RTCP RR`
  - `sender_rate_cap`
- `receive_play -> server`
  - `downlink_quality`
  - `NACK`
  - `PLI`

### 8.3 RTCP TWCC 与业务 envelope 分层

必须严格分层：

- `RTCP Transport Feedback`
  - 保持标准格式
  - 不增改自定义字段
- `SDK/session 映射层`
  - 承担 `session_id / stream_id / receiver_id / transport_id` 映射
- `业务可靠控制通道`
  - 承载 `DOWNLINK_QUALITY_V1`
  - 承载 `SENDER_RATE_CAP_V1`

标准 `RTCP TWCC` 包本身不带 `session_id / stream_id / receiver_id`。

SDK 对业务传输层暴露 `transport_port.h`，生产接入时业务侧只需要实现 `TransportPort` 的 send/deliver 回调，把 SDK 消息类型映射到自己的可靠/不可靠通道。`TransportPort` 只传递 `TransportMessage { ids, type, payload, payload_size, send_time_us, flags }`，不规定业务 wire format。

`TransportMessage::payload` 是借用指针，不是 SDK 持有的长期 buffer：

- `TransportPort::Send()` 同步调用 send callback，`payload` 只保证在 callback 返回前有效
- 业务传输如果异步写 socket、排队、加密或进入可靠通道，必须在 send callback 内复制 payload
- `TransportPort::Deliver()` 同步调用 receive callback，receive callback 不应保存 payload 指针，除非调用方显式保证网络 buffer 生命周期
- SDK 不负责业务协议封包、加密、鉴权、socket 生命周期、发送队列或跨线程调度

`production_transport_adapter.h` 是生产接入推荐模板：

- 保持 `TransportPort` 作为 SDK 边界
- 在 send callback 内把借用 payload 复制成 `OwnedTransportMessage`
- 将 `RTP` 分到 `unreliable_media`
- 将 `RTCP SR/RR/TWCC/NACK/PLI` 分到 `unreliable_control`
- 将 `DOWNLINK_QUALITY_V1 / SENDER_RATE_CAP_V1 / BYE` 分到 `reliable_control`
- 业务侧只需要把 `OwnedTransportMessage` 编进自己的 wire format，并按 lane 写入对应传输通道

当前 UDP demo 固定实现 `DEMO_TRANSPORT_V1` envelope，用于验证映射层；它是 demo 协议，不是 SDK 对生产传输协议的强约束。该 envelope 只包裹消息，不修改 RTP/RTCP wire format：

```text
u32 magic = 'WQOS'
u8  version = 1
u8  reserved = 0
u16 type
u32 session_id
u32 stream_id
u32 sender_ssrc
u32 receiver_id
u16 flags
u16 payload_len
u64 send_time_us
u8  payload[payload_len]
```

`type` 当前包括：

- `RTP`
- `RTCP_SR`
- `RTCP_RR`
- `RTCP_TWCC`
- `RTCP_NACK`
- `DOWNLINK_QUALITY_V1`
- `SENDER_RATE_CAP_V1`
- `BYE`

### 8.4 RTP header extension 固定策略

所有参与 sender QoS 的 RTP 包必须携带 transport sequence number header extension。

第一阶段固定如下：

- URI：`RtpExtension::kTransportSequenceNumberUri`
- 语义：`transport-wide-cc-01`
- extension id：固定为 `1`
- header extension 格式：优先使用 `one-byte` header extension
- 第一阶段不启用 `extmap-allow-mixed`

### 8.5 uplink_twcc on-wire 选择

第一阶段 `uplink_twcc` 不自定义新 wire format，直接使用标准 RTCP `Transport Feedback` 包。

### 8.6 uplink_twcc 逻辑字段

第一阶段 `uplink_twcc` 的 SDK 逻辑视图固定如下：

```text
transport_id
sender_ssrc
receiver_id
feedback_seq
base_transport_seq
packet_status_count
reference_time_us
fb_pkt_count
recv_deltas[]
```

其中：

- `transport_id`：拥塞控制发送通道标识
- `receiver_id`：上行闭环中固定为 `server`

### 8.7 transport sequence number 约束

第一阶段必须为每个发送出去的 RTP 包打上单调递增的 `transport sequence number`。

要求：

- 以 `transport_id` 维度维护
- 同一 `transport_id` 上的所有媒体包共享同一 sequence space
- 在发送端单调递增
- 如果音视频共用同一路发送链路，则音视频共享同一 sequence space

### 8.8 RTT 协议要求

第一阶段 RTT 协议固定如下：

- sender 定期发 `RTCP SR`
- server 作为上行 receiver 回 `RTCP RR`
- sender 用 `RR` 中的 `LSR/DLSR` 计算 `sender <-> server RTT`
- `downlink_quality.rtt_ms` 表示 `receive_play <-> server` 下行链路观测
- `downlink_quality.rtt_ms` 通过业务可靠控制通道上的 ping/pong 计算
- `uplink_twcc` 负责 per-packet arrival feedback
- 业务 ping/pong 仅作为 fallback

禁止把 `uplink_twcc` 直接当成唯一 RTT 协议来源。

### 8.9 downlink_quality 发送周期

第一阶段固定为：

- `uplink_twcc`：
  - 周期：`50ms`
  - 若有显著丢包或乱序，可提前发送
- `RTCP SR/RR`：
  - 周期：`1000ms`
- `downlink_quality`：
  - 周期：`200ms`
- `recovery_control`：
  - `NACK`：按 SDK 轻量丢包检测模块的周期/事件触发
  - `PLI`：在确认关键帧恢复需要时立即发送

### 8.10 DOWNLINK_QUALITY_V1

`downlink_quality` 不走 RTCP，第一阶段固定为业务可靠控制通道上的自定义二进制消息 `DOWNLINK_QUALITY_V1`。

编码规则固定如下：

- 字节序：`network byte order`
- 版本号：`u8`
- 消息类型：`u8`
- 固定头长度：`u16`
- 所有整数默认为无符号

固定头字段如下：

```text
u8   version = 1
u8   msg_type = 1   // DOWNLINK_QUALITY_V1
u16  header_len
u32  session_id
u32  stream_id
u32  sender_ssrc
u32  receiver_id
u32  report_seq
u64  report_time_us
u16  rtt_ms
u16  fraction_lost_q8
u16  reorder_ratio_q8
u16  flags
u32  recv_bitrate_bps
u16  video_jitter_frames
u16  video_decodable_queue_depth
u16  video_drop_frames
u16  last_pli_reason
```

### 8.11 recovery_control wire format

第一阶段恢复控制优先复用标准 RTCP：

- `NACK`：标准 RTCP Generic NACK
- `PLI`：标准 RTCP PLI

固定语义如下：

- `NACK` 针对 `RTP sequence number`
- `TWCC` 针对 `transport sequence number`
- receiver jitter buffer 按 `RTP sequence number` 去重
- congestion control 按新的 `transport sequence number` 统计重传发送事件

### 8.12 SENDER_RATE_CAP_V1

多播放端策略不直接污染 sender `GoogCC` 输入，而是通过独立消息下发：

- `SENDER_RATE_CAP_V1`

固定字段如下：

```text
u8   version = 1
u8   msg_type = 2   // SENDER_RATE_CAP_V1
u16  header_len
u32  session_id
u32  stream_id
u32  controller_seq
u32  cap_bps
u16  expire_ms
u16  reason_code
```

语义固定如下：

- 无 cap：`cap_bps = 0xFFFFFFFF`
- 过期后：自动回到 `unlimited`
- `cap_bps = 0`：保留值，第一阶段禁止使用为“暂停”

sender 最终发送目标码率计算固定为：

- `final_target_bps = min(googcc_target_bps, sender_rate_cap_bps)`

编码器自适应决策：

- SDK 对外输出 `EncoderAdaptation`
- `target_bitrate_bps` 来自 `final_target_bps`
- `max_fps` 根据 `final_target_bps / RTT / loss_fraction` 分档
- 低码率、高 RTT、高丢包时下调 FPS
- 网络恢复后随 QoS 估算恢复 FPS
- `request_keyframe` 用于高 RTT/高丢包恢复后的关键帧刷新建议
- `Phase-1a` core 不强制绑定真实编码器；真实编码器作为可选小库独立交付
- 当前可选实现为 `libwebrtc_qos_ffmpeg_encoder.a`，用于验证真实 H264 Annex-B AU 能进入 `VideoSender + SenderPacer` 链路
- 当前可选解码实现为 `libwebrtc_qos_ffmpeg_decoder.a`，用于验证 receive_play 输出的完整 Annex-B AU 可被真实 H264 decoder 消费

动态弱网自适应验收必须同时覆盖两类方向：

- 进入弱网：`target_bitrate_bps` 和 `max_fps` 必须随带宽下降、RTT 上升、丢包上升而下降
- 网络恢复：`target_bitrate_bps` 和 `max_fps` 必须随 feedback 恢复而上升，不能长期卡在低档
- 严重损伤：必须输出 `request_keyframe=true`，供编码器或 sender 触发 IDR 刷新
- 验收不能只跑单个 good/bad 场景，必须覆盖 bandwidth cliff、RTT/jitter spike、burst loss、oscillation、walk outage recovery
- 长流 QoE 验收不能只看“组帧成功”，必须用真实 H264 decoder 解码 receiver 输出；只有解码成功的 AU 才能计入 receiver frame

### 8.13 sender_rate_cap 防抖

`worst-receiver wins` 需要防抖，第一阶段固定如下：

- 降码率：
  - 立即生效
- 升码率：
  - 最小保持时间：`2000ms`
- 异常接收端剔除：
  - 连续 `5000ms` 无有效 report 的 receiver 不参与 rate cap 计算

## 9. 服务端协议责任

### 9.1 服务端最小责任

第一阶段服务端至少要负责：

- `session_id / stream_id / sender_ssrc / receiver_id` 映射维护
- 媒体包从发送端到播放端的路由
- `uplink_twcc` 生成
- `downlink_quality` 接收与聚合
- `NACK / PLI` 的反向路由
- 多播放端 `sender_rate_cap` 策略执行

### 9.2 transport feedback 固定策略

第一阶段服务端 transport feedback 策略固定如下：

- sender 上行 QoS 输入：
  - 由 `server` 自己基于 `sender -> server` 收包时间生成 `uplink_twcc`
- 播放端下行反馈：
  - 固定命名为 `downlink_quality`
  - 仅用于下行恢复与服务端策略

### 9.3 多播放端聚合策略

第一阶段固定策略如下：

- 发送端 QoS 控码率：
  - sender `GoogCC` 由 `server` 上行 `uplink_twcc` 驱动
  - 多播放端策略上限使用 `sender_rate_cap`
  - `sender_rate_cap` 默认采用 `worst-receiver wins`
- `NACK`：
  - 播放端 NACK 默认由 `server` 本地处理
- `PLI`：
  - 任一播放端请求先到 `server`
  - 若 `server` 无法通过本地恢复解决，则向上游 sender 转发 `PLI`

### 9.4 retransmission cache 责任

第一阶段重传缓存责任固定如下：

- 每个“直接发送媒体包的一侧”负责缓存自己发出去的包
- `capture_push`：
  - 缓存 `sender -> server` 上行包
- `server`：
  - 缓存 `server -> receive_play` 下行包

### 9.5 retransmission cache 保留窗口

第一阶段缓存窗口固定为：

- `cache_hold_ms = max(1000ms, 3 x smoothed_rtt_ms)`
- 最大上限 `3000ms`

### 9.6 retransmission 包身份规则

第一阶段重传包身份规则固定如下：

- RTP `ssrc`：保持该 hop 原值
- RTP `sequence number`：保持原值
- RTP `timestamp`：保持原值
- marker bit：保持原值
- payload type：保持原值
- transport sequence number：
  - 作为新的发送事件，重新分配新的值

## 10. 底层复用的 WebRTC 模块

本节区分两类交付：

- 独立 SDK 模块：不依赖 WebRTC，直接由 `/root/webrtc_qos_sdk` 的 `CMake` 生成
- WebRTC adapter 模块：在 `/root/src` 的 WebRTC `GN` 工程内构建，然后以独立 `include + lib` 形式安装到 `/root/output`

### 10.1 QoS

发送侧和接收反馈侧的核心是：

- `network_control`
- `goog_cc`
- SDK lightweight `SenderPacer`

源码入口：

- [api/transport/network_control.h](/root/src/api/transport/network_control.h:1)
- [api/transport/BUILD.gn](/root/src/api/transport/BUILD.gn:1)

源码约束：

- `NetworkControllerInterface` 明确要求非并发使用

当前交付状态：

- `//sdk_qos:webrtc_qos_googcc_adapter_complete`
  - 输出：`/root/output/lib/libwebrtc_qos_googcc_adapter.a`
  - 公开头：`/root/output/include/webrtc_qos/googcc_adapter.h`
  - API 不暴露 WebRTC 内部头，只暴露标准 C++ 类型
  - 输入：`sent packet`、`RTCP RR RTT`、`uplink_twcc transport packet feedback`
  - 输出：`target_bitrate_bps`、`pacing_bitrate_bps`
- `RTT` 输入使用 raw `RTCP RR` 计算值，不设置 `RoundTripTimeUpdate.smoothed=true`
- `SenderPacer` 仍为 SDK 自研轻量实现，不直接复用 WebRTC pacer target

发布构建参数固定为：

```gn
is_debug=false
use_sysroot=false
use_lld=false
use_custom_libcxx=false
use_custom_libcxx_for_host=false
use_safe_libstdcxx=false
use_llvm_libatomic=false
rtc_include_tests=false
rtc_build_examples=false
rtc_build_tools=false
rtc_enable_protobuf=false
rtc_use_perfetto=false
rtc_disable_trace_events=true
rtc_rust=false
enable_rust=false
enable_rust_cxx=false
enable_chromium_prelude=false
rtc_enable_grpc=false
```

这些参数的目的：

- `use_custom_libcxx=false`：发布库使用系统 `libstdc++` ABI，避免业务侧混入 Chromium 自带 `libc++`
- `use_lld=false`：避免输出对象包含系统 GNU `ld` 不能识别的 `.crel.*` section
- `use_safe_libstdcxx=false`：避免输出库依赖较新 `libstdc++` 才有的 `_GLIBCXX_ASSERTIONS` 符号
- `rtc_enable_protobuf=false` / `rtc_use_perfetto=false` / `rtc_disable_trace_events=true`：确认 QoS adapter 不需要 protobuf / Perfetto / trace event 闭包
- `rtc_build_examples=false` / `rtc_build_tools=false` / `rtc_include_tests=false`：不构建非主目标

发布 target 必须满足：

- `complete_static_lib=true`
- `suppressed_configs += [ "//build/config/compiler:thin_archive" ]`

原因：WebRTC 默认 thin archive 不适合直接分发，完整静态库必须把传递依赖对象归档进最终 `.a`。

### 10.2 视频 jitter

视频 jitter 的目标能力仍然分两层：

- RTP 包组帧：
  - [api/video/rtp_video_frame_assembler.h](/root/src/api/video/rtp_video_frame_assembler.h:1)
- 帧级 jitter / 解码前排序：
  - [api/video/frame_buffer.h](/root/src/api/video/frame_buffer.h:1)

当前实现采用更小的 Phase-1a 闭包：

- 不直接链接完整 `api/video:rtp_video_frame_assembler`
- 不直接链接完整 `api/video:encoded_frame`
- 不直接链接完整 `modules/rtp_rtcp:rtp_rtcp`
- 不引入 `libyuv`
- 不引入 `protobuf / Perfetto`
- 复用 WebRTC `H264 parser`
- 复用 WebRTC `modules/video_coding::PacketBuffer`
- SDK wrapper 负责 H264 `Single NALU / FU-A` 解析和 Annex-B AU 输出归一化

这样处理的原因是：

- `api/video:rtp_video_frame_assembler` 会带出 `rtp_rtcp`、`video_coding`、`packet_buffer`
- full target 进一步容易拖出 `EncodedFrame`、`VideoFrame`、`libyuv`、trace event 和 protobuf 相关闭包
- Phase-1a 已经固定 `H264 only + packetization-mode=1 + Single NALU/FU-A`，不需要 full assembler 的通用视频能力

当前交付状态：

- `//sdk_qos:webrtc_qos_video_jitter_adapter_complete`
  - 输出：`/root/output/lib/libwebrtc_qos_video_jitter_adapter.a`
  - 公开头：`/root/output/include/webrtc_qos/video_jitter_adapter.h`
  - API 不暴露 WebRTC 内部头，只暴露标准 C++ 类型
  - 输入：RTP header 关键字段、到达时间、H264 payload
  - 输出：完整 `Annex-B access unit`
  - 支持：`Single NALU`、`FU-A`
  - 拒绝：`STAP-A` 和 Phase-1a 之外的 H264 packetization 模式
  - 关键帧输出：必要时从缓存的 `SPS/PPS` 补齐 IDR 前置参数集

当前已落地的最小 GN target：

| 能力 | GN target | 说明 |
| --- | --- | --- |
| H264 parser | `//common_video:h264_only` | 只保留 H264 common / SPS / PPS 解析 |
| RTP video header | `//modules/rtp_rtcp:rtp_video_header_qos_minimal` | 最小 `RTPVideoHeader` 构造/析构，避免 full `VideoFrameMetadata` |
| RTP received packet | `//modules/rtp_rtcp:h264_jitter_minimal` | 只保留 `RtpPacketReceived` 必需闭包 |
| PacketBuffer | `//modules/video_coding:packet_buffer_qos_minimal` | 解码前 RTP 包重排和组帧 |

### 10.3 视频丢包恢复

Phase-1a 视频接收端固定采用 SDK 轻量 NACK 恢复模块，不直接引入 WebRTC `NackRequester`。

当前交付状态：

- 输出：`/root/output/lib/libwebrtc_qos_nack.a`
- 公开头：
  - `/root/output/include/webrtc_qos/receiver_qos_observer.h`
  - `/root/output/include/webrtc_qos/retransmission_cache.h`
- 职责：
  - `ReceiverQosObserver` 检测 RTP sequence gap
  - 生成 NACK 候选 RTP sequence number
  - `RetransmissionCache` 在每个发送 hop 保持 RTP 身份并分配新的 transport sequence number

不直接引入 WebRTC `NackRequester` 的原因：

- [modules/video_coding/nack_requester.h](/root/src/modules/video_coding/nack_requester.h:1) 不是纯算法类
- 其构造要求 `TaskQueueBase*`、`NackPeriodicProcessor*`、`Clock*`、`NackSender*`、`KeyFrameRequestSender*`、`FieldTrialsView`
- 官方 target `//modules/video_coding:nack_requester` 会引入：
  - `//api/task_queue:task_queue`
  - `//api/task_queue:pending_task_safety_flag`
  - `//api:field_trials_view`
  - `//rtc_base/task_utils:repeating_task`
  - `//rtc_base:logging`
  - `//system_wrappers`
  - 多个 abseil 基础 target
- 这会把 Phase-1a 的接收恢复模块绑定到 WebRTC task queue / field trial / repeating task 模型，不符合当前“自定义传输 + 小库按需集成”的边界

审计命令：

```bash
PATH=/root/py311bin:/root/depot_tools:$PATH \
  gn desc out/qos_min //modules/video_coding:nack_requester deps --all

PATH=/root/py311bin:/root/depot_tools:$PATH \
  gn path out/qos_min //modules/video_coding:nack_requester //api/task_queue:task_queue

PATH=/root/py311bin:/root/depot_tools:$PATH \
  gn path out/qos_min //modules/video_coding:nack_requester //api:field_trials_view

PATH=/root/py311bin:/root/depot_tools:$PATH \
  gn path out/qos_min //modules/video_coding:nack_requester //rtc_base:logging
```

后续如果业务确实需要 WebRTC `NackRequester` 的重试退避和 reorder histogram，可以作为 Phase-1b/独立重型 adapter 再做。

WebRTC 源码入口：

- [modules/video_coding/nack_requester.h](/root/src/modules/video_coding/nack_requester.h:1)

### 10.4 Pacing

`Phase-1a` 固定采用 SDK 轻量 pacer：

- 运行线程：`worker thread`
- 调度方式：固定周期 tick
- tick 间隔：`5ms`
- 配额模型：`token bucket / bytes budget`
- 队列上限：
  - 最大媒体时长：`500ms`
  - 最大缓存字节：`512KB`
- 包优先级：
  - `NACK` 重传包高于普通媒体包
  - `PLI` 控制消息不走媒体 pacer
- 队列满时策略：
  - 普通 `P` 帧可丢
  - 丢弃 `P` 帧后，必须等待或触发下一次 `IDR`，避免参考链持续污染
  - `IDR` 不轻易丢，但仍受队列和 pacing budget 限制
- `IDR` 可短时 burst，但必须同时受：
  - 最大发送队列长度
  - pacing budget
  限制

### 10.5 音频

音频 `NetEq + Opus` 仅属于 `Phase-1b`，不属于 `Phase-1a` 必选构建。

## 11. push / play 两端职责

### 11.1 capture_push

职责：

- 本地采集视频
- 编码
- RTP 打包
- 发送
- 接收来自服务端的 QoS 控制反馈
- 将 `uplink_twcc`、`RTCP SR/RR RTT` 和 `sender_rate_cap` 喂给发送侧 QoS 控制器

### 11.2 receive_play

职责：

- 接收 RTP / RTCP
- 记录收包时间、丢包、乱序、RTT
- 视频走 SDK H264 payload wrapper + WebRTC `PacketBuffer` 最小闭包
- 必要时发 `NACK / PLI / downlink_quality`
- 向解码器输出完整 `Annex-B access unit`
- 解码后播放

## 12. 为什么 play 端必须接入 qos + jitter

如果 `play` 端只做播放，不做反馈：

- 下行恢复无法及时触发
- 服务端拿不到准确的接收质量观测
- 无法正确生成多播放端策略上限
- jitter buffer 只能被动兜底

## 13. Phase-1a 最小构建依赖与 GN target 表

`Phase-1a` 当前拆为自研 SDK target 和 WebRTC adapter target。

最终交付原则固定为：

- 不交付一个巨大的 `libwebrtc.a`
- WebRTC 能力按功能拆成 adapter 小库
- 自研传输、协议 glue、demo 仍在 `/root/webrtc_qos_sdk`
- 应用按角色选择链接需要的小库
- 需要快速原型时可以链接统一 facade，但生产推荐按需链接

角色到库的推荐组合：

| 角色 | 必选库 | 可选库 |
| --- | --- | --- |
| `capture_push` | `core`、`rtp`、`rtcp`、`feedback`、`pacer`、`video`、`googcc_bridge`、`googcc_adapter` | `ffmpeg_encoder` 基础真实编码器验证；后续真实采集 adapter |
| `server relay` | `rtp`、`rtcp`、`feedback`、`nack` | 后续 mixer / recorder |
| `receive_play` | `core`、`rtp`、`rtcp`、`feedback`、`nack`、`video`、`video_jitter_bridge`、`video_jitter_adapter` | 后续 renderer adapter |
| prototype | `libwebrtc_qos.a` | `libwebrtc_qos_googcc_bridge.a`、`libwebrtc_qos_googcc_adapter.a`、`libwebrtc_qos_video_jitter_bridge.a`、`libwebrtc_qos_video_jitter_adapter.a` |

CMake package 同时暴露模块级 target 和角色级 target：

| CMake target | 说明 |
| --- | --- |
| `WebRtcQosSdk::role_transport` | 只包含业务传输接入边界 |
| `WebRtcQosSdk::role_server` | server relay 所需 RTP/RTCP/feedback/NACK helper |
| `WebRtcQosSdk::role_push` | push 端 H264 sender、pacer、feedback、WebRTC GoogCC |
| `WebRtcQosSdk::role_play` | play 端 receiver QoS、H264 jitter、WebRTC PacketBuffer adapter |
| `WebRtcQosSdk::role_prototype` | 原型期统一 facade 加可选 WebRTC adapter |

角色级 target 只是 CMake `INTERFACE IMPORTED` 聚合，不改变物理库拆分；业务仍可继续按模块级 target 精确链接。

当前和后续小库矩阵：

| 库 | 状态 | 来源 | 职责 |
| --- | --- | --- | --- |
| `libwebrtc_qos_core.a` | 已实现 | 自研 SDK | H264 Annex-B helper / 公共类型 |
| `libwebrtc_qos_rtp.a` | 已实现 | 自研 SDK | RTP parse/serialize / TWCC header extension |
| `libwebrtc_qos_rtcp.a` | 已实现 | 自研 SDK | SR/RR/TWCC/NACK/PLI helper |
| `libwebrtc_qos_feedback.a` | 已实现 | 自研 SDK | feedback 协议、rate cap、默认轻量 sender estimator、backend facade |
| `libwebrtc_qos_transport.a` | 已实现 | 自研 SDK | 业务传输接入 port，定义消息类型和 send/deliver 回调 |
| `libwebrtc_qos_nack.a` | 已实现 | 自研 SDK | RTP gap 检测、NACK 候选、重传缓存 |
| `libwebrtc_qos_pacer.a` | 已实现 | 自研 SDK | Phase-1a 轻量 pacer |
| `libwebrtc_qos_video.a` | 已实现 | 自研 SDK | H264 packetize/depacketize、当前最小 video jitter |
| `libwebrtc_qos_ffmpeg_encoder.a` | 已实现/可选 | FFmpeg/libx264 adapter | I420 -> H264 Annex-B 基础编码器，用于真实编码链路验证，不进入 core 闭包 |
| `libwebrtc_qos_ffmpeg_decoder.a` | 已实现/可选 | FFmpeg/libavcodec adapter | H264 Annex-B -> decoded frame 基础解码器，用于 QoE 验证，不进入 core 闭包 |
| `libwebrtc_qos_googcc_bridge.a` | 已实现 | SDK/WebRTC bridge | `SenderQosController` 可选接入 `GoogCcAdapter` |
| `libwebrtc_qos_googcc_adapter.a` | 已实现 | WebRTC adapter | `network_control/goog_cc` |
| `libwebrtc_qos_video_jitter_bridge.a` | 已实现 | SDK/WebRTC bridge | `VideoJitterPlayer` 可选接入 `VideoJitterAdapter` |
| `libwebrtc_qos_video_jitter_adapter.a` | 已实现 | WebRTC adapter | H264 parser + `PacketBuffer` 最小闭包 |
| `libwebrtc_qos_nack_adapter.a` | Phase-1b/可选 | WebRTC adapter | 重型 `NackRequester` adapter，Phase-1a 不纳入 |
| `libwebrtc_qos_audio_neteq_adapter.a` | Phase-1b | WebRTC adapter | `NetEq + Opus` |

自研 SDK 由 `CMake` 输出：

- `libwebrtc_qos_core.a`
- `libwebrtc_qos_rtp.a`
- `libwebrtc_qos_rtcp.a`
- `libwebrtc_qos_feedback.a`
- `libwebrtc_qos_transport.a`
- `libwebrtc_qos_nack.a`
- `libwebrtc_qos_pacer.a`
- `libwebrtc_qos_video.a`
- `libwebrtc_qos_ffmpeg_encoder.a`，当本机存在 FFmpeg/libx264 headers/libs 时启用
- `libwebrtc_qos_ffmpeg_decoder.a`，当本机存在 FFmpeg/libavcodec headers/libs 时启用
- `libwebrtc_qos.a`

WebRTC QoS adapter 由 `GN` 输出：

- `//sdk_qos:webrtc_qos_googcc_adapter`
- `//sdk_qos:webrtc_qos_googcc_adapter_complete`
- `//sdk_qos:webrtc_qos_googcc_smoke`
- `//sdk_qos:webrtc_qos_video_jitter_adapter`
- `//sdk_qos:webrtc_qos_video_jitter_adapter_complete`
- `//sdk_qos:webrtc_qos_video_jitter_smoke`
- 聚合入口：`//:sdk_qos`

当前已落地的 WebRTC 最小 target：

| 能力 | GN target | 说明 |
| --- | --- | --- |
| GoogCC adapter | `//sdk_qos:webrtc_qos_googcc_adapter_complete` | 可分发完整静态库 |
| GoogCC 核心 | `//modules/congestion_controller/goog_cc:goog_cc_qos_minimal` | 只保留 `GoogCcNetworkController` 必要闭包 |
| ALR | `//modules/congestion_controller/goog_cc:alr_detector_qos_minimal` | GoogCC 必要输入 |
| Delay BWE | `//modules/congestion_controller/goog_cc:delay_based_bwe_qos_minimal` | TWCC 到延迟趋势估计 |
| Send-side BWE | `//modules/congestion_controller/goog_cc:send_side_bwe_qos_minimal` | loss/RTT/ack 汇总 |
| Probe | `//modules/congestion_controller/goog_cc:probe_controller_qos_minimal` | 探测控制 |
| Loss BWE | `//modules/congestion_controller/goog_cc:loss_based_bwe_v2_qos_minimal` | loss-based estimate |
| Remote BWE core | `//modules/remote_bitrate_estimator:remote_bitrate_estimator_bwe_core` | 只保留 `aimd_rate_control` / `bwe_defines` |
| Video jitter adapter | `//sdk_qos:webrtc_qos_video_jitter_adapter_complete` | 可分发完整静态库 |
| H264 parser | `//common_video:h264_only` | 只保留 H264 common / SPS / PPS 解析 |
| RTP packet minimal | `//modules/rtp_rtcp:rtp_packet_minimal` | 只保留 `RtpPacket` 基础能力 |
| RTP video header minimal | `//modules/rtp_rtcp:rtp_video_header_qos_minimal` | 避免 full `rtp_video_header` 依赖 |
| PacketBuffer minimal | `//modules/video_coding:packet_buffer_qos_minimal` | 解码前 RTP 包重排和组帧 |

当前不纳入主闭包、后续再评估的 WebRTC target：

| 能力 | GN target | 说明 |
| --- | --- | --- |
| full 视频 RTP 组帧 | `//api/video:rtp_video_frame_assembler` | 通用能力过大，Phase-1a 已被最小 wrapper 替代 |
| full 视频帧 jitter | `//api/video:frame_buffer` | 依赖较重，当前用 `PacketBuffer` 最小闭包 |
| 视频丢包恢复 | `//modules/video_coding:nack_requester` | 重试退避 / reorder histogram 较完整，但依赖 task queue / field trial；Phase-1a 用 SDK 轻量 NACK 替代 |

`Phase-1a` 构建不要求：

- `NetEq`
- `Opus`
- 音频 demo
- full WebRTC `PeerConnection`
- WebRTC full `pacing` target
- WebRTC full `rtp_rtcp` target
- WebRTC full `api/video:rtp_video_frame_assembler`
- `libyuv`
- `protobuf`
- `Perfetto`

## 14. 对外公开接口草案

### 14.1 sender_qos_controller.h

职责：

- 初始化发送侧 QoS 控制器
- 输入发送包事件
- 输入来自 server 的 `uplink_twcc`
- 输入来自 server 的 `RTCP SR/RR RTT`
- 输入来自 server 的 `sender_rate_cap`
- 输出目标码率、pacing budget

### 14.2 sender_pacer.h

职责：

- SDK 内置 pacer
- 根据 QoS 控制器输出的目标码率和 pacing budget 决定实际发包时间
- 使用 `token bucket / bytes budget`
- `NACK` 重传包优先级高于普通媒体包
- `IDR` 可短时 burst，但受最大队列长度和 pacing budget 限制
- 业务层只提供 `SendPacket()` 回调
- 业务层不直接控制发送节奏

### 14.3 receiver_qos_observer.h

职责：

- 记录接收包时间
- 统计丢包 / 乱序
- 生成 `downlink_quality`
- 生成恢复控制事件

### 14.4 video_jitter_player.h

职责：

- 输入 RTP 视频包
- 输出完整 `Annex-B access unit`
- 触发丢包恢复建议
- 获取缓存深度、乱序、丢帧统计

### 14.5 video_sender.h

职责：

- 负责 H264 access unit 发送入口
- 负责打包前 timestamp / sequence / extension 配置接入
- 与 `sender_qos_controller` 和 `sender_pacer` 协同确定发送节奏

### 14.6 video_receiver.h

职责：

- 负责 RTP/RTCP 接收入口
- 负责将 RTP 包交给 `receiver_qos_observer` 和 `video_jitter_player`
- 负责回发 `downlink_quality / NACK / PLI`

### 14.7 transport_port.h

职责：

- 固定 SDK 与业务传输层之间的消息类型
- 携带 `TransportIds` 映射信息，但不污染 RTP/RTCP payload
- 业务侧实现 send 回调，将消息写入自定义 UDP/TCP/可靠控制通道
- 业务侧收到网络包后调用 deliver 回调，把 payload 交回 SDK/业务 session
- 作为替换 `DEMO_TRANSPORT_V1` 的生产接入边界

生命周期规则：

- send/deliver 都是同步 callback 边界
- callback 中看到的 `payload` 是借用视图
- 异步发送必须在 send callback 内复制 payload
- 异步处理接收数据必须在 receive callback 内复制 payload
- `libwebrtc_qos_transport.a` 不引入任何 WebRTC 网络栈依赖

### 14.7.1 production_transport_adapter.h

职责：

- 提供生产传输接入模板，不定义业务 wire format
- 将 SDK 借用 payload 转成可异步排队的 owned message
- 统一消息到 lane 的默认映射
- 让业务传输可以按不可靠媒体、不可靠控制、可靠控制三类通道实现发送
- 作为替换 `DEMO_TRANSPORT_V1` 时的推荐起点

### 14.8 video_capturer.h

状态：`experimental placeholder`，不属于 `Phase-1a` 稳定公开 API

职责：

- 抽象摄像头采集
- Linux 下后续集成项优先支持 `V4L2`

### 14.9 video_renderer.h

状态：`experimental placeholder`，不属于 `Phase-1a` 稳定公开 API

职责：

- 抽象解码后帧显示
- Linux 下后续集成项优先支持 `SDL2` 或平台渲染封装

## 15. SDK 线程模型与生命周期

### 15.1 时钟来源

SDK 所有时间相关逻辑统一要求依赖业务层注入的 `monotonic clock`：

- QoS feedback 时间戳
- jitter 统计
- RTT 估计
- NACK 定时

### 15.2 线程角色

第一阶段固定三个逻辑线程：

- `network thread`
  - RTP/RTCP 收发
  - feedback 收发
- `worker thread`
  - QoS 控制
  - jitter buffer
  - NACK/PLI 处理
  - pacer 定时
- `media thread`
  - 编码
  - 解码
  - 渲染回调

### 15.2.1 时间戳采样与保序规则

第一阶段固定如下：

- RTP 到达时间戳在 `network thread` 上、UDP 收包完成后立即采样
- 同一个 `transport_id` 上的收包事件必须以 FIFO 顺序从 `network thread` 投递到 `worker thread`
- transport feedback 统计和 jitter buffer 插入对同一流使用同一有序事件流
- 不允许对同一流在多个 worker 队列并发处理

## 16. demo 设计

### 16.1 demo/capture_push

内容：

- synthetic 或文件源
- 编码固定 H264
- RTP 发送
- RTCP `SR/RR` 与 `uplink_twcc` 接收
- 输出当前发送码率、RTT、loss、pacing 状态

### 16.2 demo/receive_play

内容：

- RTP 接收
- 视频进入 SDK H264 payload wrapper + WebRTC `PacketBuffer` 最小闭包
- 解码器消费完整 `Annex-B access unit`
- 回发 `downlink_quality / NACK / PLI`
- 输出 jitter、buffer depth、drop、reorder、RTT

### 16.3 第一阶段 demo 收敛策略

第一阶段 demo 严格收敛为：

- 先 `H264 文件流 / synthetic AU -> RTP -> server relay -> receive_play -> Annex-B AU`
- 再加丢包、乱序、delay 模拟
- 最后才接真实采集和渲染

当前额外落地了一个真实 UDP 三进程 demo：

- `udp_sender_demo`
  - synthetic H264 Annex-B AU
  - SDK RTP packetizer
  - SDK lightweight pacer
  - `GoogCcAdapter`
  - 接收 server 生成的 `uplink_twcc`
  - 发送 `RTCP SR`
  - 接收 server 生成的 `RTCP RR`
  - 接收 server 生成的 `SENDER_RATE_CAP_V1`
  - 接收 server 转发的 `PLI` 后重新发送 `IDR`
- `udp_server_demo`
  - UDP server relay
  - `DEMO_TRANSPORT_V1` envelope 解析和 session/stream 映射
  - 参数化 intentional packet drop / reorder / delay
  - retransmission cache
  - receiver NACK 本地恢复
  - receiver PLI 转发到 sender
  - 基于 sender 上行收包生成 `uplink_twcc`
  - 基于 `RTCP SR` 生成 `RTCP RR`
  - 基于 NACK / downlink quality 生成 `SENDER_RATE_CAP_V1`
- `udp_receiver_demo`
  - UDP receive_play
  - `ReceiverQosObserver`
  - NACK / downlink_quality 上报
  - 发送 `PLI` 并验证 sender 重新输出 `IDR`
  - WebRTC-backed `VideoJitterAdapter`
  - 输出完整 `Annex-B access unit`
  - 原包延迟到达且重传包先完成时，按 `RTP timestamp` 去重，避免重复输出同一帧

## 17. 第一阶段实施顺序

按以下顺序推进：

1. 文档和 SDK 边界
2. `include/` facade 头设计
3. 最小 `libwebrtc_qos.a`
4. 优先打通 `receive_play` 的 QoS + jitter 链路
5. 再补 `capture_push`
6. 最后补采集/渲染的工程化封装

## 18. 安全边界

第一阶段明确如下：

- 该 SDK 默认不提供公网安全传输能力
- 若运行在公网，传输层加密、鉴权、防重放由业务侧自定义传输实现负责

## 19. 当前机器上的现实约束

当前这台机器已经把 WebRTC 源码抓下来了，但磁盘空间很紧，后续不适合直接追完整 `libwebrtc.a`。

因此本项目的构建策略固定为：

- 只编最小目标
- 不编完整 `webrtc`
- 先做聚合最小静态库
- 有条件时迁移到资源更充足的 Ubuntu 构建机

## 20. Phase-1a 验收标准

### 20.1 H264 RTP 子集验收

- 只接入 H264
- 只允许 I/P 帧
- `packetization-mode=1`
- `Single NALU + FU-A` 闭环通过
- `PLI -> IDR` 恢复链路通过
- 接收端能稳定输出完整 `Annex-B access unit`

### 20.2 QoS feedback 验收

- transport sequence number 正确生成
- RTP header extension URI / ext id 对齐
- sender 能消费来自 server 的 `uplink_twcc`
- sender/server RTT 主路径走 RTCP `SR/RR`
- `RTCP SR/RR` 周期固定为 `1000ms`
- `GoogCC / network_control` 输出目标码率变化可观测
- `sender_rate_cap` 生效可观测
- SDK 内置 pacer 生效可观测
- 动态网络 `good -> outage -> poor -> recovering -> good_again` 下，SDK encoder adaptation 能在网络变差时下调 bitrate/FPS，在网络恢复后提升 FPS

### 20.3 接收侧 jitter 验收

- SDK H264 wrapper + WebRTC `PacketBuffer` 最小闭环通过
- `libwebrtc_qos_video_jitter_adapter.a` 能输出完整 `Annex-B access unit`
- `Single NALU` 和 `FU-A` smoke 通过
- NACK 生效
- 丢包情况下可恢复播放
- `Phase-1a` 不要求音频作为必须项

### 20.4 服务端边界验收

- `SSRC / stream_id` 映射明确
- sender 上行 `uplink_twcc` 生成链路打通
- 多播放端策略固定
- 下行 NACK 默认由 server 本地响应

### 20.5 demo 验收

- synthetic/文件流闭环跑通
- 日志能输出码率、RTT、loss、jitter、drop、NACK、PLI
- installed-output 集成 demo 能只依赖 `/root/output/include + /root/output/lib` 编译运行
- `transport_port_demo` 能验证业务传输替换边界，不依赖 UDP demo envelope，并验证异步传输需要在 send callback 内复制 payload
- `production_transport_demo` 能验证生产接入模板的 payload owned-copy 和 media/control/reliable-control lane 分流
- 集成 demo 能同时覆盖 SDK RTP packetizer、轻量 pacer、server cache/NACK 恢复、GoogCC adapter、WebRTC-backed video jitter adapter
- UDP 三进程 demo 能跑通 sender -> server -> receiver 的真实 UDP loopback
- UDP demo 能验证 `DEMO_TRANSPORT_V1` envelope 的 session/stream 映射层
- UDP demo 能验证 intentional loss、reorder、delay、receiver NACK、server retransmission、server -> sender uplink TWCC、RTCP SR/RR RTT、server -> sender rate cap、receiver Annex-B AU 输出
- `run_udp_netem_matrix.sh` 能读取 `scripts/udp_netem_scenarios.json`，按预定义弱网场景和预期指标执行验收
- 预定义弱网场景包括：`baseline_single_loss`、`burst_loss`、`reorder_only`、`delay_only`、`jitter_periodic`、`mixed_loss_reorder_delay_jitter`
- 每个场景显式定义网络损伤模型和 expected metrics threshold，包括最小 feedback/RR/rate cap/PLI/NACK/retransmission/frame 数，以及是否必须观测到 reorder/delay/jitter
- `run_udp_netem_matrix.sh` 能输出 `${LOG_DIR}/metrics.jsonl` 和 `${LOG_DIR}/summary.json`，并按阈值校验恢复帧数、RTT、最终码率、NACK/重传成功率、观测丢包、上报丢包和 jitter
- `run_udp_soak.sh` 能按时长重复执行弱网矩阵，并统计 pass/fail，作为接入业务传输前的长稳入口
- `verify_role_linking.sh` 能证明 push/server/play/transport 四种角色可按需链接小库，不依赖一个巨大 `libwebrtc.a`
- `verify_cmake_package.sh` 能证明外部工程通过 `find_package(WebRtcQosSdk CONFIG REQUIRED)` 链接 `role_transport / role_server / role_push / role_play / role_prototype`
- `dynamic_qos_demo` 能验证时变网络下的码率/FPS 自适应决策，不只覆盖单个 good/bad 场景
- `run_dynamic_qos_matrix.sh` 能读取 `scripts/dynamic_qos_scenarios.json`，按预定义动态弱网场景和预期 QoS/QoE 指标执行验收
- 动态弱网场景包括：`walk_outage_recover`、`bandwidth_cliff_recover`、`rtt_jitter_spike_recover`、`oscillating_edge`、`loss_burst_recover`
- 动态矩阵必须验证：弱网进入时 `encoder_bps/max_fps` 降档，严重弱网请求关键帧，网络恢复时 `encoder_bps/max_fps` 升档
- `ffmpeg_encoder_demo` 在存在 FFmpeg/libx264 时必须跑通真实 I420 -> H264 Annex-B -> `VideoSender` -> `SenderPacer` 链路
- `long_stream_qoe_demo` 在存在 FFmpeg/libx264 时必须跑通真实 H264 长流：`VideoSender -> SenderPacer -> server-like cache/NACK -> VideoReceiver/VideoJitterPlayer`
- `run_long_stream_qoe_matrix.sh` 必须比较 `adaptive / balanced / bitrate_only / fixed` 四类策略，并输出 smoothness-only 与 balanced-QoE 两套目标函数结果
- `run_long_stream_qoe_matrix.sh` 在存在 FFmpeg/libavcodec/libswscale 时必须真实解码 receiver Annex-B AU，输出 I420，并按 decoded PTS/RTP timestamp 与源 I420 帧对齐计算 PSNR
- `decode_errors`、`decoded_frames`、`quality_samples`、`psnr_avg`、`psnr_min`、`frame_latency_*`、`jitter_buffer_*`、`adaptation_response_time_ms` 必须进入 QoE 分数
- WebRTC backend 可用时，长流矩阵必须硬性验证：`webrtc/adaptive` 每个场景 `decode_errors=0`、每个 receiver frame 都有 source-aligned quality sample、frame-latency sample 和 jitter-buffer sample、`psnr_avg >= 20.0dB`、`psnr_min >= 14.0dB`、`frame_latency_max_ms <= 1800`、`jitter_buffer_max_ms <= 1200`，满足弱网降档、好网恢复和分阶段响应时间阈值，每个场景都是 best 或 tied-best balanced-QoE，且 aggregate best balanced-QoE 也是 `webrtc/adaptive`
- `bitrate_only / fixed` 等负面对照策略允许单 case 阈值失败，但脚本必须继续采集 summary 并纳入统一评分，不能因为第一个失败对照中断矩阵
- 长流 QoE 结论必须限定在预定义场景、候选策略集合和目标函数内，不能宣称全局最优

## 21. 外部参考

- 官方 WebRTC Linux 示例：
  - https://webrtc.googlesource.com/src/+/refs/heads/main/examples/peerconnection/client/
- libmediasoupclient：
  - https://mediasoup.org/documentation/v3/libmediasoupclient/design/
  - https://mediasoup.org/documentation/v3/libmediasoupclient/installation/
- mediasoup-cpp PlainTransport QoS case 设计参考：
  - https://github.com/shenleilei/mediasoup-cpp/blob/main/docs/plain-client-qos-case-results.md
  - 该参考覆盖 baseline、bandwidth sweep、loss sweep、RTT sweep、jitter sweep、transition、burst、traffic model、oscillation 等 case 分类；本 SDK Phase-1a 采用相同思路，把静态弱网矩阵和动态转场矩阵拆开验收。
- W3C WebRTC Stats：
  - https://www.w3.org/TR/webrtc-stats/
  - 指标体系参考 sender target bitrate / FPS / encoded frames / key frames / QP / encode time / packet send delay，以及 receiver freeze / total freeze duration / jitter buffer delay / NACK / discarded packets 等字段。
- LiveKit connection quality：
  - https://kb.livekit.io/articles/2455399507-how-is-connection-quality-determined
  - LiveKit 的 SFU 侧质量评分把 packet loss、video layer delivery、bitrate 等作为活跃因子。Phase-1a 先采用同类方向：同时看连续性、丢包/丢弃、有效帧和重复帧，不只看单一 bitrate。

## 22. Phase-1a 结论

`Phase-1a` 固定方案如下：

- 视频：`H264 only`
- `profile-level-id=42e01f`
- `720p30`
- `I/P` 帧，禁 `B` 帧
- `RTP payload type = 96`
- `packetization-mode=1`
- 只支持 `Single NALU + FU-A`
- sender 输入：`Annex-B access unit`
- receiver 输出：完整 `Annex-B access unit`
- sender 只消费 server 生成的 `uplink_twcc + RTCP RR RTT`
- SDK 内置 `SenderPacer`
- receive_play 上报 `downlink_quality / NACK / PLI`
- server 本地恢复，必要时转发 `PLI`
- 多播放端只通过 `SENDER_RATE_CAP_V1` 限制 sender
- 音频全部放到 `Phase-1b`

## 23. 当前实现状态

当前已经落地一个 `Phase-1a` 自包含原型工程：

- 工程目录：`/root/webrtc_qos_sdk`
- 交付目录：`/root/output`
- 自研 SDK facade 静态库：`/root/output/lib/libwebrtc_qos.a`
- WebRTC GoogCC adapter 静态库：`/root/output/lib/libwebrtc_qos_googcc_adapter.a`
- WebRTC video jitter adapter 静态库：`/root/output/lib/libwebrtc_qos_video_jitter_adapter.a`
- WebRTC video jitter bridge 静态库：`/root/output/lib/libwebrtc_qos_video_jitter_bridge.a`
- 业务传输接入静态库：`/root/output/lib/libwebrtc_qos_transport.a`
- 公开头：`/root/output/include/webrtc_qos/`
- demo：`/root/output/demo/`

已实现内容：

- `Phase-1a` facade 头文件
- H264 `Annex-B` access unit 输入
- 接收端完整 `Annex-B` access unit 输出
- H264 `Single NALU + FU-A` RTP 打包和重组
- RTP payload type `96`
- RTP clock `90000 Hz`
- RTP one-byte header extension 中的 transport-wide sequence number
- SDK 轻量 `SenderPacer`
- `DOWNLINK_QUALITY_V1` 二进制编解码
- `SENDER_RATE_CAP_V1` 二进制编解码
- `transport_port.h` 业务传输接入 port
- `production_transport_adapter.h` 生产传输接入模板
- `EncoderAdaptation` 编码器自适应决策输出
- 标准 RTCP `SR / RR / TWCC / NACK / PLI` helper
- SDK 轻量 NACK/恢复库 `libwebrtc_qos_nack.a`
- 重传缓存，重传时保持 RTP 身份并分配新的 transport sequence number
- WebRTC `network_control / goog_cc` 独立 adapter 库
- `googcc_adapter.h` 对外不暴露 WebRTC 内部头
- `googcc_adapter` 已支持 `sent packet + RTCP RR RTT + uplink_twcc` 输入
- `SenderQosController` 已支持默认轻量估算 backend 和可选 GoogCC bridge backend
- `libwebrtc_qos_googcc_bridge.a` 已支持 `SenderQosController -> GoogCcAdapter`
- WebRTC H264 video jitter 独立 adapter 库
- `video_jitter_adapter.h` 对外不暴露 WebRTC 内部头
- `video_jitter_adapter` 已支持 `Single NALU + FU-A -> WebRTC PacketBuffer -> Annex-B AU` 输出
- `VideoJitterPlayer` 已支持默认轻量 backend 和可选 WebRTC video jitter bridge backend
- `libwebrtc_qos_video_jitter_bridge.a` 已支持 `VideoJitterPlayer -> VideoJitterAdapter`
- installed-output 集成 demo 已支持只基于 `/root/output/include + /root/output/lib` 按需链接小库运行
- `transport_port_demo` 已验证业务传输只需实现 send/deliver 回调即可替换 demo envelope
- `production_transport_demo` 已验证推荐生产接入模板会在进入异步传输队列前复制 payload，并按 lane 分流
- 集成 demo 已覆盖 `VideoSender -> SenderPacer -> server retransmission cache -> SenderQosController/GoogCC bridge -> ReceiverQosObserver -> VideoJitterPlayer/WebRTC jitter bridge`
- UDP 三进程 demo 已支持 `udp_sender_demo -> udp_server_demo -> udp_receiver_demo`
- UDP demo 已覆盖 intentional packet loss、receiver NACK、server retransmission、uplink TWCC、WebRTC-backed video jitter output
- UDP demo 已覆盖 `PLI -> server forward -> sender IDR resend -> receiver keyframe output`
- UDP 弱网矩阵已支持配置驱动的预定义弱网场景：单点丢包、突发丢包、乱序、固定延迟、周期性 jitter、混合损伤
- UDP 弱网矩阵已支持 JSONL/summary 指标输出和阈值验收
- `dynamic_qos_demo` 已支持多类动态弱网转场：行走掉网恢复、带宽 cliff、RTT/jitter spike、振荡网络、突发丢包恢复
- `run_dynamic_qos_matrix.sh` 已支持 JSONL/summary 指标输出和阈值验收，覆盖弱网降档、恢复升档、关键帧请求
- `ffmpeg_encoder_demo` 已支持真实 FFmpeg/libx264 I420 -> H264 Annex-B 编码，并将输出接入 `VideoSender + SenderPacer`
- `long_stream_qoe_demo` 已支持真实 FFmpeg/libx264 H264 长流穿过 `VideoSender -> SenderPacer -> server-like cache/NACK -> VideoReceiver/VideoJitterPlayer`
- `libwebrtc_qos_ffmpeg_decoder.a` 已支持真实 FFmpeg/libavcodec H264 decode，低延迟单线程打开 decoder，输入 RTP timestamp 作为 PTS，并输出 I420 平面供 QoE 验证按 decoded PTS 计算 PSNR
- `run_long_stream_qoe_matrix.sh` 已支持 `adaptive / balanced / bitrate_only / fixed` 策略对比，并输出 smoothness-only 与包含 decode-error/PSNR 惩罚的 balanced-QoE 两套分数
- UDP soak 脚本已支持按时长重复执行弱网矩阵并汇总 pass/fail
- WebRTC-backed video jitter bridge 已处理重传包先到、原包后到导致的重复帧去重
- synthetic/file 风格 loopback demo
- 丢一个 RTP 包、触发恢复、从 server cache 重传、最终恢复输出两帧的 demo 路径

当前实现边界：

- `SenderQosController` 默认仍保留轻量估算 backend，避免基础 feedback 库强制依赖 WebRTC
- WebRTC `network_control / goog_cc` 已通过独立 `libwebrtc_qos_googcc_bridge.a` 接入 `SenderQosController`
- `VideoJitterPlayer` 默认仍保留轻量 backend，避免基础 video 库强制依赖 WebRTC
- WebRTC video jitter 已通过独立 `libwebrtc_qos_video_jitter_bridge.a` 接入 `VideoJitterPlayer`
- WebRTC `NackRequester` 已完成依赖审计，Phase-1a 明确不纳入；当前使用 `libwebrtc_qos_nack.a` 轻量恢复库
- WebRTC full `rtp_video_frame_assembler / frame_buffer` 没有进入主闭包，当前使用更小的 `PacketBuffer` 路线
- WebRTC `nack_requester` 不属于 Phase-1a 主目标；如后续确认需要，再作为独立重型 adapter 接入
- 当前 UDP demo 使用本机 loopback UDP 和 demo envelope，尚不是生产传输协议
- `ffmpeg_encoder_demo` 是基础编码器验证，不等价于真实 camera capture pipeline
- 音频、`NetEq`、`Opus`、真实采集、真实渲染仍属于后续阶段

已验证命令：

```bash
cmake -S webrtc_qos_sdk -B webrtc_qos_sdk/build -DCMAKE_BUILD_TYPE=Release
cmake --build webrtc_qos_sdk/build -j2
./webrtc_qos_sdk/build/webrtc_qos_selftest
./webrtc_qos_sdk/build/qos_loopback_demo
./webrtc_qos_sdk/build/capture_push_demo
./webrtc_qos_sdk/build/receive_play_demo
./webrtc_qos_sdk/build/transport_port_demo
cmake --install webrtc_qos_sdk/build --prefix output
bash webrtc_qos_sdk/scripts/package_webrtc_googcc.sh
./output/demo/webrtc_qos_googcc_smoke
./output/demo/webrtc_qos_video_jitter_smoke
bash webrtc_qos_sdk/scripts/build_googcc_bridge.sh
./output/demo/webrtc_qos_googcc_bridge_smoke
bash webrtc_qos_sdk/scripts/build_video_jitter_bridge.sh
./output/demo/webrtc_qos_video_jitter_bridge_smoke
bash webrtc_qos_sdk/scripts/build_output_integration_demo.sh
./output/demo/output_integration_demo
bash webrtc_qos_sdk/scripts/build_udp_demos.sh
bash webrtc_qos_sdk/scripts/run_udp_loopback_demo.sh
REORDER_RTP_SEQ=4 DELAY_MS=30 bash webrtc_qos_sdk/scripts/run_udp_loopback_demo.sh
bash webrtc_qos_sdk/scripts/run_dynamic_qos_matrix.sh
bash webrtc_qos_sdk/scripts/run_long_stream_qoe_matrix.sh
bash webrtc_qos_sdk/scripts/run_udp_netem_matrix.sh
DURATION_SEC=60 MATRIX_RUNS=1 bash webrtc_qos_sdk/scripts/run_udp_soak.sh
bash webrtc_qos_sdk/scripts/verify_role_linking.sh
bash webrtc_qos_sdk/scripts/verify_cmake_package.sh
bash webrtc_qos_sdk/scripts/verify_phase1a.sh
```

`verify_cmake_package.sh` 覆盖模块级 target、可选 WebRTC adapter/bridge imported target，以及 `role_transport / role_server / role_push / role_play / role_prototype` 角色级 target。

弱网指标输出：

- `${LOG_DIR}/metrics.jsonl`：每个 scenario/run 一行 JSON 指标
- `${LOG_DIR}/summary.json`：矩阵级聚合指标
- 当前覆盖 QoS 指标：sender RTT、最终目标码率、NACK 次数、重传次数、重传成功率、观测丢包率、上报 loss_q8、jitter frames、rate cap 是否生效
- 当前覆盖 QoE 指标：恢复帧数、关键帧数、最大 frame gap、是否满足最小可播放连续性
- 当前 QoE 阈值：`receiver_frames >= 3`、`keyframes >= 1`、`max_frame_gap_ms <= 34`、`retransmission_success_ratio >= 1.0`
- 当前阈值失败会导致矩阵脚本直接失败，不再只依赖人工读日志

动态 QoS/QoE 指标输出：

- `${LOG_DIR}/metrics.jsonl`：每个动态 scenario/phase 一行 JSON 指标
- `${LOG_DIR}/summary.json`：动态矩阵级聚合指标
- 当前覆盖 QoS 指标：估算码率、最终码率、RTT、loss、编码器目标码率、max FPS、是否请求关键帧
- 当前覆盖 QoE proxy 指标：降码率/降 FPS 后是否仍保持目标最低可播放帧率档位，以及恢复期是否回到 30fps
- 当前阈值不是定性描述，而是每个 phase 都显式定义 `encoder_bps_min/max`、`max_fps_min/max`、`keyframe` expected-vs-actual
- 例：`walk_outage_recover/outage` 期望 `encoder_bps=80000..200000`、`max_fps=5`、`keyframe=true`，本地实测 `156250bps / 5fps / true`
- 例：`bandwidth_cliff_recover/bandwidth_cliff` 期望 `encoder_bps=80000..150000`、`max_fps=5`，本地实测 `118549bps / 5fps`
- 例：`walk_outage_recover/good_again` 期望恢复到 `encoder_bps=2000000..2500000`、`max_fps=30`，本地实测 `2500000bps / 30fps`
- 场景文件：`/root/webrtc_qos_sdk/scripts/dynamic_qos_scenarios.json`
- 场景包括行走掉网恢复、带宽 cliff、RTT/jitter spike、振荡网络、突发丢包恢复

长流 QoE 策略对比指标输出：

- 脚本：`/root/webrtc_qos_sdk/scripts/run_long_stream_qoe_matrix.sh`
- demo：`/root/webrtc_qos_sdk/build/long_stream_qoe_demo`
- 多 run：`MATRIX_RUNS=N` 会对每个场景使用确定性 `network_seed=run` 重复执行，所有失败可按 run/seed 复现
- 链路：真实 FFmpeg/libx264 I420 -> H264 Annex-B -> RTP/FU-A -> SDK pacer -> server-like cache/NACK -> receiver jitter/player
- 场景集合：
  - `walking_dead_zone`：`good -> outage(<100kbps/high RTT/high loss/high jitter) -> poor edge -> good_again`
  - `jitter_loss_oscillation`：中等带宽下高 jitter、周期性 loss/reorder、再恢复
  - `bandwidth_staircase`：中等带宽、阶梯式下降到 poor edge、再恢复
  - `rtt_jitter_spike_recover`：高 RTT + 高 jitter，无显式 packet loss，再恢复
  - `loss_burst_recover`：突发丢包和恢复，独立于 RTT/jitter-only 场景
- backend：`lightweight` 和 `webrtc`
- `lightweight`：SDK fallback estimator + SDK H264 jitter player
- `webrtc`：WebRTC GoogCC bridge + WebRTC H264 video jitter bridge，仍保留 SDK pacer/NACK/server recovery
- 候选策略：`adaptive`、`balanced`、`bitrate_only`、`fixed`
- `smoothness_score`：只优化连续性，包含 freeze count、max freeze、network drops、弱网期 receiver FPS、恢复期 receiver FPS
- `balanced_qoe_score`：在 `smoothness_score` 基础上强惩罚 duplicate frames、network drops、弱网不降码率/FPS、好网不恢复码率/FPS、分阶段响应慢、decode errors、decoded-frame gaps、低 PSNR、高 receiver frame latency、高 jitter-buffer residence time，避免“重复帧不卡顿”“不可解码”“画质明显劣化”“缓冲排队数秒”“反应太慢”或“不自适应但看起来平滑”被误判成高质量
- `decode_errors`：真实 FFmpeg H264 decoder send/receive 失败次数，权重为 `50/次`；合法 decoder buffering/no immediate output 不计为坏帧
- `decoded_frames`：真实 decoder 输出帧数；若 receiver AU 未能产生 decoded frame，则按 decoded-frame gap 追加惩罚
- `quality_samples`：receiver frame 与源 I420 帧按 RTP timestamp 对齐后的 PSNR 样本数
- `psnr_avg / psnr_min`：源 I420 与解码 I420 的 PSNR，当前低于 `23dB` 均值或 `16dB` 最低值会进入 balanced-QoE 惩罚；WebRTC/adaptive 硬阈值为每场景 `psnr_avg >= 20dB`、`psnr_min >= 14dB`
- `frame_latency_avg/max_ms`：源 I420 生成到 receiver AU 输出的端到端 proxy latency；WebRTC/adaptive 硬阈值为 `frame_latency_max_ms <= 1800`
- `jitter_buffer_avg/max_ms`：首个 RTP 包到达 receiver 到完整 AU 输出的 jitter-buffer residence proxy；WebRTC/adaptive 硬阈值为 `jitter_buffer_max_ms <= 1200`
- `adaptation_response_time_ms`：进入每个 phase 后，编码 target bitrate/FPS 第一次达到该 phase 目标阈值的耗时；WebRTC/adaptive 硬阈值当前覆盖 outage、poor、good_again 三类 phase
- hard validation 现在按 run/scenario 执行：`webrtc/adaptive` 必须 `decode_errors=0`、每个 receiver frame 有 source-aligned PSNR、frame latency 和 jitter-buffer sample，满足 PSNR/latency/jitter-buffer/降档/恢复/响应时间阈值，并且在每个 run/scenario 中取得 best 或 tied-best balanced-QoE；aggregate best 也必须是 `webrtc/adaptive`
- 当前本地结果：`smoothness_score` 最优仍可能被高输出策略打平，因此不能单独作为产品结论
- 当前本地结果：`MATRIX_RUNS=2` 下 aggregate `balanced_qoe_score` 最优为 `webrtc/adaptive=132.0`，10 个 seeded case `decode_errors=0`，aggregate `psnr_avg=61.159dB`、`psnr_min=23.200dB`
- 当前本地结果：WebRTC backend 已补齐 periodic process、`data_in_flight`、probe cluster、route-change recovery、server `SENDER_RATE_CAP_V1` 和 smoothed loss-driven FPS adaptation 后，在当前 synthetic multi-scenario dynamic weak-network 矩阵中成为 balanced-QoE 最优候选

当前长流 QoE seeded 结果表（`MATRIX_RUNS=2`，5 场景，10 cases/backend-strategy）：

| Scenario | Best balanced QoE | Worst score | Freeze | Max drops | Duplicate | Worst PSNR avg/min | Max latency/jitter-buffer ms | 最大响应 ms outage/poor/recover | Min Outage/Poor FPS | Min Recovered FPS | 弱网 target bps | Min 恢复 target bps | 结论 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- |
| `walking_dead_zone` | `webrtc/adaptive` | 0.000 | 0 | 0 | 0 | 61.77 / 28.69 | 1310 / 795 | 0 / 0 / 100 | 5.00 / 5.00 | 30.0 | 144000 / 132000 | 2079500 | 深度掉网恢复无 freeze/drop/duplicate，响应时间、延迟和画质样本达标 |
| `jitter_loss_oscillation` | `webrtc/adaptive` | 33.000 | 0 | 11 | 0 | 59.61 / 23.20 | 500 / 430 | 100 / 0 / 100 | 10.00 / 10.00 | 30.0 | 300000 / 213626 | 2079500 | 振荡网络下少量 network drops，但无 freeze/duplicate/decode error，延迟和响应时间达标 |
| `bandwidth_staircase` | `webrtc/adaptive` | 0.000 | 0 | 0 | 0 | 61.25 / 29.68 | 960 / 640 | 0 / 0 / 100 | 10.00 / 5.00 | 30.0 | 390000 / 156000 | 2079500 | 阶梯降带宽和恢复均符合场景化阈值，延迟和响应时间达标 |
| `rtt_jitter_spike_recover` | `webrtc/adaptive` | 0.000 | 0 | 0 | 0 | 60.49 / 26.13 | 720 / 425 | 0 / 0 / 0 | 5.00 / 10.00 | 30.0 | 480000 / 390000 | 2095566 | 高 RTT/jitter 无显式丢包，decode/PSNR/latency/恢复均达标 |
| `loss_burst_recover` | `webrtc/adaptive` | 36.000 | 0 | 12 | 0 | 61.72 / 23.75 | 460 / 370 | 0 / 0 / 0 | 10.00 / 5.00 | 30.0 | 194254 / 116307 | 2000000 | 突发丢包下无 freeze/duplicate/decode error，少量 network drops 进入 QoE 惩罚 |

当前 aggregate 长流 QoE 排名：

| Backend/strategy | Aggregate balanced QoE | PSNR avg/min | Latency avg/max ms | Jitter-buffer avg/max ms | Decode errors | Drops | Duplicates | Failed cases |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `webrtc/adaptive` | 132.000 | 61.159 / 23.200 | 91.2 / 1310 | 35.2 / 795 | 0 | 44 | 0 | 0 |
| `webrtc/balanced` | 2212.000 | 60.831 / 23.200 | 112.9 / 1150 | 39.3 / 640 | 0 | 44 | 0 | 0 |
| `lightweight/adaptive` | 5040.478 | 26.989 / 16.003 | 89.7 / 2900 | 21.6 / 780 | 17 | 38 | 144 | 1 |
| `lightweight/balanced` | 5064.080 | 27.047 / 15.821 | 94.1 / 2295 | 24.9 / 2155 | 19 | 48 | 233 | 0 |
| `webrtc/bitrate_only` | 27339.000 | 57.338 / 20.907 | 175.8 / 745 | 60.5 / 440 | 0 | 73 | 0 | 0 |
| `lightweight/bitrate_only` | 32616.000 | 26.422 / 16.689 | 146.6 / 985 | 29.8 / 680 | 16 | 77 | 893 | 0 |
| `webrtc/fixed` | 83046.087 | 58.891 / 19.767 | 1180.4 / 7295 | 141.5 / 6170 | 0 | 4079 | 0 | 6 |
| `lightweight/fixed` | 94976.903 | 23.638 / 14.364 | 1146.4 / 7360 | 36.6 / 5965 | 155 | 4264 | 486 | 0 |

当前判断：

- 不能再只说“adaptive 能降码率/FPS，所以 QoS 正确”
- QoS 最优必须先定义目标函数：smoothness-only 会偏向高输出策略；当前 balanced-QoE 同时惩罚 duplicate frames、network drops、decode errors、低 PSNR、高延迟/缓冲堆积、弱网不自适应和好网不恢复，因此选出 `webrtc/adaptive`
- 当前证据只证明在这个 5 场景动态弱网集合、2 个 deterministic seed、backend 集合和候选策略集合中，`webrtc/adaptive` 是 balanced-QoE 目标下的最优候选
- WebRTC backend 之所以从弱于 lightweight 变成最优，是因为补齐了缺失闭环：周期性 `OnProcessInterval`、`data_in_flight`、probe cluster 发送和回馈、网络恢复 route-change、server 根据下行质量生成 `SENDER_RATE_CAP_V1`
- C/S 架构下，server 确认链路进入 `good_again` 后应给 sender 触发 route-change，并使用健康链路 start bitrate（当前 demo 为 `2Mbps`）帮助 GoogCC 从深度弱网后的保守状态快速恢复
- 后续接真实渲染后，需要把当前 proxy 指标替换/补充为 WebRTC stats 同类指标：`freezeCount`、`totalFreezesDuration`、真实 `jitterBufferDelay`、`framesDecoded`、`framesDropped`、QP、端到端 glass-to-glass latency 和真实 render queue 指标
- 后续如果要证明“生产最优”，必须扩展到多内容类型、多分辨率、多码率、多时长、多接收端和真实业务传输链路

弱网场景定义：

- 场景文件：`/root/webrtc_qos_sdk/scripts/udp_netem_scenarios.json`
- 场景包括单点丢包、突发丢包、乱序、固定延迟、周期性 jitter、混合损伤
- 每个场景同时定义 network impairment 和 expected metrics threshold
- 验收脚本先构造网络损伤，再解析日志生成指标，最后用阈值自动判定 QoS/recovery 是否符合预期

Phase-1a SDK 交付状态：

- 按模块拆分的 `include + lib` 已完成
- H264 视频 QoS/jitter/recovery 闭环已完成
- WebRTC `GoogCC` 与 H264 video jitter 能力已作为独立 adapter 小库交付
- 业务传输替换边界已通过 `transport_port.h` 和 `transport_port_demo` 固定
- 生产传输接入模板已通过 `production_transport_adapter.h` 和 `production_transport_demo` 固定
- 当前 demo 使用 `DEMO_TRANSPORT_V1` 验证本机 C/S UDP 链路；该 envelope 不属于生产协议要求

Phase-1a 之外的外部集成项：

1. 业务侧用真实生产传输实现 `transport_port.h` 的 send/deliver 回调，替换 `DEMO_TRANSPORT_V1`
2. 业务传输接入后，将 `run_udp_soak.sh` 的思路迁移到生产传输并提升到更长时长、更大码率和更多帧数
3. Phase-1b 再评估 `NetEq/Opus`、真实采集/渲染、WebRTC `NackRequester` 重型 adapter
