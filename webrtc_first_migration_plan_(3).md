# WebRTC-first 重构实施方案

> 历史草案说明
>
> 本文档保留为 Phase-2 重构过程中的中间方案草案，当前不再作为权威实施文档。
> 当前应以 [webrtc_first_phase2_master_plan.md](webrtc_first_phase2_master_plan.md) 为准；如果两者表述不一致，以 `webrtc_first_phase2_master_plan.md` 为准。

## 1. 背景

当前实现已经跑通了 H264 QoS/jitter 原型、弱网矩阵和发布包验证，但架构上偏离了最初目标。

当前代码更接近：

```text
自研轻量 RTP/RTCP/QoS/jitter SDK + 可选 WebRTC adapter
```

目标应调整回：

```text
WebRTC QoS/RTP/RTCP/NACK/jitter/pacer 主路径 + 自定义传输层
```

本方案的核心约束是：自研的 RTP、RTCP、NACK、pacer、video sender、video receiver、video jitter 不作为 fallback 或 test path 保留。接入 WebRTC 对应模块后，这些自研模块要从 public API、CMake、demo、tests 和发布包中删除。

## 2. 最终原则

- 能用 WebRTC 原生模块的能力，一律使用 WebRTC。
- 业务侧只自定义传输、会话、服务端策略和安全边界。
- SDK 不维护半套 RTP/RTCP/TWCC/NACK/PLI wire format。
- SDK 不维护自研 pacer。
- SDK 不维护自研视频 jitter buffer。
- SDK 不维护自研 NACK requester。
- SDK facade 可以保留，但 facade 内部必须默认调用 WebRTC 模块。
- 缺少 WebRTC 模块时构建失败，不自动降级到自研实现。

## 3. 最终架构边界

SDK 保留的自定义部分：

- `socket/UDP` 或业务传输回调。
- 业务 envelope。
- `session_id / stream_id / receiver_id` 映射。
- SSRC 映射。
- 服务端转发策略。
- 多播放端 rate cap 策略。
- 安全鉴权接口。
- push/play facade。
- QoS/QoE metrics 汇总。
- H264 Annex-B 输入输出 glue。

WebRTC 提供的主能力：

- 拥塞控制：`network_control / goog_cc`。
- pacing：`modules/pacing`。
- RTP/RTCP：`modules/rtp_rtcp`。
- TWCC：WebRTC RTCP transport feedback。
- SR/RR：WebRTC RTCP sender/receiver report。
- NACK/PLI：WebRTC RTCP feedback 包。
- NACK requester：WebRTC `modules/video_coding:nack_requester`。
- H264 packetize/depacketize：WebRTC RTP H264 packetizer/depacketizer。
- 视频 jitter：WebRTC `PacketBuffer`、`RtpVideoFrameAssembler` 或对应视频接收缓冲路径。

## 4. 需要删除的自研模块

最终需要从公开 API 删除：

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

最终需要从源码删除：

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

最终需要从 CMake 删除的库目标：

```text
webrtc_qos_rtp
webrtc_qos_rtcp
webrtc_qos_nack
webrtc_qos_pacer
webrtc_qos_video
```

`webrtc_qos_feedback` 需要拆分：只保留 facade、rate cap、metrics 等业务抽象，不再包含自研 estimator 或自研 feedback wire format。

## 5. 新的公开 API

公开 API 应收敛为角色 facade，而不是暴露底层 RTP/RTCP 实现。

建议新增：

```text
include/webrtc_qos/session_config.h
include/webrtc_qos/transport_io.h
include/webrtc_qos/video_push_client.h
include/webrtc_qos/video_play_client.h
include/webrtc_qos/server_qos_router.h
include/webrtc_qos/qos_metrics.h
include/webrtc_qos/rate_cap.h
include/webrtc_qos/control_messages.h
include/webrtc_qos/status.h
```

push 端业务只需要：

- 输入 H264 Annex-B access unit。
- 输入 capture timestamp。
- 输入服务端 rate cap。
- 输入 route change。
- 接收 SDK 输出的 RTP/RTCP bytes，通过业务传输发送。
- 读取 encoder bitrate/FPS/keyframe request 建议。

play 端业务只需要：

- 输入收到的 RTP/RTCP bytes。
- 接收 SDK 输出的完整 Annex-B access unit。
- 接收 SDK 输出的 RTCP feedback bytes，通过业务传输回传。
- 读取 jitter、loss、NACK、PLI、freeze proxy 等 metrics。

公开 facade 必须坚持 bytes 边界：

- push 输出标准 RTP/RTCP bytes。
- play 输入标准 RTP/RTCP bytes。
- play 输出标准 RTCP feedback bytes。
- 业务传输只搬运 bytes 和业务 envelope，不接触 WebRTC 内部对象。
- WebRTC 内部对象、task queue、clock、sequence checker 生命周期全部由 SDK facade 封装。

服务端或直连测试只需要：

- 转发 RTP/RTCP bytes。
- 维护 session/stream/receiver 映射。
- 可选生成或转发 rate cap。
- 路由 NACK/PLI。
- 生成 `uplink_twcc`。
- 处理或转发 SR/RR、NACK、PLI。
- 承担本地重传所需的 packet history。
- 不维护自研 RTCP wire format；所有 RTCP 解析/生成统一走 WebRTC RTCP adapter。

server facade 建议命名为 `server_qos_router.h`。它负责封装：

- sender/receiver/session/stream 映射。
- `uplink_twcc` 生成。
- NACK/PLI 路由。
- SR/RR 处理和转发。
- packet history 管理。
- 多播放端 downlink quality 汇总。
- `SENDER_RATE_CAP_V1` 生成和防抖。

删除 `transport_feedback.h` 后，业务控制消息归属如下：

- `rate_cap.h`：`SENDER_RATE_CAP_V1`、cap 过期语义、暂停/不限速语义。
- `qos_metrics.h`：downlink quality、loss、jitter、RTT、freeze proxy、decode/QoE 指标。
- `control_messages.h`：业务 envelope 内的控制消息类型、版本号、序列号和编解码。

## 6. WebRTC 模块库产物

不直接发布一个完整 `libwebrtc.a`。仍然按能力拆库，但每个库内部使用 WebRTC 原生实现。

建议发布：

```text
libwebrtc_qos_webrtc_googcc.a
libwebrtc_qos_webrtc_pacing.a
libwebrtc_qos_webrtc_rtp_rtcp.a
libwebrtc_qos_webrtc_video_jitter.a
libwebrtc_qos_webrtc_nack.a
libwebrtc_qos_push.a
libwebrtc_qos_play.a
libwebrtc_qos_transport.a
```

CMake imported targets：

```text
WebRtcQosSdk::webrtc_googcc
WebRtcQosSdk::webrtc_pacing
WebRtcQosSdk::webrtc_rtp_rtcp
WebRtcQosSdk::webrtc_video_jitter
WebRtcQosSdk::webrtc_nack
WebRtcQosSdk::role_push
WebRtcQosSdk::role_play
WebRtcQosSdk::role_transport
```

`role_push` 默认链接：

```text
WebRtcQosSdk::webrtc_googcc
WebRtcQosSdk::webrtc_pacing
WebRtcQosSdk::webrtc_rtp_rtcp
WebRtcQosSdk::webrtc_nack
WebRtcQosSdk::role_transport
```

`role_play` 默认链接：

```text
WebRtcQosSdk::webrtc_rtp_rtcp
WebRtcQosSdk::webrtc_video_jitter
WebRtcQosSdk::webrtc_nack
WebRtcQosSdk::role_transport
```

## 7. 构建策略

WebRTC 仍作为外部源码树构建。SDK 不把完整 WebRTC 源码复制进仓库。

但是可复现构建必须进入仓库管理，不能依赖 `/root/src` 里的不可见本地改动。以下内容必须纳入本仓库或以 patch 形式纳入本仓库：

- `sdk_qos` GN packaging target。
- SDK wrapper 源码。
- adapter public headers。
- 对 WebRTC `BUILD.gn` 的最小 patch。
- 依赖裁剪 patch。
- WebRTC commit 和 GN args 记录。

构建流程：

```text
WebRTC 源码树
  -> GN/Ninja 编译 WebRTC 原生模块
  -> 生成完整静态库 .a
  -> 安装到 output/lib
  -> SDK CMake imported targets 链接这些 .a
```

新增脚本建议：

```text
scripts/package_webrtc_modules.sh
scripts/verify_webrtc_modules.sh
scripts/verify_no_selfmade_media_stack.sh
```

`package_webrtc_modules.sh` 职责：

- 检查 `WEBRTC_SRC`。
- 检查 WebRTC commit。
- 从仓库内 patch 或 packaging 目录写入 WebRTC packaging `BUILD.gn`。
- 检查 WebRTC 源码树是否已经应用所需 patch，未应用时直接失败或按显式参数应用。
- 使用 GN args 禁用无关模块。
- `ninja` 构建完整静态库。
- 拷贝 `.a` 和必要公开 wrapper 头到 `output/`。

`verify_no_selfmade_media_stack.sh` 职责：

- 检查被删除的自研头文件不再存在。
- 检查源码不再引用自研 RTP/RTCP/NACK/pacer/jitter。
- 检查 CMake 不再导出旧目标。
- 检查 dist 不再包含旧静态库。

## 8. 迁移顺序

不能先直接删除文件，否则仓库会长时间不可编译。迁移顺序必须是“接一个 WebRTC 模块，删一个自研模块”。

### Step 1：固定 WebRTC 版本和构建产物

- 记录 `/root/src` 当前 WebRTC commit。
- 固定 GN args。
- 固定 Linux x86_64 ABI 说明。
- 生成 WebRTC module archive。
- 在 CMake 中加入 imported targets。

验收：

```bash
scripts/package_webrtc_modules.sh
scripts/verify_webrtc_modules.sh
```

### Step 2：替换 GoogCC

当前已有 GoogCC adapter，但要改成默认且必选。

动作：

- 删除 `SenderQosController` 内部 fallback estimator。
- `SenderQosController` 或新 `VideoPushClient` 默认持有 WebRTC GoogCC。
- 缺少 `libwebrtc_qos_webrtc_googcc.a` 时 CMake 失败。
- demo 不允许构造无 backend 的 QoS controller。

删除：

- 自研 loss/recv-rate estimator 逻辑。

验收：

- 动态 QoS matrix 仍能下探和恢复。
- `rg` 不再出现 fallback estimator 相关逻辑。

### Step 3：替换 pacer

动作：

- 接入 WebRTC `modules/pacing`。
- push facade 内部持有 WebRTC pacer。
- 业务只提供 `SendPacket(bytes)` 回调。
- 先产出 `webrtc_pacing_adapter`，通过专门门禁后再删除 SDK `SenderPacer`。

pacer 删除门禁：

- `webrtc_pacing_adapter` 能独立通过 smoke。
- 弱网矩阵能通过。
- probe cluster 发送节奏正确。
- NACK/RTX 重传优先级正确。
- IDR burst 受 WebRTC pacer 控制。
- pacer queue 不在弱网下无限增长。
- 外部 CMake consumer 能只通过 facade 使用 pacer，不接触 WebRTC 内部对象。

删除：

```text
include/webrtc_qos/sender_pacer.h
src/sender_pacer.cc
webrtc_qos_pacer
```

验收：

- NACK/RTX 优先级仍正确。
- IDR burst 受 WebRTC pacer 控制。
- 弱网下队列不无限增长。

### Step 4：替换 WebRTC RTP/RTCP + H264 packetization/depacketization

这一阶段和旧 Step 6 强耦合，不能割裂实施。WebRTC H264 packetizer/depacketizer 依赖 RTP 层，video jitter 又依赖 depacketized video packet metadata。因此 RTP/RTCP 与 H264 packetization/depacketization 应作为一个大步骤推进；如果拆成子任务，也必须并行开发、同一阶段验收。

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

### Step 5：替换 NACK

动作：

- 接入 WebRTC `NackRequester`。
- SDK 只负责路由 NACK/PLI。
- 接收端丢包判断、重试窗口、keyframe 请求策略由 WebRTC recovery 模块处理。
- 删除旧 `RetransmissionCache`，但不能删除重传历史能力。
- sender 或 server 本地响应 NACK 时仍必须有 packet history。
- 优先使用 WebRTC sender/packet history。
- 如果 server relay 不接入 WebRTC sender 模块，则新增 `transport_packet_history`。
- `transport_packet_history` 只能保存 opaque RTP bytes，用于按 RTP sequence number 查找原始包。
- `transport_packet_history` 不实现 NACK 逻辑，不解析 RTCP wire format，不做自研恢复策略。
- `transport_packet_history` 的 key 固定为 `hop_id / ssrc / rtp_sequence_number`。
- `transport_packet_history` 每条记录必须保存发送时间、payload bytes、是否重传。
- 如果服务端做 SSRC 重映射，必须在写入 history 前明确使用映射后的 hop-local SSRC。

删除：

```text
include/webrtc_qos/receiver_qos_observer.h
include/webrtc_qos/retransmission_cache.h
src/receiver_qos_observer.cc
src/retransmission_cache.cc
webrtc_qos_nack
```

允许新增：

```text
include/webrtc_qos/transport_packet_history.h
src/transport_packet_history.cc
```

前提是它只属于 transport/server support，不属于自研 NACK/recovery 模块。

验收：

- NACK 针对 RTP sequence number。
- 重传仍保持原 RTP sequence number。
- 重传包重新进入 WebRTC RTP/RTCP/TWCC 统计路径。

### Step 6：替换 video jitter

动作：

- 组帧使用 WebRTC `RtpVideoFrameAssembler` 或 `PacketBuffer / FrameBuffer`。
- 接收端输出完整 Annex-B AU 的职责由 SDK wrapper 做格式归一化，但不做 jitter/reorder 算法。

删除：

```text
include/webrtc_qos/video_jitter_player.h
src/video_jitter_player.cc
```

验收：

- 复杂乱序、丢包恢复不依赖自研逻辑。
- SDK wrapper 输出完整 Annex-B AU，IDR 前可补 SPS/PPS。

### Step 7：迁移 demo 和测试

动作：

- `udp_long_sender_demo` 改用 `VideoPushClient`。
- `udp_long_receiver_demo` 改用 `VideoPlayClient`。
- QoE matrix 不再 include 自研底层头。
- `verify_cmake_package.sh` 改为验证新 facade。
- 删除旧 loopback 里对自研 RTP/RTCP 的直接测试。

验收：

```bash
cmake -S webrtc_qos_sdk -B webrtc_qos_sdk/build -DCMAKE_BUILD_TYPE=Release
cmake --build webrtc_qos_sdk/build -j"$(nproc)"
cmake --install webrtc_qos_sdk/build --prefix /root/output
PREFIX=/root/output bash webrtc_qos_sdk/scripts/verify_cmake_package.sh
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

除本文档或迁移历史说明外，不应再出现引用。

## 9. 最终验收门禁

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
```

弱网门禁：

```bash
bash webrtc_qos_sdk/scripts/run_udp_direct_long_stream_matrix.sh
bash webrtc_qos_sdk/scripts/run_udp_long_stream_matrix.sh
bash webrtc_qos_sdk/scripts/run_udp_long_stream_720p_stability.sh
bash webrtc_qos_sdk/scripts/run_long_stream_qoe_720p_stability.sh
```

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

## 10. 风险和注意事项

这不是小修，而是破坏性重构。

主要风险：

- WebRTC RTP/RTCP/pacer/NACK/video jitter 模块会带入 task queue、clock、sequence checker、field trial、environment 等生命周期要求。
- WebRTC 原生模块可能依赖更多基础库，静态库闭包会比当前自研版本大。
- public API 会破坏兼容，需要接受旧 demo 和旧头文件删除。
- 弱网测试阈值可能需要重新校准，因为 WebRTC pacer 和 WebRTC jitter 的行为不会和当前自研实现完全一致。
- 发布包 ABI 要重新验证，尤其是外部机器只拿 `include + lib` 时的链接顺序和系统库依赖。

处理原则：

- 不为了兼容旧实现保留 fallback。
- 不为了短期测试通过继续维护半套 RTCP/TWCC。
- 如果某个 WebRTC 模块依赖过重，应该继续裁剪 WebRTC GN 闭包，而不是回退到自研实现。
- 每删除一个自研模块，都必须有对应 WebRTC 模块的弱网和外部消费验证。

## 11. 当前结论

当前原型证明了需求方向和测试体系，但不是最终正确架构。下一版应进入 WebRTC-first 重构：

```text
接入 WebRTC 原生模块 -> 迁移 facade -> 删除对应自研模块 -> 跑弱网/QoE 门禁
```

最终交付标准不是“WebRTC adapter 可选存在”，而是：

```text
SDK 默认主路径就是 WebRTC；
自研 RTP/RTCP/NACK/pacer/jitter 已从代码和发布包中删除；
业务只负责传输和服务端策略。
```
