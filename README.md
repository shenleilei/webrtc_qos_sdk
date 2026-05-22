# WebRTC QoS SDK

这是一个 Linux native C/S 架构下的 WebRTC-first QoS SDK 原型。目标不是做完整 WebRTC Client、PeerConnection 或 SFU，而是在业务自定义传输上复用 WebRTC 的 QoS、RTP/RTCP、NACK、pacing 和视频 jitter 能力。

## 文档导航

- [WebRTC QoS 总览与 SDK 设计说明](docs/webrtc_qos_overview.md)
- [WebRTC 边界声明](docs/webrtc_boundary_statement.md)
- [QoS 测试与验证方法](docs/qos_test_validation_methodology.md)
- [推拉客户端 SDK 集成说明](docs/sdk_push_play_integration.md)
- [最小 UDP 集成最佳实践](docs/minimal_udp_integration_best_practice.md)
- [WebRTC 子模块拆分编译说明](docs/webrtc_module_split_build.md)
- [Phase-2 主实施文档](webrtc_first_phase2_master_plan.md)
- [Phase-3 逻辑正确性收敛计划](webrtc_first_phase3_plan.md)
- [Phase-4 多 Track / 多 SSRC 计划](webrtc_first_phase4_plan.md)
- [Phase-5 生产集成化、可观测性与日志体系计划](webrtc_first_phase5_plan.md)

## 当前状态

默认构建已经切到 Phase-2 WebRTC-first 边界：

- 已删除旧自研 RTP/RTCP/NACK/pacer/video jitter 的 public headers、CMake targets、默认 demos、tests 和发布包产物。
- 已保留业务 glue 层：`video_push_client.h`、`video_play_client.h`、`server_qos_router.h`、`transport_io.h`、`rate_cap.h`、`qos_metrics.h`、`control_messages.h`。
- 已保留 `transport_packet_history`：只保存 opaque RTP bytes，供 sender/server 在 WebRTC NACK 路由后按 `hop_id/ssrc/rtp_sequence_number` 找原包重传；它不解析 RTCP、不生成 NACK、不做恢复策略。
- 已提供 WebRTC-backed `CreateVideoPushClient()` / `CreateVideoPlayClient()` / `CreateServerQosRouter()` 默认实现。push/play 使用 WebRTC H264 RTP、RTP packet、pacing、GoogCC、NackRequester 和 video jitter adapters；server 使用 WebRTC RTP/RTCP adapters 和 `transport_packet_history` 做 relay、uplink TWCC 生成、SR/RR RTT、NACK 本地重传、PLI/NACK 路由。
- WebRTC adapter patch 已纳入 `third_party/webrtc_patches/webrtc_qos_sdk.patch`，不再依赖 `/root/src` 里的不可见本地改动。
- 当前工作区已经包含默认 multi-track / multi-SSRC 能力基线：`SessionConfig.video_tracks`、`source_id / track_id / sender_ssrc`、per-track snapshot/adaptation 查询，以及 shared `GoogCC / pacer` 下的多 track / 多 SSRC 主路径。它已经通过 `verify_webrtc_first_multitrack.sh`、`verify_webrtc_first_roles.sh` 和 Phase-2 smoke/qoe/production 短时门禁；但多 receiver fanout support 层仍未进入当前实现，P5 以前也不做多接收端产品化。
- 当前默认门禁里还增加了 `run_webrtc_first_multitrack_matrix.sh`，用于验证双 track 下的 shared source cap 分配、track 级 `PLI/NACK/retransmission` 隔离，以及 per-track 输出身份。

当前可打包的 WebRTC 模块：

```text
libwebrtc_qos_webrtc_googcc.a
libwebrtc_qos_webrtc_pacing.a
libwebrtc_qos_webrtc_rtp_rtcp.a
libwebrtc_qos_webrtc_video_jitter.a
libwebrtc_qos_webrtc_nack_requester.a
```

`libwebrtc_qos_webrtc_rtp_rtcp.a` 当前包含标准 RTP packet bytes build/parse adapter、RTCP PLI/NACK/TWCC/SR/RR wire format adapter，以及 H264 RTP payload packetization/depacketization 子集。H264 子集固定为 `packetization-mode=1`，只输出 Single NALU + FU-A，不输出 STAP-A。RTP packet adapter 使用 WebRTC `RtpPacket` 和固定 `transport-wide-cc-01` header extension，不在 SDK facade 里手写 RTP header。

`libwebrtc_qos_webrtc_pacing.a` 当前已经切到 WebRTC `PacingController` 最小闭包：adapter 内部把 SDK bytes 解析成 `RtpPacketToSend`，交给 `PacingController` 做队列、packet priority、probe cluster 和发送时机判断，再把出队结果还原成 RTP bytes。发布包没有直接打全量 `modules/pacing`，也没有引入 `task_queue_paced_sender` 或 `packet_router`。RTP padding 由 adapter 在已有媒体包模板后生成：`size <= 1 byte` 的 probe/keepalive padding 请求返回空，避免破坏 probe 首包顺序；真实 padding 包分配新的 RTP sequence number 和 transport-wide sequence number，设置 RTP padding bit，参与 uplink TWCC，但不进入 packet history 或视频 jitter/解码路径。

SDK facade 已显式透出 padding 边界：`TransportPacketMetadata::padding` 标记 padding RTP 包，`QosSnapshot::emitted_padding_packets / emitted_padding_bytes` 记录 pacer padding 输出；server 对 padding 包生成 TWCC arrival feedback 但不缓存为可重传媒体包；play 端先喂 NACK requester 处理序号连续性，再跳过 H264 depacketize/video jitter。

### 当前仍未闭合的事项

下面这些点当前还不能对外描述成“正式完成”：

- 正式验收闭环还缺 3 项：`SOAK_MINUTES>=120` 的 production soak、真实 renderer `pass`、正式 `capture_library/manifest.csv` 和业务素材库。
- 当前支持的是 `NACK + 原 RTP 包重传`，不支持 `RFC4588 RTX`，也不支持 `FEC / ULPFEC / FlexFEC / RED`。
- compound RTCP 当前只承诺处理 `SR / RR / TWCC / NACK / PLI`；server 对 unsupported RTCP packet 会显式计数并默认 drop，不做透明 relay。

上面这些逻辑正确性问题的收敛计划见 [Phase-3 逻辑正确性收敛计划](webrtc_first_phase3_plan.md)。

## 默认发布包

默认 SDK 安装只发布 Phase-2 facade/support 层：

```text
libwebrtc_qos.a
libwebrtc_qos_core.a
libwebrtc_qos_transport.a
libwebrtc_qos_transport_packet_history.a
libwebrtc_qos_facade_video.a
```

当前安装包还会额外生成按角色聚合后的“大静态库”：

```text
libwebrtc_qos_role_push_bundle.a
libwebrtc_qos_role_play_bundle.a
libwebrtc_qos_role_server_bundle.a
```

它们把当前角色实际需要的 SDK archive 和 WebRTC 子模块 archive 聚合到单个 `.a` 里，便于 sender/play/server 分别直接集成。

WebRTC 能力库由 `scripts/package_webrtc_modules.sh` 从 WebRTC 源码树单独构建并复制到同一个 prefix。当前 source build 默认开启 `WEBRTC_QOS_ENABLE_WEBRTC_FACADE=ON`，并默认从仓库内 `dist/linux-x86_64` 查找 WebRTC modules；如需使用其它 prefix，显式传 `-DWEBRTC_QOS_WEBRTC_MODULE_PREFIX=<prefix>`。缺少 WebRTC modules 会直接配置失败，不会 fallback。

当 `WEBRTC_QOS_ENABLE_WEBRTC_FACADE=ON` 时，`cmake --install` 现在也会把所依赖的 `libwebrtc_qos_webrtc_*.a` 和 adapter headers 一并复制到安装 prefix，确保外部工程用安装后的 prefix 仍能拿到 `role_push / role_play / role_server`。

默认公开头文件：

```text
control_messages.h
production_transport_adapter.h
qos_metrics.h
rate_cap.h
runtime_logging.h
runtime_metrics.h
runtime_alerts.h
server_qos_router.h
session_config.h
status.h
transport_io.h
transport_packet_history.h
transport_port.h
types.h
video_play_client.h
video_push_client.h
```

## 构建 SDK

前置条件：当前 source build 默认开启 WebRTC-first facade，并默认从仓库内 `dist/linux-x86_64` 读取 WebRTC modules。首次在新机器构建前，先确认该目录下已经有 `libwebrtc_qos_webrtc_*.a` 和对应 adapter headers；没有的话先执行下面的“打包 WebRTC 模块”步骤。

如果显式传 `-DWEBRTC_QOS_ENABLE_WEBRTC_FACADE=OFF`，得到的是 maintenance/support-only 构建，不是 Phase-2 正式交付边界。

```bash
cd /root/webrtc_qos_sdk
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
./build/webrtc_qos_selftest
cmake --install build --prefix /root/output
```

## 打包 WebRTC 模块

默认假设 WebRTC 源码树在 `/root/src`：

```bash
cd /root/webrtc_qos_sdk
PREFIX=/root/output REQUIRE_ALL=1 NINJA_JOBS=2 \
  scripts/package_webrtc_modules.sh
```

如果是干净 WebRTC checkout，需要显式允许应用 patch：

```bash
WEBRTC_SRC=/path/to/webrtc \
PREFIX=/root/output \
APPLY_WEBRTC_PATCH=1 \
scripts/package_webrtc_modules.sh
```

## 验证

```bash
cd /root/webrtc_qos_sdk
PREFIX=/root/output VERIFY_LEVEL=smoke scripts/verify_webrtc_first_phase2.sh
PREFIX=/root/output REQUIRE_ALL=1 scripts/verify_webrtc_modules.sh
PREFIX=/root/output scripts/verify_cmake_package.sh
PREFIX=/root/output scripts/verify_webrtc_first_loopback.sh
PREFIX=/root/output SDK_ROOT=/root/webrtc_qos_sdk \
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
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/run_phase5_implementation_gate.sh
GATE_DIR=artifacts/phase5_implementation_gate/latest \
  scripts/verify_phase5_implementation_gate.sh
REQUIRE_PRODUCTION_EVIDENCE=0 \
  scripts/verify_phase5_completion_audit.sh
```

`verify_webrtc_first_phase2.sh` 是当前 Phase-2 聚合门禁入口。`VERIFY_LEVEL=smoke` 会串起 no-selfmade、WebRTC module smoke、外部 CMake package、loopback、pacing probe、role facade 和 synthetic 弱网矩阵；`VERIFY_LEVEL=qoe` 在 smoke 基础上增加低 RPS/低码率真实 H264 QoE 和恢复时间分布；`VERIFY_LEVEL=production` 会继续进入 production soak，并可通过 `REQUIRE_REAL_RENDERER=1 / REQUIRE_CAPTURE_LIBRARY=1` 把真实 renderer 和正式采集素材库变成硬门禁。当前 `SOAK_MINUTES=0` 的默认本地 production smoke 只验证 runner/archive 链路，默认配置为 `FRAMES_PER_CYCLE=12 / CONTENT_MODES=block_motion / SCENARIOS=weak_network_low_rps_low_bitrate`；正式验收仍必须显式跑 `SOAK_MINUTES>=120`。

`scripts/verify_webrtc_first_phase2_completion_audit.sh` 是“能否宣布 Phase-2 完成”的审计门禁。它不会重新跑所有 case，而是检查既有证据是否达到完成标准：smoke/qoe 必须通过，production soak 必须来自 `SOAK_MINUTES>=120` 或更长的正式运行并有 archive，real renderer 必须是有真实显示环境的 pass 结果，capture library 必须是正式业务素材库而不是 fixture。当前本机预期不会通过这个审计，因为还缺多小时 production soak、真实 GPU/窗口 renderer 和正式业务采集素材库。

`scripts/collect_webrtc_first_phase2_evidence_bundle.sh` 用于把一次正式验收的 smoke/qoe/production soak/real renderer/capture 证据收集到统一目录，并生成 `manifest.sha256`。后续可以用 `EVIDENCE_BUNDLE_DIR=/path/to/bundle scripts/verify_webrtc_first_phase2_completion_audit.sh` 直接审计该目录，避免正式结果散落在多个 artifacts 路径里。

`scripts/verify_phase5_production_readiness.sh` 是 Phase-5 正式验收前置检查：它不跑长时 soak，只检查 WebRTC module prefix、`SOAK_MINUTES` 配置、正式 capture manifest、真实 renderer 可用性和 Phase-5 gate/audit 脚本是否齐全，并输出 `phase5_production_readiness_status=ready|not_ready`、logs、`next_required_actions.txt`、`files.txt` 和 `manifest.sha256`。默认本地缺正式素材或真实 renderer 时只生成 not-ready 报告；正式 CI 可设置 `REQUIRE_READY=1` 把这些缺口变成硬失败。

`scripts/run_phase5_production_gate.sh` 是 Phase-5 顶层正式验收 wrapper。它先跑并复验 Phase-5 implementation gate，再跑 release contract、production readiness 和 debug bundle 门禁，然后调用 `run_webrtc_first_phase2_production_gate.sh` 做 production preflight、长时 soak、真实 renderer、正式 capture library、evidence bundle 和 completion audit，并在 `artifacts/phase5_production_gate/<utc_build_id>/` 下生成 metadata、summary、logs、`files.txt` 和 `manifest.sha256`；其中 `phase5_implementation_gate/` 固定在 production gate 目录内，保证正式证据自包含。非 dry-run 执行失败时，wrapper 会自动收集并校验 `failure_debug_bundle/`，确保失败也有日志、metrics、alerts、timeline 和 runtime config 可排查；`verify_phase5_production_gate.sh` 会在成功路径离线复验 `phase5_implementation_gate/`、`phase5_production_readiness/`、`phase5_debug_bundle/`，同时复验底层 Phase-2 evidence bundle manifest 和 `phase2_completion_audit=pass / phase2_completion_status=complete`，在失败路径复验 `failure_debug_bundle/`，并且只要 implementation gate 已经 pass，也会复验该实现证据；如果失败发生在 implementation/readiness 阶段，还会复验对应 summary、manifest、失败 check 和 `next_required_actions.txt`，避免只相信 summary 或留下不可执行的失败报告。底层 Phase-2 production gate 默认要求 `SOAK_MINUTES=120`。当前本机 preflight 预期仍会失败：`/root/webrtc_qos_sdk/capture_library/manifest.csv` 不存在，且没有真实 renderer 环境；可以用 `PHASE5_DRY_RUN=1` 只验证 gate 结构，但这不代表生产证据完成。

当前本机 `VERIFY_LEVEL=qoe` 聚合门禁已通过，summary 位于 `artifacts/webrtc_first_phase2_verify_qoe/phase2_verify_summary.txt`。本次聚合里 synthetic facade 弱网矩阵 8/8 通过；真实 H264 low-RPS/low-bitrate case 结果为 `bad_send_rps=10.9091`、`bad_rtp_pps=92.7273`、`max_bad_target_bps=400000`、`max_bad_encoder_fps=10`，恢复到 `recovery_send_rps=30`、`max_recovery_target_bps=840944`、`max_recovery_encoder_fps=30`，`playable_ratio=0.923077`、`avg_psnr_y=45.9423`、`avg_ssim_y=0.999833`。恢复时间分布门禁 `samples=1`，`target/fps/full_recovery_time_ms_p95=0`，低于 `1000ms` 门槛。

当前本机也跑通了 `VERIFY_LEVEL=production` 短时 smoke，summary 位于 `artifacts/webrtc_first_phase2_verify/phase2_verify_summary.txt`，对应 production soak 证据在 `artifacts/webrtc_first_phase2_verify/production_soak/`。本次只配置 `SOAK_CYCLES=1 / SOAK_MINUTES=0 / FRAMES_PER_CYCLE=12 / CONTENT_MODES=block_motion / SCENARIOS=weak_network_low_rps_low_bitrate / RUN_REAL_RENDERER=0 / RUN_CAPTURE_LIBRARY=0`，用于验证 production runner、CSV 聚合、archive metadata、sha256 manifest、tarball 和离线 archive verifier 链路，不代表生产级多小时结论。短时结果：`cycles=1`、`rows=1`、`pass_rows=1`、`decode_errors=0`、`freeze_count=0`、`renderer_proxy_drop_frames=0`、`weak_low_bad_send_rps_max=12.8571`、`weak_low_bad_rtp_pps_max=150`、`weak_low_target_bps_max=750000`、`weak_low_encoder_fps_max=10`，离线归档校验和恢复时间分布校验均通过。

当前本机还跑通了 Phase-2 聚合门禁中的 capture fixture：先用 `scripts/generate_capture_library_fixture.sh` 生成六类 deterministic mp4 和 `manifest.csv`，再用 `RUN_CAPTURE_LIBRARY=1 REQUIRE_CAPTURE_LIBRARY=1` 驱动 `verify_webrtc_first_phase2.sh`。结果位于 `artifacts/webrtc_first_phase2_verify_capture_fixture/phase2_verify_summary.txt`：manifest 校验 `entries=6`，覆盖 `high_motion,indoor_face,low_light_noise,outdoor_walking,scene_cut,screen_text`；capture QoE `rows=6/6 pass`，`playable_ratio_min=0.833333`、`avg_psnr_y_min=42.6753`、`avg_ssim_y_min=0.998468`、`decode_errors=0`、`freeze_count=0`、`renderer_proxy_drop_frames=0`、`renderer_proxy_max_gap_ms=34`。这只证明采集库入口、manifest 强门禁和转码/QoE 链路可执行，不等价于正式业务真实采集素材。

`verify_webrtc_first_loopback.sh` 会创建临时外部 CMake consumer，链接发布包中的 `webrtc_rtp_rtcp + webrtc_pacing + webrtc_video_jitter`，跑 synthetic H264 Annex-B AU -> WebRTC H264 RTP payload -> WebRTC RTP packet bytes -> WebRTC pacing adapter -> WebRTC video jitter -> Annex-B AU 的端到端 bytes 闭环。

`verify_webrtc_first_pacing_probe.sh` 会创建只链接 `WebRtcQosSdk::role_push` 的外部 consumer，验证 push facade 启动时从 GoogCC 取 probe cluster，传给 pacing adapter，并在 `QosSnapshot` 中输出 `emitted_probe_packets / emitted_probe_bytes / last_probe_cluster_id`。当前本地结果为 `rtp_packets=6`、`probe_packets=6`、`probe_bytes=745`、`probe_cluster=1`。

`verify_cmake_package.sh` 会创建临时外部 CMake consumer，验证 `role_push`、`role_play`、`role_server` 都能单独链接并真实调用对应 `Create*()` 工厂函数；`role_server` 会额外验证基础 rate cap runtime。

当前 `verify_cmake_package.sh` 还覆盖了几条关键恢复语义：

- sender 收到 `PLI` 后会把 `request_keyframe` 反映到 `GetEncoderAdaptation()`
- sender 收到 `NACK` 后会执行 sender packet history 查找和 sender 侧重传
- play 侧 `Process(now_us)` 会推进 NackRequester 的无包窗口重试
- server 对部分命中 NACK 会本地重传命中包，并只把 miss 的 packet ids 转发给 sender

`verify_webrtc_first_roles.sh` 会继续调用 `verify_no_selfmade_media_stack.sh`、`verify_webrtc_first_loopback.sh`、`verify_webrtc_first_multitrack.sh` 和 `run_webrtc_first_multitrack_matrix.sh`，确认旧自研媒体栈没有回到 public API、CMake 或发布包，基础 WebRTC-first bytes 链路可外部消费，并且当前默认 multi-track 能力在双 track 情况下满足 shared source cap 分配、feedback isolation 和 per-track 身份输出。它也会构建 `webrtc_qos_webrtc_first_udp_demo`，跑 UDP selftest，并 smoke 检查独立 `sender/server/receiver` 三个角色入口都使用 `backend=webrtc_first_facade transport=udp peer_connection=false`。

`verify_phase5_logging.sh` 是 Phase-5 第一条日志门禁：它验证默认不把 SDK 运行日志打到 stdout/stderr，显式传 `--log-dir` 后会生成 push/server/play 三类 JSONL 日志文件，并检查 config_dump、start/stop、access unit、downlink quality、retransmission、decode output 等关键事件和统一身份字段；其中 config_dump 只包含脱敏运行配置摘要，stop 事件用于证明正常 `Stop()` 后日志已 flush 到文件。它还会用 `--log-max-queue-records 1` 压测异步日志队列，要求看到 `dropped_log_count` 且 warn/error/stop 不丢。

`verify_phase5_metrics.sh` 是 Phase-5 metrics snapshot 门禁：它验证显式传 `--metrics-dir` 后会生成 push/server/play 三类 JSONL metrics 文件，并检查弱网下的 bitrate/FPS 下探、恢复回升、server retransmission、play NACK、dual-track 指标身份，以及 `process_tick_count / process_tick_gap_us / max_process_tick_gap_us`、`rtp_output_gap_us / rtp_input_gap_us`、`transport_failure_count / consecutive_transport_failures / max_consecutive_transport_failures` 这类运行循环、媒体流和 transport callback 健康度字段。

`verify_phase5_alerts.sh` 是 Phase-5 监控告警门禁：它验证显式传 `--alerts-dir` 后会生成 push/server/play 三类 JSONL alerts 文件，弱网下覆盖 low target bitrate、low encoder FPS、high downlink loss、video drop、NACK 和本地重传命中；同时用安装包外部 CMake fixture 覆盖 malformed RTP、transport output failure、连续 transport output failure、decode output failure、三角色 `process_tick_gap`、sender/server `sender_rtp_output_gap` 和 play `receiver_rtp_input_gap` availability alert，并检查对应 warn/error 日志落盘。

`verify_phase5_error_contract.sh` 是 Phase-5 错误码与运行契约门禁：它先安装当前 SDK，再用外部 CMake consumer 只链接 `WebRtcQosSdk::role_push / role_play / role_server`，验证 `Start()` config error、before-start 调用、malformed H264/RTP、transport output failure、server relay failure 和 decode output failure 的 `StatusCode`、日志事件和 alerts 规则一致。

`collect_phase5_debug_bundle.sh` / `verify_phase5_debug_bundle.sh` 是 Phase-5 排障包门禁：collector 默认跑一次 UDP selftest，同时开启 `--log-dir / --metrics-dir / --alerts-dir`，把 metadata、build config、git status、session config、runtime config dump、push/server/play 日志、metrics、alerts、timeline、first problem、metrics/alerts/timeline 汇总和 sha256 manifest 收集到一个目录；verifier 离线校验必需文件、JSON 字段、每个 role 的 `config_dump` 日志脱敏快照、弱网告警规则、首个告警/首个问题汇总、timeline、manifest、runtime config 脱敏标记，以及 bundle 中不能出现 payload/token/secret/password 类字段。

`verify_phase5_minimal_udp_external_app.sh` 是 Phase-5 外部最小 UDP 业务样板门禁：它先从当前源码安装一个临时 SDK prefix，再从 `examples/minimal_udp_app` 用 `find_package(WebRtcQosSdk)` 构建 sender/server/receiver/selftest，验证样板不 include SDK `src/` 或 WebRTC PeerConnection 内部头，并检查 selftest 生成三角色日志、metrics 和 alerts。

`verify_phase5_release_contract.sh` 是 Phase-5 发布契约门禁：它从当前源码安装临时 SDK prefix，检查 public headers、WebRTC adapter headers、role archives、role bundle archives 和 CMake package，再用外部 consumer 分别链接普通 `role_*` 与 `role_*_bundle` target，验证 runtime logging/metrics/alerts 字段和 PeerConnection-free 发布边界。

`run_phase5_implementation_gate.sh` 是 Phase-5 非生产实现证据 wrapper：它串起 no-selfmade、logging、metrics、alerts、error contract、minimal UDP external app、release contract 和 debug bundle 门禁，并在 `artifacts/phase5_implementation_gate/<utc_build_id>/` 下保留 summary、logs、关键运行产物、`files.txt` 和 `manifest.sha256`。`verify_phase5_implementation_gate.sh` 会离线复验所有子门禁 pass、三角色日志/metrics/alerts 产物、debug bundle manifest 和运行 JSON 统一身份字段，避免 completion audit 只相信脚本存在。

`verify_phase5_completion_audit.sh` 是 Phase-5 完成度审计入口：默认要求传入已通过的 `PHASE5_GATE_DIR` 并验证正式 production evidence；如果该 production gate 内包含 `phase5_implementation_gate/`，audit 会自动复验实现证据，也可以显式传 `PHASE5_IMPLEMENTATION_GATE_DIR`。本地可用 `REQUIRE_PRODUCTION_EVIDENCE=0` 审计“除正式生产证据外的 P5 实现项是否齐全”，但仍需要 implementation gate 证据，且不会把 P5 判定为生产完成。

## WebRTC-first Demo

已新增仓库内 demo：`webrtc_qos_webrtc_first_loopback_demo`。当前默认 source build 就会构建它；如果显式关闭 `WEBRTC_QOS_ENABLE_WEBRTC_FACADE`，该 demo 会随 facade 一起关闭。它直接使用 `VideoPushClient / ServerQosRouter / VideoPlayClient` 三个 role facade，不直接 include WebRTC adapter，也不使用旧自研 RTP/RTCP/pacer/video jitter 入口。当前默认会同时覆盖 `single_track` 和 `dual_track` 两组场景。

构建和运行：

```bash
cmake -S . -B build-webrtc-first \
  -DCMAKE_BUILD_TYPE=Release \
  -DWEBRTC_QOS_ENABLE_WEBRTC_FACADE=ON \
  -DWEBRTC_QOS_WEBRTC_MODULE_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64
cmake --build build-webrtc-first \
  --target webrtc_qos_webrtc_first_loopback_demo -j2
./build-webrtc-first/webrtc_qos_webrtc_first_loopback_demo
```

最新本地输出：

```text
backend=webrtc_first_facade transport=custom_bytes peer_connection=false
track_profile=single_track tracks=1
good_static_single_track ... decoded_tracks=1 ... pass=true
walking_dead_zone_recover_single_track ... decoded_tracks=1 ... pass=true
track_profile=dual_track tracks=2
good_static_dual_track ... decoded_tracks=2 ... pass=true
walking_dead_zone_recover_dual_track ... decoded_tracks=2 ... pass=true
```

这个 demo 的意义是补齐 Phase-2 的独立可运行入口：业务传输仍只是搬运 bytes，server 只做最小 relay/QoS router，弱网场景能触发 `NACK / retransmission`、rate cap 下探和恢复回升，并明确不创建 `PeerConnection`。

当前日志里的 `retransmission` 表示 `NACK + 原 RTP 包重传`，不是 RFC4588 RTX。

同时新增仓库内 UDP role demo：`webrtc_qos_webrtc_first_udp_demo`。它保留自动化 `selftest`，并提供独立 `sender/server/receiver` 三个进程模式，便于手工验证自定义 UDP transport 下的 WebRTC-first facade bytes 边界。当前默认 `selftest` 会同时覆盖 `single_track` 和 `dual_track` 两组场景，并输出总体 `udp_selftest profiles=single_track,dual_track pass=...` 结果。

业务外围只实现 UDP socket、packet envelope 和编解码/渲染时，推荐按 [最小 UDP 集成最佳实践](docs/minimal_udp_integration_best_practice.md) 接入 `VideoPushClient / ServerQosRouter / VideoPlayClient`，track 通过 `SessionConfig.video_tracks` 声明，不直接依赖 WebRTC `PeerConnection` 或内部 `AddTrack` API。

如果要看安装包外部工程形态，参考 [Minimal UDP App](examples/minimal_udp_app/README.md)。它只通过 `find_package(WebRtcQosSdk)` 链接 `role_*` 或 `role_*_bundle` target，提供 `minimal_udp_sender / minimal_udp_server / minimal_udp_receiver / minimal_udp_selftest` 四个入口，并支持 `--log-dir / --log-max-file-bytes / --log-max-files / --metrics-dir / --metrics-max-file-bytes / --metrics-max-files / --alerts-dir / --alerts-max-file-bytes / --alerts-max-files`。

```bash
cmake --build build-webrtc-first \
  --target webrtc_qos_webrtc_first_udp_demo -j2

# 单进程自动门禁：三个 localhost UDP socket 串起 sender/server/receiver。
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo selftest 36

# 显式启用 Phase-5 文件日志：生成 webrtc_qos_udp.{push,server,play}.*.log。
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 36 --log-dir /tmp/webrtc_qos_udp_logs

# 用低阈值验证日志轮转和 max_files 保留策略。
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 90 --log-dir /tmp/webrtc_qos_udp_logs \
  --log-max-file-bytes 512 --log-max-files 3

# 用极小异步队列验证高频日志不会阻塞媒体线程，丢弃计数会写入 dropped_log_count。
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 180 --log-dir /tmp/webrtc_qos_udp_logs \
  --log-max-queue-records 1

# 显式启用 Phase-5 metrics：生成 webrtc_qos_udp_metrics.{push,server,play}.*.jsonl。
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 36 --metrics-dir /tmp/webrtc_qos_udp_metrics

# 用低阈值验证 metrics 轮转和 max_files 保留策略。
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 90 --metrics-dir /tmp/webrtc_qos_udp_metrics \
  --metrics-max-file-bytes 1024 --metrics-max-files 3

# 显式启用 Phase-5 alerts：生成 webrtc_qos_udp_alerts.{push,server,play}.*.jsonl。
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 36 --alerts-dir /tmp/webrtc_qos_udp_alerts

# 用低阈值验证 alerts 轮转和 max_files 保留策略。
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  selftest 90 --alerts-dir /tmp/webrtc_qos_udp_alerts \
  --alerts-max-file-bytes 256 --alerts-max-files 3

# 三进程手工模式示例，端口可自行调整。
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  server 50000 127.0.0.1:50001 127.0.0.1:50002 90
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  receiver 50002 127.0.0.1:50000 90
./build-webrtc-first/webrtc_qos_webrtc_first_udp_demo \
  sender 50001 127.0.0.1:50000 90
```

`selftest` 最新本地输出显示 `transport=udp` 且 `peer_connection=false`，默认会依次输出 `udp_selftest_single_track decoded_tracks=1`、`udp_selftest_dual_track decoded_tracks=2` 和总体 `udp_selftest profiles=single_track,dual_track pass=true`；双轨场景下坏网阶段允许 shared source cap 把 `min_bad_fps` 拉到 `15`，同时仍要求弱网下探、恢复回升和 `NACK / retransmission` 链路成立。独立角色 smoke 输出分别为 `udp_sender tracks=2`、`udp_server tracks=2`、`udp_receiver tracks=2`，用于确认 demo 不再只有单进程入口，也不再退回单轨 profile。

## CMake 集成

```cmake
find_package(WebRtcQosSdk REQUIRED CONFIG)

add_executable(app main.cc)
target_link_libraries(app PRIVATE WebRtcQosSdk::role_push)
```

可用 role targets：

```text
WebRtcQosSdk::role_transport
WebRtcQosSdk::role_push
WebRtcQosSdk::role_play
WebRtcQosSdk::role_server
```

`role_push`、`role_play`、`role_server` 只有在 facade 实现库 `libwebrtc_qos_facade_video.a` 和对应 WebRTC 模块库都存在时才会创建；缺少实现时不导出半可用 role target。

如果你想要更“大”的静态库，而不是在业务侧继续链接多份底层 `.a`，当前安装包也会导出按角色聚合后的 bundle：

```text
WebRtcQosSdk::role_push_bundle
WebRtcQosSdk::role_play_bundle
WebRtcQosSdk::role_server_bundle
```

这几个 bundle 会把当前角色实际用到的 SDK 静态库和 WebRTC 子模块 archive 合并成单个 `.a` 文件；外部工程仍只需要再补系统库依赖（`Threads::Threads`、`dl`、`rt`、`atomic`）。

如果你要接入当前默认 multi-track 能力，发送端和接收端已经支持：

- `SessionConfig.video_tracks`
- `AnnexBAccessUnitView.ids.{source_id,track_id,sender_ssrc}`
- `VideoPushClient::GetTrackEncoderAdaptation(...)`
- `VideoPushClient::GetTrackQosSnapshot(...)`
- `VideoPlayClient::GetTrackQosSnapshot(...)`

底层 WebRTC module targets：

```text
WebRtcQosSdk::webrtc_googcc
WebRtcQosSdk::webrtc_pacing
WebRtcQosSdk::webrtc_rtp_rtcp
WebRtcQosSdk::webrtc_video_jitter
WebRtcQosSdk::webrtc_nack_requester
WebRtcQosSdk::transport_packet_history
```

## WebRTC-first 弱网矩阵

当前已新增 `scripts/run_webrtc_first_facade_matrix.sh`，直接驱动发布包里的 `VideoPushClient / ServerQosRouter / VideoPlayClient`，不依赖旧 Phase-1a 自研 RTP/RTCP/pacer/video demo。

运行命令：

```bash
FRAMES=36 PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/run_webrtc_first_facade_matrix.sh
```

最新本地结果写入 `artifacts/webrtc_first_facade_matrix/webrtc_first_facade_matrix.csv`：

```text
scenario,ticks,frames_pushed,decoded_frames,playable_ratio,bad_send_ratio,recovery_send_ratio,rtp_sent,rtp_to_server,rtp_to_play,rtp_dropped_downlink,rtcp_twcc,rtcp_rr,rtcp_nack,rtcp_pli,retransmissions,selected_receiver_id,rate_cap_reason,bad_selected_receiver_id,bad_rate_cap_reason,min_target_bps,final_target_bps,min_encoder_fps,final_encoder_fps,bad_send_rps,bad_rtp_pps,recovery_send_rps,recovery_rtp_pps,min_bad_target_bps,max_bad_target_bps,max_recovery_target_bps,min_bad_encoder_fps,max_bad_encoder_fps,max_recovery_encoder_fps,max_rtt_ms,pass
good_static,36,36,36,1,0,0,108,108,108,0,18,2,0,0,0,0,0,0,0,1200000,1207178,30,30,0,0,0,0,0,0,0,0,0,0,0,true
burst_loss_recover,36,36,36,1,1,1,108,108,108,5,18,2,5,0,5,0,0,0,0,1200000,1207178,30,30,30,90,30,90,1207178,1207178,1207178,30,30,30,0,true
bandwidth_cliff_low_rps_recover,36,30,30,1,0.4,1,90,90,90,0,16,2,0,0,0,8738,0,0,0,600000,1207178,10,30,12,36,30,90,600000,600000,1207178,10,10,30,0,true
weak_network_low_rps_low_bitrate,36,24,24,1,0.368421,1,72,72,72,0,15,2,0,0,0,8738,0,0,0,600000,1207178,10,30,11.0526,33.1579,30,90,600000,600000,1207178,10,10,30,0,true
multi_receiver_worst_cap_recover,36,30,30,1,0.4,1,90,90,90,0,16,2,0,0,0,8739,0,8738,1,600000,1207178,10,30,12,36,30,90,600000,600000,1207178,10,10,30,0,true
walking_dead_zone_recover,36,30,30,1,0.4,1,90,90,90,12,16,2,1,0,12,8738,0,0,0,600000,1207178,10,30,12,36,30,90,600000,600000,1207178,10,10,30,0,true
sustained_low_bandwidth_low_rps,36,18,18,1,0.333333,0,54,54,54,0,13,2,0,0,0,8738,2,0,0,600000,600000,10,10,10,30,0,0,600000,600000,0,10,10,0,0,true
weak_start_low_bandwidth_low_rps,36,12,12,1,0.333333,0,36,36,36,0,12,2,0,0,0,8738,2,0,0,600000,600000,10,10,10,30,0,0,600000,600000,0,10,10,0,0,true
```

弱网矩阵必须显式覆盖“弱网情况下以较低 RPS 和较低码率发送”。这不是定性观察，也不是只看某个瞬时最低点；所有 weak-low 场景都要按弱网窗口最大值验收 `bad_send_rps / bad_rtp_pps / max_bad_target_bps / max_bad_encoder_fps`，证明发送端在整个弱网阶段持续低 AU 发送频率、低 RTP 包速率、低目标码率和低 encoder FPS。

- `bandwidth_cliff_low_rps_recover` 覆盖“带宽突然降低但不丢包”的场景：弱网阶段 AU 发送频率降到 `12 RPS`、RTP 发送降到 `36 pps`、目标码率降到 `600000bps`、encoder FPS 建议降到 `10fps`；恢复阶段 AU 发送频率回到 `30 RPS`、RTP 发送回到 `90 pps`、目标码率回到约 `1207178bps`、FPS 回到 `30fps`。
- `weak_network_low_rps_low_bitrate` 专门覆盖“弱网期间必须低 RPS + 低码率发送，网络恢复后必须回升”的场景：弱网窗口更长，发送端仍必须保持不高于 `15 AU RPS / 45 RTP pps / 600000bps / 10fps`，当前结果为 `11.0526 RPS / 33.1579 pps / 600000bps / 10fps`；恢复段回到 `30 RPS / 90 pps / 1207178bps / 30fps`。
- `multi_receiver_worst_cap_recover` 覆盖“多播放端里一个 receiver 变差”的场景：坏 receiver 在弱网窗口内通过 `bad_selected_receiver_id=8738 / bad_rate_cap_reason=1` 被选为 worst receiver，健康 receiver 的上报不能清掉 sender cap；恢复后回到无限速并恢复到 `1207178bps / 30fps`。
- `walking_dead_zone_recover` 覆盖“走入弱覆盖区域，带宽下降并伴随下行全丢/重传恢复”的场景：弱网阶段同样降到 `12 RPS / 36 pps / 600000bps / 10fps`，恢复后回到 `30 RPS / 90 pps / 1207178bps / 30fps`，同时验证 NACK 和 server 本地重传。
- `sustained_low_bandwidth_low_rps` 覆盖“进入弱网后一直没有恢复”的场景：从 1/4 流时长开始持续低带宽，发送端必须维持不高于 `15 AU RPS`、不高于 `45 RTP pps`、不高于 `600000bps`、不高于 `10fps`，最终也不能自行回升。
- `weak_start_low_bandwidth_low_rps` 覆盖“开局就是弱网”的场景：第 0 帧起持续低带宽，发送端不能先按好网码率冲一段，必须直接进入不高于 `15 AU RPS / 45 RTP pps / 600000bps / 10fps` 的低发送模式。

为了避免这个要求只埋在大矩阵里，仓库还提供独立门禁：

```bash
WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/run_webrtc_first_qoe_low_rps_low_bitrate_check.sh
```

它会同时跑 synthetic facade 矩阵中的 `weak_network_low_rps_low_bitrate` 和一条真实 H264 QoE low-RPS/low-bitrate case，并生成 `artifacts/webrtc_first_low_rps_low_bitrate_check/webrtc_first_low_rps_low_bitrate_summary.txt`。切到 WebRTC `PacingController` 最小闭包后的本地复测结果：facade 弱网窗口 `11.0526 AU RPS / 33.1579 RTP pps / 600000bps / 10fps`；真实 H264 QoE 弱网窗口 `10.9091 AU RPS / 92.7273 RTP pps / 400000bps / 10fps`，恢复后 `30 RPS / 840944bps / 30fps`，`playable_ratio=0.923077`、`avg_psnr_y=45.7965`、`avg_ssim_y=0.999829`。

## 真实编解码 QoE

已新增可选脚本 `scripts/run_webrtc_first_ffmpeg_qoe.sh`。它不会进入默认 SDK 依赖闭包；脚本运行时会临时构建可选 FFmpeg H264 encoder/decoder 库，并叠加当前 WebRTC-first 发布包，跑真实 H264 encode -> push/server/play facade ->真实 H264 decode。

运行命令：

```bash
FRAMES=30 WIDTH=160 HEIGHT=90 \
  WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/run_webrtc_first_ffmpeg_qoe.sh
```

最新本地结果写入 `artifacts/webrtc_first_ffmpeg_qoe/webrtc_first_ffmpeg_qoe.csv`：

```text
scenario,seed,source_frames,encoded_frames,pushed_frames,push_queue_full,decoded_frames,playable_ratio,rtp_dropped_downlink,nacks,retransmissions,decode_errors,avg_psnr_y,min_psnr_y,avg_ssim_y,min_ssim_y,freeze_count,freeze_duration_ms,max_inter_render_gap_ms,bad_send_rps,bad_rtp_pps,recovery_send_rps,recovery_rtp_pps,min_target_bps,final_target_bps,min_encoder_fps,final_encoder_fps,min_bad_target_bps,max_bad_target_bps,max_recovery_target_bps,min_bad_encoder_fps,max_bad_encoder_fps,max_recovery_encoder_fps,target_recovery_time_ms,fps_recovery_time_ms,full_recovery_time_ms,max_recovery_time_ms,pass
baseline,1,30,30,30,0,29,0.966667,0,0,0,0,49.1338,46.7009,0.9999,0.9998,0,0,33,0,0,0,0,400000,430829,30,30,0,0,0,0,0,0,-1,-1,-1,1000,true
```

这证明当前 WebRTC-first bytes 链路可以承载真实 H264 编码输出，并被真实 H264 解码器消费。脚本现在会按 `VideoPushClient::GetEncoderAdaptation()` 调整真实 FFmpeg 编码器的码率/FPS，并支持 `SCENARIOS="baseline bandwidth_cliff_recover weak_network_low_rps_low_bitrate sustained_low_bandwidth_low_rps weak_start_low_bandwidth_low_rps walking_dead_zone_recover"` 这类多场景聚合。QoE harness 已新增 SSIM-Y 作为 VMAF 的轻量替代画质指标，CSV 输出 `avg_ssim_y / min_ssim_y`，并通过 `MIN_AVG_SSIM_Y` 参与 pass/fail，默认普通内容门槛为 `0.80`、高复杂 stress 为 `0.55`。QoE harness 还包含 renderer 前置的 freeze proxy 和 renderer proxy：前者按 decoded frame 原始帧序号间隔统计 `freeze_count / freeze_duration_ms / max_inter_render_gap_ms`，门禁要求 `freeze_count=0`；后者按 RTP timestamp 映射的 capture time 模拟固定播放延迟调度，默认 `350ms` target delay、`500ms` hard latency、`0` late/drop frame，并输出 `renderer_proxy_avg/max_latency_ms`、`renderer_proxy_avg/max_gap_ms`、`renderer_proxy_avg/max_jitter_ms`，其中 `MAX_RENDERER_PROXY_GAP_MS` 默认 `150ms`，用于把“不卡顿”变成播放间隔门禁。当前 renderer gap smoke 中 baseline `max_gap=34ms / max_jitter=0ms`，weak-network low-RPS low-bitrate `max_gap=100ms / max_jitter=67ms`，均通过 `150ms` 门槛。它还会输出 `max_bad_target_bps / max_bad_encoder_fps / target_recovery_time_ms / fps_recovery_time_ms / full_recovery_time_ms`，并通过 `MAX_WEAK_SEND_RPS / MAX_WEAK_RTP_PPS / MAX_WEAK_TARGET_BPS / MAX_WEAK_ENCODER_FPS / MAX_RECOVERY_TIME_MS` 配置弱网低发送和恢复门槛。真实 H264 QoE 的弱网低发送门槛为不高于 `15 AU RPS / 150 RTP pps / 600000bps / 10fps`，RTP pps 阈值高于 synthetic 矩阵是因为真实 720p H264 一帧会拆成更多 RTP 包；弱网验收以 720p wrapper 脚本为准，160x90 baseline 只作为真实编解码 smoke。

真实 renderer 不能继续和 renderer proxy 混为一谈。已新增 `scripts/verify_real_renderer_smoke.sh`：有 `DISPLAY` 且可链接 X11 时，它会创建真实 X11 window，按 30fps present 帧并输出 `rendered_frames / late_frames / avg_present_gap_ms / max_present_gap_ms / avg_present_jitter_ms / max_present_jitter_ms`；没有 `DISPLAY` 但存在 `Xvfb` 时，脚本会自动启动 headless X11 server 跑同一套 X11 present smoke，用于 CI 覆盖窗口 present 代码路径；两者都不可用时默认写出 skipped 证据，设置 `REQUIRE_REAL_RENDERER=1` 则直接失败。当前机器没有 `DISPLAY/WAYLAND_DISPLAY`，也没有 `Xvfb`，所以本地结果是：

```text
real_renderer_status=skipped
reason=DISPLAY is not set and Xvfb is not available
xvfb_available=0
```

这说明当前 QoE 结论仍以 renderer proxy 播放调度为准，不能声明已经完成真实 GPU/窗口 renderer 验收；但真实 renderer/Xvfb renderer 的可选门禁入口已经具备。

两个实现规则已经写入测试：`VideoPushClient::Process(now_us)` 必须由业务 worker/task queue 周期性驱动，不能只在有新 AU 时调用，否则低 FPS 弱网段会让 pacer 队列不及时出包；play facade 输出 AU 的 `capture_time_us` 必须来自 RTP timestamp 映射后的 media time，QoE/renderer 才能按真实 PTS 对齐参考帧，而不是按解码顺序误判画质。

## 720p QoE 稳定性

已新增 `scripts/run_webrtc_first_qoe_stability_720p.sh`。它基于同一个真实 FFmpeg QoE harness，默认跑 1280x720、30 tick、baseline / bandwidth cliff / weak-network low-RPS low-bitrate / sustained low-bandwidth / weak-start low-bandwidth / walking dead-zone 六个场景，并验证真实编码器在弱网段降码率、降 FPS、降 RPS，恢复段回升；持续弱网和弱网起步场景还要求最终保持低 RPS、低码率和低 FPS。

运行命令：

```bash
WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/run_webrtc_first_qoe_stability_720p.sh
```

最新本地结果写入 `artifacts/webrtc_first_qoe_stability_720p/webrtc_first_qoe_stability_720p.csv`：

```text
scenario,seed,decoded_frames,playable_ratio,decode_errors,avg_psnr_y,freeze_count,freeze_duration_ms,max_inter_render_gap_ms,bad_send_rps,bad_rtp_pps,recovery_send_rps,final_target_bps,final_encoder_fps,max_bad_target_bps,max_bad_encoder_fps,full_recovery_time_ms,pass
baseline,1,29,0.966667,0,29.8579,0,0,33,0,0,0,1282455,30,0,0,-1,true
bandwidth_cliff_recover,1,22,0.916667,0,30.247,0,0,100,10,90,30,1280451,30,600000,10,0,true
weak_network_low_rps_low_bitrate,1,18,0.947368,0,29.9562,0,0,100,9.375,78.75,30,1260990,30,600000,10,0,true
sustained_low_bandwidth_low_rps,1,14,1,0,30.0861,0,0,100,9.13043,80.8696,0,600000,10,600000,10,-1,true
weak_start_low_bandwidth_low_rps,1,10,1,0,30.899,0,0,100,10,90,0,600000,10,600000,10,-1,true
walking_dead_zone_recover,1,22,0.916667,0,30.2242,0,0,100,10,90,30,1280451,30,600000,10,0,true
```

这组结果说明：720p 真实编码链路在带宽 cliff、weak-network low-RPS、持续弱网、弱网起步和 dead-zone 弱网段会持续降到不高于 `600000bps / 10fps / 10 RPS`，不是只瞬时触底；新增 `weak_network_low_rps_low_bitrate` 明确验证弱网窗口内以 `9.375 RPS / 78.75 RTP pps / 600000bps / 10fps` 低速发送，恢复段回到 `30 RPS / 1260990bps / 30fps`；可恢复场景 `full_recovery_time_ms=0` 且门槛为不超过 `1000ms`；持续弱网和弱网起步场景最终必须继续保持低码率和低 FPS；dead-zone 场景还验证了 NACK 和 server 本地重传。当前 freeze proxy 全部为 `0`，最大 decoded frame 间隔不超过 `100ms`。它仍不是完整生产 QoE 体系，因为还缺真实 renderer、生产级多小时 soak 和更丰富的真实内容库。

## 720p 多 Seed QoE

已新增 `scripts/run_webrtc_first_qoe_multiseed_720p.sh`。它默认跑 1280x720、30 tick、3 个 deterministic seed、baseline / bandwidth cliff / weak-network low-RPS low-bitrate / sustained low-bandwidth / weak-start low-bandwidth / walking dead-zone 六个场景，覆盖内容运动相位和丢包相位变化。

运行命令：

```bash
WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/run_webrtc_first_qoe_multiseed_720p.sh
```

最新完整本地结果写入 `artifacts/webrtc_first_qoe_multiseed_720p/webrtc_first_qoe_multiseed_720p.csv`，18 个 case 全部通过。汇总如下：

```text
cases=18/18 pass
playable_ratio_min=0.875
avg_psnr_y_min=28.6765
min_psnr_y_min=19.7343
decode_errors=0
freeze_count=0
freeze_duration_ms=0
max_inter_render_gap_ms<=100
push_queue_full=0
dead_zone_nack=1 per seed
dead_zone_retransmission=27..28 per seed
weak_network_bad_send_rps=9.375
weak_network_bad_rtp_pps=80.625..90
weak_network_final_target_bps=1260893..1287137
weak_network_full_recovery_time_ms=0
sustained_bad_send_rps=9.13043
sustained_final_target_bps=600000
sustained_final_encoder_fps=10
weak_start_bad_send_rps=10
weak_start_bad_rtp_pps=88..93
weak_start_final_target_bps=600000
weak_start_final_encoder_fps=10
recover_bad_send_rps=10
recover_recovery_send_rps=30
bad_target_bps=600000
recovery_target_bps=1280451
```

多 seed 首轮曾用逐像素高频内容作为 seed 变化，结果在 720p/1.2Mbps 下 PSNR 明显不达标。该高频内容不适合作为稳定性门禁，已改为块状运动内容；高频内容应单独作为后续 stress/码率策略验证项。

## 长流动态 QoE

已新增 `scripts/run_webrtc_first_qoe_long_dynamic.sh`。它默认跑 1280x720、60 tick、baseline / bandwidth cliff / weak-network low-RPS low-bitrate / sustained low-bandwidth / weak-start low-bandwidth / walking dead-zone / oscillating edge 七个场景；`oscillating_edge_recover` 会在弱网和恢复之间反复切换，用来验证进入弱网能降码率/FPS，网络恢复后能多次回升。

运行命令：

```bash
WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/run_webrtc_first_qoe_long_dynamic.sh
```

最新完整本地结果写入 `artifacts/webrtc_first_qoe_long_dynamic/webrtc_first_qoe_long_dynamic.csv`，7 个 case 全部通过：

```text
scenario,seed,decoded_frames,playable_ratio,decode_errors,avg_psnr_y,freeze_count,freeze_duration_ms,max_inter_render_gap_ms,bad_send_rps,bad_rtp_pps,recovery_send_rps,final_target_bps,final_encoder_fps,pass
baseline,1,59,0.983333,0,30.1334,0,0,33,0,0,0,1393569,30,true
bandwidth_cliff_recover,1,49,0.98,0,30.2689,0,0,100,11.25,135,30,1386438,30,true
weak_network_low_rps_low_bitrate,1,39,0.975,0,30.461,0,0,100,10.6452,103.548,30,1327376,30,true
sustained_low_bandwidth_low_rps,1,30,1,0,30.0479,0,0,100,10,93.3333,0,600000,10,true
weak_start_low_bandwidth_low_rps,1,20,1,0,30.7446,0,0,100,10,89,0,600000,10,true
walking_dead_zone_recover,1,49,0.98,0,30.3675,0,0,100,11.25,136.875,30,1386438,30,true
oscillating_edge_recover,1,46,0.978723,0,30.8201,0,0,100,10.5,148.5,30,1386544,30,true
```

实现结论：新增 `weak_network_low_rps_low_bitrate` 在 60 tick 下弱网段保持 `10.6452 RPS / 103.548 RTP pps / 600000bps / 10fps`，恢复段回到 `30 RPS / 1327376bps / 30fps`；持续弱网和弱网起步场景最终保持 `600000bps / 10fps / 10 RPS`，不自行回升；oscillating 场景能在弱网和恢复之间多次下探/回升，最坏弱网 RTP pps 为 `148.5`，仍在真实 H264 QoE 门槛内。所有长流动态 case 的 freeze proxy 均为 `0`，最大 decoded frame 间隔不超过 `100ms`，`push_queue_full=0`。当 sender rate cap 明显下降时，SDK 会丢弃 pacer 中已经过期的 queued live media、请求下一帧 IDR，并把 RTP/TWCC 序号滚动到最后实际发出的包之后，避免旧队列污染实时链路。

## 720p Extended Soak QoE

已新增 `scripts/run_webrtc_first_qoe_soak_720p.sh`。它默认跑 1280x720、120 tick baseline，并用更长的 bandwidth cliff / weak-network low-RPS low-bitrate / sustained low-bandwidth / weak-start low-bandwidth / walking dead-zone / oscillating edge 场景验证长一点的真实 H264 QoE 稳定性。

运行命令：

```bash
WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/run_webrtc_first_qoe_soak_720p.sh
```

最新完整本地结果写入 `artifacts/webrtc_first_qoe_soak_720p/webrtc_first_qoe_soak_720p.csv`，7 个 case 全部通过：

```text
scenario,seed,decoded_frames,playable_ratio,decode_errors,avg_psnr_y,min_psnr_y,freeze_count,max_inter_render_gap_ms,bad_send_rps,bad_rtp_pps,recovery_send_rps,recovery_rtp_pps,final_target_bps,final_encoder_fps,pass
baseline,1,118,0.983333,0,30.6671,25.3741,0,33,0,0,0,0,1625457,30,true
bandwidth_cliff_recover,1,98,0.98,0,31.0946,28.9151,0,100,10.6452,114.194,30,227.288,1556211,30,true
weak_network_low_rps_low_bitrate,1,78,0.975,0,30.3911,25.5781,0,100,10.3279,98.3607,30,214.138,1418928,30,true
sustained_low_bandwidth_low_rps,1,59,0.983333,0,29.9071,24.3764,0,100,10,91,0,0,600000,10,true
weak_start_low_bandwidth_low_rps,1,40,1,0,30.0456,24.8773,0,100,10,87.75,0,0,600000,10,true
walking_dead_zone_recover,1,98,0.98,0,31.0879,28.9151,0,100,10.6452,114.194,30,226.78,1556211,30,true
oscillating_edge_recover,1,94,0.979167,0,29.8947,13.3985,0,100,10.5405,137.838,30,231.356,1608862,30,true
```

这组 extended soak 结果把你的要求转成了可量化门禁：进入弱网时必须把真实编码发送压到不高于 `15 AU RPS / 150 RTP pps / 600000bps / 10fps`；新增 `weak_network_low_rps_low_bitrate` 在 120 tick 下弱网段保持 `10.3279 RPS / 98.3607 RTP pps / 600000bps / 10fps`，恢复到 `30 RPS / 214.138 RTP pps / 1418928bps / 30fps`；持续弱网或弱网起步时不能自行回升。当前 7/7 通过，所有 case `decode_errors=0`、`freeze_count=0`、`push_queue_full=0`。

## Production Soak QoE

已新增 `scripts/run_webrtc_first_qoe_production_soak.sh`，用于把真实 H264 QoE 矩阵包装成可重复运行的生产 soak runner。它可以按 `SOAK_CYCLES` 固定轮数运行，也可以按 `SOAK_MINUTES` 做 wall-clock soak；每轮都会调用 `run_webrtc_first_ffmpeg_qoe.sh`，最后聚合所有 cycle 的 CSV，并把 `decode_errors / freeze_count / renderer_proxy_late/drop / push_queue_full / 弱网低发送 / 恢复时间` 汇总成 pass/fail 门禁。弱网低发送不是只看单行 `pass=true`，runner 和 archive verifier 会再次按 `MAX_WEAK_SEND_RPS / MAX_WEAK_RTP_PPS / MAX_WEAK_TARGET_BPS / MAX_WEAK_ENCODER_FPS` 复查所有 weak-low 场景，确保弱网窗口内持续低 RPS、低 RTP pps、低码率和低 FPS。

runner 现在还会生成可归档证据链：`webrtc_first_qoe_production_soak_config.env`、`archive/metadata.txt`、`archive/git_status.txt`、`archive/manifest.sha256`、每个 cycle 的 CSV/log，以及 `webrtc_first_qoe_production_soak_archive.tar.gz`。离线校验入口：

```bash
OUTPUT_DIR=/path/to/soak/output \
  scripts/verify_webrtc_first_qoe_production_soak_archive.sh
```

短时 smoke 命令：

```bash
SOAK_CYCLES=1 FRAMES_PER_CYCLE=12 WIDTH=160 HEIGHT=90 \
START_BITRATE_BPS=400000 MIN_BITRATE_BPS=150000 MAX_BITRATE_BPS=800000 \
MIN_AVG_PSNR_Y=15 MIN_PLAYABLE_RATIO=0.75 \
MAX_WEAK_TARGET_BPS=300000 MAX_WEAK_RTP_PPS=180 \
CONTENT_MODES=block_motion \
SCENARIOS="baseline weak_network_low_rps_low_bitrate" \
WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/run_webrtc_first_qoe_production_soak.sh
```

当前 low-RPS archive smoke 写入 `artifacts/webrtc_first_qoe_production_soak_low_rps_smoke/`，结果为：

```text
cycles=1
rows=2
pass_rows=2
playable_ratio_min=1
avg_psnr_y_min=49.3455
avg_ssim_y_min=0.999931
decode_errors=0
freeze_count=0
renderer_proxy_late_frames=0
renderer_proxy_drop_frames=0
renderer_proxy_max_gap_ms=100
renderer_proxy_max_jitter_ms=67
push_queue_full=0
bad_send_rps_max=12.8571
bad_rtp_pps_max=60
max_bad_target_bps_max=200000
max_bad_encoder_fps_max=10
weak_low_rows=1
weak_low_bad_send_rps_max=12.8571
weak_low_bad_rtp_pps_max=60
weak_low_target_bps_max=200000
weak_low_encoder_fps_max=10
full_recovery_time_ms_max=0
recoverable_rows=1
target_recovery_time_ms_p95=0
fps_recovery_time_ms_p95=0
full_recovery_time_ms_p95=0
archive_verification=true
recovery_distribution_verification=true
```

这个脚本已经具备生产级多轮/多分钟 soak 的执行入口和归档/验签入口；真正的“多小时”结论还需要在稳定机器上用 `SOAK_MINUTES=120` 或更长时间实际跑完，并把 tarball、summary 和日志归档。

完成度审计命令：

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

PHASE5_DRY_RUN=1 \
  OUTPUT_ROOT=/tmp/webrtc_qos_phase5_production_gate_dry_run \
  scripts/run_phase5_production_gate.sh
GATE_DIR=/tmp/webrtc_qos_phase5_production_gate_dry_run \
  scripts/verify_phase5_production_gate.sh
```

这个审计脚本会读取 smoke/qoe summary、production soak summary/config/archive、real renderer summary 和 capture manifest summary，并复用 production soak archive verifier 校验 sha256 manifest、row pass、弱网低 RPS/低码率和恢复时间分布。它的默认 production 输入路径是 `artifacts/webrtc_first_phase2_verify_production/`，也可以通过 `EVIDENCE_BUNDLE_DIR` 审计收集好的 bundle。当前只有短时 production smoke、renderer skipped 和 fixture capture 时会失败，这是预期结果；失败 summary 会写出还缺哪类证据。

如果要在正式机器上一键跑完整验收，直接使用：

```bash
SOAK_MINUTES=120 \
CAPTURE_LIBRARY_DIR=/path/to/business_capture_library \
CAPTURE_LIBRARY_MANIFEST=/path/to/business_capture_library/manifest.csv \
OUTPUT_ROOT=/path/to/output/phase5_production_gate \
  scripts/run_phase5_production_gate.sh

GATE_DIR=/path/to/output/phase5_production_gate \
REQUIRE_PASS=1 \
  scripts/verify_phase5_production_gate.sh

PHASE5_GATE_DIR=/path/to/output/phase5_production_gate \
  scripts/verify_phase5_completion_audit.sh
```

已新增恢复时间分布门禁 `scripts/verify_recovery_time_distribution.sh`。它读取一个或多个 QoE CSV，默认只统计可恢复场景 `bandwidth_cliff_recover / weak_network_low_rps_low_bitrate / walking_dead_zone_recover / oscillating_edge_recover`，输出 `target/fps/full_recovery_time_ms` 的 p50/p95/max，并按 p95 和 max 门槛失败。production soak archive verifier 会自动调用它，并把 `archive/recovery_distribution_summary.txt` 纳入 sha256 manifest 和 tarball。

## 720p 高复杂内容 Stress QoE

已新增 `scripts/run_webrtc_first_qoe_high_complexity_720p.sh`。它复用真实 FFmpeg QoE harness，但把内容模式切到 `CONTENT_MODE=stress`：移动高频棋盘、斜向细节和确定性噪声叠加，用来验证高复杂内容下 QoS 仍能降码率/FPS/RPS、恢复回升、保持可播放和无 freeze。

运行命令：

```bash
WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/run_webrtc_first_qoe_high_complexity_720p.sh
```

最新本地结果写入 `artifacts/webrtc_first_qoe_high_complexity_720p/webrtc_first_qoe_high_complexity_720p.csv`，8 个 case 全部通过。汇总如下：

```text
cases=8/8 pass
content_mode=stress
seeds=1,2
scenarios=baseline,bandwidth_cliff_recover,walking_dead_zone_recover,oscillating_edge_recover
playable_ratio_min=0.851064
avg_psnr_y_min=15.5423
min_psnr_y_min=12.7144
decode_errors=0
freeze_count=0
freeze_duration_ms=0
push_queue_full=0
bad_send_rps_max=11.25
bad_rtp_pps_max=220.5
bad_target_bps=900000
bad_encoder_fps=10
recovery_send_rps=30
recovery_target_bps=2079075..2089773
recovery_encoder_fps=30
full_recovery_time_ms=0
dead_zone_nack=1 per seed
dead_zone_retransmission=96..102
oscillating_nack=13..15
oscillating_retransmission=13..15
```

高复杂内容的门槛故意和普通 720p 稳定性分开：它要求 `playable_ratio>=0.75`、`avg_psnr_y>=15dB`、`decode_errors=0`、`freeze_count=0`，弱网段不高于 `15 AU RPS / 240 RTP pps / 900000bps / 10fps`，并且 `max_bad_target_bps` 和 `max_bad_encoder_fps` 在整个弱网窗口内都不能超过上限；恢复段回到 `30 AU RPS / 2Mbps+ / 30fps`，`full_recovery_time_ms<=1000ms`。这里的 RTP pps 和弱网码率上限高于普通内容，是因为 stress 内容每帧 RTP 分片显著更多，且 1.8Mbps 起始码率下 server 当前半码率 rate cap 会落到 `900000bps`。

## 720p 内容库 QoE

已新增 `scripts/run_webrtc_first_qoe_content_library_720p.sh`。它复用真实 FFmpeg QoE harness，但一次覆盖多种 deterministic 内容：`block_motion`、`camera_pan`、`scene_cut`、`low_light_noise`。场景覆盖 baseline、weak-network low-RPS low-bitrate、walking dead-zone recover、oscillating edge recover，用来验证不同画面类型下进入弱网能持续低 RPS/低码率发送，网络恢复后能回升，同时不出现 decode error 或 freeze。

运行命令：

```bash
WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/run_webrtc_first_qoe_content_library_720p.sh
```

最新本地结果写入 `artifacts/webrtc_first_qoe_content_library_720p/webrtc_first_qoe_content_library_720p.csv`，16 个 case 全部通过。汇总如下：

```text
cases=16/16 pass
content_modes=block_motion,camera_pan,scene_cut,low_light_noise
scenarios=baseline,weak_network_low_rps_low_bitrate,walking_dead_zone_recover,oscillating_edge_recover
playable_ratio_min=0.942857
avg_psnr_y_min=31.384
min_psnr_y_min=19.4395
decode_errors=0
freeze_count=0
push_queue_full=0
renderer_proxy_late_frames=0
renderer_proxy_drop_frames=0
renderer_proxy_max_latency_ms=468
renderer_proxy_target_delay_ms=350
renderer_proxy_latency_budget_ms=500
renderer_proxy_max_gap_ms=150
bad_send_rps_max=11.25
bad_rtp_pps_max=191.25
bad_target_bps=750000
bad_encoder_fps=10
full_recovery_time_ms=0
max_inter_render_gap_ms=100
```

内容库门槛独立于普通稳定性和 high-complexity stress：弱网段要求不高于 `15 AU RPS / 210 RTP pps / 750000bps / 10fps`，恢复段要求回到 `30 AU RPS / 1.5Mbps+ / 30fps`。`210 RTP pps` 是根据内容库中 `low_light_noise + oscillating_edge_recover` 的真实 RTP 分片结果校准的，仍低于高复杂 stress 的 `240 RTP pps` 门槛。新增的低 RPS/低码率场景在四类内容下均保持约 `10.4348 AU RPS / 108.261..117.391 RTP pps / 750000bps / 10fps`，恢复段回到 `30 AU RPS / 1.55..1.63Mbps / 30fps`，并且 renderer proxy 在 `500ms` 播放预算内 `late=0/drop=0`。

## 真实采集内容库 QoE

已新增 `scripts/run_webrtc_first_qoe_capture_library_720p.sh`，用于把真实采集素材接入同一套真实 FFmpeg QoE harness。脚本会扫描 `CAPTURE_LIBRARY_DIR` 下的 `.mp4 / .mov / .mkv / .webm / .yuv / .i420` 文件：视频文件先用系统 `ffmpeg -nostdin` 转成 720p30 raw I420，raw 文件直接按 `WIDTH x HEIGHT` I420 读取；随后以 `capture_i420:<label>:<path>` 内容源跑真实 H264 encode -> WebRTC-first push/server/play -> 真实 H264 decode -> QoE/renderer proxy 门禁。

采集库现在支持 `manifest.csv` 覆盖门禁，并提供独立校验脚本：

```bash
CAPTURE_LIBRARY_DIR=/path/to/captured/videos \
  scripts/verify_capture_library_manifest.sh
```

manifest 至少需要 `category,path` 两列，可选 `label,enabled`。默认要求六类正式素材都存在且文件路径不能重复冒充多类：`indoor_face / outdoor_walking / low_light_noise / screen_text / high_motion / scene_cut`。视频文件会用 `ffprobe` 检查存在视频流和最小时长；raw `.yuv/.i420` 会按 `CAPTURE_WIDTH x CAPTURE_HEIGHT x MIN_CAPTURE_FRAMES` 检查大小。完整 QoE 跑法可以打开强门禁：

```bash
CAPTURE_LIBRARY_DIR=/path/to/captured/videos \
REQUIRE_CAPTURE_MANIFEST=1 \
WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/run_webrtc_first_qoe_capture_library_720p.sh
```

如果业务真实素材库还没准备好，可以先生成一套 deterministic fixture 采集库，用来复现 manifest、转码和 QoE 门禁链路：

```bash
CAPTURE_LIBRARY_DIR=/root/webrtc_qos_sdk/artifacts/capture_library_fixture \
  scripts/generate_capture_library_fixture.sh
```

运行命令：

```bash
CAPTURE_LIBRARY_DIR=/path/to/captured/videos \
WEBRTC_PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
  scripts/run_webrtc_first_qoe_capture_library_720p.sh
```

当前本地 fixture smoke 使用 `scripts/generate_capture_library_fixture.sh` 生成 6 类 mp4 素材，先通过 manifest 校验，再跑 baseline QoE。最新 Phase-2 聚合门禁结果写入 `artifacts/webrtc_first_phase2_verify_capture_fixture/capture_library/webrtc_first_qoe_capture_library_720p.csv`：

```text
manifest_entries=6
categories=high_motion,indoor_face,low_light_noise,outdoor_walking,scene_cut,screen_text
cases=6/6 pass
scenario=baseline
decoded_frames_min=10
playable_ratio_min=0.833333
avg_psnr_y_min=42.6753
avg_ssim_y_min=0.998468
decode_errors=0
freeze_count=0
renderer_proxy_drop_frames=0
renderer_proxy_max_gap_ms=34
```

这个脚本已经解决“采集内容如何进入同一套 QoS/QoE 验收”和“素材覆盖是否足够”的工程入口问题。fixture 库只用于可复现 smoke，不等价于正式业务真实采集素材；正式素材库仍需要业务侧提供或录制，但以后不能只用单个临时 mp4 作为采集库结论，`REQUIRE_CAPTURE_MANIFEST=1` 会把六类覆盖变成硬门禁。

## 剩余工作

- `video_push_client`、`video_play_client`、`server_qos_router` 已有 WebRTC-backed 最小默认实现；server -> sender 的 uplink TWCC 到 push GoogCC 的最小闭环已接通，push SR -> server RR -> push RTT 已进入 runtime 验证，play 侧 WebRTC NackRequester -> 标准 RTCP NACK -> server 本地重传也已进入 runtime 验证，WebRTC-first facade 弱网矩阵已覆盖基础下探、弱网起步、持续低 RPS/低码率和恢复，可选 FFmpeg QoE smoke、720p QoE 稳定性脚本、720p 多 seed QoE 脚本、720p 长流动态 QoE 脚本、720p extended soak 脚本、production soak runner、720p 高复杂内容 stress 脚本、720p deterministic 内容库 QoE 脚本和真实采集内容库入口脚本已覆盖真实 H264 encode/decode、Y-PSNR、SSIM-Y、freeze proxy 与 renderer proxy latency/gap/jitter 门禁；仓库内 WebRTC-first loopback demo 和 UDP sender/server/receiver demo 已改为直接驱动 role facade；`verify_webrtc_first_phase2.sh` 已提供 smoke/qoe/production 三档聚合门禁入口，当前 smoke/qoe、production 短时 smoke 和 capture fixture 聚合门禁均已在本机通过。下一步需要实际跑完并归档 production 级多小时 soak、在具备显示环境的机器上跑真实 renderer 门禁、补正式真实采集素材库。
- QoE 矩阵需要继续扩展到真实 VMAF、真实 renderer 实机结果、多次恢复时间分布和正式真实采集内容 stress，不能继续引用已删除的自研 RTP/RTCP/pacer/video 入口；当前 SSIM-Y 是无需额外模型/工具链的 VMAF 替代指标，renderer proxy 是播放调度门禁，不等价于真实 GPU/窗口 renderer；`verify_real_renderer_smoke.sh` 已支持真实 X11 display 和可选 Xvfb headless smoke，但本机两者都不可用，尚缺真实 GPU/窗口 renderer 实跑结果。
- `webrtc_pacing` 已从 `IntervalBudget` 子集推进到 WebRTC `PacingController` 最小闭包，并保留 probe cluster、重传优先、RTP padding 生成和 push facade 主路径门禁；后续仍需更长时间生产 soak，但不再是自研轻量 pacer 或纯 budget adapter。

## 二进制可移植性

当前静态库面向 Linux x86_64。`.a` 文件本身不是“与 Linux 版本完全无关”的万能二进制，最终链接仍受目标机 libc、libstdc++、编译器 ABI 和系统库版本影响。生产发布建议在最老支持发行版或固定容器/toolchain 中构建，再分发到兼容环境。
