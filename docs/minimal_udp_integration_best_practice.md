# 最小 UDP 集成最佳实践

本文档说明当前 SDK 的最小实现集成方式：业务外围只实现 UDP
传输、H264 编解码、渲染/采集和少量控制消息，媒体 plane 和 QoS
能力通过 SDK 的 WebRTC-first facade 使用。

当前 SDK 不是完整 WebRTC Client、`PeerConnection` 或 SFU，也不把
`RTCPeerConnection::AddTrack()` 作为稳定公共接口暴露。对业务来说，
“添加 track”的稳定入口是：

- 在 `SessionConfig.video_tracks` 里声明每条 video track。
- 发送每个 H264 Annex-B AU 时，把对应 track 的 `TransportIds` 填到
  `AnnexBAccessUnitView::ids`。
- 接收 AU 时，按 `AnnexBAccessUnitView::ids.track_id` 或
  `sender_ssrc` 分发到对应解码/渲染链路。

底层 RTP packetization、RTP/RTCP wire format、TWCC、NACK、PLI、
GoogCC、pacing 和 video jitter 都由 SDK 的 WebRTC-backed facade
承担。

## 1. 最小职责边界

推荐的最小拓扑：

```text
capture/encoder
  -> VideoPushClient
  -> UDP socket
  -> ServerQosRouter
  -> UDP socket
  -> VideoPlayClient
  -> decoder/render
```

业务侧需要实现：

- UDP socket 的 bind、send、recv、地址路由和线程模型。
- 一个很薄的 UDP packet envelope，用于区分 RTP、RTCP、下行质量报告和
  sender rate cap。
- H264 Annex-B encoder 输入和 decoder/render 输出。
- 周期性 worker，持续驱动 `VideoPushClient::Process(now_us)` 和
  `VideoPlayClient::Process(now_us)`。
- 可选的业务安全层、鉴权、会话协商、NAT 穿透、QUIC/DTLS/VPN 等。

SDK 负责：

- 把 H264 Annex-B AU 切成 RTP bytes。
- 从 RTP bytes 重组 Annex-B AU。
- 生成和消费标准 RTCP：TWCC、SR、RR、NACK、PLI。
- 发送端 GoogCC、pacer、probe、padding 和 sender packet history。
- server 侧最小 QoS router、packet history、本地重传和 feedback 路由。
- play 侧 NACK requester、PLI、video jitter 和 per-track 输出身份。
- 按 `RuntimeLogConfig` 输出结构化角色日志到文件，方便按
  session/source/track/receiver 排查问题。
- 按 `RuntimeMetricsConfig` 定期输出 metrics snapshot，到文件后可被 CI、
  监控或 debug bundle 收集。
- 按 `RuntimeAlertConfig` 输出结构化 alerts，用于弱网、media failure、
  transport failure 和 malformed packet 的最小生产告警闭环。

业务侧不应该重复实现：

- 自己生成 RTP header、RTCP NACK、RTCP TWCC、RTCP PLI。
- 自己写 pacer、GoogCC、NACK requester 或 jitter buffer。
- 为每条 track 单独创建一个 `VideoPushClient` 来绕开
  `SessionConfig.video_tracks`。
- 直接 include WebRTC 内部头文件或依赖 `PeerConnection` 行为。

外部工程推荐只链接角色 target，不手动拼 WebRTC 子模块：

```cmake
find_package(WebRtcQosSdk REQUIRED CONFIG)

add_executable(sender sender_main.cc)
target_link_libraries(sender PRIVATE WebRtcQosSdk::role_push)

add_executable(server server_main.cc)
target_link_libraries(server PRIVATE WebRtcQosSdk::role_server)

add_executable(receiver receiver_main.cc)
target_link_libraries(receiver PRIVATE WebRtcQosSdk::role_play)
```

如果集成环境更适合单个 archive，可使用对应 bundle target：
`WebRtcQosSdk::role_push_bundle`、`WebRtcQosSdk::role_server_bundle`、
`WebRtcQosSdk::role_play_bundle`。

## 2. UDP envelope

`TransportOutput` 输出的是 SDK 已经生成好的 packet bytes：

```cpp
using TransportOutput =
    std::function<Status(const TransportPacketView& packet)>;
```

UDP 层只需要把 `packet.bytes / packet.size` 原样发出去，并携带足够的
业务 envelope 元数据，让接收端知道该把 payload 喂给哪个 SDK 入口。

推荐最小 envelope：

```cpp
enum class WireKind : uint8_t {
  kRtp = 1,
  kRtcp = 2,
  kDownlinkQuality = 3,
  kSenderRateCap = 4,
};

struct WirePacket {
  WireKind kind = WireKind::kRtp;
  uint8_t flags = 0;
  int64_t time_us = 0;
  std::vector<uint8_t> payload;
};
```

关键约束：

- RTP/RTCP payload 必须 byte-for-byte 保持不变。
- 每个 SDK 输出 packet 建议对应一个 UDP datagram。
- 如果底层换成 TCP/QUIC stream，必须额外做 length framing，不能丢失 packet
  边界。
- envelope 必须保留 `RTP` 和 `RTCP` 类型，否则 server/play/push 侧无法可靠
  dispatch 到 `On*Rtp()` 或 `On*Rtcp()`。
- `TransportPacketMetadata::retransmission` 和 `padding` 对业务转发不是必需，
  但建议带进 envelope flags，方便日志、弱网模拟和排查。
- 当前默认 H264 RTP payload 上限是 `1200` bytes，加上 envelope 后仍应避免
  IP fragmentation。

仓库内 UDP demo 的 envelope 实现在
[`demo/webrtc_first_udp/main.cc`](../demo/webrtc_first_udp/main.cc)，它只是
示例 wire format，不是必须照抄的公共协议。

安装包外部工程参考在
[`examples/minimal_udp_app`](../examples/minimal_udp_app/README.md)。该样板只用
`find_package(WebRtcQosSdk)` 和 public headers，代码结构更接近业务仓库：
`common/wire_packet.h` 放 UDP envelope，`common/udp_socket.h` 放 socket glue，
`codec/synthetic_h264_source.h` 代表业务 encoder 输出 Annex-B AU，
`sender/server/receiver` 分别链接 `role_push / role_server / role_play` 或 bundle。

## 3. Session 和 Track

所有角色必须使用同一份 `SessionConfig` 语义：sender、server、receiver
看到的 `session_id / stream_id / transport_id / receiver_id / source_id /
track_id / sender_ssrc` 必须一致。

最小双 track 配置示例：

```cpp
webrtc_qos::SessionConfig MakeSession(const char* debug_name) {
  webrtc_qos::SessionConfig session;
  session.ids.session_id = 1;
  session.ids.stream_id = 1;
  session.ids.transport_id = 1;
  session.ids.receiver_id = 0x2222;
  session.ids.source_id = session.ids.stream_id;
  session.start_bitrate_bps = 1200000;
  session.min_bitrate_bps = 300000;
  session.max_bitrate_bps = 2500000;
  session.debug_name = debug_name;

  auto add_track = [&](uint32_t track_id,
                       uint32_t sender_ssrc,
                       bool base_track,
                       uint32_t weight) {
    webrtc_qos::VideoTrackConfig track;
    track.ids = session.ids;
    track.ids.track_id = track_id;
    track.ids.sender_ssrc = sender_ssrc;
    track.h264 = session.h264;
    track.base_track = base_track;
    track.weight = weight;
    session.video_tracks.push_back(track);
  };

  add_track(101, 0x12345678u, true, 70);
  add_track(202, 0x13355779u, false, 30);

  // 兼容部分旧字段语义：session.ids.sender_ssrc 放第一条/base track。
  session.ids.sender_ssrc = session.video_tracks.front().ids.sender_ssrc;
  return session;
}
```

规则：

- `SessionConfig.video_tracks` 是 track 数量的唯一来源。
- 填 1 条就是 1 条 track；填 2 条就是 2 条 track；填 N 条就是 N 条 track。
- 每条 track 必须有稳定的 `track_id` 和唯一的 `sender_ssrc`。
- 同一个 source 下的多条 track 放进同一个 `VideoPushClient`，共享
  GoogCC/pacer/source cap。
- `weight` 用于 shared source cap 下的 track 分配倾向，base track 通常权重
  更高。
- 不要新增业务侧 `track_count` 开关，也不要让 sender/server/receiver 各自推导
  不同 track 列表。

## 4. Sender 最小实现

sender 侧创建一个 `VideoPushClient`，把 SDK 输出通过 UDP 发给 server。

```cpp
webrtc_qos::SessionConfig session = MakeSession("sender");

webrtc_qos::VideoPushClientConfig config;
config.session = session;
config.logging.file.enabled = true;
config.logging.file.directory = "/var/log/webrtc_qos";
config.logging.file.basename = "sender";
config.metrics.file.enabled = true;
config.metrics.file.directory = "/var/log/webrtc_qos/metrics";
config.alerts.file.enabled = true;
config.alerts.file.directory = "/var/log/webrtc_qos/alerts";
config.transport_output =
    [&](const webrtc_qos::TransportPacketView& packet) {
      WirePacket wire;
      wire.kind = packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtp
                      ? WireKind::kRtp
                      : WireKind::kRtcp;
      wire.time_us = packet.metadata.send_time_us;
      wire.payload.assign(packet.bytes, packet.bytes + packet.size);
      return SendUdp(server_addr, wire);
    };

auto push = webrtc_qos::CreateVideoPushClient(config);
push->Start();
```

生产集成建议至少启用以下运行时输出：

- `RuntimeLogConfig`：写 JSONL 角色日志，记录 start/stop、packetize failure、
  transport output failure、NACK/重传、decode output 等事件。
- `RuntimeMetricsConfig`：写 push/server/play 的 session/track metrics snapshot，
  用于观察 bitrate/FPS 下探、恢复、loss、NACK、retransmission 和 drop。
- `RuntimeAlertConfig`：写 alerts JSONL，默认覆盖 low target bitrate、low encoder
  FPS、high downlink loss、video drop、NACK/retransmission recovery、malformed
  RTP/RTCP/H264、transport output failure 和 decode output failure。

sender worker 的核心循环：

```cpp
while (running) {
  const int64_t now_us = MonotonicNowUs();

  // 1. 先处理 server 回来的 RTCP 和 sender cap。
  for (const WirePacket& wire : RecvUdp()) {
    if (wire.kind == WireKind::kRtcp) {
      push->OnTransportFeedback(wire.payload.data(),
                                wire.payload.size(),
                                now_us);
    } else if (wire.kind == WireKind::kSenderRateCap) {
      webrtc_qos::SenderRateCap cap = DecodeSenderRateCap(wire.payload);
      push->OnSenderRateCap(cap);
    }
  }

  // 2. 即使没有新帧，也必须持续推进 GoogCC/pacer/RTCP。
  push->Process(now_us);

  // 3. 按每条 track 的适配建议驱动编码器。
  for (const auto& track : session.video_tracks) {
    webrtc_qos::EncoderAdaptation adaptation;
    if (!push->GetTrackEncoderAdaptation(track.ids.track_id,
                                         now_us,
                                         &adaptation)) {
      continue;
    }

    ConfigureEncoder(track.ids.track_id,
                     adaptation.target_bitrate_bps,
                     adaptation.max_fps,
                     adaptation.request_keyframe);

    EncodedAu encoded = TryEncodeAnnexB(track.ids.track_id, now_us);
    if (!encoded.available) {
      continue;
    }

    webrtc_qos::AnnexBAccessUnitView au;
    au.bytes = encoded.bytes.data();
    au.size = encoded.bytes.size();
    au.capture_time_us = encoded.capture_time_us;
    au.keyframe = encoded.keyframe;
    au.ids = track.ids;
    push->PushAnnexBAccessUnit(au);

    // 低延迟场景建议 AU 入队后再推进一次 pacer。
    push->Process(MonotonicNowUs());
  }
}
```

sender 侧注意事项：

- `PushAnnexBAccessUnit()` 的输入必须是完整 Annex-B AU，不是单个裸 NALU。
- 多 track 时必须给每个 AU 填正确的 `au.ids = track.ids`。
- `capture_time_us` 应来自媒体采集/编码时间，不要用解码顺序或随机递增值替代。
- `GetTrackEncoderAdaptation()` 是多 track 下的优先入口；单 track 可使用
  `GetEncoderAdaptation()`。
- 收到 `PLI` 后，`request_keyframe` 会通过 adaptation 暴露给业务编码器。
- `SenderRateCap` 走业务控制 envelope，不是 RTCP packet。

## 5. Server 最小实现

server 侧创建一个 `ServerQosRouter`，负责 sender 和 receiver 之间的 RTP/RTCP
bytes 路由，以及下行质量到 sender cap 的收敛。

```cpp
webrtc_qos::SessionConfig session = MakeSession("server");

webrtc_qos::ServerQosRouterConfig config;
config.session = session;
config.logging.file.enabled = true;
config.logging.file.directory = "/var/log/webrtc_qos";
config.logging.file.basename = "server";
config.sender_output =
    [&](const webrtc_qos::TransportPacketView& packet) {
      return SendUdp(sender_addr, EncodeTransportPacket(packet));
    };
config.receiver_output =
    [&](const webrtc_qos::TransportPacketView& packet) {
      return SendUdp(receiver_addr, EncodeTransportPacket(packet));
    };

auto server = webrtc_qos::CreateServerQosRouter(config);
server->Start();
```

server UDP dispatch：

```cpp
while (running) {
  const int64_t now_us = MonotonicNowUs();

  for (const ReceivedDatagram& datagram : RecvUdp()) {
    WirePacket wire = DecodeWirePacket(datagram.bytes);

    if (datagram.from == sender_addr) {
      if (wire.kind == WireKind::kRtp) {
        server->OnSenderRtp(wire.payload.data(),
                            wire.payload.size(),
                            now_us);
      } else if (wire.kind == WireKind::kRtcp) {
        server->OnSenderRtcp(wire.payload.data(),
                             wire.payload.size(),
                             now_us);
      }
      continue;
    }

    if (datagram.from == receiver_addr) {
      if (wire.kind == WireKind::kRtcp) {
        server->OnReceiverRtcp(session.ids.receiver_id,
                               wire.payload.data(),
                               wire.payload.size(),
                               now_us);
      } else if (wire.kind == WireKind::kDownlinkQuality) {
        webrtc_qos::DownlinkQuality quality =
            DecodeDownlinkQuality(wire.payload);
        server->OnDownlinkQuality(quality);

        const auto cap = server->CurrentSenderRateCap(now_us);
        SendUdp(sender_addr, EncodeSenderRateCap(cap));
      }
    }
  }
}
```

server 侧注意事项：

- sender RTP 必须喂 `OnSenderRtp()`，sender RTCP 必须喂 `OnSenderRtcp()`。
- receiver RTCP 必须喂 `OnReceiverRtcp(receiver_id, ...)`，`receiver_id` 是业务
  下游身份，不是 RTCP SSRC。
- `receiver_output` 是单包输出回调。当前 SDK 不维护 receiver registry，也不自动
  做多 receiver 全量 fanout。
- 如果要做多 receiver，业务 server 需要维护 receiver 列表，把 sender RTP/RTCP
  fanout 到多个下游；SDK 负责每个 receiver 的反馈语义和最小修复路由。
- server 不解码媒体，不改写 H264 payload，不生成业务层 GOP 策略。

## 6. Receiver 最小实现

receiver 侧创建一个 `VideoPlayClient`，把 server 发来的 RTP/RTCP 喂给 SDK，
并消费 SDK 输出的 Annex-B AU。

```cpp
webrtc_qos::SessionConfig session = MakeSession("receiver");

webrtc_qos::VideoPlayClientConfig config;
config.session = session;
config.logging.file.enabled = true;
config.logging.file.directory = "/var/log/webrtc_qos";
config.logging.file.basename = "receiver";
config.transport_output =
    [&](const webrtc_qos::TransportPacketView& packet) {
      return SendUdp(server_addr, EncodeTransportPacket(packet));
    };
config.decoded_access_unit_output =
    [&](const webrtc_qos::AnnexBAccessUnitView& au) {
      DecodeAndRender(au.ids.track_id,
                      au.bytes,
                      au.size,
                      au.capture_time_us);
      return webrtc_qos::Status::Ok();
    };

auto play = webrtc_qos::CreateVideoPlayClient(config);
play->Start();
```

receiver worker 的核心循环：

```cpp
while (running) {
  const int64_t now_us = MonotonicNowUs();

  for (const WirePacket& wire : RecvUdp()) {
    if (wire.kind == WireKind::kRtp) {
      play->OnRtpPacket(wire.payload.data(), wire.payload.size(), now_us);
    } else if (wire.kind == WireKind::kRtcp) {
      play->OnRtcpPacket(wire.payload.data(), wire.payload.size(), now_us);
    }
  }

  // 即使暂时没有新 RTP，也要推进 NACK/PLI 重试计时。
  play->Process(now_us);

  webrtc_qos::DownlinkQuality quality;
  quality.ids = session.ids;
  quality.report_seq = NextReportSeq();
  quality.report_time_us = static_cast<uint64_t>(now_us);
  quality.fraction_lost_q8 = EstimateLossQ8();
  quality.recv_bitrate_bps = EstimateRecvBitrateBps();
  quality.video_drop_frames = ReadRendererDropFrames();
  SendUdp(server_addr, EncodeDownlinkQuality(quality));
}
```

receiver 侧注意事项：

- `decoded_access_unit_output` 输出的是完整 Annex-B AU。
- 多 track 时，解码器和 renderer 应按 `au.ids.track_id` 或 `sender_ssrc` 分路。
- `VideoPlayClient::GetTrackQosSnapshot(track_id, now_us, &snapshot)` 可用于查看
  per-track NACK、PLI、loss、RTT 等传输/恢复指标。
- PSNR、SSIM、playable ratio、freeze proxy、renderer proxy 不是
  `VideoPlayClient` 的公共 API，正式 QoE 应由业务 decode/render 或 QoE harness
  计算。

## 7. 日志和排障

生产集成不要把 SDK 运行事件依赖在 stdout/stderr 上。sender、server、receiver
三个角色都建议显式配置 `RuntimeLogConfig`，把结构化 JSON Lines 写入日志目录：

```cpp
webrtc_qos::RuntimeLogConfig logging;
logging.min_level = webrtc_qos::LogLevel::kInfo;
logging.file.enabled = true;
logging.file.directory = "/var/log/webrtc_qos";
logging.file.basename = "webrtc_qos";
logging.file.max_file_bytes = 64 * 1024 * 1024;
logging.file.max_files = 5;
logging.file.json_lines = true;
logging.max_queue_records = 4096;

push_config.logging = logging;
server_config.logging = logging;
play_config.logging = logging;
```

默认不配置日志时 SDK 不会输出运行日志。demo 可用 `--log-dir` 快速验证：

```bash
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 36 --log-dir /tmp/webrtc_qos_udp_logs

./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 90 --log-dir /tmp/webrtc_qos_udp_logs \
  --log-max-file-bytes 512 --log-max-files 3

./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 180 --log-dir /tmp/webrtc_qos_udp_logs \
  --log-max-queue-records 1
```

日志文件命名形如 `webrtc_qos_udp.push.<pid>...log`、
`webrtc_qos_udp.server.<pid>...log`、`webrtc_qos_udp.play.<pid>...log`。
当 `max_file_bytes` 超过阈值时同一 role 会按 index 轮转，`max_files` 控制单个
logger 实例保留的文件数；`verify_phase5_logging.sh` 会用低阈值把轮转作为硬门禁。
日志写文件走内部异步队列，`max_queue_records` 控制每个 logger 实例的待写记录上限；
队列满时优先丢 info/debug/trace 级记录，warn/error 和 `Stop()` 的 stop 事件必须保留，
并在后续保留日志中写 `dropped_log_count`。`verify_phase5_logging.sh` 会用极小队列
把这个退化路径作为硬门禁。
正常 `Stop()` 会写入 `stop` 事件并 flush 文件，`verify_phase5_logging.sh`
会把 push/server/play 三个 role 的 stop 事件落盘作为回归门禁。
每条日志包含 `role`、`event`、`session_id`、`stream_id`、`transport_id`、
`source_id`、`track_id`、`sender_ssrc`、`receiver_id`，warn/error 还会带
`status_code` 和 `reason`。不要记录 H264 payload、RTP payload、鉴权 token
或用户隐私字段。

同一套 facade 也支持 metrics snapshot 文件化。生产集成建议显式配置
`RuntimeMetricsConfig`，把 session/track 级 QoS 快照按固定 interval 写入
JSON Lines：

```cpp
webrtc_qos::RuntimeMetricsConfig metrics;
metrics.file.enabled = true;
metrics.file.directory = "/var/log/webrtc_qos";
metrics.file.basename = "webrtc_qos_metrics";
metrics.file.max_file_bytes = 64 * 1024 * 1024;
metrics.file.max_files = 5;
metrics.interval_ms = 1000;
metrics.include_track_snapshots = true;

push_config.metrics = metrics;
server_config.metrics = metrics;
play_config.metrics = metrics;
```

demo 可用 `--metrics-dir` 验证 metrics 文件：

```bash
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 36 --metrics-dir /tmp/webrtc_qos_udp_metrics

./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 90 --metrics-dir /tmp/webrtc_qos_udp_metrics \
  --metrics-max-file-bytes 1024 --metrics-max-files 3
```

metrics 文件包含 `final_target_bps`、`adaptation_target_bps`、
`adaptation_max_fps`、`downlink_fraction_lost_q8`、`nack_count`、
`pli_count`、`retransmission_count` 等字段，用于区分网络/QoS 恢复问题和
上层 codec/render 问题。`verify_phase5_metrics.sh` 会用低阈值把 metrics 轮转
和保留文件数上限作为硬门禁。

生产集成还应启用 alerts，并把 logs、metrics、alerts 一起纳入排障包：

```cpp
webrtc_qos::RuntimeAlertConfig alerts;
alerts.file.enabled = true;
alerts.file.directory = "/var/log/webrtc_qos";
alerts.file.basename = "webrtc_qos_alerts";
alerts.file.max_file_bytes = 64 * 1024 * 1024;
alerts.file.max_files = 5;
alerts.high_loss_fraction_q8 = 128;
alerts.low_target_bps = 700000;
alerts.low_encoder_fps = 20;

push_config.alerts = alerts;
server_config.alerts = alerts;
play_config.alerts = alerts;
```

demo 可用 `--alerts-dir` 验证 alerts 文件：

```bash
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 36 --alerts-dir /tmp/webrtc_qos_udp_alerts

./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 90 --alerts-dir /tmp/webrtc_qos_udp_alerts \
  --alerts-max-file-bytes 256 --alerts-max-files 3
```

`verify_phase5_alerts.sh` 会用低阈值把 alerts 轮转和保留文件数上限作为硬门禁。

仓库内排障包 collector 会跑一次最小 UDP selftest 并同时打开日志、metrics 和
alerts，然后生成可离线校验的 bundle：

```bash
OUTPUT_DIR=/tmp/webrtc_qos_phase5_debug_bundle \
  scripts/collect_phase5_debug_bundle.sh
BUNDLE_DIR=/tmp/webrtc_qos_phase5_debug_bundle \
  scripts/verify_phase5_debug_bundle.sh
```

bundle 固定包含 `metadata.txt`、`build_config.txt`、`git_status.txt`、
`session_config.json`、`runtime_config.json`、`log/{push,server,play}.log`、
`metrics/{push,server,play}_metrics.jsonl`、`metrics/summary.csv`、
`alerts/alerts.jsonl`、`alerts/alerts_summary.txt`、`timeline/events.jsonl`、
`timeline/first_problem.json` 和 `manifest.sha256`。这些文件可以回答
“第一条 warn/error 在哪个角色、哪个 track、哪个 receiver 出现”以及“弱网前后
bitrate/FPS/NACK/retransmission 怎么变化”。

`runtime_config.json` 是脱敏后的运行配置 dump，只记录 role、factory、UDP 边界、
log/metrics/alerts 开关和 bundle 内相对路径，不记录媒体 bytes、原始帧、鉴权材料或
运行机绝对目录。`verify_phase5_debug_bundle.sh` 会把这些脱敏标记作为硬门禁检查。

## 8. 错误码和运行契约

最小 UDP 外围不要把 SDK 返回的 `Status` 当成普通 bool 丢弃。业务 summary 可以只打
`operation + status_code + reason`，但完整上下文必须依赖 `RuntimeLogConfig` 写入角色
日志文件。当前 public `StatusCode` 的集成语义如下：

- `kInvalidArgument`：配置缺必需 callback、空 RTP/RTCP/AU、未知 track 或非法
  `SessionConfig`。
- `kUnsupported`：facade 尚未 `Start()` 就调用运行期方法，或收到当前不承诺处理的
  RTCP 能力。
- `kMalformedPacket`：RTP、RTCP 或 H264 Annex-B 解析失败。
- `kQueueFull`：pacer、恢复队列或 history 达到容量；上层应丢当前帧/包并等待后续
  `Process()` 恢复。
- `kInternalError`：业务 `TransportOutput`、decoded AU callback 或 SDK 内部不可恢复
  构包路径失败。

主要 public method 的错误边界：

| API | 主要非 OK 返回 | 最小处理方式 |
| --- | --- | --- |
| `VideoPushClient::Start()` | `kInvalidArgument` | 修正 config 后重建 facade。 |
| `VideoPushClient::Process()` | `kUnsupported`、`kInternalError` | before-start 属集成错误；transport failure 要记录并按业务网络策略重试或重连。 |
| `VideoPushClient::PushAnnexBAccessUnit()` | `kUnsupported`、`kInvalidArgument`、`kMalformedPacket`、`kQueueFull` | 单个 malformed/queue full 不要杀进程，记录并等待下一帧；持续发生再触发业务告警。 |
| `VideoPushClient::OnTransportFeedback()` | `kInvalidArgument`、`kMalformedPacket` | drop 当前 RTCP，并依赖后续反馈恢复。 |
| `VideoPlayClient::Start()` | `kInvalidArgument` | 修正 config 后重建 facade。 |
| `VideoPlayClient::Process()` | `kUnsupported`、`kInternalError` | before-start 属集成错误；RTCP 输出失败按业务网络策略处理。 |
| `VideoPlayClient::OnRtpPacket()` | `kUnsupported`、`kInvalidArgument`、`kMalformedPacket`、`kInternalError` | malformed 单包丢弃；decoded AU callback 失败要作为媒体输出故障处理。 |
| `VideoPlayClient::OnRtcpPacket()` | `kInvalidArgument`、`kMalformedPacket` | drop 当前 RTCP。 |
| `ServerQosRouter::Start()` | `kInvalidArgument` | 修正 sender/receiver output 后重建 router。 |
| `ServerQosRouter::OnSenderRtp()` | `kUnsupported`、`kMalformedPacket`、`kInternalError` | malformed 单包丢弃；receiver output failure 要进入网络/relay 故障处理。 |
| `ServerQosRouter::OnSenderRtcp()` | `kUnsupported`、`kInvalidArgument`、`kMalformedPacket`、`kInternalError` | unsupported RTCP 默认 drop；output failure 按 relay 故障处理。 |
| `ServerQosRouter::OnReceiverRtcp()` | `kUnsupported`、`kInvalidArgument`、`kMalformedPacket`、`kInternalError` | NACK/PLI 可触发本地重传或转发；output failure 按 relay 故障处理。 |
| `ServerQosRouter::OnDownlinkQuality()` | `kOk` | 当前只更新状态、写 metrics/alerts，不应失败。 |

日志和告警契约：

- 所有 warn/error 日志都带 `status_code`、`reason` 和
  `session_id/stream_id/transport_id/source_id/track_id/sender_ssrc/receiver_id`。
- malformed H264/RTP、transport output failure、server receiver output failure 和
  decode output failure 会写 alerts，规则名分别是 `malformed_h264`、
  `malformed_rtp`、`transport_output_failed`、`receiver_output_failed`、
  `decode_output_failed`。
- 日志和 alerts 不写媒体 payload，也不写 RTP/RTCP/AU 原始 bytes。
- stdout/stderr 只适合打印人工 summary；生产排障以 JSONL 日志、metrics、alerts 和
  debug bundle 为准。

门禁：

```bash
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_phase5_error_contract.sh
```

该脚本会先安装当前 SDK，再从安装 prefix 构建外部 CMake fixture，覆盖 config error、
before-start、malformed packet、transport failure、relay output failure 和 decode
output failure，并验证返回 `StatusCode`、日志事件和 alerts 规则一致。

## 9. 线程和时钟

推荐线程模型：

- sender role 一个 worker，串行调用 `push->Start/Process/Push/OnFeedback`。
- server role 一个 worker，串行调用 `server->Start/OnSender*/OnReceiver*`。
- receiver role 一个 worker，串行调用 `play->Start/Process/OnRtp/OnRtcp`。
- 如果业务必须多线程调用同一个 facade，需要在业务侧加锁或投递到同一 task
  queue。

时钟要求：

- `now_us` 使用单调时钟，单位微秒。
- `Process(now_us)` 必须稳定周期调用，建议 5ms 到 20ms tick。
- 低 FPS、弱网、暂停采集期间也要继续调用 `Process(now_us)`。
- RTP/RTCP receive time 用收到 UDP datagram 的本地单调时间。

## 10. 安全和网络边界

最小 UDP 方式适用于本机、内网、专线、可信 C/S 网络或业务已有安全隧道的场景。
当前 SDK 不提供完整 WebRTC 的这些能力：

- ICE / STUN / TURN
- DTLS handshake
- SRTP key management
- NAT traversal
- 浏览器 PeerConnection signaling

如果要跑在公网或不可信网络，业务必须在 SDK 外层提供等价安全和连接能力，例如
QUIC、DTLS、VPN、专线加密、访问控制和重放保护。无论底层是 UDP、QUIC 还是业务
自定义传输，SDK facade 看到的仍然只是 RTP/RTCP opaque bytes。

## 11. 最小验证方式

本仓库内最接近业务最小集成的参考是 UDP 三角色 demo：

```bash
cd /root/webrtc_qos_sdk
cmake -S . -B build-webrtc-first \
  -DCMAKE_BUILD_TYPE=Release \
  -DWEBRTC_QOS_ENABLE_WEBRTC_FACADE=ON \
  -DWEBRTC_QOS_WEBRTC_MODULE_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64
cmake --build build-webrtc-first \
  --target webrtc_qos_webrtc_first_udp_demo -j2

./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo selftest 36
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 36 --log-dir /tmp/webrtc_qos_udp_logs
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 36 --metrics-dir /tmp/webrtc_qos_udp_metrics
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 36 --alerts-dir /tmp/webrtc_qos_udp_alerts
```

预期结果应包含：

```text
backend=webrtc_first_facade transport=udp peer_connection=false
udp_selftest_dual_track ... tracks=2 ... decoded_tracks=2 ... pass=true
```

更完整的角色和 multi-track 门禁：

```bash
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
SDK_ROOT=/root/webrtc_qos_sdk \
  scripts/verify_webrtc_first_roles.sh
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_phase5_logging.sh
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_phase5_metrics.sh
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_phase5_alerts.sh
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_phase5_error_contract.sh
OUTPUT_DIR=/tmp/webrtc_qos_phase5_debug_bundle \
  scripts/collect_phase5_debug_bundle.sh
BUNDLE_DIR=/tmp/webrtc_qos_phase5_debug_bundle \
  scripts/verify_phase5_debug_bundle.sh
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_phase5_minimal_udp_external_app.sh
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_phase5_release_contract.sh
```

## 12. 集成检查清单

- sender/server/receiver 使用同一份 `SessionConfig`。
- 所有 track 都来自 `SessionConfig.video_tracks`。
- 每个 AU 都填了正确的 `AnnexBAccessUnitView::ids`。
- UDP envelope 能区分 RTP、RTCP、`DownlinkQuality` 和 `SenderRateCap`。
- RTP/RTCP payload 没有被业务层解析、修改、合包或拆错边界。
- sender 持续调用 `VideoPushClient::Process(now_us)`。
- receiver 持续调用 `VideoPlayClient::Process(now_us)`。
- server 把 receiver RTCP 调到 `OnReceiverRtcp(receiver_id, ...)`。
- sender 把 server RTCP 调到 `OnTransportFeedback(...)`。
- sender 使用 `GetTrackEncoderAdaptation()` 驱动每条 track 的码率、FPS 和关键帧。
- receiver 按 `track_id` 或 `sender_ssrc` 分发 decoded AU。
- sender/server/receiver 显式配置文件日志，stdout 只保留人工 summary。
- sender/server/receiver 显式配置 metrics 文件，能看到弱网下探、恢复和恢复事件。
- sender/server/receiver 显式配置 alerts 文件，能看到弱网、恢复、malformed、
  transport failure 和 decode failure 告警。
- 所有 SDK `Status` 失败都打印 `status_code` 和 `reason`，完整上下文写入角色日志文件。
- 每次问题复现都收集 debug bundle，并用 `manifest.sha256` 做离线完整性校验。
- debug bundle 里必须有 `runtime_config.json`，并通过配置 dump 脱敏校验。
- 正式 production gate 非 dry-run 失败时，优先使用 wrapper 输出的
  `failure_debug_bundle/` 和 `logs/failure_debug_bundle_*.log` 排查。
- 发布前必须跑 `verify_phase5_release_contract.sh`，确认普通 `role_*` 和
  `role_*_bundle` 两种安装包链接方式都可用。
- 业务没有直接依赖 WebRTC 内部头、`PeerConnection`、ICE、DTLS 或 SRTP。

## 13. 参考文档

- [推拉客户端 SDK 集成说明](sdk_push_play_integration.md)
- [WebRTC 边界声明](webrtc_boundary_statement.md)
- [QoS 测试与验证方法](qos_test_validation_methodology.md)
- [UDP 三角色 demo](../demo/webrtc_first_udp/main.cc)
- [Phase-5 生产集成化、可观测性与日志体系计划](../webrtc_first_phase5_plan.md)
