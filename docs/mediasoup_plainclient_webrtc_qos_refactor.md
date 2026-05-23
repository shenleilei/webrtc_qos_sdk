# mediasoup-cpp plainclient WebRTC QoS SDK 重构方案

本文档定义 P5 后续的 mediasoup-cpp `plainclient` 重构目标：保留
mediasoup-cpp 上层信令和 PlainTransport 接入能力，废弃 plainclient 里失控的
自研媒体/QoS 发送链路，视频发送统一切到本 SDK 的 WebRTC-first `VideoPushClient`。

## 1. 结论

`plainclient` 不应该再维护第二套 RTP/RTCP/NACK/TWCC/pacer/BWE/QoS。

正确边界是：

- 保留：WebSocket 信令、`join`、`plainPublish`、PlainTransport 参数、UDP socket
  建立、FFmpeg H264 Annex-B 输入、server restart 等上层控制。
- 替换：RTP packetizer、RTCP SR/RR/NACK/PLI/TWCC、重传缓存、pacer、带宽估计、
  publisher QoS controller、弱网矩阵注入、线程内自研 transport controller。
- 新链路：`FFmpeg H264 Annex-B AU -> VideoPushClient -> UDP PlainTransport`。
- P5 阶段只做 H264 video publisher。VP8、audio QoS、多接收端 fanout、RTX/FEC
  不作为本阶段目标。

## 2. 当前 plainclient 不能继续信任的模块

这些模块可以临时保留在 legacy backend 做对照，但不能进入新的默认视频链路：

| 模块 | 问题 |
| --- | --- |
| `client/qos/*` | 自研 publisher QoS 状态机、planner、probe、profile ladder，控制面和媒体面耦合过深。 |
| `client/sendsidebwe/*` | 自研发送侧带宽估计，和 WebRTC GoogCC 重叠。 |
| `client/ccutils/*` | 自研 probe、trend detector、regulator，和 WebRTC pacer/probe 重叠。 |
| `client/RtcpHandler.h` | 自研 SR、RR、NACK、PLI、RTT 估算和重传缓存。 |
| `common/media/rtp/H264Packetizer.*`、`client/Vp8Packetizer.h` | 自研 RTP packetization。H264 应由 SDK 内部 WebRTC-backed packetizer 负责。 |
| `client/SenderTransportController.h` | 自研 pacing、队列、重传优先级和发送预算。 |
| `client/NetworkThread.h` | 把自研 packetizer、RTCP、TWCC rewrite、BWE、pacer 全部串在一起，是主要替换对象。 |
| `PlainClientLegacy.cpp` / `PlainClientThreaded.cpp` 的媒体发送分支 | 当前默认实际调用上述自研链路。 |

## 3. 继续保留的部分

这些部分可以作为上层 glue 继续使用：

| 模块 | 保留方式 |
| --- | --- |
| `client/WsClient.*` | 继续负责 WebSocket request/notification。 |
| `PlainClientApp::InitializeSession()` | 继续执行 `join`、`plainPublish`，并解析 server 返回的 `ip/port/videoTracks/audioPt`。 |
| UDP socket 建立 | 继续使用 connected UDP socket 对接 mediasoup PlainTransport。 |
| FFmpeg 输入/编码 | 继续负责 MP4/camera 到 H264 Annex-B AU。编码参数改由 SDK adaptation 输出驱动。 |
| `serverRestart` 通知 | 继续作为会话重建触发条件。 |
| `producerId/trackId` 映射 | 继续用于日志、排查和业务上报；SDK `TransportIds` 用数值字段承载媒体身份。 |

`getStats` 可以保留为观测输入，但不能再作为核心码率控制依据。码率控制以 SDK
内部 GoogCC、TWCC、RR、NACK/PLI 和业务 rate cap 为准。

## 4. 新架构

```text
mediasoup-cpp signaling
  -> WsClient.join()
  -> WsClient.plainPublish(videoSsrcs, audioSsrc)
  -> plainPublish response
      ip / port / videoTracks[].ssrc / pt / transportCcExtId / producerId
  -> MediasoupPlainSignalingAdapter
      builds webrtc_qos::SessionConfig

FFmpeg H264 Annex-B AU
  -> VideoPushClient::PushAnnexBAccessUnit()
  -> VideoPushClient::Process(now_us)
      WebRTC H264 packetization
      WebRTC RTP/RTCP
      WebRTC GoogCC
      WebRTC PacingController
      sender packet history / retransmission
  -> TransportOutput
  -> connected UDP socket
  -> mediasoup PlainTransport

UDP recv from PlainTransport
  -> RTCP classifier
  -> VideoPushClient::OnTransportFeedback(rtcp, len, now_us)
      TWCC / RR / NACK / PLI handled inside SDK

VideoPushClient::GetTrackEncoderAdaptation()
  -> FFmpeg encoder bitrate/fps/keyframe control
```

mediasoup worker/browser receiver 仍然是下游，P5 不把 mediasoup worker 替换成
`ServerQosRouter`。这里使用的是本 SDK 的 push role。

## 5. Adapter 设计

建议新增一个独立 backend，而不是在旧 backend 上继续打补丁：

```text
client/webrtc_qos_backend/
  MediasoupPlainSignalingAdapter.h/.cc
  PlainUdpTransportAdapter.h/.cc
  WebRtcQosPlainClientBackend.h/.cc
```

运行时通过环境变量切换：

```bash
PLAIN_CLIENT_MEDIA_BACKEND=webrtc_qos_sdk
```

迁移期保留：

```bash
PLAIN_CLIENT_MEDIA_BACKEND=legacy
```

新 backend 稳定后，默认值改为 `webrtc_qos_sdk`，legacy 只保留一个版本窗口用于回滚。

### 5.1 信令到 SessionConfig

`plainPublish` 返回值映射如下：

| plainPublish 字段 | SDK 字段 |
| --- | --- |
| `videoTracks[i].ssrc` | `SessionConfig.video_tracks[i].ids.sender_ssrc` |
| `videoTracks[i].pt` 或 `videoPt` | `SessionConfig.video_tracks[i].h264.payload_type` |
| `videoTracks[i].transportCcExtId` | `SessionConfig.twcc.extension_id` |
| 本地稳定 track index | `SessionConfig.video_tracks[i].ids.track_id` |
| room/session 派生 id | `SessionConfig.ids.session_id` |
| peer/source 派生 id | `SessionConfig.ids.source_id` |

注意事项：

- 当前 SDK 的 `twcc.extension_id` 是 session 级配置，所以 P5 要求所有 video track
  使用同一个 transport-cc extension id；如果 mediasoup 返回不一致，启动时直接报错。
- `producerId` 是字符串，不直接塞进 `TransportIds`。adapter 需要维护
  `track_id -> producerId` 映射，并写入应用层日志。
- H264 固定使用 `packetization-mode=1`、`profile-level-id=42e01f`、90kHz clock。
- payload type 和 SSRC 必须完全使用 mediasoup 返回值，不能由 SDK 自己生成。

### 5.2 UDP 适配

mediasoup PlainTransport 期望原始 RTP/RTCP datagram。这里不使用本 SDK demo 里的业务
envelope，`TransportOutput` 直接把 SDK 输出 bytes 原样发到 UDP：

```cpp
webrtc_qos::VideoPushClientConfig config;
config.session = session;
config.transport_output =
    [&](const webrtc_qos::TransportPacketView& packet) {
      return SendConnectedUdp(udp_fd, packet.bytes, packet.size);
    };
```

UDP 收包线程只处理 RTCP：

```text
recv(udp_fd)
  -> if RTCP: push->OnTransportFeedback(bytes, len, now_us)
  -> else: ignore or log unexpected inbound RTP
```

如果 PlainTransport 配置没有启用 rtcp-mux，adapter 必须显式创建和维护单独 RTCP
socket。P5 推荐要求 `rtcpMux=true`，否则复杂度没有必要。

### 5.3 H264 输入

FFmpeg 输出必须是完整 Annex-B access unit，不是单个裸 NALU：

```cpp
webrtc_qos::AnnexBAccessUnitView au;
au.bytes = packet->data;
au.size = packet->size;
au.capture_time_us = now_us;
au.keyframe = is_keyframe;
au.ids = track_ids;
push->PushAnnexBAccessUnit(au);
```

`PushAnnexBAccessUnit()` 之后仍然要持续调用：

```cpp
push->Process(now_us);
```

`Process()` 不能只在有新帧时调用。低 FPS、暂停采集、弱网降级期间也要稳定 tick，
建议 5ms 到 20ms。

### 5.4 编码器控制

旧 `PublisherQosController` 的 `SetEncodingParameters / PauseUpstream /
ResumeUpstream` 不进入新 backend。

新 backend 只从 SDK 读取 encoder adaptation：

```cpp
webrtc_qos::EncoderAdaptation adaptation;
if (push->GetTrackEncoderAdaptation(track_id, now_us, &adaptation)) {
  ApplyEncoderBitrate(adaptation.target_bitrate_bps);
  ApplyEncoderFps(adaptation.max_fps);
  if (adaptation.request_keyframe) ForceNextIdr();
}
```

如果上层业务需要限速，使用：

- `VideoPushClient::OnSenderRateCap()`：业务或服务端给一个发送上限。
- `VideoPushClient::OnNetworkRouteChange()`：网络路径切换、初始码率范围变化。

不要再通过自研 `qosPolicy/qosOverride` 直接驱动媒体发送状态机。

## 6. 日志、指标和告警

新 backend 不再使用 `std::cout` 或散落的 printf 作为主要排查手段。

SDK runtime 配置统一打开文件日志、metrics 和 alerts：

```cpp
config.logging.file.enabled = true;
config.logging.file.directory = "/var/log/webrtc_qos/plainclient";
config.logging.file.basename = "push";

config.metrics.file.enabled = true;
config.metrics.file.directory = "/var/log/webrtc_qos/plainclient";
config.metrics.file.basename = "push_metrics";

config.alerts.file.enabled = true;
config.alerts.file.directory = "/var/log/webrtc_qos/plainclient";
config.alerts.file.basename = "push_alerts";
```

adapter 层也要打结构化日志，至少包含：

- `roomId`
- `peerId`
- `producerId`
- `track_id`
- `sender_ssrc`
- `payload_type`
- `transportCcExtId`
- mediasoup `plainPublish` 返回的 `ip/port`
- SDK status code 和错误信息

必须纳入监控的指标：

| 类别 | 指标 |
| --- | --- |
| 发送活性 | `Process()` tick gap、RTP output gap、AU input gap |
| 网络质量 | RTT、fraction lost、TWCC feedback count、NACK count、PLI count |
| 发送控制 | GoogCC target、final target、pacing bitrate、sender rate cap |
| 恢复能力 | retransmission count、dropped retransmission、keyframe request |
| 队列健康 | pacer queue delay、dropped frames、transport output failures |
| 数据质量 | malformed RTP/RTCP、unknown feedback SSRC、payload type mismatch |

建议告警：

- 连续 `Process()` tick gap 超过 2s。
- 连续 3 次 UDP send hard error。
- 5s 内没有收到任何 RTCP feedback。
- NACK/PLI 持续增长但 retransmission/keyframe 没有响应。
- final target 长时间低于 700kbps。
- malformed RTCP 出现。

debug bundle 需要收集：

- SDK logs / metrics / alerts。
- `plainPublish` 原始 response。
- adapter 的 `SessionConfig` dump。
- mediasoup worker/room 的 producer stats。
- 运行参数和 git commit。

## 7. P5 里程碑

| 里程碑 | 目标 | 验收 |
| --- | --- | --- |
| M0 Audit & Freeze | 明确旧模块退出默认链路，新增 backend 开关 | 文档和 build target 明确 legacy/new backend 边界 |
| M1 Adapter Compile | 新增 `webrtc_qos_sdk` backend，能链接 `WebRtcQosSdk::role_push` | 不依赖 `client/qos`、`sendsidebwe`、`ccutils`、`RtcpHandler`、`NetworkThread` |
| M2 H264 Send Smoke | `plainPublish -> UDP -> VideoPushClient -> mediasoup PlainTransport` 跑通 | 浏览器能看到 H264 视频，SSRC/PT/TWCC extension 与 mediasoup 返回一致 |
| M3 Feedback Loop | UDP RTCP 投递到 `OnTransportFeedback()` | TWCC/RR/NACK/PLI 有日志和 metrics，PLI 能触发 keyframe |
| M4 Encoder Adaptation | FFmpeg 编码器由 SDK adaptation 控制 | 弱网下 bitrate/fps 下探，恢复后回升，不卡死在低档 |
| M5 Observability Gate | 文件日志、metrics、alerts、debug bundle 接入 | 出问题能按 room/peer/producer/track/ssrc 定位 |
| M6 Legacy Removal | 新 backend 成为默认，legacy 只留回滚窗口 | grep/link gate 确认默认链路不包含旧自研媒体/QoS 模块 |

P5 验收不要求 120 分钟重复跑相同内容。正式 gate 以 10 分钟覆盖弱网进入、持续弱网、
恢复、NACK/PLI 和反馈闭环；120 分钟只作为后续 release soak 或客户现场稳定性验证。

## 8. 测试门禁

必须有这些门禁：

| 门禁 | 内容 |
| --- | --- |
| Build gate | mediasoup-cpp 新 backend 能通过 CMake 链接 SDK installed package。 |
| Dependency gate | 新 backend target 不编译/链接 `client/qos`、`client/sendsidebwe`、`client/ccutils`、`RtcpHandler`、`NetworkThread`、`H264Packetizer`。 |
| Signaling smoke | `join/plainPublish` 返回的 tracks 能完整映射成 `SessionConfig`。 |
| RTP compatibility | 抓包确认 RTP SSRC/PT/TWCC extension id 与 mediasoup producer 参数一致。 |
| RTCP feedback | RR/TWCC/NACK/PLI 能进入 `OnTransportFeedback()`，并产生 SDK metrics。 |
| Weak-network smoke | 注入延迟/丢包/带宽下降后，SDK target bitrate/fps 下探并恢复。 |
| Observability | logs/metrics/alerts/debug bundle 文件存在且包含 room/peer/producer/track/ssrc。 |
| Rollback | `PLAIN_CLIENT_MEDIA_BACKEND=legacy` 在迁移期仍可启动，用于对照和紧急回滚。 |

## 9. FEC/RTX 取舍

P5 不优先做 FEC，原因是：

- FEC 适合“带宽相对充足、随机小丢包、希望避免重传等待”的场景。
- 当前更关键的问题是弱网带宽下降和排队，FEC 会额外增加冗余流量，可能放大拥塞。
- 当前 SDK 已经有 NACK、PLI、TWCC、GoogCC、pacing 和 sender packet history，先把这条
  WebRTC 主恢复链路跑稳，收益更确定。

P5 也不启用 RFC4588 RTX：

- 当前重传使用原 RTP packet retransmission，链路和 mediasoup PlainTransport 对接更简单。
- RTX 需要额外 payload type、RTX SSRC、apt 映射和更多 mediasoup 参数协商，当前阶段不是
  最小闭环必需项。
- 后续如果客户场景证明原 RTP 重传不足，再单独立项做 RTX。

## 10. 风险

| 风险 | 处理 |
| --- | --- |
| PlainTransport RTCP 没有回到同一个 UDP socket | P5 要求 `rtcpMux=true`；否则单独实现 RTCP socket adapter。 |
| mediasoup 返回的 TWCC extension id 多 track 不一致 | 启动失败并报配置错误；P5 不做 per-track TWCC ext id。 |
| H264 profile/packetization-mode 不匹配 | plainPublish 必须按 SDK 支持范围创建 producer：baseline、packetization-mode=1。 |
| VP8 依赖旧链路 | P5 新 backend 不支持 VP8；VP8 要么禁用，要么继续 legacy 对照，不进入默认路径。 |
| audio 仍是旧 RTP | P5 只声明 H264 video publisher；audio QoS 后续单独设计，不能混在本次验收里。 |
| 旧 QoS policy 继续下发 | 新 backend 忽略旧媒体控制动作，只接受 rate cap / route change 这类边界清晰的输入。 |

## 11. 完成定义

P5 mediasoup plainclient 重构完成必须同时满足：

- 默认 H264 video 发送链路只使用 `VideoPushClient`。
- 默认链路不包含旧自研 RTP/RTCP/NACK/TWCC/pacer/BWE/QoS 模块。
- mediasoup `plainPublish` 信令和 PlainTransport 仍然可复用。
- SSRC、payload type、TWCC extension id 与 mediasoup producer 参数一致。
- RTCP feedback 能进入 SDK，并驱动 GoogCC、NACK、PLI、retransmission、keyframe。
- 编码器 bitrate/fps/keyframe 由 SDK adaptation 输出驱动。
- logs、metrics、alerts、debug bundle 可按 room/peer/producer/track/ssrc 排查问题。
- 10 分钟弱网 gate 通过，120 分钟仅作为后续 release soak。
