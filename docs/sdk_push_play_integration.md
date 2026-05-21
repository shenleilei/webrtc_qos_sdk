# WebRTC-first SDK 推拉集成说明

本文档面向业务侧集成 `VideoPushClient`、`VideoPlayClient` 和 `ServerQosRouter`。目标是说明二期当前对外稳定边界，而不是解释 WebRTC 内部实现。

## 1. 集成前提

- 当前 source build 默认开启 WebRTC-first facade。
- 默认 WebRTC module prefix 是仓库内 `dist/linux-x86_64`。
- 如果在新机器集成，先确认 `dist/linux-x86_64/lib/libwebrtc_qos_webrtc_*.a` 和 `dist/linux-x86_64/include/webrtc_qos/*_adapter.h` 已存在。
- 如果没有现成 `dist`，先执行：

```bash
cd /root/webrtc_qos_sdk
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 REQUIRE_ALL=1 NINJA_JOBS=2 \
  scripts/package_webrtc_modules.sh
```

## 2. 角色说明

- `role_push`
  对应发送端 `VideoPushClient`
- `role_play`
  对应接收播放端 `VideoPlayClient`
- `role_server`
  对应最小 relay/QoS router `ServerQosRouter`
- `role_transport`
  只提供业务传输边界 support

业务项目通常直接按角色链接，不自己手动拼 `webrtc_googcc + webrtc_pacing + webrtc_rtp_rtcp + ...`。

## 3. CMake 接入

最小 CMake：

```cmake
cmake_minimum_required(VERSION 3.16)
project(app LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(WebRtcQosSdk REQUIRED CONFIG)

add_executable(push_app push_main.cc)
target_link_libraries(push_app PRIVATE WebRtcQosSdk::role_push)

add_executable(play_app play_main.cc)
target_link_libraries(play_app PRIVATE WebRtcQosSdk::role_play)

add_executable(server_app server_main.cc)
target_link_libraries(server_app PRIVATE WebRtcQosSdk::role_server)
```

配置示例：

```bash
cmake -S app -B app/build \
  -DCMAKE_PREFIX_PATH=/root/webrtc_qos_sdk/dist/linux-x86_64
cmake --build app/build -j"$(nproc)"
```

## 4. Push 端集成

### 4.1 你需要提供什么

- 已编码好的 H264 Annex-B access unit
- 每个 AU 的 `capture_time_us`
- 一个业务发送回调，把 SDK 输出的 RTP/RTCP bytes 发出去
- 一个周期性 worker，持续调用 `Process(now_us)`

### 4.2 最小流程

```cpp
webrtc_qos::SessionConfig session;
session.ids.session_id = 1;
session.ids.stream_id = 1;
session.ids.transport_id = 1;
session.ids.sender_ssrc = 0x12345678;

webrtc_qos::VideoPushClientConfig config;
config.session = session;
config.transport_output =
    [&](const webrtc_qos::TransportPacketView& packet) {
      // 业务侧把 packet.bytes / packet.size 发到 server
      return webrtc_qos::Status::Ok();
    };

auto push = webrtc_qos::CreateVideoPushClient(config);
push->Start();
```

送入一个 AU：

```cpp
webrtc_qos::AnnexBAccessUnitView au;
au.bytes = encoded_h264_annexb_bytes;
au.size = encoded_h264_annexb_size;
au.capture_time_us = now_us;
au.keyframe = is_idr;

push->PushAnnexBAccessUnit(au);
```

周期驱动：

```cpp
push->Process(now_us);
```

接收 server 回来的 RTCP feedback：

```cpp
push->OnTransportFeedback(rtcp_bytes, rtcp_size, receive_time_us);
```

接收 server 生成的 sender cap：

```cpp
push->OnSenderRateCap(cap);
```

业务网络路由变化时：

```cpp
push->OnNetworkRouteChange(start_bps, min_bps, max_bps, now_us);
```

### 4.3 编码器怎么适配

业务编码器不直接猜码率/FPS，按 SDK 建议更新：

```cpp
const auto adaptation = push->GetEncoderAdaptation(now_us);
// adaptation.target_bitrate_bps
// adaptation.max_fps
// adaptation.request_keyframe
```

## 5. Play 端集成

### 5.1 你需要提供什么

- 收到的 RTP bytes
- 收到的 RTCP bytes
- 一个业务发送回调，把 SDK 生成的 RTCP feedback 回传给 server
- 一个 AU 回调，消费 SDK 输出的 Annex-B access unit

### 5.2 最小流程

```cpp
webrtc_qos::VideoPlayClientConfig config;
config.session = session;
config.transport_output =
    [&](const webrtc_qos::TransportPacketView& packet) {
      // 业务侧把 RTCP feedback 回传给 server
      return webrtc_qos::Status::Ok();
    };
config.decoded_access_unit_output =
    [&](const webrtc_qos::AnnexBAccessUnitView& access_unit) {
      // 业务解码器直接消费 Annex-B AU
      return webrtc_qos::Status::Ok();
    };

auto play = webrtc_qos::CreateVideoPlayClient(config);
play->Start();
```

喂 RTP/RTCP：

```cpp
play->OnRtpPacket(rtp_bytes, rtp_size, receive_time_us);
play->OnRtcpPacket(rtcp_bytes, rtcp_size, receive_time_us);
```

### 5.3 当前 play 侧公共指标边界

当前 `GetQosSnapshot()` 主要暴露接收侧传输/恢复统计：

- `nack_count`
- `pli_count`
- `dropped_frames`
- `downlink_quality.rtt_ms`
- `downlink_quality.fraction_lost_q8`

当前不把以下内容作为 `VideoPlayClient` 的原生公共接口承诺：

- PSNR / SSIM / playable ratio
- freeze proxy / renderer proxy
- 完整 QoE 结论

这些指标由上层 decode/QoE harness 计算，例如 `run_webrtc_first_ffmpeg_qoe.sh`。

## 6. Server 端集成

### 6.1 你需要提供什么

- sender -> server 收到的 RTP/RTCP
- receiver -> server 收到的 RTCP
- receiver -> server 的 downlink quality
- 两个输出回调：
  一个发回 sender
  一个发给 receiver

### 6.2 最小流程

```cpp
webrtc_qos::ServerQosRouterConfig config;
config.session = session;
config.sender_output =
    [&](const webrtc_qos::TransportPacketView& packet) {
      // 发给 sender
      return webrtc_qos::Status::Ok();
    };
config.receiver_output =
    [&](const webrtc_qos::TransportPacketView& packet) {
      // 发给 receiver
      return webrtc_qos::Status::Ok();
    };

auto server = webrtc_qos::CreateServerQosRouter(config);
server->Start();
```

喂 sender 上行：

```cpp
server->OnSenderRtp(rtp_bytes, rtp_size, receive_time_us);
server->OnSenderRtcp(rtcp_bytes, rtcp_size, receive_time_us);
```

喂 receiver 下行反馈：

```cpp
server->OnReceiverRtcp(receiver_id, rtcp_bytes, rtcp_size, receive_time_us);
server->OnDownlinkQuality(quality);
```

取当前 sender cap：

```cpp
const auto cap = server->CurrentSenderRateCap(now_us);
```

## 7. 推荐消息回路

### 7.1 Push -> Server

- `VideoPushClient::transport_output`
  发送 RTP/RTCP bytes 到 server

### 7.2 Server -> Play

- `ServerQosRouter::receiver_output`
  转发 RTP/RTCP bytes 到 play

### 7.3 Play -> Server

- `VideoPlayClient::transport_output`
  回传 RTCP NACK/PLI/RR 到 server

### 7.4 Server -> Push

- `ServerQosRouter::sender_output`
  回传 uplink TWCC / RR / 必要 RTCP 到 push
- 业务控制通道额外传 `SenderRateCap`

## 8. SenderRateCap 语义

当前 Phase-2 public API 只定义两种 sender cap 语义：

- 有限上限：`cap_bps` 是一个明确的码率上限
- 不限速：`cap_bps == kUnlimitedRateCapBps`

当前 SDK 不把 `cap_bps == 0` 作为公共“暂停发送”协议语义承诺。业务如果需要暂停/恢复，应通过更高层的业务控制策略实现，而不是假定 `SenderRateCap.cap_bps=0` 会让 push 端停发。

## 9. 业务侧常见坑

- `PushAnnexBAccessUnit()` 之后不能只在“有新帧时”才调 `Process()`。
  push worker 必须周期性调 `Process(now_us)`，否则 pacer 和 GoogCC 不会正常推进。
- `VideoPlayClient` 输出的是完整 Annex-B AU，不是裸 NALU。
- 不要把 QoE harness 里的 PSNR/SSIM/freeze proxy 当成 `VideoPlayClient` 公共接口字段。
- `SenderRateCap` 和 RTCP feedback 不是一回事。
  sender cap 走业务控制消息；TWCC/RR/NACK/PLI 走 RTP/RTCP bytes。
- `WEBRTC_QOS_ENABLE_WEBRTC_FACADE=OFF` 不是 Phase-2 正式交付模式，只用于维护/排查。

## 10. 参考入口

- push/play/server 端到端最小参考：
  [demo/webrtc_first_loopback/main.cc](/root/webrtc_qos_sdk/demo/webrtc_first_loopback/main.cc:1)
- UDP 三角色参考：
  [demo/webrtc_first_udp/main.cc](/root/webrtc_qos_sdk/demo/webrtc_first_udp/main.cc:1)
- 外部工程集成验证：
  [scripts/verify_cmake_package.sh](/root/webrtc_qos_sdk/scripts/verify_cmake_package.sh:1)
