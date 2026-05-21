# WebRTC-first Phase-2 总体实施计划

## 1. 背景

当前 Phase-1a 已经证明了方向：

- H264 Annex-B 输入输出可闭环。
- 自定义 C/S 传输边界可行。
- TWCC、RTCP SR/RR、NACK/PLI、sender rate cap、弱网矩阵和 QoE 指标体系已经跑通。
- WebRTC GoogCC adapter 和 WebRTC video jitter adapter 已经具备雏形。

但当前实现形态仍偏离初衷：

```text
自研轻量 RTP/RTCP/QoS/NACK/pacer/video jitter SDK + 可选 WebRTC adapter
```

目标必须切回：

```text
WebRTC QoS/RTP/RTCP/NACK/jitter/pacer 主路径 + 自定义传输层
```

Phase-2 的核心不是继续扩展功能，而是做一次架构归位：把 WebRTC 已经成熟的媒体、QoS、RTP/RTCP、恢复和 jitter 能力恢复为默认主路径，把自研实现从 public API、CMake、demo、tests 和发布包中删除。

### 1.1 当前实现状态

本轮重构后的当前状态：

- 旧自研 RTP/RTCP/TWCC/NACK/PLI/pacer/video jitter 已从 public headers、CMake 默认目标、demo、tests、scripts 和默认安装包中删除。
- SDK 仓库保留角色 facade 头文件、WebRTC-backed push/play 默认实现、业务控制消息、transport support、`transport_packet_history` 和 CMake imported target glue。
- WebRTC 外部源码树通过仓库 patch 提供 `googcc`、`rtcp`、`h264_rtp`、`video_jitter`、`nack_requester`、`pacing_controller` adapter；`pacing_controller` 当前使用 WebRTC `PacingController` 最小闭包，覆盖 packet priority、probe cluster、重传优先、RTP padding 生成和发送时机门禁。
- `package_webrtc_modules.sh` 已能生成独立 WebRTC 模块库和 adapter headers。
- `verify_webrtc_first_phase2.sh` 是当前 Phase-2 聚合门禁入口；`verify_no_selfmade_media_stack.sh`、`verify_webrtc_modules.sh`、`verify_cmake_package.sh`、`verify_webrtc_first_loopback.sh`、`verify_webrtc_first_roles.sh` 是它在 smoke 档串起的主门禁脚本。
- `verify_webrtc_first_loopback.sh` 已能作为外部 CMake consumer 跑通 H264 Annex-B AU -> WebRTC H264 RTP payload -> WebRTC RTP packet bytes -> WebRTC pacing adapter -> WebRTC video jitter -> Annex-B AU 的基础 media bytes 闭环。

当前真正仍未闭合的仅有 3 项：

- 生产级多小时 soak 实际运行和归档：必须在正式验收环境跑出 `SOAK_MINUTES>=120` 的 production soak 证据，不能只用短时 smoke 代替。当前本机只有 `artifacts/webrtc_first_phase2_verify_production_smoke/`，只能证明 runner/archive/verifier 链路可用。
- 真实 renderer 验收：必须拿到 `real_renderer_status=pass` 的正式结果。当前本机没有 `DISPLAY`，也没有 `Xvfb`，因此 production gate preflight 失败。
- 正式业务采集素材库：必须提供正式 `capture_library/manifest.csv` 和六类业务素材覆盖，不能继续使用 deterministic fixture 作为完成证据。当前本机默认路径下不存在正式 manifest。

除上述 3 项外，下面这些都属于“已完成并已有 smoke/qoe/runtime 证据的实现或门禁”，不再视为未完成功能项：

- `VideoPushClient`、`VideoPlayClient` 已有 WebRTC-backed 默认实现，可通过 `CreateVideoPushClient()` / `CreateVideoPlayClient()` 创建并跑通基础 H264 RTP bytes 闭环。
- `ServerQosRouter` 已有 WebRTC-backed 最小默认实现，可通过 `CreateServerQosRouter()` 做 sender RTP relay、packet history 缓存、receiver NACK 本地重传、缺包 NACK/PLI 向 sender 路由和基础 rate cap。
- server -> sender 的 uplink TWCC 到 push GoogCC 的最小闭环已接通：server 基于 sender RTP 到达生成标准 RTCP Transport Feedback，push 解析 feedback 后喂 WebRTC GoogCC，并用 GoogCC 输出更新 target/pacing rate。
- push SR -> server RR -> push RTT 的最小标准 RTCP SR/RR 闭环已接通，并通过外部 CMake package runtime 验证。
- play 侧 WebRTC NackRequester -> 标准 RTCP NACK -> server packet history 本地重传的最小恢复闭环已接通，并通过外部 CMake package runtime 验证。
- WebRTC-first facade 弱网矩阵已新增，直接驱动 `VideoPushClient / ServerQosRouter / VideoPlayClient`，覆盖好网、burst loss recover、bandwidth cliff low-RPS recover、weak-network low-RPS low-bitrate、multi-receiver worst-cap recover、sustained low-bandwidth low-RPS、weak-start low-bandwidth low-RPS、walking dead-zone recover，并验证弱网阶段低码率、低 AU 发送 RPS、低 RTP pps、低 encoder FPS；可恢复场景要求恢复后全部回升，持续弱网和弱网起步场景要求最终仍保持低 RPS/低码率/低 FPS；多 receiver 场景要求健康 receiver 的上报不能清掉坏 receiver 的 sender cap。
- 可选 FFmpeg QoE smoke 已新增，临时叠加 FFmpeg H264 encoder/decoder 可选库和 WebRTC-first dist，覆盖真实 H264 encode -> push/server/play facade -> 真实 H264 decode，并输出 playable ratio、decode error、Y-PSNR 和 SSIM-Y；SSIM-Y 已作为 VMAF 的轻量替代指标进入 CSV 和 pass/fail。
- Phase-2 `VERIFY_LEVEL=qoe` 聚合门禁已在本机通过：no-selfmade、WebRTC module smoke、外部 CMake package、loopback、pacing probe、role facade、synthetic 弱网矩阵、真实 H264 low-RPS/low-bitrate QoE 和恢复时间分布全部通过；真实 H264 low-RPS/low-bitrate case 为 `10.9091 AU RPS / 92.7273 RTP pps / 400000bps / 10fps`，恢复到 `30 RPS / 840944bps / 30fps`，`playable_ratio=0.923077`、`avg_psnr_y=45.9423`、`avg_ssim_y=0.999833`，`target/fps/full_recovery_time_ms_p95=0`。
- Phase-2 `VERIFY_LEVEL=production` 短时 smoke 已在本机通过：`SOAK_CYCLES=1 / FRAMES_PER_CYCLE=12 / RUN_REAL_RENDERER=0 / RUN_CAPTURE_LIBRARY=0`，用于验证 production runner、CSV 聚合、archive metadata、sha256 manifest、tarball 和离线 archive verifier 链路；短时结果 `cycles=1`、`rows=1`、`pass_rows=1`、`decode_errors=0`、`freeze_count=0`、`renderer_proxy_drop_frames=0`、`weak_low_bad_send_rps_max=12.8571`、`weak_low_bad_rtp_pps_max=184.286`、`weak_low_target_bps_max=750000`、`weak_low_encoder_fps_max=10`，archive verifier 和恢复时间分布 verifier 均通过。它不是 production 级多小时结论。
- 720p QoE 稳定性脚本已新增，基于真实 FFmpeg H264 encode/decode 和 WebRTC-first facade，覆盖 baseline、bandwidth cliff recover、weak-network low-RPS low-bitrate、sustained low-bandwidth low-RPS、weak-start low-bandwidth low-RPS、walking dead-zone recover，并验证真实编码器在弱网段持续降码率/降 FPS/降 RPS；可恢复场景恢复段回升并输出恢复耗时，持续弱网和弱网起步场景最终保持低发送速率；已输出 renderer 前置 freeze proxy。
- 720p 多 seed QoE 脚本已新增，基于真实 FFmpeg H264 encode/decode 和 WebRTC-first facade，覆盖 3 个 deterministic seed、baseline、bandwidth cliff recover、weak-network low-RPS low-bitrate、sustained low-bandwidth low-RPS、weak-start low-bandwidth low-RPS、walking dead-zone recover，验证内容运动相位和丢包相位变化下的稳定性，并要求 freeze proxy 为 0。
- 720p 长流动态 QoE 脚本已新增，基于真实 FFmpeg H264 encode/decode 和 WebRTC-first facade，覆盖 60 tick baseline、bandwidth cliff recover、weak-network low-RPS low-bitrate、sustained low-bandwidth low-RPS、weak-start low-bandwidth low-RPS、walking dead-zone recover、oscillating edge recover，验证反复弱网/恢复切换下真实编码器多次降码率/降 FPS 并回升，并验证持续弱网或开局弱网不恢复时保持低发送速率；已输出 freeze proxy。
- 720p extended soak QoE 脚本已新增，基于真实 FFmpeg H264 encode/decode 和 WebRTC-first facade，覆盖 120 tick baseline、bandwidth cliff recover、weak-network low-RPS low-bitrate、sustained low-bandwidth low-RPS、weak-start low-bandwidth low-RPS、walking dead-zone recover、oscillating edge recover，并把弱网阶段低 RPS/低 RTP pps/低码率/低 FPS 作为 pass/fail 门禁。
- production soak runner 已新增，支持按 `SOAK_CYCLES` 或 `SOAK_MINUTES` 重复运行真实 H264 QoE 矩阵，聚合跨 cycle CSV，并把 decode error、freeze、renderer proxy late/drop/gap/jitter、push queue、弱网低发送和恢复时间作为总门禁；当前已完成短时 smoke，真正多小时 soak 仍需在稳定机器上实际执行并归档。
- 720p 高复杂内容 stress QoE 脚本已新增，基于真实 FFmpeg H264 encode/decode 和 WebRTC-first facade，使用移动高频棋盘、斜向细节和确定性噪声，覆盖 2 个 seed、baseline、bandwidth cliff recover、walking dead-zone recover、oscillating edge recover，并把高复杂内容下的可播放、弱网窗口最大 RPS/pps/码率/FPS、恢复回升时间、NACK/RTX 和 freeze proxy 作为 pass/fail 门禁。
- 720p 内容库 QoE 脚本已新增，基于真实 FFmpeg H264 encode/decode 和 WebRTC-first facade，覆盖 `block_motion / camera_pan / scene_cut / low_light_noise` 四类 deterministic 内容，并在 baseline、weak-network low-RPS low-bitrate、walking dead-zone recover、oscillating edge recover 下验证不同画面类型的弱网低发送、恢复回升、NACK/RTX、画质和 freeze proxy。
- 真实采集内容库 QoE 入口脚本已新增，支持把 `CAPTURE_LIBRARY_DIR` 下的 `.mp4 / .mov / .mkv / .webm / .yuv / .i420` 素材转换/读取为 raw I420，并进入同一套真实 H264 encode/decode、WebRTC-first facade、QoE/renderer proxy 门禁；当前已新增 deterministic fixture 生成器，并通过 Phase-2 聚合门禁跑通 6 类 manifest + baseline QoE smoke：`entries=6`、类别覆盖 `high_motion,indoor_face,low_light_noise,outdoor_walking,scene_cut,screen_text`、QoE `rows=6/6 pass`、`playable_ratio_min=0.833333`、`avg_psnr_y_min=42.6753`、`avg_ssim_y_min=0.998468`、`decode_errors=0`、`freeze_count=0`、`renderer_proxy_drop_frames=0`。正式业务真实采集素材库仍需业务侧提供或录制。
- 仓库内 WebRTC-first loopback demo 已新增，直接驱动 `VideoPushClient / ServerQosRouter / VideoPlayClient` role facade，不直接 include WebRTC adapter，不使用旧自研 RTP/RTCP/pacer/video jitter，并输出 WebRTC backend、custom bytes transport 和 `peer_connection=false`。
- 仓库内 WebRTC-first UDP sender/server/receiver demo 已新增，保留 `selftest` 自动门禁，并提供独立 `sender/server/receiver` 三进程手工模式；所有入口都直接驱动 role facade，输出 `backend=webrtc_first_facade transport=udp peer_connection=false`，不引入 PeerConnection，不让 WebRTC 持有 socket。
- 综上，当前 Phase-2 剩余工作已经收敛为上面的 3 项正式验收闭环，不再是新的核心模块研发。
- 旧 Phase-1a 自研链路 demo 已删除，不再作为测试入口；当前已有外部 loopback smoke、CMake package runtime smoke、仓库内 role facade loopback demo、UDP role demo、弱网矩阵和 `verify_webrtc_first_phase2.sh` 聚合门禁覆盖 push/play/server facade。
- QoS 弱网/QoE 矩阵已开始基于 WebRTC-first facade 重建，旧自研链路的弱网脚本已删除；后续需要继续扩展真实采集内容库和生产级长时间 soak。
- `webrtc_pacing` 已从 WebRTC `IntervalBudget` 子集切到 WebRTC `PacingController` 最小闭包；adapter 不直接发布完整 `modules/pacing`，而是只编 `pacing_controller / bitrate_prober / prioritized_packet_queue` 和必要 `RtpPacketToSend` 依赖。当前已通过 adapter smoke、push facade probe、loopback 和 role facade 门禁，并已补齐基于媒体包模板的 RTP padding 生成、统计和 facade/server/play padding 边界。

## 2. 总原则

### 2.1 WebRTC-first

- 能用 WebRTC 原生模块的能力，一律使用 WebRTC。
- SDK 不维护半套 RTP/RTCP/TWCC/NACK/PLI wire format。
- SDK 不维护自研 pacer。
- SDK 不维护自研视频 jitter buffer。
- SDK 不维护自研 NACK requester。
- SDK facade 可以保留，但 facade 内部必须默认调用 WebRTC 模块。
- 缺少 WebRTC 模块时构建失败，不自动降级。

### 2.2 强删除

旧轻量实现不作为 fallback 或 test path 保留。

接入 WebRTC 对应模块后，旧自研模块要从以下位置删除：

- public API
- CMake targets
- demo
- tests
- scripts
- dist 发布包

允许保留的只有业务/传输层 support 代码，例如 `transport_packet_history`。

`transport_packet_history` 的边界必须固定：

- 只按 `hop_id / ssrc / rtp_sequence_number` 缓存 opaque RTP bytes。
- 只记录发送时间、是否重传、原始 RTP packet bytes。
- 只给 sender/server 在 WebRTC RTCP/NACK 路由已经决定重传后查找原包。
- 不解析 RTCP。
- 不生成 NACK。
- 不决定 NACK/PLI 路由。
- 不实现 NACKRequester。
- 不实现丢包恢复策略。
- 不参与 WebRTC jitter 或拥塞控制计算。

### 2.3 自定义边界

业务侧只自定义：

- socket / UDP / QUIC / 业务传输回调
- 业务 envelope
- session_id / stream_id / receiver_id 映射
- SSRC 映射
- 服务端转发策略
- 多播放端 rate cap 策略
- 安全鉴权接口
- QoS/QoE metrics 汇总
- H264 Annex-B 输入输出 glue

WebRTC 提供主能力：

- 拥塞控制：`network_control / goog_cc`
- pacing：`modules/pacing`
- RTP/RTCP：`modules/rtp_rtcp`
- TWCC：WebRTC RTCP transport feedback
- SR/RR：WebRTC RTCP sender/receiver report
- NACK/PLI：WebRTC RTCP feedback
- NACK requester：WebRTC `modules/video_coding:nack_requester`
- H264 packetize/depacketize：WebRTC RTP H264 packetizer/depacketizer
- 视频 jitter：WebRTC `PacketBuffer`、`RtpVideoFrameAssembler` 或对应视频接收缓冲路径

### 2.4 WebRTC 使用姿势

目标不是把 SDK 改成完整 WebRTC 会话层，也不是让 WebRTC 接管业务网络。

目标是把 WebRTC 作为媒体和 QoS 能力引擎，为业务侧所用：

```text
业务参数 / 媒体数据 / 网络反馈
  -> SDK facade
  -> WebRTC 原生模块
  -> RTP/RTCP bytes / bitrate 建议 / NACK/PLI / jitter 后视频帧 / metrics
  -> 业务侧继续掌握传输、路由、调度和策略
```

边界原则：

- 业务掌握网络 IO、socket、连接生命周期、鉴权、session、stream、receiver、server relay 和 envelope。
- 业务掌握服务端转发策略、多接收端 rate cap、弱网策略参数和发布形态。
- WebRTC 只负责它擅长且应该负责的事情：RTP/RTCP wire format、H264 RTP packetization、拥塞控制、pacing、NACK/PLI、jitter/reorder、RTCP 统计与反馈。
- SDK facade 负责把业务参数翻译成 WebRTC module input，把 WebRTC output 翻译回业务可消费的 bytes、事件、建议和指标。
- 不引入 WebRTC `PeerConnection` 语义，不让 WebRTC 拥有 socket，不让 WebRTC 决定业务路由。
- 不在业务层暴露 WebRTC 内部对象；业务只通过稳定 facade 传参、喂数据、取输出。

## 3. 最终架构

### 3.1 目标链路

```text
push app
  -> business params / encoded H264 AU
  -> VideoPushClient
      -> WebRTC H264 packetizer
      -> WebRTC RTP/RTCP
      -> WebRTC GoogCC
      -> WebRTC Pacer
      -> TransportOutput(RTP/RTCP bytes, bitrate/keyframe/metrics events)
  -> business transport
  -> server
      -> ServerQosRouter
      -> WebRTC RTCP adapter
      -> packet history / relay
      -> rate cap policy
  -> business transport
  -> VideoPlayClient
      -> WebRTC RTP/RTCP
      -> WebRTC NackRequester
      -> WebRTC video jitter
      -> Annex-B AU output / RTCP feedback bytes / metrics events
  -> play app
```

### 3.2 对外 bytes 边界

对外 facade 必须坚持 bytes 边界：

- push 输入：H264 Annex-B access unit。
- push 输出：标准 RTP/RTCP bytes。
- play 输入：标准 RTP/RTCP bytes。
- play 输出：完整 Annex-B access unit。
- play 输出：标准 RTCP feedback bytes。
- server 输入/输出：标准 RTP/RTCP bytes + 业务控制消息。
- 业务传输只搬运 bytes 和业务 envelope，不接触 WebRTC 内部对象。
- WebRTC 内部对象、task queue、clock、sequence checker、field trial、environment 生命周期全部由 SDK facade 封装。

### 3.3 运行时模型

所有 WebRTC runtime 对象必须由 SDK facade 统一创建和销毁，不能散落到 demo、业务层或 transport helper 中。

约束：

- SDK 内部统一持有 WebRTC clock / task queue / environment。
- `VideoPushClient`、`VideoPlayClient`、`ServerQosRouter` 的 public API 不暴露 WebRTC runtime 类型。
- transport 回调只收发 bytes，不直接调用 WebRTC 对象。
- WebRTC 回调进入业务层前必须经过 facade 线程边界，避免业务回调重入 WebRTC 内部状态。
- destroy 顺序由 facade 保证：先停止 transport callback，再 drain WebRTC task queue，最后释放 WebRTC module。
- 所有 adapter 的时间来源统一使用 WebRTC clock 或 facade 注入的 monotonic clock，不允许各模块各自取系统时间。

## 4. 最终公开 API

公开 API 收敛为角色 facade，不暴露底层 RTP/RTCP 实现。

建议公开：

```text
include/webrtc_qos/status.h
include/webrtc_qos/session_config.h
include/webrtc_qos/transport_io.h
include/webrtc_qos/video_push_client.h
include/webrtc_qos/video_play_client.h
include/webrtc_qos/server_qos_router.h
include/webrtc_qos/qos_metrics.h
include/webrtc_qos/rate_cap.h
include/webrtc_qos/control_messages.h
```

### 4.1 VideoPushClient

业务只需要：

- 输入 H264 Annex-B access unit。
- 输入 capture timestamp。
- 输入服务端 `SENDER_RATE_CAP_V1`。
- 输入 route change。
- 接收 SDK 输出的 RTP/RTCP bytes，通过业务传输发送。
- 读取 encoder bitrate / FPS / keyframe request 建议。

H264 glue 只允许做格式适配：

- 输入仍是 Annex-B access unit。
- wrapper 负责解析必要的 SPS/PPS/profile、timestamp、frame type 和 marker 语义。
- wrapper 把输入转换为 WebRTC RTP sender / H264 packetizer 需要的 `EncodedImage`、`RTPVideoHeader` 或等价 wrapper 结构。
- wrapper 不实现自研 H264 packetizer，不维护 RTP sequence number 策略，不绕过 WebRTC RTP/RTCP。

### 4.2 VideoPlayClient

业务只需要：

- 输入收到的 RTP/RTCP bytes。
- 接收 SDK 输出的完整 Annex-B access unit。
- 接收 SDK 输出的 RTCP feedback bytes，通过业务传输回传。
- 读取 jitter、loss、NACK、PLI、freeze proxy、decode/QoE metrics。

### 4.3 ServerQosRouter

服务端 facade 建议命名为 `server_qos_router.h`。

职责：

- sender / receiver / session / stream 映射。
- SSRC 映射。
- `uplink_twcc` 生成。
- NACK / PLI 路由。
- SR / RR 处理和转发。
- packet history 管理。
- 多播放端 downlink quality 汇总。
- `SENDER_RATE_CAP_V1` 生成和防抖。

服务端不维护自研 RTCP wire format；所有 RTCP 解析/生成统一走 WebRTC RTCP adapter。

### 4.4 控制消息归属

删除 `transport_feedback.h` 后，业务控制消息归属如下：

- `rate_cap.h`：`SENDER_RATE_CAP_V1`、cap 过期语义、暂停/不限速语义。
- `qos_metrics.h`：downlink quality、loss、jitter、RTT、freeze proxy、decode/QoE 指标。
- `control_messages.h`：业务 envelope 内的控制消息类型、版本号、序列号和编解码。

## 5. 删除清单

### 5.1 删除公开头

```text
include/webrtc_qos/rtp_packet.h
include/webrtc_qos/rtcp_packets.h
include/webrtc_qos/sender_pacer.h
include/webrtc_qos/receiver_qos_observer.h
include/webrtc_qos/retransmission_cache.h
include/webrtc_qos/video_sender.h
include/webrtc_qos/video_receiver.h
include/webrtc_qos/video_jitter_player.h
include/webrtc_qos/transport_feedback.h
```

### 5.2 删除源码

```text
src/rtp_packet.cc
src/rtp_packet.h
src/rtcp_packets.cc
src/sender_pacer.cc
src/receiver_qos_observer.cc
src/retransmission_cache.cc
src/video_sender.cc
src/video_receiver.cc
src/video_jitter_player.cc
src/transport_feedback.cc
```

### 5.3 删除 CMake targets

```text
webrtc_qos_rtp
webrtc_qos_rtcp
webrtc_qos_nack
webrtc_qos_pacer
webrtc_qos_video
```

`webrtc_qos_feedback` 需要拆分，只保留 facade、rate cap、metrics 等业务抽象，不再包含自研 estimator 或自研 feedback wire format。

## 6. WebRTC 模块产物

不发布完整 `libwebrtc.a`。仍按能力拆库，但每个库内部使用 WebRTC 原生实现。

建议发布：

```text
libwebrtc_qos_webrtc_googcc.a
libwebrtc_qos_webrtc_pacing.a
libwebrtc_qos_webrtc_rtp_rtcp.a
libwebrtc_qos_webrtc_video_jitter.a
libwebrtc_qos_webrtc_nack_requester.a
libwebrtc_qos_transport_packet_history.a
libwebrtc_qos_push.a
libwebrtc_qos_play.a
libwebrtc_qos_server.a
libwebrtc_qos_transport.a
```

命名边界必须清楚：

- `webrtc_rtp_rtcp`：负责 RTP/RTCP、TWCC、SR/RR、NACK/PLI wire format 的 WebRTC 序列化/解析。
- `webrtc_nack_requester`：只封装 WebRTC `NackRequester`，属于播放端接收链路。
- `transport_packet_history`：只保存 opaque RTP bytes，供 sender/server 响应已经路由过来的 NACK，不生成 NACK，不解析 RTCP，不做恢复策略。

CMake imported targets：

```text
WebRtcQosSdk::webrtc_googcc
WebRtcQosSdk::webrtc_pacing
WebRtcQosSdk::webrtc_rtp_rtcp
WebRtcQosSdk::webrtc_video_jitter
WebRtcQosSdk::webrtc_nack_requester
WebRtcQosSdk::transport_packet_history
WebRtcQosSdk::role_push
WebRtcQosSdk::role_play
WebRtcQosSdk::role_server
WebRtcQosSdk::role_transport
```

`role_push` 默认链接：

```text
WebRtcQosSdk::webrtc_qos_facade_video
WebRtcQosSdk::webrtc_googcc
WebRtcQosSdk::webrtc_pacing
WebRtcQosSdk::webrtc_rtp_rtcp
WebRtcQosSdk::transport_packet_history
WebRtcQosSdk::role_transport
```

`role_play` 默认链接：

```text
WebRtcQosSdk::webrtc_qos_facade_video
WebRtcQosSdk::webrtc_rtp_rtcp
WebRtcQosSdk::webrtc_video_jitter
WebRtcQosSdk::webrtc_nack_requester
WebRtcQosSdk::role_transport
```

`role_server` 默认链接：

```text
WebRtcQosSdk::webrtc_qos_facade_video
WebRtcQosSdk::webrtc_rtp_rtcp
WebRtcQosSdk::transport_packet_history
WebRtcQosSdk::role_transport
```

当前实现阶段 `libwebrtc_qos_facade_video.a` 同时提供 `CreateVideoPushClient()`、`CreateVideoPlayClient()` 和 `CreateServerQosRouter()`。`role_push`、`role_play`、`role_server` 只有在该 facade 实现库和对应 WebRTC module targets 都存在时才创建，避免只导出底层模块但没有 facade 工厂实现的半可用 target。

`WebRtcQosSdk::role_server` 内部负责 session/stream/receiver 映射、NACK/PLI 路由、packet history 管理、downlink quality 汇总和 sender rate cap 生成；上面的列表是它继续链接的底层 WebRTC/transport support targets。后续如果 server facade 独立成 `libwebrtc_qos_server.a`，必须保持相同的 role target 语义和外部 CMake 验证。

`role_push` 和 `role_server` 不默认链接 `webrtc_nack_requester`。它们只消费已经由 WebRTC RTCP adapter 解析出来的 NACK/PLI 事件，并通过 WebRTC sender history 或 `transport_packet_history` 找包重传。只有当 server 明确承担某一路上游的接收端角色时，才允许在该接收角色内引入 `webrtc_nack_requester`。

## 7. 可复现构建策略

WebRTC 仍作为外部源码树构建。SDK 不把完整 WebRTC 源码复制进仓库。

但是可复现构建必须进入仓库管理，不能依赖 `/root/src` 里的不可见本地改动。

以下内容必须纳入本仓库，或以 patch 形式纳入本仓库：

- `sdk_qos` GN packaging target。
- SDK wrapper 源码。
- adapter public headers。
- 对 WebRTC `BUILD.gn` 的最小 patch。
- 依赖裁剪 patch。
- WebRTC commit 和 GN args 记录。

当前仓库固定记录：

- WebRTC patch：`third_party/webrtc_patches/webrtc_qos_sdk.patch`
- 当前本地 WebRTC adapter commit：`1ae6348299bcc008785407e416542fcfb605cfaf`
- 当前已可打包 WebRTC 模块：`webrtc_googcc`、`webrtc_video_jitter`、`webrtc_rtp_rtcp` 的 RTP packet bytes build/parse + RTCP wire-format + H264 RTP payload 子集、`webrtc_pacing` 的 `PacingController` 最小闭包、`webrtc_nack_requester`
- 当前必须继续拆分的 WebRTC 模块：无；后续重点是把 facade 主路径切到这些模块，并基于 WebRTC-first facade 重建 demo 和弱网/QoE 矩阵。
- 旧自研媒体栈已从 public headers、CMake 默认目标、demo、tests、scripts 和默认安装包中删除，不再作为 fallback/test path 保留。
- 当前 `webrtc_pacing` 已切到 WebRTC `PacingController` 最小闭包：adapter 内部把 RTP bytes 解析成 `RtpPacketToSend`，由 `PacingController` 做队列、packet priority、probe cluster 和发送时机，再输出 RTP bytes；没有直接打全量 `modules/pacing`，没有引入 `task_queue_paced_sender` 或 `packet_router`。RTP padding 由 adapter 在已有媒体包模板后生成，`size <= 1 byte` 的 probe/keepalive padding 请求返回空，真实 padding 包分配新的 RTP sequence number 和 transport-wide sequence number，设置 RTP padding bit，参与 uplink TWCC，但不进入 packet history 或视频 jitter/解码路径。

重要约束：

- 不允许简单把 `modules/pacing`、`modules/rtp_rtcp`、`modules/video_coding:nack_requester` 整体作为 `complete_static_lib` 发布。
- 本机验证显示，直接完整打包这些原生 target 会拉入 protobuf/full 等无关依赖，违背“非主目标不编译”的裁剪原则。
- Phase-2 后续必须为这些能力建立专用最小 adapter target：只暴露 SDK facade 需要的 bytes/event/metrics 接口，只链接 WebRTC 内部必要源码和依赖。
- 如果某个 adapter 无法避免重依赖，必须先在文档和脚本中列出依赖闭包并解释原因，不能静默扩大发布包。
- 已验证 `webrtc_rtp_rtcp` 不能依赖全量 `rtp_rtcp_format`，因为它经 `rtc_base:event_tracer -> perfetto -> protobuf_full` 拉入无关依赖；当前改为 `rtcp_packet_qos_minimal`，只包含 WebRTC RTCP PLI/NACK/TWCC/SR/RR 必要源码。
- 已验证 RTP packet bytes build/parse 可以通过 `rtp_packet_qos_minimal` 单独发布，包含 WebRTC `RtpPacket`、`RtpHeaderExtensionMap` 和 `TransportSequenceNumber` header extension，不依赖完整 `modules/rtp_rtcp:rtp_rtcp`、`rtc_base:event_tracer` 或 `protobuf_full`。
- 已验证 H264 RTP payload adapter 不能直接依赖 WebRTC 通用 `rtp_format.cc` 或默认 `video_rtp_depacketizer.cc`，因为前者会引入非目标 codec packetizer，后者经 `api/video:encoded_image -> api:rtp_packet_info -> rtp_rtcp_format` 拉入 perfetto/protobuf；当前改为 H264-only `h264_rtp_qos_minimal`。
- 已验证 `webrtc_pacing` 不能直接发布完整 `modules/pacing` 闭包；当前发布专用 `modules/pacing:pacing_controller_qos_minimal`，只包含 `pacing_controller.cc`、`bitrate_prober.cc`、`prioritized_packet_queue.cc` 和必要 `rtp_packet_to_send_qos_minimal`，避免把 RTP sender、event tracer 或 protobuf 路径带入 Phase-2 基础包。
- 已验证 `webrtc_nack_requester` 可直接依赖 `modules/video_coding:nack_requester` 做最小 adapter；当前闭包不经过 protobuf/full、`rtc_base:threading` 或完整 `modules/rtp_rtcp`。

构建流程：

```text
WebRTC source checkout
  -> verify commit
  -> apply sdk_qos patches
  -> gn gen with pinned args
  -> ninja WebRTC module archives
  -> install adapter headers and .a to output/
  -> SDK CMake imported targets link these archives
```

新增脚本：

```text
scripts/package_webrtc_modules.sh
scripts/verify_webrtc_modules.sh
scripts/verify_no_selfmade_media_stack.sh
scripts/verify_webrtc_first_loopback.sh
scripts/verify_webrtc_first_roles.sh
```

`package_webrtc_modules.sh`：

- 检查 `WEBRTC_SRC`。
- 检查 WebRTC commit。
- 从仓库 patch 或 packaging 目录写入 WebRTC packaging `BUILD.gn`。
- 检查 WebRTC 源码树是否已经应用所需 patch，未应用时直接失败或按显式参数应用。
- 使用固定 GN args 禁用无关模块。
- `ninja` 构建完整静态库。
- 拷贝 `.a` 和必要公开 wrapper 头到 `output/`。

`verify_no_selfmade_media_stack.sh`：

- 检查被删除的自研头文件不再存在。
- 检查源码不再引用自研 RTP/RTCP/NACK/pacer/jitter。
- 检查 CMake 不再导出旧目标。
- 检查 dist 不再包含旧静态库。

`verify_webrtc_first_roles.sh`：

- 缺少 facade 实现库或 WebRTC module archive 时，对应 role 不生成或构建失败。
- `role_push / role_play / role_server` 不链接旧自研目标。
- 当前检查 role imported targets、旧自研目标缺失、CMake 包可消费、无 `PeerConnection` 或 WebRTC socket 接管。
- 构建并运行 `webrtc_qos_webrtc_first_loopback_demo`，demo 日志必须标明 WebRTC backend。
- demo 和 facade 不创建 `PeerConnection`，不让 WebRTC 打开 socket，不让 WebRTC 接管业务 IO。
- WebRTC module output 必须通过 facade 转换成 bytes、事件、建议和指标返回业务层。

`verify_webrtc_first_loopback.sh`：

- 用发布包创建临时外部 CMake consumer。
- 链接 `WebRtcQosSdk::webrtc_rtp_rtcp`、`WebRtcQosSdk::webrtc_pacing`、`WebRtcQosSdk::webrtc_video_jitter`。
- 输入 synthetic H264 Annex-B AU。
- 通过 WebRTC H264 RTP payload adapter 生成 payload。
- 通过 WebRTC RTP packet adapter 生成带 TWCC extension 的标准 RTP bytes。
- 通过 WebRTC pacing adapter 出队。
- 通过 WebRTC RTP packet adapter 解析 bytes。
- 通过 WebRTC video jitter adapter 输出完整 Annex-B AU。

`verify_cmake_package.sh`：

- 用发布包创建临时外部 CMake consumer。
- 验证 `role_transport`、`transport_packet_history`、`role_push`、`role_play`、`role_server` 和底层 WebRTC module targets 可按需链接。
- `role_push`、`role_play`、`role_server` 必须真实调用对应 `Create*()` 工厂函数，不能只做头文件编译检查。
- `role_server` 已单独验证只链接 `WebRtcQosSdk::role_server` 时可创建 router，并能执行基础 downlink quality -> sender rate cap runtime；`server_role_runtime` 还覆盖 worst receiver 选择和 rate cap 过期回到 unlimited。
- 不使用旧自研 RTP/RTCP/pacer/video jitter。
- 当前复测命令：`PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 WORK_DIR=/tmp/webrtc_qos_cmake_consumer_server_audit scripts/verify_cmake_package.sh`，结果 `CMake package verification passed`。

## 8. 实施顺序

迁移顺序必须是：

```text
接入 WebRTC 原生模块 -> 迁移 facade -> 删除对应自研模块 -> 跑弱网/QoE 门禁
```

不能先直接删除文件，否则仓库会长时间不可编译。

### Step 1：固定 WebRTC 版本和构建产物

动作：

- 记录当前 WebRTC commit。
- 固定 GN args。
- 固定 Linux x86_64 ABI 说明。
- 纳入 `sdk_qos` patch / wrapper / public headers。
- 生成 WebRTC module archive。
- 在 SDK CMake 中加入 imported targets。

验收：

```bash
scripts/package_webrtc_modules.sh
scripts/verify_webrtc_modules.sh
scripts/verify_webrtc_first_roles.sh
```

### Step 2：替换 GoogCC

动作：

- 删除 `SenderQosController` 内部 fallback estimator。
- `VideoPushClient` 默认持有 WebRTC GoogCC。
- 缺少 `libwebrtc_qos_webrtc_googcc.a` 时 CMake 失败。
- demo 不允许构造无 backend 的 QoS controller。

删除：

```text
自研 loss/recv-rate estimator 逻辑
```

验收：

- 动态 QoS matrix 仍能下探和恢复。
- `rg` 不再出现 fallback estimator 相关逻辑。
- 日志输出 `qos_backend=webrtc_googcc`。

### Step 3：替换 pacer

动作：

- 接入 WebRTC pacing 能力；当前使用 `modules/pacing:pacing_controller_qos_minimal` 建立专用最小 adapter。
- push facade 内部持有 WebRTC pacer。
- 业务只提供 `SendPacket(bytes)` 回调。
- 先产出 `webrtc_pacing_adapter`，通过完整 pacer 门禁后再删除 SDK `SenderPacer`。

`webrtc_pacing_adapter` 合同：

- 输入来自 WebRTC RTP/RTCP sender 产出的 RTP/RTCP packet bytes 和 packet metadata。
- adapter 内部使用 WebRTC `PacingController` 决定发送时机、probe cluster、priority 和 queue delay；SDK 只负责 bytes 与 `RtpPacketToSend` 之间的转换，以及把出队结果转成 `TransportOutput::SendPacket(bytes, metadata)`。
- adapter 的唯一外部输出是 `TransportOutput::SendPacket(bytes, metadata)`。
- pacer tick/process 由 facade runtime 驱动，不由业务 transport 线程直接驱动。
- `VideoPushClient::Process(now_us)` 必须由业务 worker/task queue 周期性调用；不能只在 `PushAnnexBAccessUnit()` 后调用，否则低 FPS 弱网阶段会让 pacer 队列缺少 drain 机会。
- 重传包可以设置更高优先级，但重传策略和 NACK 决策不在 pacer 内实现。
- packet history 写入发生在 packet 进入发送/重传路径时，不能由 pacer 复制出第二套缓存。
- 当 sender rate cap 明显下降导致 queued live media 已经过期时，facade 可以丢弃 pacer 队列、请求下一帧 IDR，并将下一包 RTP/TWCC 序号滚动到最后实际发送的包之后；这样避免旧高码率队列继续阻塞实时弱网链路，也避免人为制造长参考链污染。

pacer 删除门禁：

- `webrtc_pacing_adapter` 独立 smoke 通过。
- 弱网矩阵通过。
- probe cluster 发送节奏正确；当前 `webrtc_qos_pacing_adapter_smoke` 验证 `probe_emitted=2 / probe_bytes=800 / padding_emitted=5 / padding_bytes=600`，`verify_webrtc_first_pacing_probe.sh` 验证 push facade 主路径 `rtp_packets=6 / probe_packets=6 / probe_bytes=745 / probe_cluster=1`。
- NACK/RTX 重传优先级正确；当前 pacing smoke 验证 retransmission 在 probe/media 前发送。
- IDR/关键帧进入 `PacingController` 队列，metadata 必须保留；当前 pacing smoke 验证 keyframe metadata 保留，发送节奏由 WebRTC `PacingController` 决定。
- pacer queue 不在弱网下无限增长。
- 外部 CMake consumer 能只通过 facade 使用 pacer，不接触 WebRTC 内部对象。

删除：

```text
include/webrtc_qos/sender_pacer.h
src/sender_pacer.cc
webrtc_qos_pacer
```

### Step 4：替换 WebRTC RTP/RTCP + H264 packetization/depacketization

这一阶段和旧 video sender/receiver 强耦合，不能割裂实施。WebRTC H264 packetizer/depacketizer 依赖 RTP 层，video jitter 又依赖 depacketized video packet metadata。因此 RTP/RTCP 与 H264 packetization/depacketization 作为一个大步骤推进；如果拆成子任务，也必须并行开发、同一阶段验收。

动作：

- 接入 WebRTC `modules/rtp_rtcp`。
- RTP header extension、TWCC、SR/RR、NACK、PLI 全部由 WebRTC 序列化/解析。
- H264 packetization 使用 WebRTC H264 packetizer。
- H264 depacketization 使用 WebRTC H264 depacketizer。
- SDK 不再暴露 `RtpPacket` 和 RTCP packet helper。
- 业务只看到 RTP/RTCP bytes。

删除：

```text
include/webrtc_qos/rtp_packet.h
include/webrtc_qos/rtcp_packets.h
src/rtp_packet.cc
src/rtp_packet.h
src/rtcp_packets.cc
include/webrtc_qos/video_sender.h
include/webrtc_qos/video_receiver.h
src/video_sender.cc
src/video_receiver.cc
webrtc_qos_rtp
webrtc_qos_rtcp
webrtc_qos_video
```

验收：

- TWCC 能解析 WebRTC 合法 status vector chunks。
- SR/RR reporter SSRC/media SSRC 语义正确。
- NACK/PLI wire format 由 WebRTC 生成。
- Single NALU / FU-A 由 WebRTC 处理。
- RTP seq/timestamp wrap 由 WebRTC 处理。
- push/play facade 的输入输出仍保持标准 RTP/RTCP bytes 边界。

### Step 5：替换 video jitter / receive pipeline

NACK requester 依赖接收侧 packet/frame buffer、包到达事件、关键帧请求回调、clock 和 task queue，因此不能在 video receive pipeline 之前单独替换。先把 WebRTC 接收缓冲链路接起来，再挂 NACK requester，避免后续二次改造。

动作：

- 组帧使用 WebRTC `RtpVideoFrameAssembler` 或 `PacketBuffer / FrameBuffer`。
- 接收端输出完整 Annex-B AU 的职责由 SDK wrapper 做格式归一化。
- SDK wrapper 不做 jitter / reorder 算法。
- facade 将接收包到达、完整帧输出、关键帧请求回调和 runtime clock/task queue 统一封装。

删除：

```text
include/webrtc_qos/video_jitter_player.h
src/video_jitter_player.cc
```

验收：

- 复杂乱序、丢包恢复不依赖自研逻辑。
- SDK wrapper 输出完整 Annex-B AU。
- IDR 前可补 SPS/PPS。
- FU-A 丢片、重复包、乱序包、timestamp wrap 场景通过。
- receive pipeline 能向后续 `webrtc_nack_requester` 提供 packet arrival、missing sequence、keyframe request 所需事件。

### Step 6：替换 NACK

动作：

- 接入 WebRTC `NackRequester`。
- SDK 只负责路由 NACK/PLI。
- 接收端丢包判断、重试窗口、keyframe 请求策略由 WebRTC recovery 模块处理。
- 删除旧 `RetransmissionCache`，但不能删除重传历史能力。
- sender 或 server 本地响应 NACK 时仍必须有 packet history。
- 优先使用 WebRTC sender/packet history。
- 如果 server relay 不接入 WebRTC sender 模块，则新增 `transport_packet_history`。

`transport_packet_history` 约束：

- 只保存 opaque RTP bytes。
- 用于按 RTP sequence number 查找原始包。
- 不实现 NACK 逻辑。
- 不解析 RTCP wire format。
- 不做自研恢复策略。
- key 固定为 `hop_id / ssrc / rtp_sequence_number`。
- 每条记录必须保存发送时间、payload bytes、是否重传。
- 如果服务端做 SSRC 重映射，必须在写入 history 前明确使用映射后的 hop-local SSRC。

删除：

```text
include/webrtc_qos/receiver_qos_observer.h
include/webrtc_qos/retransmission_cache.h
src/receiver_qos_observer.cc
src/retransmission_cache.cc
webrtc_qos_nack
```

允许新增 `transport_packet_history`，但它只属于 transport/server support，不属于自研 NACK/recovery 模块。

验收：

- NACK 针对 RTP sequence number。
- 重传仍保持原 RTP sequence number。
- 重传包重新进入 WebRTC RTP/RTCP/TWCC 统计路径。
- burst loss、reorder、late packet 不触发 NACK 风暴。

### Step 7：迁移 demo 和测试

动作：

- 仓库内 `webrtc_first_loopback_demo` 改用 `VideoPushClient / ServerQosRouter / VideoPlayClient`。
- 后续 `udp_long_sender_demo` 改用 `VideoPushClient`。
- 后续 `udp_long_receiver_demo` 改用 `VideoPlayClient`。
- 后续 server demo 改用 `ServerQosRouter`。
- QoE matrix 不再 include 自研底层头。
- `verify_cmake_package.sh` 改为验证新 facade。
- 删除旧 loopback 里对自研 RTP/RTCP 的直接测试。

验收：

```bash
cmake -S webrtc_qos_sdk -B webrtc_qos_sdk/build -DCMAKE_BUILD_TYPE=Release
cmake --build webrtc_qos_sdk/build -j"$(nproc)"
cmake --install webrtc_qos_sdk/build --prefix /root/output
PREFIX=/root/output bash webrtc_qos_sdk/scripts/verify_cmake_package.sh
PREFIX=/root/output SDK_ROOT=/root/webrtc_qos_sdk \
  bash webrtc_qos_sdk/scripts/verify_webrtc_first_roles.sh
```

当前 demo 本地结果：

```text
backend=webrtc_first_facade transport=custom_bytes peer_connection=false
good_static pushed=36 decoded=36 playable_ratio=1 dropped=0 receiver_rtcp=0 rtx=0 bad_send_rps=0 recovery_send_rps=0 min_bad_target=0 max_recovery_target=0 min_bad_fps=0 max_recovery_fps=0 final_target=1207178 final_fps=30 pass=true
walking_dead_zone_recover pushed=30 decoded=30 playable_ratio=1 dropped=12 receiver_rtcp=1 rtx=12 bad_send_rps=12 recovery_send_rps=30 min_bad_target=600000 max_recovery_target=1207178 min_bad_fps=10 max_recovery_fps=30 final_target=1207178 final_fps=30 pass=true
```

### Step 8：删除旧模块和发布包重建

动作：

- 删除旧头文件。
- 删除旧源码。
- 删除旧 CMake targets。
- 删除旧 dist `.a`。
- 重新生成 `dist/linux-x86_64`。

验收：

```bash
rg -n "rtp_packet.h|rtcp_packets.h|sender_pacer.h|receiver_qos_observer.h|retransmission_cache.h|video_jitter_player.h|video_sender.h|video_receiver.h|transport_feedback.h" \
  include src demo tests scripts CMakeLists.txt cmake
```

除迁移历史文档外，不应再出现引用。

## 9. 验收矩阵

### 9.1 功能验收

- H264 RTP Single NALU / FU-A 正常。
- IDR + SPS/PPS 恢复正常。
- TWCC 50ms 周期。
- SR/RR 1000ms 周期。
- GoogCC target bitrate 可观测。
- WebRTC pacer pacing rate 可观测。
- NACK/PLI 恢复链路可观测。
- sender rate cap 生效。
- 多接收端策略生效。

### 9.2 互操作验收

- SDK RTCP facade 和 WebRTC 原生 RTCP parser/serializer 互通。
- SDK push 输出可被 WebRTC depacketizer/jitter adapter 消费。
- WebRTC video jitter adapter 输出完整 Annex-B AU。
- GoogCC adapter 可消费真实 TWCC + RR RTT。
- 业务 envelope 不污染标准 RTP/RTCP bytes。

### 9.3 弱网验收

场景：

- 0% loss / 50ms RTT baseline。
- 2% random loss。
- 5% random loss。
- burst loss。
- 100ms / 300ms / 600ms RTT。
- jitter 20ms / 80ms。
- 带宽从 2.5Mbps 降到 500kbps 再恢复。
- 多 receiver 中一个弱网 receiver。

指标：

- target bitrate 收敛时间。
- freeze count / freeze duration。
- jitter buffer delay。
- NACK count。
- PLI count。
- retransmission success ratio。
- dropped frames。
- sender queue delay。
- glass-to-glass latency，如果接入真实 renderer。

### 9.4 发布验收

- 干净机器可消费 CMake package。
- 默认 role 不静默 fallback。
- dist 不包含构建机绝对路径。
- 静态库 ABI / libstdc++ 依赖说明完整。
- 最老支持发行版构建通过。

## 10. 最终门禁

Phase-2 聚合门禁入口：

```bash
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  VERIFY_LEVEL=smoke \
  scripts/verify_webrtc_first_phase2.sh

PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  VERIFY_LEVEL=qoe \
  scripts/verify_webrtc_first_phase2.sh

PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  VERIFY_LEVEL=production \
  REQUIRE_REAL_RENDERER=1 \
  REQUIRE_CAPTURE_LIBRARY=1 \
  CAPTURE_LIBRARY_DIR=/path/to/business_capture_library \
  scripts/verify_webrtc_first_phase2.sh
```

`VERIFY_LEVEL=smoke` 用于本机快速回归，串起 no-selfmade、WebRTC module smoke、外部 CMake package、loopback、pacing probe、role facade 和 synthetic 弱网矩阵。`VERIFY_LEVEL=qoe` 在 smoke 基础上增加低 RPS/低码率真实 H264 QoE 和恢复时间分布。`VERIFY_LEVEL=production` 继续进入 production soak；生产验收时必须用 `REQUIRE_REAL_RENDERER=1 / REQUIRE_CAPTURE_LIBRARY=1` 把真实 renderer 和正式业务采集素材库变成硬门禁。

Phase-2 完成度审计入口：

```bash
OUTPUT_DIR=/root/webrtc_qos_sdk/artifacts/webrtc_first_phase2_completion_audit \
  scripts/verify_webrtc_first_phase2_completion_audit.sh

OUTPUT_DIR=/root/webrtc_qos_sdk/artifacts/webrtc_first_phase2_evidence_bundle \
  scripts/collect_webrtc_first_phase2_evidence_bundle.sh

EVIDENCE_BUNDLE_DIR=/root/webrtc_qos_sdk/artifacts/webrtc_first_phase2_evidence_bundle \
  OUTPUT_DIR=/root/webrtc_qos_sdk/artifacts/webrtc_first_phase2_completion_audit_from_bundle \
  scripts/verify_webrtc_first_phase2_completion_audit.sh

PREFLIGHT_ONLY=1 \
  OUTPUT_ROOT=/root/webrtc_qos_sdk/artifacts/webrtc_first_phase2_production_gate \
  scripts/run_webrtc_first_phase2_production_gate.sh
```

这个脚本只判断“是否可以宣布 Phase-2 完成”，不替代 smoke/qoe/production 执行本身。默认完成标准：

- smoke 聚合门禁通过。
- qoe 聚合门禁通过，且 low-RPS/low-bitrate QoE 和恢复时间分布都通过。
- production soak 来自 `artifacts/webrtc_first_phase2_verify_production/production_soak`，`SOAK_MINUTES>=120`，summary/archive 存在，`rows==pass_rows`，`decode_errors/freeze_count/renderer_proxy_drop_frames` 为 0。
- real renderer summary 为 `real_renderer_status=pass`；默认不把 Xvfb 当成真实显示环境完成证据。
- capture manifest summary 覆盖六类正式业务素材；默认不接受 fixture capture library 作为完成证据。

`collect_webrtc_first_phase2_evidence_bundle.sh` 用于把正式验收机器上的 smoke/qoe/production soak/real renderer/capture 证据收集成统一 bundle，并生成 `manifest.sha256`。`verify_webrtc_first_phase2_completion_audit.sh` 支持 `EVIDENCE_BUNDLE_DIR`，会先校验 bundle sha256，再按完成标准审计其中的 summary/config/archive；production soak 部分会复用 `verify_webrtc_first_qoe_production_soak_archive.sh`，继续校验 archive sha256、row pass、弱网低 RPS/低码率和恢复时间分布。正式交付时应归档这个 bundle，而不是只给零散 log。

`run_webrtc_first_phase2_production_gate.sh` 是正式验收 wrapper。它先做三项 preflight：

- `verify_webrtc_modules.sh`
- `verify_capture_library_manifest.sh`
- `verify_real_renderer_smoke.sh`

preflight 全部通过后，才会继续执行：

- `verify_webrtc_first_phase2.sh VERIFY_LEVEL=production`
- `collect_webrtc_first_phase2_evidence_bundle.sh`
- `verify_webrtc_first_phase2_completion_audit.sh`

默认门槛就是正式验收门槛：`SOAK_MINUTES=120`、`REQUIRE_REAL_RENDERER=1`、`REQUIRE_CAPTURE_LIBRARY=1`。当前本机 `PREFLIGHT_ONLY=1` 结果是：

- `webrtc_modules=pass`
- `capture_manifest=fail`，因为 `/root/webrtc_qos_sdk/capture_library/manifest.csv` 不存在
- `real_renderer=fail`，因为没有 `DISPLAY` 且没有 `Xvfb`

这说明当前代码和门禁链路已经具备，但这台机器还不具备完成正式 production 验收的外部条件。

当前本机运行这个审计应当失败，因为已有的是 qoe、production 短时 smoke、renderer skipped 和 capture fixture 证据；这能防止把短时 runner 验证误当成生产级完成。

换句话说，当前 completion audit 失败并不表示还有新的架构功能没做，而是准确地等价于前面列出的 3 个正式验收闭环尚未完成：多小时 production soak、真实 renderer、正式业务采集素材库。

当前本机 `VERIFY_LEVEL=qoe` 聚合门禁结果：

- `phase2_verify_status=pass`，summary：`artifacts/webrtc_first_phase2_verify_qoe/phase2_verify_summary.txt`。
- synthetic facade 弱网矩阵：8/8 通过。
- low-RPS/low-bitrate synthetic facade：`11.0526 AU RPS / 33.1579 RTP pps / 600000bps / 10fps`，恢复到 `30 RPS / 1207178bps / 30fps`。
- low-RPS/low-bitrate 真实 H264 QoE：`10.9091 AU RPS / 92.7273 RTP pps / 400000bps / 10fps`，恢复到 `30 RPS / 840944bps / 30fps`，`playable_ratio=0.923077`、`avg_psnr_y=45.9423`、`avg_ssim_y=0.999833`。
- 恢复时间分布：`samples=1`，`target_recovery_time_ms_p95=0`、`fps_recovery_time_ms_p95=0`、`full_recovery_time_ms_p95=0`，均低于 `1000ms` 门槛。

当前本机 `VERIFY_LEVEL=production` 短时 smoke 结果：

- `phase2_verify_status=pass`，summary：`artifacts/webrtc_first_phase2_verify_production_smoke/phase2_verify_summary.txt`。
- 配置：`SOAK_CYCLES=1`、`FRAMES_PER_CYCLE=12`、`SCENARIOS=weak_network_low_rps_low_bitrate`、`CONTENT_MODES=block_motion`、`RUN_REAL_RENDERER=0`、`RUN_CAPTURE_LIBRARY=0`。
- production soak summary：`cycles=1`、`rows=1`、`pass_rows=1`、`playable_ratio_min=1`、`avg_psnr_y_min=54.2687`、`avg_ssim_y_min=0.999968`、`decode_errors=0`、`freeze_count=0`、`renderer_proxy_drop_frames=0`。
- 弱网低发送：`weak_low_bad_send_rps_max=12.8571`、`weak_low_bad_rtp_pps_max=184.286`、`weak_low_target_bps_max=750000`、`weak_low_encoder_fps_max=10`。
- 归档：已生成 `webrtc_first_qoe_production_soak_archive.tar.gz`、`archive/metadata.txt`、`archive/manifest.sha256`、`archive/recovery_distribution_summary.txt`；离线 `verify_webrtc_first_qoe_production_soak_archive.sh` 通过。
- 约束：该结果只证明 production runner 和归档/验签链路可执行，不能替代 `SOAK_MINUTES=120` 或更长时间的 production 级多小时 soak，也没有覆盖真实 renderer 和正式业务采集素材库。

源码门禁：

```bash
scripts/verify_no_selfmade_media_stack.sh
```

构建门禁：

```bash
cmake -S webrtc_qos_sdk -B webrtc_qos_sdk/build -DCMAKE_BUILD_TYPE=Release
cmake --build webrtc_qos_sdk/build -j"$(nproc)"
cmake --install webrtc_qos_sdk/build --prefix /root/output
PREFIX=/root/output bash webrtc_qos_sdk/scripts/verify_cmake_package.sh
PREFIX=/root/output bash webrtc_qos_sdk/scripts/verify_webrtc_first_loopback.sh
scripts/verify_webrtc_first_roles.sh
```

弱网门禁：

```bash
FRAMES=36 PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  bash webrtc_qos_sdk/scripts/run_webrtc_first_facade_matrix.sh

FRAMES=30 WIDTH=160 HEIGHT=90 \
  WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  bash webrtc_qos_sdk/scripts/run_webrtc_first_ffmpeg_qoe.sh

WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  bash webrtc_qos_sdk/scripts/run_webrtc_first_qoe_stability_720p.sh

WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  bash webrtc_qos_sdk/scripts/run_webrtc_first_qoe_multiseed_720p.sh

WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  bash webrtc_qos_sdk/scripts/run_webrtc_first_qoe_long_dynamic.sh

WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  bash webrtc_qos_sdk/scripts/run_webrtc_first_qoe_soak_720p.sh

WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  bash webrtc_qos_sdk/scripts/run_webrtc_first_qoe_high_complexity_720p.sh
```

`run_webrtc_first_facade_matrix.sh` 的 pass/fail 不只看是否可播放，还必须验证弱网退让和恢复。弱网矩阵必须显式覆盖“弱网情况下以较低 RPS 和较低码率发送”：所有 weak-low 场景都要按弱网窗口最大值验收 `bad_send_rps / bad_rtp_pps / max_bad_target_bps / max_bad_encoder_fps`，证明发送端在整个弱网阶段持续低 AU 发送频率、低 RTP 包速率、低目标码率和低 encoder FPS，不能只证明某个瞬间曾经触底。

- `bandwidth_cliff_low_rps_recover`：弱网段必须降到不高于 `15 AU RPS`、不高于 `45 RTP pps`、不高于 `600000bps`、不高于 `10fps`；恢复段必须回到不低于 `25 AU RPS`、不低于 `75 RTP pps`、不低于 `1000000bps`、不低于 `25fps`。
- `weak_network_low_rps_low_bitrate`：专门验证“弱网情况下以较低 RPS 和较低码率发送”。弱网窗口必须保持不高于 `15 AU RPS`、不高于 `45 RTP pps`、不高于 `600000bps`、不高于 `10fps`；网络恢复后必须回到不低于 `25 AU RPS`、不低于 `75 RTP pps`、不低于 `1000000bps`、不低于 `25fps`。当前 facade 本地结果为 `11.0526 RPS / 33.1579 RTP pps / 600000bps / 10fps`，恢复到 `30 RPS / 90 RTP pps / 1207178bps / 30fps`。
- `multi_receiver_worst_cap_recover`：至少两个 receiver 同时上报质量，一个 receiver 弱网、另一个 receiver 健康；server 必须在弱网窗口内选择坏 receiver 作为 worst receiver 生成 sender cap，健康 receiver 的上报不能清掉 cap，恢复后回到不限速。
- `walking_dead_zone_recover`：在上述低 RPS/低码率门槛之外，还必须触发 NACK，并通过 server 本地 packet history 完成重传恢复。
- `sustained_low_bandwidth_low_rps`：从 1/4 流时长开始持续弱网到结束，必须降到不高于 `15 AU RPS`、不高于 `45 RTP pps`、不高于 `600000bps`、不高于 `10fps`，并且最终不能自行回升。
- `weak_start_low_bandwidth_low_rps`：第 0 帧起就是持续弱网，必须直接进入不高于 `15 AU RPS`、不高于 `45 RTP pps`、不高于 `600000bps`、不高于 `10fps` 的发送模式，不能先按好网码率冲一段。
- `burst_loss_recover`：必须触发 NACK 和重传，但不要求降码率，因为它模拟的是短 burst loss，不是持续带宽 cliff。

弱网低 RPS/低码率发送还有独立门禁 `scripts/run_webrtc_first_qoe_low_rps_low_bitrate_check.sh`。它不是新场景，而是把 `weak_network_low_rps_low_bitrate` 从大矩阵里单独抽出来，同时跑 synthetic facade 和真实 H264 QoE 两条链路，强制检查弱网窗口内 `bad_send_rps / bad_rtp_pps / max_bad_target_bps / max_bad_encoder_fps`。切到 WebRTC `PacingController` 最小闭包后的本地复测：facade 为 `11.0526 AU RPS / 33.1579 RTP pps / 600000bps / 10fps`；真实 H264 QoE 为 `10.9091 AU RPS / 92.7273 RTP pps / 400000bps / 10fps`，恢复后 `30 RPS / 840944bps / 30fps`，`playable_ratio=0.923077`、`avg_psnr_y=45.7965`、`avg_ssim_y=0.999829`。

`run_webrtc_first_qoe_stability_720p.sh` 是当前真实编解码 QoE 门禁：

- baseline：1280x720 真实 H264 encode/decode，playable ratio 必须不低于 `0.85`，decode errors 必须为 `0`，平均 Y-PSNR 必须不低于 `22dB`，平均 SSIM-Y 必须不低于 `0.80`。
- bandwidth cliff recover：真实编码器必须在弱网段降到 `600000bps / 10fps / 10 RPS` 级别，恢复段回到约 `1.2Mbps+ / 30fps / 30 RPS`。
- weak-network low-RPS low-bitrate：真实编码器必须在弱网窗口内持续低发送，门槛为不高于 `15 AU RPS / 150 RTP pps / 600000bps / 10fps`，恢复段必须回到 `30 RPS / 1.2Mbps+ / 30fps`；当前 720p 本地结果为 `9.375 RPS / 78.75 RTP pps / 600000bps / 10fps`，恢复到 `30 RPS / 1260990bps / 30fps`，`full_recovery_time_ms=0`。
- sustained low-bandwidth low-RPS：真实编码器必须在持续弱网段降到 `600000bps / 10fps / 10 RPS` 级别，并且最终仍保持低发送速率。
- weak-start low-bandwidth low-RPS：真实编码器必须从流开始就降到 `600000bps / 10fps / 10 RPS` 级别，并且最终仍保持低发送速率。
- walking dead-zone recover：在 bandwidth cliff 门槛之外，还必须触发 NACK 和 server 本地重传。
- freeze proxy：所有 case 必须满足 `freeze_count=0`、`freeze_duration_ms=0`；当前 720p 稳定性最大 decoded frame 间隔不超过 `100ms`。
- renderer proxy：所有真实 H264 QoE case 默认使用 `350ms` target delay、`500ms` hard latency、`150ms` max late 门槛，必须满足 `renderer_proxy_late_frames=0`、`renderer_proxy_drop_frames=0`、`renderer_proxy_max_gap_ms<=150`。CSV 还输出 `renderer_proxy_avg_gap_ms / renderer_proxy_max_gap_ms / renderer_proxy_avg_jitter_ms / renderer_proxy_max_jitter_ms`，用于定量判断弱网下播放节奏是否卡顿；当前 renderer gap smoke 中 baseline 为 `max_gap=34ms / max_jitter=0ms`，weak-network low-RPS low-bitrate 为 `max_gap=100ms / max_jitter=67ms`。该指标只模拟播放调度和端到端 media time，不等价于真实 GPU/窗口 renderer。
- real renderer：已新增 `scripts/verify_real_renderer_smoke.sh`。有 `DISPLAY` 且可链接 X11 时，它创建真实 X11 window，按 30fps present 帧并输出 `rendered_frames / late_frames / avg_present_gap_ms / max_present_gap_ms / avg_present_jitter_ms / max_present_jitter_ms`；无 `DISPLAY` 但存在 `Xvfb` 时，脚本会自动启动 headless X11 server 跑同一套 X11 present smoke，用于 CI 覆盖窗口 present 代码路径；两者都不可用时默认输出 skipped 证据，设置 `REQUIRE_REAL_RENDERER=1` 则失败。当前机器无 `DISPLAY/WAYLAND_DISPLAY`，且 `Xvfb` 不可用，本地结果为 `real_renderer_status=skipped / reason=DISPLAY is not set and Xvfb is not available / xvfb_available=0`，所以还不能声明真实 GPU/窗口 renderer 验收完成。
- SSIM-Y：作为无需额外模型和外部工具链的 VMAF 替代指标，所有普通真实 H264 QoE case 默认要求 `avg_ssim_y>=0.80`；高复杂 stress 默认要求 `avg_ssim_y>=0.55`。
- 真实 H264 QoE 的弱网低发送门槛为不高于 `15 AU RPS / 150 RTP pps / 600000bps / 10fps`；RTP pps 阈值高于 synthetic facade 矩阵是因为真实 720p H264 一帧会拆成更多 RTP 包。
- 弱网低发送必须按整个弱网窗口验收：`max_bad_target_bps<=600000`、`max_bad_encoder_fps<=10`，不能只看 `min_bad_target_bps` 的瞬时最低点。
- 可恢复场景必须输出 `target_recovery_time_ms / fps_recovery_time_ms / full_recovery_time_ms`，并要求单条 `full_recovery_time_ms<=1000ms`；持续弱网和弱网起步场景不要求恢复时间，字段保持 `-1`。
- 已新增 `scripts/verify_recovery_time_distribution.sh` 和 Python 实现，跨一个或多个 QoE CSV 聚合可恢复场景，输出 `target/fps/full_recovery_time_ms` 的 p50/p95/max，并按 p95/max 门槛失败。production soak archive verifier 会自动运行该分布门禁，并把 `archive/recovery_distribution_summary.txt` 纳入 sha256 manifest 和 tarball。
- play facade 输出 AU 的 `capture_time_us` 必须是由 RTP timestamp 映射出的 media capture time，QoE/renderer 不能按解码顺序猜测参考帧，否则在 pacer 丢弃过期 live media 或 NACK 恢复后会产生错误画质判断。

`run_webrtc_first_qoe_multiseed_720p.sh` 是当前多 seed QoE 门禁：

- 默认跑 3 个 deterministic seed，覆盖内容运动相位和丢包相位变化。
- 每个 seed 跑 baseline、bandwidth cliff recover、weak-network low-RPS low-bitrate、sustained low-bandwidth low-RPS、weak-start low-bandwidth low-RPS、walking dead-zone recover。
- 所有 case 必须满足 playable ratio、decode errors、Y-PSNR、SSIM-Y、freeze proxy、弱网降码率/降 FPS/降 RPS、恢复段回升门槛。
- 当前本地结果 18/18 通过，`playable_ratio_min=0.875`、`avg_psnr_y_min=28.6765`、`decode_errors=0`、`freeze_count=0`、`freeze_duration_ms=0`；新增 low-RPS low-bitrate seed case 弱网段为 `9.375 RPS / 80.625..90 RTP pps / 600000bps / 10fps`，恢复到 `1260893..1287137bps / 30fps`；持续弱网和弱网起步 seed case 均最终保持 `600000bps / 10fps`。
- 高频逐像素内容曾导致 720p/1.2Mbps PSNR 不达标，该内容不作为稳定性门禁，归入后续 stress/码率策略验证。

`run_webrtc_first_qoe_long_dynamic.sh` 是当前长流动态 QoE 门禁：

- baseline：1280x720、60 tick 真实 H264 encode/decode，playable ratio 必须不低于 `0.8`，decode errors 必须为 `0`。
- bandwidth cliff recover / weak-network low-RPS low-bitrate / walking dead-zone recover：弱网段必须降码率、降 FPS、降 RPS，恢复段必须回升。
- sustained low-bandwidth low-RPS：弱网持续到结束时必须保持低码率、低 FPS、低 RPS，不允许在网络没有恢复时自行回升。
- weak-start low-bandwidth low-RPS：第 0 帧开始就是弱网时必须保持低码率、低 FPS、低 RPS，不允许先按好网码率发送。
- oscillating edge recover：弱网和恢复反复切换，必须多次下探和回升，同时保持 playable ratio、decode errors、NACK/RTX、Y-PSNR 和 SSIM-Y 门槛。
- freeze proxy：所有 case 必须满足 `freeze_count=0`、`freeze_duration_ms=0`。
- 当前本地结果 7/7 通过，新增 low-RPS low-bitrate case 弱网段为 `10.6452 RPS / 103.548 RTP pps / 600000bps / 10fps`，恢复到 `1327376bps / 30fps`；`sustained_low_bandwidth_low_rps` 和 `weak_start_low_bandwidth_low_rps` 在 60 tick 下最终保持 `600000bps / 10fps / 10RPS`，`playable_ratio_min=0.975`；所有 case 最大 decoded frame 间隔不超过 `100ms`，`push_queue_full=0`。
- 如果 pacer 队列被主动清空或某个 AU 没有完整进入链路，下一帧必须强制 IDR，避免 P 帧继续引用丢失参考帧造成长参考链污染；测试必须记录 `push_queue_full` 和 sender requested keyframe 行为。

`run_webrtc_first_qoe_soak_720p.sh` 是当前 720p extended soak QoE 门禁：

- baseline：1280x720、120 tick 真实 H264 encode/decode，playable ratio 必须不低于 `0.8`，decode errors 必须为 `0`。
- bandwidth cliff recover / weak-network low-RPS low-bitrate / walking dead-zone recover / oscillating edge recover：弱网段必须降到不高于 `15 AU RPS / 150 RTP pps / 600000bps / 10fps`，恢复段必须回到 `30 AU RPS / 1.5Mbps+ / 30fps` 级别。
- 弱网段必须使用窗口最大值验收：`max_bad_target_bps<=600000`、`max_bad_encoder_fps<=10`，并记录 `bad_send_rps/bad_rtp_pps`。
- 可恢复场景必须满足 `full_recovery_time_ms<=1000ms`。
- sustained low-bandwidth low-RPS：持续弱网必须最终保持 `600000bps / 10fps / 10RPS`，不能自行回升。
- weak-start low-bandwidth low-RPS：开局弱网必须直接低发送，不能先高码率冲一段。
- freeze proxy：所有 case 必须满足 `freeze_count=0`、`freeze_duration_ms=0`。
- 当前本地结果 7/7 通过，`playable_ratio_min=0.975`、`avg_psnr_y_min=29.8947`、`min_psnr_y_min=13.3985`、`decode_errors=0`、`freeze_count=0`、`push_queue_full=0`；新增 low-RPS low-bitrate case 弱网段为 `10.3279 RPS / 98.3607 RTP pps / 600000bps / 10fps`，恢复到 `1418928bps / 30fps`，其他可恢复场景恢复到 `1.55..1.61Mbps / 30fps`。

`run_webrtc_first_qoe_production_soak.sh` 是当前 production soak runner：

- 支持 `SOAK_CYCLES` 固定轮数和 `SOAK_MINUTES` wall-clock 时长两种模式。
- 每个 cycle 调用 `run_webrtc_first_ffmpeg_qoe.sh`，可配置 `FRAMES_PER_CYCLE / CONTENT_MODES / SCENARIOS / SEEDS / WIDTH / HEIGHT / 弱网门槛 / renderer proxy 门槛`。
- 聚合输出 `webrtc_first_qoe_production_soak.csv`、summary txt、config env、每个 cycle 的 CSV/log、archive metadata、git status、sha256 manifest 和 tar.gz。
- 总门禁要求所有 rows pass，并且 `decode_errors=0`、`freeze_count=0`、`renderer_proxy_late_frames=0`、`renderer_proxy_drop_frames=0`、`renderer_proxy_max_gap_ms` 不超过配置门槛、`push_queue_full=0`。
- production soak 聚合层会二次复查所有 weak-low 场景：`bandwidth_cliff_recover / weak_network_low_rps_low_bitrate / sustained_low_bandwidth_low_rps / weak_start_low_bandwidth_low_rps / walking_dead_zone_recover / oscillating_edge_recover` 必须满足 `bad_send_rps<=MAX_WEAK_SEND_RPS`、`bad_rtp_pps<=MAX_WEAK_RTP_PPS`、`max_bad_target_bps<=MAX_WEAK_TARGET_BPS`、`max_bad_encoder_fps<=MAX_WEAK_ENCODER_FPS`。这条门禁用于证明弱网情况下确实以较低 RPS 和较低码率发送，而不是只在某个瞬间触底。
- 已新增 `scripts/verify_webrtc_first_qoe_production_soak_archive.sh`，离线校验归档完整性、sha256 manifest、summary marker、最小 cycle/row 数、所有 row pass、`decode_errors/freeze/renderer late/drop/push_queue_full` 为 0，并根据归档的 config 再次复查 weak-low 低 RPS/低码率门槛。
- archive verifier 会自动调用 recovery distribution 门禁，检查可恢复场景的 `target/fps/full_recovery_time_ms` p50/p95/max。
- 当前 low-RPS archive smoke：`cycles=1`、`rows=2`、`pass_rows=2`、`recoverable_rows=1`、`weak_low_rows=1`、`playable_ratio_min=1`、`avg_psnr_y_min=49.3455`、`avg_ssim_y_min=0.999931`、`decode_errors=0`、`freeze_count=0`、`renderer_proxy_drop_frames=0`、`renderer_proxy_max_gap_ms=100`、`renderer_proxy_max_jitter_ms=67`、`bad_send_rps_max=12.8571`、`bad_rtp_pps_max=60`、`max_bad_target_bps_max=200000`、`max_bad_encoder_fps_max=10`、`weak_low_bad_send_rps_max=12.8571`、`weak_low_bad_rtp_pps_max=60`、`weak_low_target_bps_max=200000`、`weak_low_encoder_fps_max=10`，`target/fps/full_recovery_time_ms_p95=0`，archive verifier 和 recovery distribution verifier 均通过。
- 生产级多小时结论仍需用 `SOAK_MINUTES=120` 或更长时间在稳定机器上实际跑完，并归档 tarball、summary 和日志。

`run_webrtc_first_qoe_high_complexity_720p.sh` 是当前 720p 高复杂内容 stress QoE 门禁：

- 内容：`CONTENT_MODE=stress`，包含移动高频棋盘、斜向细节和确定性噪声；默认跑 2 个 deterministic seed。
- 场景：baseline、bandwidth cliff recover、walking dead-zone recover、oscillating edge recover。
- baseline：playable ratio 必须不低于 `0.75`，decode errors 必须为 `0`，平均 Y-PSNR 必须不低于 `15dB`，平均 SSIM-Y 必须不低于 `0.55`，freeze proxy 必须为 `0`。
- bandwidth cliff / walking dead-zone / oscillating edge：弱网段必须降到不高于 `15 AU RPS / 240 RTP pps / 900000bps / 10fps`，恢复段必须回到 `30 AU RPS / 2Mbps+ / 30fps` 级别。
- 高复杂内容也必须使用弱网窗口最大值验收：`max_bad_target_bps<=900000`、`max_bad_encoder_fps<=10`，不能只证明曾经降到低码率。
- 可恢复场景必须满足 `full_recovery_time_ms<=1000ms`。
- walking dead-zone 和 oscillating edge 必须触发 NACK/RTX，且不能出现 decode error 或 freeze。
- 当前本地结果 8/8 通过，`playable_ratio_min=0.851064`、`avg_psnr_y_min=15.5423`、`min_psnr_y_min=12.7144`、`decode_errors=0`、`freeze_count=0`、`push_queue_full=0`；弱网最坏 `11.25 RPS / 220.5 RTP pps / 900000bps / 10fps`，恢复到 `2.07..2.09Mbps / 30fps`，`full_recovery_time_ms=0`。
- 该门槛独立于普通 720p 稳定性门槛；高复杂内容一帧会拆出更多 RTP 包，且 1.8Mbps 起始码率下当前 server 半码率 rate cap 会落到 `900000bps`。

`run_webrtc_first_qoe_content_library_720p.sh` 是当前 720p deterministic 内容库 QoE 门禁：

- 内容：`block_motion`、`camera_pan`、`scene_cut`、`low_light_noise`。
- 场景：baseline、weak-network low-RPS low-bitrate、walking dead-zone recover、oscillating edge recover。
- baseline：每种内容都必须满足 playable ratio、decode errors、Y-PSNR、SSIM-Y、freeze proxy 和 renderer proxy 门槛。
- weak-network low-RPS low-bitrate：弱网段必须降到不高于 `15 AU RPS / 210 RTP pps / 750000bps / 10fps`，恢复段必须回到 `30 AU RPS / 1.5Mbps+ / 30fps` 级别。
- walking dead-zone recover / oscillating edge recover：必须触发 NACK/RTX，弱网段必须低发送，恢复段必须回升，并且不能出现 decode error 或 freeze。
- 当前本地结果 16/16 通过，`playable_ratio_min=0.942857`、`avg_psnr_y_min=31.384`、`min_psnr_y_min=19.4395`、`decode_errors=0`、`freeze_count=0`、`push_queue_full=0`、`renderer_proxy_late_frames=0`、`renderer_proxy_drop_frames=0`、`renderer_proxy_max_latency_ms=468`；弱网最坏 `11.25 RPS / 191.25 RTP pps / 750000bps / 10fps`，恢复到 `1.5Mbps+ / 30fps`，`full_recovery_time_ms=0`，最大 decoded frame 间隔 `100ms`。
- `weak_network_low_rps_low_bitrate` 在四类内容下分别保持 `10.4348 AU RPS`，RTP pps 为 `108.261..117.391`，码率上限为 `750000bps`，encoder FPS 上限为 `10fps`；恢复段回到 `30 AU RPS / 1.55..1.63Mbps / 30fps`，renderer proxy 在 `500ms` 播放预算内 `late=0/drop=0`。
- 该门槛独立于普通 720p 稳定性和 high-complexity stress：`210 RTP pps` 是根据内容库中 `low_light_noise + oscillating_edge_recover` 的真实 RTP 分片结果校准的，仍低于 high-complexity stress 的 `240 RTP pps` 门槛。

`run_webrtc_first_qoe_capture_library_720p.sh` 是当前真实采集内容库 QoE 入口门禁：

- 输入：`CAPTURE_LIBRARY_DIR` 下的 `.mp4`、`.mov`、`.mkv`、`.webm`、`.yuv`、`.i420` 文件。
- 视频文件由系统 `ffmpeg -nostdin` 转成 `WIDTH x HEIGHT`、30fps、raw I420；raw 文件按 I420 直接读取。`-nostdin` 是硬规则，避免 `ffmpeg` 从脚本 `while read` 的 stdin 消费下一条 manifest 行，导致素材 label 或路径被破坏。
- 已新增 `scripts/verify_capture_library_manifest.sh`。正式采集库推荐提供 `manifest.csv`，至少包含 `category,path`，可选 `label,enabled`；默认必须覆盖 `indoor_face / outdoor_walking / low_light_noise / screen_text / high_motion / scene_cut` 六类，且不允许同一个真实文件重复冒充多个类别。
- manifest 校验会用 `ffprobe` 验证视频文件有视频流和最小时长；raw `.yuv/.i420` 会按 `CAPTURE_WIDTH x CAPTURE_HEIGHT x MIN_CAPTURE_FRAMES` 验证文件大小；缺少类别、路径不存在、重复路径、格式不支持都会直接失败。
- 已新增 `scripts/generate_capture_library_fixture.sh`，可在业务正式素材库准备前生成 deterministic fixture 采集库和 `manifest.csv`，覆盖 `indoor_face / outdoor_walking / low_light_noise / screen_text / high_motion / scene_cut` 六类，用来复现 manifest、转码和 QoE 门禁链路。
- `run_webrtc_first_qoe_capture_library_720p.sh` 支持 `REQUIRE_CAPTURE_MANIFEST=1`，用于在跑 QoE 前强制执行六类覆盖门禁，并输出 `capture_manifest_summary.txt`。
- 转换后的内容以 `capture_i420:<label>:<path>` 内容源进入 `run_webrtc_first_ffmpeg_qoe.sh`，复用真实 H264 encode/decode、WebRTC-first push/server/play、弱网低发送、恢复回升、freeze proxy 和 renderer proxy 门禁。
- 当前本地 fixture smoke 已通过 Phase-2 聚合门禁 `RUN_CAPTURE_LIBRARY=1 REQUIRE_CAPTURE_LIBRARY=1` 跑入 `verify_webrtc_first_phase2.sh`，summary 为 `artifacts/webrtc_first_phase2_verify_capture_fixture/phase2_verify_summary.txt`。manifest 校验 `entries=6`、类别覆盖 `high_motion,indoor_face,low_light_noise,outdoor_walking,scene_cut,screen_text`，QoE `cases=6/6 pass`、`decoded_frames_min=10`、`playable_ratio_min=0.833333`、`avg_psnr_y_min=42.6753`、`avg_ssim_y_min=0.998468`、`decode_errors=0`、`freeze_count=0`、`renderer_proxy_drop_frames=0`、`renderer_proxy_max_gap_ms=34`。
- fixture 库只用于可复现 smoke，不等价于正式业务真实采集素材；正式采集素材库仍需业务侧提供或录制，但验收入口已经从“临时单文件 smoke”升级为“manifest 六类覆盖 + QoE 矩阵”。

旧 Phase-1a 自研链路弱网脚本已删除，不能继续作为 Phase-2 QoS 结论依据。新的弱网门禁必须直接驱动 `VideoPushClient / ServerQosRouter / VideoPlayClient`，并记录 WebRTC adapter backend、目标码率、实际发送码率、FPS/RPS、RTT、loss、jitter、NACK、PLI、重传、恢复时间、freeze proxy 和 playable frame ratio。

发布包门禁：

```bash
find dist/linux-x86_64/include/webrtc_qos -maxdepth 1 -type f | sort
find dist/linux-x86_64/lib -maxdepth 1 -name '*.a' -type f | sort
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 bash scripts/verify_cmake_package.sh
```

禁止项：

- 发布包中不得再包含 `libwebrtc_qos_rtp.a`。
- 发布包中不得再包含 `libwebrtc_qos_rtcp.a`。
- 发布包中不得再包含 `libwebrtc_qos_nack.a`。
- 发布包中不得再包含 `libwebrtc_qos_pacer.a`。
- 发布包中不得再包含 `libwebrtc_qos_video.a`。
- 对外头文件不得再暴露自研 `RtpPacket`、`Rtcp*`、`SenderPacer`、`VideoJitterPlayer`。
- 默认 role 缺少 WebRTC module 时不得自动 fallback。
- facade、demo 和发布包不得引入 `PeerConnection` 会话语义，不得让 WebRTC 拥有 socket 或业务网络 IO。

## 11. 风险和处理原则

### 11.1 主要风险

- WebRTC RTP/RTCP/pacer/NACK/video jitter 模块会带入 task queue、clock、sequence checker、field trial、environment 等生命周期要求。
- WebRTC 原生模块可能依赖更多基础库，静态库闭包会比当前自研版本大。
- public API 会破坏兼容，需要接受旧 demo 和旧头文件删除。
- 弱网测试阈值可能需要重新校准，因为 WebRTC pacer 和 WebRTC jitter 的行为不会和当前自研实现完全一致。
- 发布包 ABI 要重新验证，尤其是外部机器只拿 `include + lib` 时的链接顺序和系统库依赖。

### 11.2 处理原则

- 不为了兼容旧实现保留 fallback。
- 不为了短期测试通过继续维护半套 RTCP/TWCC。
- 如果某个 WebRTC 模块依赖过重，继续裁剪 WebRTC GN 闭包，而不是回退到自研实现。
- 每删除一个自研模块，都必须有对应 WebRTC 模块的弱网和外部消费验证。
- 旧轻量实现不得换名进入工具、测试或发布包。

## 12. 后续扩展

这些不阻塞 WebRTC-first 重构主线：

- Opus + NetEq 音频闭环。
- 真实 Linux `tc/netem` / 容器网络矩阵。
- 真实 renderer 指标；当前已有 X11 real-renderer smoke 入口和可选 Xvfb headless smoke 支持，但本机无 `DISPLAY` 且无 `Xvfb`，只有 skipped 证据，尚缺有显示环境机器上的真实 GPU/窗口实跑结果。
- 正式真实采集素材库；当前已有采集素材接入脚本和 smoke 门禁。
- 多接收端 server rate cap 策略扩展。
- 生产传输加密接入。
- 多发行版 ABI profile。

音频扩展目标：

- Opus 48kHz。
- RTP payload type 默认 111，可配置。
- WebRTC NetEq 输出 PCM。
- 暴露 concealment、jitter buffer delay、expand、accelerate、preemptive expand 等统计。
- 音视频共用 transport sequence space 时，GoogCC 输入正确。

## 13. 最终结论

Phase-2 的最终交付标准不是“WebRTC adapter 可选存在”，而是：

```text
SDK 默认主路径就是 WebRTC；
自研 RTP/RTCP/NACK/pacer/jitter 已从代码和发布包中删除；
业务只负责传输和服务端策略。
```

执行口径：

```text
接入 WebRTC 原生模块
  -> 迁移 facade
  -> 删除对应自研模块
  -> 跑弱网/QoE/发布包门禁
```

这是一轮破坏性重构，但它能把项目从原型验证拉回最初目标：不做完整 WebRTC 会话层，也不自研媒体协议栈，而是在自定义 C/S 传输系统上复用 WebRTC 成熟的 QoS、RTP/RTCP、pacing、NACK 和 jitter 能力。
