# WebRTC QoS SDK Phase-1a

这是 `webrtc_qos_sdk_design.md` 的第一阶段实现。项目目标不是做完整
WebRTC Client、PeerConnection 或 SFU，而是在 Linux native C/S 架构里，把
WebRTC 里真正需要的 QoS、拥塞控制、RTP/RTCP、NACK 恢复、视频 jitter 能力拆成
可按需链接的小库。业务侧仍然负责真实传输、安全、鉴权、会话和服务端策略。

根目录 `README.md` 默认使用中文；`dist/linux-x86_64/README.md` 是随发布包安装出来
的说明文件。

## 当前范围

Phase-1a 已收敛为 H264 视频闭环：

- 只做 H264 视频，不做音频、NetEq、Opus。
- 发送端输入 Annex-B access unit，接收端输出完整 Annex-B access unit。
- RTP payload type 固定为 `96`，视频时钟固定为 `90000 Hz`。
- H264 固定 `profile-level-id=42e01f`，目标验证规格为 `720p30`。
- RTP H264 `packetization-mode=1`，只支持 Single NALU 和 FU-A，禁用 STAP-A。
- 禁用 B 帧，只允许 I/P 帧；IDR 作为关键帧，SPS/PPS 随 IDR 发送。
- 所有参与 QoS 的 RTP 包携带 transport-wide sequence number，header extension id 固定为 `1`。
- 发送端 QoS 只消费 server 或 receiver 生成的 `uplink_twcc` 与 RTCP RR RTT。
- `uplink_twcc` 周期目标为 `50ms`；RTCP SR/RR 周期目标为 `1000ms`。
- Pacing 使用 SDK 自研轻量 `SenderPacer`，不直接引入 WebRTC pacer。
- 接收端生成 downlink quality、NACK、PLI；downlink quality 不直接喂 sender GoogCC。
- 多播放端或服务端下行策略只通过 `SENDER_RATE_CAP_V1` 压 sender 上限。
- 不包含 ICE、DTLS、SRTP、SDP、PeerConnection、完整 RTP/RTCP 栈或完整 WebRTC media pipeline。

## 已实现能力

- H264 Annex-B 解析、SPS/PPS/IDR/B-frame 校验、Annex-B access unit 归一化输出。
- RTP 解析/序列化、transport-wide CC RTP header extension。
- RTCP SR、RR、TWCC transport feedback、Generic NACK、PLI。
- `SenderQosController` facade，支持轻量 fallback estimator 与 WebRTC GoogCC adapter 后端。
- SDK 轻量 `SenderPacer`，支持 token bucket、5ms tick、重传优先、AU 原子入队、队列上限和 P 帧丢弃。
- H264 `VideoSender`，将 Annex-B AU packetize 为 Single NALU/FU-A RTP 包。
- H264 `VideoReceiver` 与 `VideoJitterPlayer`，输出完整 Annex-B AU。
- `ReceiverQosObserver` 与 `RetransmissionCache`，支持 NACK 候选、重传缓存和 downlink report。
- WebRTC GoogCC 被单独打包为 `libwebrtc_qos_googcc_adapter.a`。
- WebRTC H264 PacketBuffer 视频 jitter 路径被单独打包为 `libwebrtc_qos_video_jitter_adapter.a`。
- FFmpeg/libx264 编码器和 FFmpeg H264 解码器作为可选 demo/QoE 验证模块，不进入核心 SDK 依赖闭包。
- 提供本地 loopback、两端直连 UDP、三进程 UDP relay harness、长流 QoE、720p 稳定性等测试入口。

## 代码目录

- `include/webrtc_qos/`：对外公开的 SDK 头文件。
- `src/h264_annexb.cc`：Annex-B NALU split/join、H264 AU 分类、SPS/PPS/IDR/B-frame 检查。
- `src/rtp_packet.cc`：轻量 RTP 解析/序列化和 TWCC header extension。
- `src/rtcp_packets.cc`：RTCP SR/RR/TWCC/NACK/PLI wire format。
- `src/transport_feedback.cc`：`DownlinkQuality` 和 `SenderRateCap` 的 SDK 二进制消息。
- `src/sender_qos_controller.cc`：发送端 QoS facade、fallback estimator、rate cap、编码码率/FPS 决策。
- `src/sender_pacer.cc`：SDK 轻量 pacer，负责发送节奏、队列控制和重传优先级。
- `src/video_sender.cc`：H264 AU 到 RTP packetization，负责 RTP timestamp 和 transport sequence 分配。
- `src/video_receiver.cc`、`src/video_jitter_player.cc`：H264 RTP depacketize、jitter 组帧、Annex-B AU 输出。
- `src/receiver_qos_observer.cc`、`src/retransmission_cache.cc`：接收端丢包观测、NACK、重传缓存。
- `src/production_transport_adapter.cc`：业务传输适配模板，将 SDK payload 拷贝为业务自有消息后异步发送。
- `src/sender_qos_googcc_bridge.cc`：`SenderQosController` 到 WebRTC GoogCC adapter 的可选桥接。
- `src/video_jitter_bridge.cc`：`VideoJitterPlayer` 到 WebRTC H264 PacketBuffer adapter 的可选桥接。
- `src/ffmpeg_h264_encoder.cc`、`src/ffmpeg_h264_decoder.cc`：真实 H264 编解码验证模块，可选。
- `demo/`：loopback、push、receive_play、UDP、long stream、QoE 验证 demo。
- `scripts/`：构建、打包、弱网矩阵、QoE 矩阵和发布包校验脚本。

## 快速构建

```bash
cd /root
cmake -S webrtc_qos_sdk -B webrtc_qos_sdk/build -DCMAKE_BUILD_TYPE=Release
cmake --build webrtc_qos_sdk/build -j"$(nproc)"
cmake --install webrtc_qos_sdk/build --prefix /root/output
```

基础自测：

```bash
cd /root/webrtc_qos_sdk
./build/webrtc_qos_selftest
```

完整 Phase-1a 验证入口：

```bash
cd /root
bash webrtc_qos_sdk/scripts/verify_phase1a.sh
```

外部 CMake 消费验证：

```bash
cd /root/webrtc_qos_sdk
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 bash scripts/verify_cmake_package.sh
```

## 发布包

仓库内已提交 Linux x86_64 发布包：

```text
dist/linux-x86_64/
  include/webrtc_qos/
  lib/
    libwebrtc_qos*.a
    cmake/WebRtcQosSdk/
  README.md
```

当前发布包包含 19 个公开头文件和 15 个静态库：

```text
libwebrtc_qos.a
libwebrtc_qos_core.a
libwebrtc_qos_feedback.a
libwebrtc_qos_ffmpeg_decoder.a
libwebrtc_qos_ffmpeg_encoder.a
libwebrtc_qos_googcc_adapter.a
libwebrtc_qos_googcc_bridge.a
libwebrtc_qos_nack.a
libwebrtc_qos_pacer.a
libwebrtc_qos_rtcp.a
libwebrtc_qos_rtp.a
libwebrtc_qos_transport.a
libwebrtc_qos_video.a
libwebrtc_qos_video_jitter_adapter.a
libwebrtc_qos_video_jitter_bridge.a
```

发布包内已包含两个从 WebRTC 源码编译并裁剪出来的核心能力：

- `libwebrtc_qos_googcc_adapter.a`：WebRTC `network_control/goog_cc` 适配库。
- `libwebrtc_qos_video_jitter_adapter.a`：基于 WebRTC H264 PacketBuffer 的视频 jitter 适配库。

### 其他服务器能否直接使用

可以在 Linux x86_64 机器上直接作为静态 SDK 使用，但它不是“与 Linux 版本完全无关”的二进制：

- 二进制目标是 Linux x86_64、ELF64、System V ABI。
- 静态 `.a` 在最终链接和运行时仍然依赖目标机的 libc、libstdc++、编译器 ABI 与系统库版本。
- 生产发布建议在“最老支持发行版”或固定容器/toolchain 中构建发布包，再分发到更高版本环境。
- CMake package 使用 `_IMPORT_PREFIX` 相对路径，不应固化 `/root/output`、`/root/webrtc_qos_sdk`、`/root/src` 或 `/usr/lib64`。
- 核心 SDK、WebRTC GoogCC adapter、WebRTC H264 jitter adapter 消费方需要链接 `pthread`、`dl`、`rt`、`atomic`。
- FFmpeg encoder/decoder 目标是可选目标，只有目标机器能找到 `avcodec`、`avutil`、`swscale` 时才创建；核心 push/play/transport 角色不要求 FFmpeg。

检查发布包是否带入本机绝对路径：

```bash
cd /root/webrtc_qos_sdk
if rg -n "/root/output|/root/webrtc_qos_sdk|/root/src|/usr/lib64" \
  dist/linux-x86_64/lib/cmake/WebRtcQosSdk; then
  echo "unexpected absolute path in release CMake package"
  exit 1
fi
```

## 外部项目集成

外部项目只需要指向 `dist/linux-x86_64`：

```cmake
find_package(WebRtcQosSdk REQUIRED CONFIG)

add_executable(app main.cc)
target_link_libraries(app PRIVATE WebRtcQosSdk::role_push)
```

构建示例：

```bash
cmake -S app -B app/build \
  -DCMAKE_PREFIX_PATH=/path/to/webrtc_qos_sdk/dist/linux-x86_64
cmake --build app/build -j"$(nproc)"
```

可用的角色 target：

- `WebRtcQosSdk::role_transport`：只接入业务传输边界。
- `WebRtcQosSdk::role_server`：轻量 relay/test harness 需要的 RTP、RTCP、feedback、NACK。
- `WebRtcQosSdk::role_push`：发送端 push，包含 video、pacer、feedback、NACK、RTCP/RTP、GoogCC bridge/adapter。
- `WebRtcQosSdk::role_play`：播放端 receive，包含 video、NACK、feedback、RTCP/RTP、video jitter bridge/adapter。
- `WebRtcQosSdk::role_prototype`：原型期单进程集成，包含 facade 与可选 WebRTC adapter。

也可以按模块单独链接 `WebRtcQosSdk::webrtc_qos_rtp`、`WebRtcQosSdk::webrtc_qos_rtcp`、
`WebRtcQosSdk::webrtc_qos_pacer` 等小库。

## 库边界

- `libwebrtc_qos_core.a`：公共类型和 H264 Annex-B helper。
- `libwebrtc_qos_rtp.a`：轻量 RTP 与 TWCC header extension。
- `libwebrtc_qos_rtcp.a`：SR、RR、TWCC、NACK、PLI。
- `libwebrtc_qos_feedback.a`：downlink quality、sender rate cap、sender QoS facade。
- `libwebrtc_qos_transport.a`：业务传输集成边界。
- `libwebrtc_qos_nack.a`：轻量 RTP gap detection、NACK、重传缓存。
- `libwebrtc_qos_pacer.a`：SDK 轻量发送 pacer。
- `libwebrtc_qos_video.a`：H264 video sender、receiver、jitter player。
- `libwebrtc_qos_googcc_adapter.a`：WebRTC GoogCC adapter。
- `libwebrtc_qos_googcc_bridge.a`：QoS facade 到 GoogCC adapter 的桥接。
- `libwebrtc_qos_video_jitter_adapter.a`：WebRTC H264 PacketBuffer 视频 jitter adapter。
- `libwebrtc_qos_video_jitter_bridge.a`：video jitter facade 到 WebRTC adapter 的桥接。
- `libwebrtc_qos_ffmpeg_encoder.a`：可选 FFmpeg/libx264 编码器 demo/QoE 验证库。
- `libwebrtc_qos_ffmpeg_decoder.a`：可选 FFmpeg H264 解码器 demo/QoE 验证库。
- `libwebrtc_qos.a`：Phase-1a SDK facade 聚合库，便于原型期单库链接。

设计原则是不要发布一个巨大的 `libwebrtc.a`。每个保留下来的 WebRTC 能力都单独出库、单独出头文件，应用按需集成。

## WebRTC 裁剪边界

Phase-1a 中保留的 WebRTC 能力：

- `network_control/goog_cc`：用于发送端拥塞控制。
- H264 parsing 与 `modules/video_coding::PacketBuffer`：用于视频 jitter 组帧。

明确没有进入 Phase-1a WebRTC 闭包的能力：

- WebRTC pacer：当前使用 SDK 自研轻量 `SenderPacer`。
- 完整 WebRTC RTP/RTCP 模块：当前使用 SDK 轻量 RTP/RTCP helpers。
- `api/video:rtp_video_frame_assembler` 全量 target：依赖过重，当前只保留 H264 PacketBuffer 所需闭包。
- WebRTC `NackRequester`：当前使用 SDK 轻量 NACK 与重传缓存。
- protobuf、Perfetto、examples、tools、Rust、gRPC、Opus、NetEq、libyuv、完整 PeerConnection 相关能力。

构建 WebRTC adapter 的入口：

```bash
cd /root
bash webrtc_qos_sdk/scripts/package_webrtc_googcc.sh
bash webrtc_qos_sdk/scripts/build_googcc_bridge.sh
bash webrtc_qos_sdk/scripts/build_video_jitter_bridge.sh
```

## 协议和反馈方向

发送方向：

- `sender -> receiver/server`：H264 RTP，携带 RTP sequence number、RTP timestamp、transport sequence number。
- `sender -> receiver/server`：RTCP SR，用于 RTT 计算。

上行 QoS：

- `receiver/server -> sender`：标准 RTCP TWCC transport feedback，即 `uplink_twcc`。
- `receiver/server -> sender`：RTCP RR，sender 通过 LSR/DLSR 语义得到 RTT，SDK 内部暴露为 `RtcpReceiverReport::rtt_ms`。
- `receiver/server -> sender`：`SENDER_RATE_CAP_V1`，限制最终发送码率上限。

下行质量：

- `receive_play -> server` 或直连测试里的 `receiver -> sender`：`DownlinkQuality`、NACK、PLI。
- `downlink_quality.rtt_ms` 来自业务可靠控制通道 ping/pong 或测试 harness 观测，只服务服务端策略和日志，不作为 sender GoogCC RTT 主输入。

重传语义：

- NACK 针对 RTP sequence number。
- TWCC 针对 transport sequence number。
- 重传包保持原 RTP sequence number，重新分配新的 transport sequence number。
- jitter buffer 按 RTP sequence number 去重，拥塞控制按新的 transport sequence number 统计重传发送事件。

## 轻量 SenderPacer

Phase-1a 默认使用 SDK 自研轻量 pacer，原因是 WebRTC pacer 依赖闭包较重，而当前目标是先跑通 C/S 自定义传输里的端上 QoS 闭环。

当前硬参数：

- tick 间隔：`5ms`。
- token bucket 按 `final_target_bps` 或 pacing target 增加预算。
- 队列上限：`500ms` 媒体时长或 `512KB`。
- 最大媒体包年龄：默认 `1400ms`。
- 重传包优先于普通媒体包。
- IDR 可以短时 burst，但仍受预算和队列上限约束。
- 队列满时普通 P 帧可丢。
- 丢弃 P 帧后进入等待 IDR 状态，避免后续参考链持续污染。

后续如果 WebRTC pacer 的依赖闭包可控，可以作为单独 adapter 库替换或对比，但不阻塞 Phase-1a。

## Demo 和测试入口

基础 demo：

```bash
cd /root
./webrtc_qos_sdk/build/demo/loopback/loopback_demo
./webrtc_qos_sdk/build/demo/dynamic_qos/dynamic_qos_demo
```

两端直连 UDP 长流矩阵：

```bash
cd /root
bash webrtc_qos_sdk/scripts/run_udp_direct_long_stream_matrix.sh
```

三进程 UDP relay harness 矩阵：

```bash
cd /root
bash webrtc_qos_sdk/scripts/run_udp_long_stream_matrix.sh
```

720p 端到端稳定性矩阵：

```bash
cd /root
bash webrtc_qos_sdk/scripts/run_udp_long_stream_720p_profile.sh
bash webrtc_qos_sdk/scripts/run_udp_long_stream_720p_stability.sh
```

策略对比 QoE 矩阵：

```bash
cd /root
bash webrtc_qos_sdk/scripts/run_long_stream_qoe_matrix.sh
bash webrtc_qos_sdk/scripts/run_long_stream_qoe_720p_profile.sh
bash webrtc_qos_sdk/scripts/run_long_stream_qoe_720p_stability.sh
```

UDP netem 类弱网矩阵：

```bash
cd /root
RUNS=3 bash webrtc_qos_sdk/scripts/run_udp_netem_matrix.sh
```

soak 入口：

```bash
cd /root
DURATION_SEC=60 MATRIX_RUNS=1 bash webrtc_qos_sdk/scripts/run_udp_soak.sh
```

## 弱网场景

当前测试不是只覆盖单一 happy path，已经覆盖：

- `walking_dead_zone`：正常网络进入无覆盖/弱覆盖，再恢复到好网络。
- `bandwidth_cliff_recover`：带宽突然跌到 `<100kbps` 级别，然后恢复。
- `jitter_loss_recover`：高 jitter、丢包、乱序混合，再恢复。
- `rtt_jitter_spike_recover`：RTT 和 jitter 激增但没有显式高丢包，再恢复。
- `loss_burst_recover`：突发丢包后恢复。
- `oscillating_edge`：边缘网络反复震荡。

内容 profile 覆盖：

- `motion`：基础运动内容。
- `low_motion`：低运动、低细节内容，用于观察不必要降质。
- `detail_motion`：高细节加运动，用于压测过激降码率/降帧。

指标体系分为 QoS 和 QoE：

- QoS：sender target bitrate、pacing bitrate、final target bitrate、FPS、RTT、loss、rate cap、NACK、PLI、RTX、TWCC、队列丢包。
- QoE：完成帧数、解码帧数、decode errors、PSNR avg/min、completion gap、media gap、frame latency、jitter buffer residence、deadline drops、freeze proxy。

## 当前测试结果摘要

### 直连两端动态弱网矩阵

最新本地结果：`MATRIX_CONTENTS="motion low_motion detail_motion"`，`MATRIX_RUNS=3`，默认 `FRAMES=300`。

| 指标 | 结果 |
| --- | ---: |
| 通过用例 | 27 / 27 |
| 完成帧 / 解码帧 | 6300 / 6300 |
| 解码错误 | 0 |
| sender target 最低 / 恢复最高 | 80000 / 2500000 bps |
| sender FPS 最低 / 恢复最高 | 5 / 30 |
| receiver drop / delay / jitter 事件 | 372 / 1878 / 743 |
| receiver 最大 completion gap | 943 ms |
| receiver 最大 media gap | 1600 ms |
| PSNR avg/min floor | 50.11 / 32.37 dB |
| NACK / PLI / sender RTX | 399 / 45 / 3480 |
| sender rate cap 次数 | 304 |
| pacer 丢 AU / enqueue 丢 AU | 137 / 0 |
| sender source frame skips | 1257 |

结论：直连端到端路径已经证明 sender 会在严重弱网下降到 `80kbps/5fps`，并在网络恢复后回到 `2500000bps/30fps`。该测试不依赖服务端重传或 SFU 行为，重点验证端上 QoS、pacing、NACK、jitter 和恢复。

### 三进程 UDP 动态弱网矩阵

最新本地 320x180 真实 UDP 结果：`MATRIX_CONTENTS=motion`，`MATRIX_RUNS=1`。

| 场景 | 完成 / 解码 | sender 最低 target | sender 最低 FPS | sender 最终 target / FPS | 最大 frame gap | PSNR avg/min | NACK / RTX | 结果 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `walking_dead_zone` | 156 / 154 | 90000 bps | 8 | 2500000 bps / 30 | 380 ms | 61.34 / 30.50 dB | 25 / 176 | PASS |
| `bandwidth_cliff_recover` | 154 / 150 | 180000 bps | 8 | 2500000 bps / 30 | 101 ms | 59.24 / 30.16 dB | 28 / 132 | PASS |
| `jitter_loss_recover` | 180 / 166 | 500000 bps | 15 | 2500000 bps / 30 | 230 ms | 60.55 / 24.08 dB | 13 / 64 | PASS |

汇总：3/3 通过，`decode_errors=0`，所有场景结束时 sender 都恢复到 `2500000bps/30fps`，server rate cap 都恢复到 unlimited。

### 720p 真实 UDP 端到端稳定性

最新本地结果：`MATRIX_CONTENTS="motion low_motion detail_motion"`，`MATRIX_RUNS=3`，1280x720，起始 2.5Mbps。

| 指标 | 结果 |
| --- | ---: |
| 通过用例 | 27 / 27 |
| network seeds | 1, 2, 3 |
| 解码错误 | 0 |
| 完成帧 / 解码帧 | 4414 / 4372 |
| sender target 最低 | 90000 bps |
| sender FPS 最低 | 5 |
| sender FPS 恢复 | 30 |
| sender target 恢复最高 | 2500000 bps |
| 最大 completion gap | 575 ms |
| 最大 media gap | 667 ms |
| PSNR avg/min floor | 38.23 / 16.18 dB |
| NACK / RTX | 1209 / 6089 |

结论：720p 端到端测试已经覆盖三类内容、三组 deterministic seed、三种动态弱网 profile，证明 live 编码器码率/FPS 可下探和恢复，接收端可通过 NACK/jitter 输出可解码 Annex-B AU。

### 策略对比 QoE 矩阵

长流 QoE 矩阵比较 `adaptive`、`balanced`、`bitrate_only`、`fixed` 策略，并比较 `lightweight` 与 `webrtc` 后端。它不是单纯看“能跑”，而是用定义好的目标函数衡量是否更优。

最新 320x180 聚合排名：

| 后端/策略 | balanced QoE | PSNR avg/min | latency avg/max ms | jitter avg/max ms | decode errors | drops | deadline drops | failed cases |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `webrtc/adaptive` | 455.336 | 56.84 / 15.33 | 131.9 / 1480 | 41.1 / 730 | 0 | 67 | 0 | 0 |
| `webrtc/balanced` | 3342.996 | 56.85 / 15.33 | 138.8 / 1480 | 41.4 / 665 | 0 | 67 | 0 | 0 |
| `lightweight/adaptive` | 11001.106 | 27.47 / 14.30 | 103.0 / 1790 | 9.0 / 435 | 74 | 67 | 7 | 3 |
| `webrtc/bitrate_only` | 41023.278 | 52.95 / 15.46 | 165.6 / 890 | 48.4 / 430 | 0 | 104 | 0 | 0 |
| `webrtc/fixed` | 166487.944 | 59.16 / 14.97 | 302.7 / 1800 | 48.1 / 1175 | 0 | 8565 | 1437 | 0 |

当前结论是有边界的：在已定义场景、内容、候选策略、seed、视频规格和目标函数内，`webrtc/adaptive` 是当前最优候选；这不等价于生产全局最优。

### 720p QoE 稳定性

最新 720p 多 seed 稳定性结果：`MATRIX_RUNS=3`，3 类内容，5 个场景，共 45 个 case。

| 后端/策略 | cases | balanced QoE | PSNR avg/min | max latency/jitter ms | decode errors | drops | deadline drops | failed cases | validation failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `webrtc/adaptive` | 45 | 3668.548 | 56.140 / 15.673 | 1800 / 895 | 0 | 212 | 3 | 0 | 0 |

该结果比一次 demo pass 更可信，但仍有风险边界：

- 最坏 case 的最大 latency 会触到 `1800ms` 验证门限，裕量不大。
- `detail_motion/bandwidth_staircase` 仍是最难恢复场景。
- `detail_motion/rtt_jitter_spike_recover` 的 `psnr_min` 可低到约 `15.67 dB`，高于当前硬门限但视觉上仍偏脆弱。

## 当前服务端/测试拓扑

服务端目前不是生产 SFU。测试里有两类拓扑：

- 两端直连：`udp_long_sender_demo <-> udp_long_receiver_demo`。receiver 直接回传 TWCC、RR、NACK、PLI、rate cap，sender 自己缓存并重传 RTP。
- 三进程 relay harness：`sender -> udp_long_server_demo -> receiver`。server 只负责本地 UDP relay、弱网模拟、feedback plumbing、重传缓存和 rate cap 转发/生成。

这符合当前优先级：先把 SDK 端上的 QoS、pacing、jitter、NACK、编码器适配跑通。生产服务端的 SSRC 映射、多播放端汇总、最差接收端策略、防抖、鉴权、加密和公网抗攻击不在 Phase-1a 代码闭包内。

## 已知边界和后续工作

当前可控但还没有证明生产最优的部分：

- 还没有在真实 `tc/netem`、真实 NIC queue、真实公网移动网络下完成完整 720p 多 seed 矩阵。
- 还没有真实 renderer，因此 freeze、glass-to-glass latency、render queue depth 仍主要依赖 proxy 指标。
- 还没有多 receive client 的 SFU 汇总策略和 worst-receiver 防抖验证。
- 还没有音频 Opus + NetEq；这放到 Phase-1b。
- SDK 轻量 pacer 已能满足当前矩阵，但还没有和 WebRTC pacer adapter 做生产级 A/B。
- 当前 QoE “最优”只在已定义目标函数和场景集内成立，不是全局最优证明。

建议下一阶段：

- Phase-1b：补 Opus + NetEq 音频闭环。
- Phase-2：真实 Linux `tc/netem`/容器网络矩阵、真实 renderer 指标、多接收端 rate cap 汇总、防抖和生产传输加密接入。
- Phase-3：WebRTC pacer adapter 可选库、更多移动网络 trace、长时间 soak、跨发行版 ABI profile。

## 发布流程

重新生成安装目录和仓库发布包：

```bash
cd /root
cmake -S webrtc_qos_sdk -B webrtc_qos_sdk/build -DCMAKE_BUILD_TYPE=Release
cmake --build webrtc_qos_sdk/build -j"$(nproc)"
cmake --install webrtc_qos_sdk/build --prefix /root/output
bash webrtc_qos_sdk/scripts/package_webrtc_googcc.sh
bash webrtc_qos_sdk/scripts/build_googcc_bridge.sh
bash webrtc_qos_sdk/scripts/build_video_jitter_bridge.sh

cd /root/webrtc_qos_sdk
rm -rf dist/linux-x86_64/include dist/linux-x86_64/lib dist/linux-x86_64/README.md
mkdir -p dist/linux-x86_64
cp -a /root/output/include dist/linux-x86_64/
cp -a /root/output/lib dist/linux-x86_64/
cp -a /root/output/README.md dist/linux-x86_64/README.md
find dist/linux-x86_64/include/webrtc_qos -maxdepth 1 -type f | wc -l
find dist/linux-x86_64/lib -maxdepth 1 -name '*.a' -type f | wc -l
```

发布前至少执行：

```bash
cd /root/webrtc_qos_sdk
./build/webrtc_qos_selftest
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 bash scripts/verify_cmake_package.sh
git diff --check
```

更完整的门禁：

```bash
cd /root
bash webrtc_qos_sdk/scripts/verify_phase1a.sh
```

## C++ ABI 规则

拆分静态库时，公开的有状态 C++ 类不能依赖 header 内联生成析构和 move 生命周期代码。尤其是持有 STL 容器、`std::function`、`std::unique_ptr`、pimpl 或 backend interface 的类。

当前 `SenderQosController`、`TransportPort`、`VideoJitterPlayer` 已提供 out-of-line destructor/move 定义。`scripts/verify_cmake_package.sh` 会构造、移动、调用并销毁 push/play/transport/prototype 对象，防止外部消费者只拿 `dist` 包链接时出现生命周期符号或 ABI 问题。

新增公开有状态类时，必须先把它加入外部 CMake consumer 验证，再发布 `dist`。

## 参考指标

- W3C WebRTC Stats：定义 receiver video freeze、total freeze duration、jitter buffer delay、packet discard、NACK，以及 sender target bitrate、FPS、encoded frames、keyframes、QP、encode time、packet send delay、quality limitation 等指标。https://www.w3.org/TR/webrtc-stats/
- LiveKit connection quality：可作为 SFU 侧质量评分参考，主要考虑 packet loss、video layer delivery 和 bitrate。https://kb.livekit.io/articles/2455399507-how-is-connection-quality-determined
