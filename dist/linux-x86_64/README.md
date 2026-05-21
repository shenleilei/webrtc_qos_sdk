# WebRTC QoS SDK Linux x86_64 发布包

这是仓库当前 `dist/linux-x86_64` 的安装产物，默认说明使用中文。

## 目录结构

```text
include/webrtc_qos/
lib/
  libwebrtc_qos.a
  libwebrtc_qos_core.a
  libwebrtc_qos_transport.a
  libwebrtc_qos_transport_packet_history.a
  libwebrtc_qos_facade_video.a
  libwebrtc_qos_webrtc_googcc.a
  libwebrtc_qos_webrtc_pacing.a
  libwebrtc_qos_webrtc_rtp_rtcp.a
  libwebrtc_qos_webrtc_video_jitter.a
  libwebrtc_qos_webrtc_nack_requester.a
  cmake/WebRtcQosSdk/
demo/
  webrtc_qos_*_smoke
```

## 当前边界

- SDK 不是完整 WebRTC Client、PeerConnection 或 SFU。
- 业务侧仍负责 UDP/socket、业务 envelope、会话映射、安全鉴权和服务端策略。
- SDK facade 负责 H264 push/play、server relay、WebRTC GoogCC、WebRTC RTP/RTCP、WebRTC NACKRequester、WebRTC pacing adapter、WebRTC video jitter adapter。
- 旧自研 RTP/RTCP/NACK/pacer/video jitter 不再作为 public API 或默认构建路径保留。
- 当前 `libwebrtc_qos_webrtc_pacing.a` 使用 WebRTC `PacingController` 最小闭包：SDK bytes 进入 adapter 后被解析为 `RtpPacketToSend`，由 `PacingController` 负责队列、packet priority、probe cluster 和发送时机，再输出 RTP bytes。发布包没有直接打全量 `modules/pacing`，也不包含 `task_queue_paced_sender` 或 `packet_router`。RTP padding 由 adapter 基于已有媒体包模板生成，参与 TWCC 但不进入重传历史或视频 jitter/解码路径。

## CMake 集成

外部项目指向本目录即可：

```bash
cmake -S app -B app/build \
  -DCMAKE_PREFIX_PATH=/path/to/webrtc_qos_sdk/dist/linux-x86_64
cmake --build app/build -j"$(nproc)"
```

推荐按角色链接：

- `WebRtcQosSdk::role_push`：发送端 push facade。
- `WebRtcQosSdk::role_play`：播放端 play facade。
- `WebRtcQosSdk::role_server`：最小 server relay/QoS router。
- `WebRtcQosSdk::role_transport`：业务传输边界。

## 验证命令

在仓库根目录运行：

```bash
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_webrtc_modules.sh

PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_webrtc_first_pacing_probe.sh

PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/verify_webrtc_first_loopback.sh

PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  SDK_ROOT=/root/webrtc_qos_sdk \
  scripts/verify_webrtc_first_roles.sh
```

当前本地验证点：

- WebRTC module smoke：`pacing_adapter_smoke passed emitted=3 probe_emitted=2 probe_bytes=800 padding_emitted=5 padding_bytes=600`。
- push facade probe：`rtp_packets=6`、`probe_packets=6`、`probe_bytes=745`、`probe_cluster=1`。
- facade 弱网矩阵：8/8 通过。
- `weak_network_low_rps_low_bitrate` 弱网窗口：`11.0526 AU RPS / 33.1579 RTP pps / 600000bps / 10fps`。
- `weak_network_low_rps_low_bitrate` 恢复窗口：`30 AU RPS / 90 RTP pps / 1207178bps / 30fps`。
- Phase-2 qoe 聚合门禁：`VERIFY_LEVEL=qoe` 通过；真实 H264 low-RPS/low-bitrate 为 `10.9091 AU RPS / 92.7273 RTP pps / 400000bps / 10fps`，恢复到 `30 RPS / 840944bps / 30fps`，`playable_ratio=0.923077`、`avg_psnr_y=45.9423`、`avg_ssim_y=0.999833`，恢复时间分布 `p95=0ms`。
- Phase-2 production 短时 smoke：`VERIFY_LEVEL=production` 通过，配置为 `SOAK_CYCLES=1 / FRAMES_PER_CYCLE=12 / RUN_REAL_RENDERER=0 / RUN_CAPTURE_LIBRARY=0`；production archive tarball、sha256 manifest 和离线 archive verifier 通过。该结果只验证 runner/归档链路，不代表多小时生产结论。
- Phase-2 capture fixture 聚合门禁：`RUN_CAPTURE_LIBRARY=1 REQUIRE_CAPTURE_LIBRARY=1` 通过；manifest 六类覆盖，capture QoE `rows=6/6 pass`、`playable_ratio_min=0.833333`、`avg_psnr_y_min=42.6753`、`avg_ssim_y_min=0.998468`、`decode_errors=0`、`freeze_count=0`。该结果只验证采集入口和 fixture 链路，不代表正式业务真实采集素材库。
- Real renderer smoke：`verify_real_renderer_smoke.sh` 支持真实 X11 `DISPLAY`，也支持存在 `Xvfb` 时自动启动 headless X11 smoke；当前机器无 `DISPLAY` 且无 `Xvfb`，结果为 skipped，不代表真实 GPU/窗口 renderer 已验收。
- Phase-2 completion audit：`scripts/verify_webrtc_first_phase2_completion_audit.sh` 用于判断是否可以宣布整期完成。默认要求 smoke/qoe 通过、`SOAK_MINUTES>=120` 的正式 production soak archive、真实显示环境 renderer pass、正式业务采集素材库 manifest；当前短时 smoke、renderer skipped 和 fixture capture 不会被当成完成证据。
- Phase-2 evidence bundle：`scripts/collect_webrtc_first_phase2_evidence_bundle.sh` 会把 smoke/qoe/production soak/real renderer/capture 证据收集成单个带 `manifest.sha256` 的目录；completion audit 支持 `EVIDENCE_BUNDLE_DIR=/path/to/bundle` 直接审计该目录。
- Phase-2 production gate：`scripts/run_webrtc_first_phase2_production_gate.sh` 会先做 WebRTC modules、capture manifest、real renderer 的 preflight，之后才跑正式 `VERIFY_LEVEL=production`、bundle 收集和 completion audit。当前本机 preflight 失败在缺少正式 `capture_library/manifest.csv` 和缺少真实显示环境。

低 RPS/低码率弱网独立门禁：

```bash
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  OUTPUT_DIR=/root/webrtc_qos_sdk/artifacts/webrtc_first_low_rps_low_bitrate_check \
  scripts/run_webrtc_first_qoe_low_rps_low_bitrate_check.sh
```

这条门禁同时跑 synthetic facade 和真实 H264 QoE。弱网阶段必须满足低 RPS、低 RTP pps、低 target bitrate、低 encoder FPS；恢复阶段必须回升。真实 H264 QoE 还会检查 playable ratio、PSNR、SSIM 和 freeze/renderer proxy 指标。

## 二进制兼容性

- 本发布包目标是 Linux x86_64、ELF64、System V ABI。
- 静态 `.a` 仍依赖最终链接机器的 libc、libstdc++、pthread、dl、rt、atomic 等系统 ABI。
- 生产发布建议在“最老支持发行版”或固定容器/toolchain 中构建，再分发到更高版本环境。
- `third_party/webrtc_patches/webrtc_qos_sdk.patch` 已纳入仓库，用于在兼容 WebRTC checkout 上复现 adapter 构建。
