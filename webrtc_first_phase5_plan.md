# WebRTC-first Phase-5 计划：生产集成化、可观测性与日志体系

## 1. 背景

Phase-2 已经把主路径切回 WebRTC-first facade。Phase-3 收敛了 sender
retransmission、RTCP 身份、compound RTCP 可观测性和重传命名。Phase-4 把默认
能力推进到 multi-track / multi-SSRC，并明确 media plane 尽量保留 WebRTC 原生
语义，业务继续掌握 transport/control plane。

Phase-5 的核心不是继续横向扩媒体能力，而是把当前 SDK 做到业务真正可集成、可
验收、可排障、可监控：

```text
业务只实现 transport/control/codec/render glue，
SDK 提供稳定的 push/server/play media-QoS facade，
运行时具备正式日志、指标、告警、证据归档和排障能力。
```

## 1.1 阶段边界：P5 以前不做多接收端产品化

这里必须明确阶段边界：

- Phase-2 到 Phase-4 不做多接收端产品化。
- Phase-2 到 Phase-4 只保留当前必要的 `receiver_id`、RTCP 身份和反馈不串语义。
- Phase-2 到 Phase-4 不做 receiver registry。
- Phase-2 到 Phase-4 不做 sender RTP 自动 fanout 到多个 receiver。
- Phase-2 到 Phase-4 不把 `ServerQosRouter` 设计成 SFU。

多接收端 fanout 如果进入 Phase-5，也只能排在生产证据、日志、监控、外部样板和
排障体系之后。没有这些基础，直接做多接收端只会让问题更难定位。

因此 Phase-5 的主线是：

1. 正式生产验收证据链。
2. 正规日志系统，写入日志文件，而不是散落 `std::cout`。
3. 运行时 metrics、监控和告警。
4. 问题排查工具链和 artifact bundle。
5. 外部最小 UDP 业务样板工程。
6. 发布契约、错误码、配置 dump 和兼容性。
7. 多接收端 fanout 只作为 Phase-5 后段可选工作包，不作为 P5 前置目标。

## 1.2 当前问题

当前已经可以用最小 UDP 方式跑通：

```text
VideoPushClient -> UDP -> ServerQosRouter -> UDP -> VideoPlayClient
```

但离生产集成还差这些能力：

- 正式验收证据还没闭合：`SOAK_MINUTES>=120` production soak、真实 renderer、
  正式 capture library 仍缺正式结果。
- demo 和验证脚本里大量运行信息直接写 `std::cout` / `std::cerr`，不适合作为
  SDK 生产日志。
- 运行时缺统一日志格式、日志级别、日志文件轮转、上下文字段和错误事件归档。
- `QosSnapshot` 有基础指标，但缺生产监控语义、告警规则和 receiver/track/session
  维度的排查视图。
- 出问题时还不能稳定回答：是 sender、server、receiver、transport、codec、
  renderer 还是环境问题。
- 外部最小业务样板还不够正式，业务方需要看到安装包集成、日志落盘、metrics 输出
  和故障排查怎么做。

## 2. Phase-5 总目标

Phase-5 的完成标准：

```text
同一套 SDK 能在外部最小 UDP 业务工程中运行，
生产验收证据可离线审计，
日志写文件并可轮转，
指标可采集、告警可配置，
故障可用 artifact bundle 定位。
```

工程目标：

- **生产验收闭环**
  跑出正式 `SOAK_MINUTES>=120` production soak、真实 renderer pass、正式
  capture library QoE pass，并生成可离线 audit 的 evidence bundle。

- **正式日志系统**
  SDK 和 demo 不再依赖散落的 `std::cout` 作为运行日志。引入统一 logger，支持
  log level、结构化字段、写文件、轮转、flush 和错误事件落盘。

- **可观测性和监控告警**
  明确 session/source/track/receiver 维度 metrics，提供采集出口和告警规则，
  能持续监控低码率、丢包、NACK、重传、freeze、decode error、queue full 等问题。

- **问题排查工具链**
  每次运行能输出 config dump、runtime metadata、metrics snapshot、关键日志和
  artifact bundle，方便定位问题。

- **外部最小业务样板工程**
  一个按外部 consumer 方式构建的 UDP sender/server/receiver sample，链接安装后
  的 `WebRtcQosSdk::role_*` 或 `role_*_bundle`，证明业务只写 UDP socket /
  envelope / codec glue 即可接入。

- **发布契约和错误语义**
  明确 public API、错误码、日志字段、metrics 字段、配置字段和兼容策略。

## 3. 非目标

Phase-5 不做以下事情：

- 不做完整 `PeerConnection`。
- 不做 ICE / STUN / TURN / DTLS / SRTP / SDP / 浏览器 signaling。
- 不做 SFU 级转码、转封装、分层订阅或复杂媒体协商。
- 不引入新的 media-plane 路线。
- 不做 RFC4588 RTX，当前仍是 `NACK + 原 RTP 包重传`。
- 不做 FEC / ULPFEC / FlexFEC / RED。
- 不做 simulcast / SVC / 多 encoding 发布语义。
- 不把业务 transport 迁移成 WebRTC socket。
- 不在 P5 前做多接收端 receiver registry / fanout 产品化。

这些能力未来可以单独立项，但不能挤占 Phase-5 的生产集成、日志和可观测性目标。

## 4. 工作包

### 4.1 P0：正式生产验收证据链

#### 当前问题

仓库内已有 smoke/qoe/production 短时 runner，但正式验收仍缺三类证据：

- `SOAK_MINUTES>=120` 的 production soak archive。
- 真实 renderer `pass`。
- 正式 `capture_library/manifest.csv` 和业务素材库 QoE pass。

这些不是新的媒体功能，但它们决定 SDK 能不能对外描述成“生产可接入”。

#### 设计方案

Phase-5 第一阶段先把生产证据链跑实并制度化：

- 固定 production gate 命令：
  `scripts/run_phase5_production_gate.sh`
- 固定证据输出目录规范：
  `artifacts/phase5_production_gate/<date_or_build_id>/`
- 每次正式验收必须包含：
  - git commit
  - tracked worktree clean 状态
  - SDK build config
  - WebRTC module prefix
  - capture manifest sha256
  - renderer environment
  - soak config
  - all CSV/log/archive
  - `manifest.sha256`
- completion audit 必须能离线复验：
  `EVIDENCE_BUNDLE_DIR=<bundle> scripts/verify_webrtc_first_phase2_completion_audit.sh`
- completion audit 必须输出 `phase2_completion_audit_metrics.prom`，让生产证据缺口和
  pass 状态都能被 CI/监控系统机器读取。

当前已新增 Phase-5 production gate wrapper：

```bash
scripts/run_phase5_implementation_gate.sh
scripts/verify_phase5_implementation_gate.sh
scripts/verify_phase5_production_readiness.sh
scripts/run_phase5_production_gate.sh
scripts/verify_phase5_production_gate.sh
scripts/verify_phase5_completion_audit.sh
```

`run_phase5_implementation_gate.sh` 是 Phase-5 非生产实现证据 wrapper。它不替代正式
production evidence，而是把 no-selfmade、logging、metrics、alerts、error
contract、minimal UDP external app、release contract 和 debug bundle 门禁串成一份
可离线复验的实现证据，默认输出到
`artifacts/phase5_implementation_gate/<utc_build_id>/`，包含 summary、logs、关键
runtime artifacts、`phase5_implementation_gate_metrics.prom`、`files.txt` 和
`manifest.sha256`。`phase5_implementation_gate_metrics.prom` 用 Prometheus/textfile
形式导出 gate pass/fail、各 step 最终状态和 debug bundle 状态，供 CI、监控告警和
production gate wrapper 在正式验收前判断实现证据是否闭合。
`verify_phase5_implementation_gate.sh` 会复验所有子门禁 pass、三角色日志/metrics/
alerts 产物、debug bundle manifest、顶层 `.prom` 指标、`files.txt` /
`manifest.sha256` / 实际文件集合一致性和运行 JSON 统一身份字段，避免
completion audit 只靠脚本存在和文档 pattern。

`verify_phase5_production_readiness.sh` 是正式验收前的轻量 preflight。它不跑长时
soak，只检查 WebRTC module prefix、`SOAK_MINUTES` 配置、正式 capture manifest、
tracked worktree 是否干净、真实 renderer 可用性和 Phase-5 gate/audit 脚本是否齐全，并输出带 manifest 的
readiness 报告、`readiness_report.json`、`next_required_actions.json` 和
`risk_milestone_report.json`、`risk_milestone_summary.txt`、
`phase5_production_readiness_metrics.prom`、`next_required_actions.txt`。
JSON 报告记录每个 check、失败/跳过原因、机器可消费的 remediation action、M1-M6
里程碑状态和 R1-R5 风险状态；`.prom` 文件用 Prometheus/textfile 形式导出
readiness 状态、失败/跳过/action 数、SOAK_MINUTES、check status、M1-M6、R1-R5 和
remediation action，供 CI、监控告警和发布系统直接解析；文本文件用于人工排查。
M6 fanout 在 P5 基础范围内固定为 deferred，正式完成状态仍要求 passed Phase-5
production gate。
默认本地缺正式素材或真实 renderer 时只生成 not-ready 报告；正式 CI 可设置
`REQUIRE_READY=1` 作为硬门禁。

wrapper 会先跑并复验 Phase-5 implementation gate，再跑 release contract、production
readiness 和 debug bundle 门禁，然后调用底层
`run_webrtc_first_phase2_production_gate.sh` 完成正式 production soak、真实 renderer、
正式 capture library、evidence bundle 和 completion audit。默认输出目录为
`artifacts/phase5_production_gate/<utc_build_id>/`，并生成 metadata、summary、logs、
`git_tracked_status.txt`、`phase5_release_evidence.json`、`phase5_release_evidence.txt`、
`phase5_production_gate_metrics.prom`、`files.txt` 和 `manifest.sha256`；
`phase5_implementation_gate/` 固定在 production gate 目录内，保证正式证据自包含。
顶层 Phase-5 gate 和底层 Phase-2 production gate 都把 `MIN_PRODUCTION_SOAK_MINUTES`
默认固定为 `120`，并在入口前置拒绝 `SOAK_MINUTES<120`、
`MIN_PRODUCTION_SOAK_MINUTES<120` 或 `SOAK_MINUTES<MIN_PRODUCTION_SOAK_MINUTES`，
避免短时 production run 先消耗测试机再由末端审计判无效。standalone readiness、
外部 Phase-2 evidence bundle import 和 Phase-2 completion audit 也不能把
`MIN_PRODUCTION_SOAK_MINUTES` 降到 `120` 以下，防止绕过顶层 gate 生成弱生产证据。
release evidence summary 会写出 `min_production_soak_minutes`，verifier 会确认声明最低值
不低于 120，且实际 production soak 分钟数不低于该声明最低值。
release evidence 生成阶段也会拒绝 `renderer_backend=xvfb` 或没有实际 rendered frames
的 renderer 结果，避免正式 gate 先声明弱 renderer 证据 pass。
`phase5_production_gate_metrics.prom` 是顶层 gate 的 Prometheus/textfile 指标出口：
导出 pass/fail/dry_run、各 step 状态、failure debug bundle 状态和 release evidence
状态，供 CI、监控告警和发布系统直接解析。`phase5_release_evidence.json` 是正式发布证据索引，必须列出
顶层 `files.txt`、顶层 `manifest.sha256`、顶层 `phase5_production_gate_metrics.prom`、
implementation gate、implementation gate `.prom` 指标、clean tracked worktree、production readiness summary、
readiness report、next required actions、risk milestone report、readiness `.prom` 指标、readiness check records、debug bundle
manifest、runtime config、health/SLO report、monitoring metrics、alert policy、incident report/runbook、timeline、first problem、alerts summary、底层 Phase-2
production gate、底层 Phase-2 completion audit `.prom` 指标、production soak 原始 summary/CSV/archive、真实 renderer summary/metrics、
正式 capture library、capture manifest summary、capture QoE CSV、capture QoE summary、
evidence bundle 和 completion audit 的 pass 状态及相对 artifact 路径，同时记录
production soak rows、real renderer backend、readiness report/metrics/risk milestone 指针、debug health/monitoring/incident 指针、顶层 gate 文件清单/sha256 manifest/metrics 指针、capture QoE rows/minima 和
`multi_receiver_fanout=deferred_before_p5_completion`。release evidence verifier 会按固定
evidence id 集合校验，重复 id 或未知 id 都会失败，避免发布证据里混入未审计条目。
非 dry-run 失败时会自动收集并校验
`failure_debug_bundle/`，让失败证据也包含日志、metrics、alerts、timeline 和 runtime
config；`verify_phase5_production_gate.sh` 在 gate 失败时会要求该失败包存在且
manifest 可离线校验；如果 implementation gate 已经 pass，即使后续 readiness 或 soak
失败，也会离线复验这份实现证据；如果失败发生在 implementation 或 readiness 阶段，
还会离线复验对应 summary、manifest、失败 step/check、`readiness_report.json`、
`next_required_actions.json`、`risk_milestone_report.json`、
`phase5_production_readiness_metrics.prom` 和 `next_required_actions.txt`；
在 gate 成功时会离线复验
`phase5_implementation_gate/` 的实现证据和 `.prom` 指标、`phase5_debug_bundle/` 的日志、
metrics、alerts、timeline 和 runtime config，离线复验
`phase5_production_readiness/` 的 ready 状态、production gate `.prom` 指标和
readiness `.prom` 指标、clean tracked worktree 证据，并直接复验顶层 `files.txt` 与
`manifest.sha256` 文件集合一致、底层 Phase-2 evidence bundle manifest、
`phase2_completion_audit=pass` 和
`phase2_completion_status=complete`、`phase2_completion_audit_metrics.prom`，同时强制复验 `phase5_release_evidence.json` 和
release evidence 里索引的 production soak archive、真实 renderer summary/metrics 和 capture QoE
CSV；production soak 证据会通过 `verify_webrtc_first_qoe_production_soak_evidence.sh`
复验 `SOAK_MINUTES>=120`、summary/CSV/config/archive 一致性、clean tracked worktree
metadata、弱网低发送预算和恢复时间分布，真实 renderer 证据会通过
`verify_real_renderer_evidence.sh` 复验非 Xvfb backend、实际 rendered frames、late/gap/jitter 预算，避免只相信 summary。
本地可用 `PHASE5_DRY_RUN=1` 验证 gate 结构，但 dry-run 不代表生产证据完成。

production soak archive 也必须是可追溯的正式证据：runner 在
`archive/files.txt` 写入真实归档文件清单，并在 `archive/metadata.txt` 写入 `sdk_git_tracked_worktree_clean=true|false`，
`archive/git_status.txt` 只记录 tracked 文件状态，未跟踪 artifacts/build 目录不污染
clean 判定；`verify_webrtc_first_qoe_production_soak_archive.sh` 默认要求该归档来自
clean tracked worktree，并复验 `archive/files.txt`、`archive/manifest.sha256` 与实际
archive 文件集合一致；只有排查历史归档时才允许显式设置 `REQUIRE_CLEAN_GIT_WORKTREE=0`。
P5 正式审计不直接信任 archive verifier 的单点结果，还会调用
`verify_webrtc_first_qoe_production_soak_evidence.sh` 复验 summary 与 CSV 聚合一致、
`SOAK_MINUTES` 不低于声明最低值和 P5 120 分钟下限、QoE 下限、hard failure 计数、
弱网低发送预算和 archive 指针。

如果真实 renderer、正式 capture library 和 `SOAK_MINUTES>=120` 是在专用测试机跑出的，
P5 顶层 gate 支持导入该机器收集的 Phase-2 evidence bundle：

```bash
PHASE2_EVIDENCE_BUNDLE_DIR=/path/to/phase2_evidence_bundle \
  scripts/run_phase5_production_gate.sh
```

导入路径由 `scripts/import_phase5_phase2_evidence_bundle.sh` 负责。它会复制外部
bundle 到 P5 gate 目录内，复验源 bundle、复制后 bundle 和导入目录的 `files.txt` /
`manifest.sha256` / 实际文件集合一致性，重新运行
`verify_webrtc_first_phase2_completion_audit.sh`，要求 production soak、真实 renderer、
正式 capture library manifest、capture QoE CSV、completion audit `.prom` 指标和 evidence bundle 全部 pass，并默认要求
bundle 里的 git head 与当前 P5 gate 的 git head 一致，且 bundle metadata 证明外部测试机
tracked worktree clean。导入报告还必须索引原始证据：
production soak summary/CSV/config/archive、真实 renderer summary/metrics、capture
manifest summary、capture manifest sha256、capture QoE CSV/summary，并输出 `production_soak_evidence`、`production_soak_raw_evidence`、
`real_renderer_raw_evidence`、`real_renderer_rendered_frames`、`capture_qoe_raw_evidence` 检查项；导入时会调用
`verify_webrtc_first_qoe_production_soak_evidence.sh` 复验 production soak summary/CSV/config/archive，
调用 `verify_real_renderer_evidence.sh` 复验真实 renderer summary/metrics，避免外部机器只给
pass 摘要、短时或不一致 soak、Xvfb-only renderer 或没有实际 rendered frames 的结果而缺少可复验文件。readiness 在存在 `PHASE2_EVIDENCE_BUNDLE_DIR` 时会用
`external_phase2_evidence_bundle` 作为生产环境证据来源，不再要求当前机器也有真实显示器
和业务素材；但只有导入报告 `import_status=pass`，且 clean tracked worktree、git head、
production soak、真实 renderer、capture QoE、capture manifest sha256 和原始证据指针都
复验通过时，readiness 才会派生记录 `capture_manifest` / `real_renderer` pass。readiness
还会在导入报告上复验 capture fixture flag、QoE `rows/pass_rows` 完整性、必需类别覆盖、
`playable_ratio / avg_psnr_y / avg_ssim_y` 下限和 `decode_errors / freeze_count /
renderer_proxy_drop_frames` 全 0，避免外部 bundle 只给 pass 摘要却绕过正式素材质量门禁。release
evidence 和 production gate verifier 仍会离线复验导入报告及这些原始证据指针。

正式 capture library 不能只证明 manifest 存在。`scripts/verify_capture_library_manifest.sh`
会在 summary 中输出 `capture_manifest_sha256`；Phase-2 completion audit、外部 bundle
导入和 Phase-5 release evidence 必须携带并复验该哈希，证明发布证据对应具体的正式
manifest 内容。`scripts/verify_capture_library_qoe_csv.sh`
会离线复验 `webrtc_first_qoe_capture_library_720p.csv`：所有行必须 `pass=true`，必需类别
必须覆盖，`playable_ratio / avg_psnr_y / avg_ssim_y` 不能低于门槛，`decode_errors /
freeze_count / renderer_proxy_drop_frames` 必须为 0。`scripts/verify_capture_library_evidence.sh`
会进一步绑定复验 manifest summary、QoE CSV 和 QoE summary，要求 QoE summary 中的
`capture_manifest_sha256` 等于 manifest summary，避免正式素材库或 CSV 被替换后只靠旧
summary 通过。Phase-2 completion audit 和外部 bundle 导入都会调用该 verifier。Phase-5 release evidence 生成阶段也会独立拒绝
fixture capture manifest，并要求 capture QoE summary 行数完整、`pass_rows == rows`、
必需类别覆盖、QoE 下限存在、manifest sha 绑定且 `decode_errors / freeze_count / renderer_proxy_drop_frames`
为 0，避免先把不完整素材库证据写成发布 pass 再由离线 verifier 打回。

`verify_phase5_completion_audit.sh` 是最终完成度审计入口：默认要求
`PHASE5_GATE_DIR` 指向已经 `REQUIRE_PASS=1` 验证通过的 Phase-5 production gate；
如果该 gate 内包含 `phase5_implementation_gate/`，audit 会自动复验实现证据，也可以
显式传 `PHASE5_IMPLEMENTATION_GATE_DIR`。如果设置 `REQUIRE_PRODUCTION_EVIDENCE=0`，
仍必须提供 implementation gate 证据，但只返回
`implemented_without_required_production_evidence`，不能用来宣布生产完成。completion
audit 同时输出 `phase5_completion_audit_metrics.prom`，用 Prometheus/textfile 指标导出
completion status、audit status、pass/warn/fail check 数、单项 check 状态、production
evidence 状态和 next required action，供 CI、监控告警和发布系统直接判断“正式完成”与
“只缺生产证据”的差异。

#### 验收标准

- implementation gate 可离线 verify 通过，证明日志、metrics、alerts、debug bundle、
  external sample、错误契约和发布契约都有运行证据。
- implementation gate 必须输出并离线复验 `phase5_implementation_gate_metrics.prom`，
  覆盖 gate status、step status 和 debug bundle status。
- `SOAK_MINUTES>=120` production soak 通过。
- 真实 renderer summary 为 `pass`，不是 skipped。
- 正式 capture library 覆盖所需类别，manifest 校验通过，QoE 通过。
- evidence bundle 可离线 audit 通过。
- README 当前状态从“缺正式验收闭环”更新为“Phase-5 已补齐正式证据”。

### 4.2 P0：正式日志系统

#### 当前问题

当前 demo、脚本和部分运行输出主要依赖 `std::cout` / `std::cerr`。这对 smoke demo
够用，但不适合生产：

- 日志没有统一级别。
- 日志没有固定字段。
- 日志不能稳定写入文件。
- 无轮转和保留策略。
- 多角色、多 track、多 receiver_id 时难以关联事件。
- 运行失败后，stdout/stderr 很容易丢失或被 CI 截断。

#### 设计方案

引入 SDK 内部轻量日志系统，先不依赖重型第三方库。公共配置可以是：

```cpp
enum class LogLevel {
  kTrace = 0,
  kDebug = 1,
  kInfo = 2,
  kWarn = 3,
  kError = 4,
  kOff = 5,
};

struct FileLogConfig {
  bool enabled = false;
  std::string directory;
  std::string basename = "webrtc_qos";
  uint64_t max_file_bytes = 64 * 1024 * 1024;
  uint32_t max_files = 5;
  bool json_lines = true;
};

struct RuntimeLogConfig {
  LogLevel min_level = LogLevel::kInfo;
  FileLogConfig file;
};
```

角色 config 可逐步增加：

```cpp
struct VideoPushClientConfig {
  SessionConfig session;
  TransportOutput transport_output;
  RuntimeLogConfig logging;
};

struct VideoPlayClientConfig {
  SessionConfig session;
  TransportOutput transport_output;
  AnnexBAccessUnitCallback decoded_access_unit_output;
  RuntimeLogConfig logging;
};

struct ServerQosRouterConfig {
  SessionConfig session;
  TransportOutput sender_output;
  TransportOutput receiver_output;
  RuntimeLogConfig logging;
};
```

如果担心 config 结构兼容性，可以先用全局 runtime options 或新增 V2 config。具体
实现时按当前 ABI 承诺决定。

#### 日志文件规范

推荐文件命名：

```text
<log_dir>/webrtc_qos.<role>.<pid>.<YYYYMMDD-HHMMSS>.log
```

推荐 JSON Lines 格式：

```json
{"ts_us":1000000,"level":"INFO","role":"push","event":"start","session_id":1,"stream_id":1,"source_id":1}
```

每条日志必须尽量包含：

- `ts_us`
- `level`
- `role`
- `event`
- `status_code`
- `session_id`
- `stream_id`
- `transport_id`
- `source_id`
- `track_id`
- `sender_ssrc`
- `receiver_id`
- `rtp_sequence_number`
- `transport_sequence_number`
- `packet_size`
- `reason`

不是每条都能有全部字段，但字段名必须统一。

#### 必须记录的事件

生命周期：

- `create`
- `start`
- `stop`
- `config_dump`
- `route_change`
- `network_route_change`

sender：

- `push_au`
- `packetize_failed`
- `pacer_enqueue_failed`
- `pacer_emit`
- `googcc_target_update`
- `sender_rate_cap_update`
- `keyframe_requested`
- `sender_retransmission_enqueue`
- `sender_retransmission_drop`

server：

- `sender_rtp_in`
- `sender_rtcp_in`
- `receiver_rtcp_in`
- `downlink_quality_update`
- `sender_cap_selected`
- `local_retransmission_hit`
- `local_retransmission_miss`
- `unsupported_rtcp_drop`

receiver：

- `rtp_in`
- `rtcp_in`
- `nack_generated`
- `pli_generated`
- `jitter_frame_output`
- `decode_au_output`
- `malformed_rtp`
- `malformed_h264`

transport/output：

- `transport_output_failed`
- `packet_dropped_by_test_network`
- `udp_send_failed`
- `udp_recv_failed`

#### 性能要求

日志不能拖垮媒体线程：

- 默认 info 级别只打关键状态变化和异常。
- debug/trace 才允许高频 packet 级日志。
- 文件写入使用缓冲或异步队列。
- 队列满时丢 debug/trace，保留 warn/error，并记录 `dropped_log_count`。
- `Stop()` 时 flush。
- 崩溃前不保证所有日志都落盘，但正常 stop 必须 flush。

#### 安全要求

- 不记录 RTP/H264 payload bytes。
- 不记录原始视频帧。
- 不记录鉴权 token、密钥、用户隐私字段。
- config dump 要支持字段脱敏。
- 可以记录 packet size、SSRC、sequence number、track_id、receiver_id。

#### 验收标准

- demo 和 external sample 支持 `--log-dir`。
- 默认运行会生成角色日志文件。
- `std::cout` 只保留最终 summary 和人工 demo 提示，不作为 SDK 运行日志。
- SDK runtime logger 不提供 stderr fallback；文件日志不可用时不能把结构化运行日志
  退回 stdout/stderr。
- 显式启用 log/metrics/alerts 文件输出但目录为空、目录不可创建或文件不可打开时，
  push/server/play `Start()` 必须返回错误，避免生产排障包缺失关键运行证据。
- 日志文件超过阈值会轮转；demo 和 external sample 支持
  `--log-max-file-bytes / --log-max-files`，`verify_phase5_logging.sh` 会用低阈值
  强制验证 push/server/play 三个 role 的轮转和保留文件数上限。
- 日志文件写入走内部异步队列；demo 和 external sample 支持
  `--log-max-queue-records`，`verify_phase5_logging.sh` 会用极小队列验证
  `dropped_log_count`，且 warn/error/stop 不丢。
- push/server/play `Start()` 成功后会写脱敏 `config_dump`，记录 UDP 边界、
  track 数、码率边界和日志/metrics/alerts 开关，不记录运行机路径、媒体 payload
  或鉴权材料。
- `verify_phase5_logging.sh` 会检查 push/server/play 的 `stop` 事件已写入 JSONL
  文件，作为正常 `Stop()` 后 flush 的回归门禁。
- CI artifact 收集日志文件。
- 故障 case 能在日志中定位到角色、track、receiver、packet 或 status code。

### 4.3 P0：Metrics 和可观测性

#### 当前问题

当前 `QosSnapshot` 已经有基础字段，但生产排障还需要稳定的分层指标：

- session/source 级
- track 级
- receiver 级
- transport 级
- codec/render 级

#### 设计方案

保留现有 `QosSnapshot`，新增或明确以下视图：

```cpp
bool GetTrackQosSnapshot(uint32_t track_id,
                         int64_t now_us,
                         QosSnapshot* out) const;
```

Phase-5 可新增 receiver 视图，但不代表 P5 前做多接收端 fanout：

```cpp
bool GetReceiverQosSnapshot(uint32_t receiver_id,
                            int64_t now_us,
                            QosSnapshot* out) const;
```

推荐补充 metrics sink：

```cpp
using MetricsOutput =
    std::function<void(const MetricsRecord& record)>;
```

或者先以文件方式落地：

```text
webrtc_qos_metrics.<role>.<pid>.<timestamp>.<index>.jsonl
metrics_summary.csv
qos_snapshot_<role>.json
```

当前已落地第一版文件型 metrics：

```cpp
struct FileMetricsConfig {
  bool enabled = false;
  std::string directory;
  std::string basename = "webrtc_qos_metrics";
  uint64_t max_file_bytes = 64 * 1024 * 1024;
  uint32_t max_files = 5;
};

struct RuntimeMetricsConfig {
  FileMetricsConfig file;
  uint32_t interval_ms = 1000;
  bool include_track_snapshots = true;
};
```

role config 已追加 `RuntimeMetricsConfig metrics`。当前 JSONL 覆盖
`session/track` 两类 scope，包含身份字段、target bitrate、FPS、downlink
loss、NACK、PLI、retransmission、drop、probe/padding，以及
`process_tick_count / process_tick_gap_us / max_process_tick_gap_us` 等运行循环
健康度字段，以及 `rtp_output_gap_us / max_rtp_output_gap_us`、
`rtp_input_gap_us / max_rtp_input_gap_us` 等媒体流健康度字段，以及
`transport_failure_count / consecutive_transport_failures /
max_consecutive_transport_failures` 等 transport callback 健康度字段。

#### 指标分层

session/source 级：

- final target bps
- GoogCC target bps
- pacing bps
- sender cap bps
- RTT
- loss
- emitted RTP/RTCP/padding/probe/retransmission
- process tick gap

track 级：

- target bitrate
- max fps
- pushed AU
- output AU
- emitted RTP packets/bytes
- decoded AU
- NACK
- PLI
- retransmission
- dropped/recovered

receiver/downlink 级：

- last downlink quality
- fraction lost
- recv bitrate
- video drop frames
- NACK/PLI
- local retransmission hit/miss
- last active time

codec/render 级：

- encode errors
- decode errors
- rendered frames
- freeze count
- max render gap
- renderer late/drop frames

#### 验收标准

- 每个 role 能定期输出 metrics snapshot 文件。
- weak network case 能从 metrics 看出 target bitrate/FPS/RPS 下探和恢复。
- NACK/retransmission 能按 track 维度定位。
- decode/render 问题能与 transport 问题区分。
- metrics 文件超过阈值会轮转；demo 和 external sample 支持
  `--metrics-max-file-bytes / --metrics-max-files`，`verify_phase5_metrics.sh` 会用
  低阈值强制验证 push/server/play 三个 role 的轮转和保留文件数上限。
- push/server/play metrics 都包含 process tick gap 字段，用于定位业务线程或
  router event loop 卡顿。
- push/server/play metrics 覆盖 RTP input/output gap，用于定位线程仍在跑但媒体
  没流动的问题。
- metrics 字段文档化，避免把 QoE harness 私有字段误当 public API。

### 4.4 P0：监控告警规则

#### 当前问题

现在脚本可以 pass/fail，但生产运行需要持续告警，不是事后看 CSV。

#### 设计方案

Phase-5 先定义 SDK 推荐告警规则，并在 runner/external sample 中实现文件级或脚本级
告警。未来业务可接 Prometheus、OpenTelemetry 或自研监控。

推荐告警分三类：

#### 可用性告警

- sender `Process()` tick gap 超过阈值。
- receiver `Process()` tick gap 超过阈值。
- 连续 N 秒无 sender RTP 输出。
- 连续 N 秒无 receiver RTP 输入。
- transport output 连续失败。
- `StatusCode::kInternalError` 连续出现。

#### 媒体质量告警

- `decode_errors > 0`
- `freeze_count > 0`
- renderer drop/late frames 超阈值。
- playable ratio 低于阈值。
- target bitrate 长时间低于最低预期。
- encoder FPS 长时间低于最低预期。
- recovery time 超阈值。

#### 网络/QoS 告警

- fraction lost 高于阈值持续 N 秒。
- NACK rate 突增。
- retransmission miss rate 高。
- RTT 高于阈值。
- pacer queue 或 jitter queue 接近上限。
- malformed RTP/RTCP/H264 packet 出现。
- unsupported RTCP packet 持续出现。

#### 告警输出

最小实现可以输出：

```text
alerts.jsonl
alerts_summary.txt
```

单条告警推荐格式：

```json
{"ts_us":1000000,"severity":"WARN","rule":"high_nack_rate","role":"play","track_id":101,"value":42,"threshold":20}
```

当前已落地第一版文件型 alerts：

```cpp
struct FileAlertsConfig {
  bool enabled = false;
  std::string directory;
  std::string basename = "webrtc_qos_alerts";
  uint64_t max_file_bytes = 64 * 1024 * 1024;
  uint32_t max_files = 5;
};

struct RuntimeAlertConfig {
  FileAlertsConfig file;
  uint32_t suppress_repeated_alerts_ms = 1000;
  bool alert_on_qos_degradation = true;
  bool alert_on_recovery_events = true;
  bool alert_on_malformed_packet = true;
  bool alert_on_transport_failure = true;
  bool alert_on_media_failure = true;
  uint16_t high_loss_fraction_q8 = 128;
  uint16_t video_drop_frames_threshold = 1;
  uint32_t low_target_bps = 700000;
  uint32_t low_encoder_fps = 20;
};
```

role config 已追加 `RuntimeAlertConfig alerts`。当前 JSONL 覆盖统一身份字段、
`severity/rule/category/value/threshold/status_code/reason`，并在以下路径触发：

- push：low target bitrate、low encoder FPS、malformed H264、pacer enqueue
  failure、transport output failure、sender retransmission enqueue/drop、process
  tick gap、sender RTP output gap。
- server：malformed RTP/RTCP、unsupported RTCP、receiver/sender output failure、
  high downlink loss、video drop、本地重传 hit/miss、router event loop tick gap、
  sender RTP output gap。
- play：malformed RTP、NACK/PLI、transport output failure、decode output failure、
  jitter packet drop、process tick gap、receiver RTP input gap。

仓库内 UDP demo 已支持 `--alerts-dir`，文件名为：

```text
webrtc_qos_udp_alerts.<role>.<pid>.<timestamp>.<index>.jsonl
```

当前门禁为：

```bash
scripts/verify_phase5_alerts.sh
```

该脚本先用 UDP weak-network selftest 验证降码率/FPS、downlink loss、video drop、
NACK 和重传告警，再用安装包外部 CMake fixture 验证 malformed RTP、transport
output failure、decode output failure 和 push/server/play `process_tick_gap`
availability alert，以及 sender/server `sender_rtp_output_gap`、play
`receiver_rtp_input_gap` media-flow availability alert、push
`consecutive_transport_failures` availability alert，同时确认对应 warn/error 日志落盘。

#### 验收标准

- weak network low-RPS case 产生预期的 bitrate/FPS 下探记录，但不误报 fatal。
- decode error fixture 能触发 decode 告警。
- transport output failure 能触发可用性告警。
- process tick gap fixture 能触发 push/server/play 可用性告警。
- media flow gap fixture 能触发 sender/server RTP 输出停滞和 play RTP 输入停滞告警。
- malformed packet 能触发 warn/error 日志和告警。
- 告警文件进入 evidence bundle。
- alerts 文件超过阈值会轮转；demo 和 external sample 支持
  `--alerts-max-file-bytes / --alerts-max-files`，`verify_phase5_alerts.sh` 会用低阈值
  强制验证 push/server/play 三个 role 的轮转和保留文件数上限。

### 4.5 P1：问题排查 Bundle

#### 当前问题

出问题时，单独的 stdout 或 CSV 不够。需要一键收集可排查上下文。

#### 设计方案

新增排查 bundle 规范：

```text
  debug_bundle/
  metadata.txt
  build_config.txt
  git_status.txt
  session_config.json
  runtime_config.json
  log/
    push.log
    server.log
    play.log
  metrics/
    push_metrics.jsonl
    server_metrics.jsonl
    play_metrics.jsonl
    summary.csv
  alerts/
    alerts.jsonl
    alerts_summary.txt
  monitoring/
    health_report.json
    health_summary.txt
    slo_report.json
    slo_summary.txt
    phase5_monitoring_metrics.prom
    alert_policy.json
    alert_policy_summary.txt
    incident_report.json
    incident_runbook.txt
  evidence/
    qoe.csv
    renderer_summary.txt
```

新增脚本：

```bash
scripts/collect_phase5_debug_bundle.sh
scripts/verify_phase5_debug_bundle.sh
```

当前已落地第一版排障 bundle。collector 默认会构建并运行一次 UDP selftest，同时
打开 `--log-dir / --metrics-dir / --alerts-dir`，再把运行产物规整成：

```text
debug_bundle/
  metadata.txt
  build_config.txt
  git_status.txt
  session_config.json
  runtime_config.json
  log/
    push.log
    server.log
    play.log
  metrics/
    push_metrics.jsonl
    server_metrics.jsonl
    play_metrics.jsonl
    summary.csv
  alerts/
    push_alerts.jsonl
    server_alerts.jsonl
    play_alerts.jsonl
    alerts.jsonl
    alerts_summary.txt
  timeline/
    events.jsonl
    first_problem.json
    summary.txt
  monitoring/
    health_report.json
    health_summary.txt
    slo_report.json
    slo_summary.txt
    phase5_monitoring_metrics.prom
    alert_policy.json
    alert_policy_summary.txt
    incident_report.json
    incident_runbook.txt
  evidence/
    udp_selftest_output.txt
    cmake_configure.log
    cmake_build.log
    qoe.csv
    renderer_summary.txt
  files.txt
  manifest.sha256
```

`timeline/events.jsonl` 会把日志、metrics 和 alerts 统一按 `ts_us` 排序，
`timeline/first_problem.json` 指向第一条 WARN/ERROR 或 alert，便于快速定位
“第一个坏点”在哪个 role/track/receiver。

`metrics/summary.csv` 会按 role 输出关键 QoS 极值、最大 process tick gap 以及对应
session/track/receiver；`alerts/alerts_summary.txt` 会输出 `first_alert` 和
role/category/rule 计数；`timeline/summary.txt` 会输出 log/metric/alert 事件计数
和 `first_problem` 一行，方便不展开全部 JSONL 就能定位首个坏点和影响范围。

`monitoring/health_report.json` 是给 CI/运维直接消费的聚合健康视图：按
push/server/play 汇总 metric record 数、alert record 数、alert category/rule、
最大 process tick gap、RTP input/output gap、连续 transport failure 和对应身份字段；
同时输出总体 `health_status`、`first_problem`、top alert rules 和
`recommended_actions`。`monitoring/health_summary.txt` 提供同样信息的文本摘要，
方便人工在失败 artifact 中快速读取。

`monitoring/slo_report.json` 是给监控和值班直接消费的目标视图：按
availability、media_quality、network_qos 三类记录目标、当前观测值、阈值、状态和
排查动作。`monitoring/slo_summary.txt` 是同一信息的文本版。该报告只声明
single debug bundle run 的观测结果，不等价于正式生产 SLO 完成结论。

`monitoring/phase5_monitoring_metrics.prom` 是 Prometheus/textfile 风格的监控出口：
从同一份 health/SLO/alert policy/timeline 数据导出 role metric records、最大
process tick gap、RTP input/output gap、连续 transport failure、alert totals、SLO
objective status/observed/threshold 和 policy observed counts。它用于 CI artifact
展示、node_exporter textfile collector 或内部监控导入单次排障包证据，不声明多次
运行或生产级 SLO 达标。

`monitoring/alert_policy.json` 是本次运行使用的默认告警策略快照：包含
availability、media_quality、network_qos 三类规则，记录每条规则的名称、类别、
严重级别、适用 role、阈值来源、默认阈值、排查动作和本次 bundle 中的观测计数。
`monitoring/alert_policy_summary.txt` 是同一策略的文本摘要，方便 CI artifact 页面
直接展示策略覆盖和观测命中情况。

`monitoring/incident_report.json` 是事故排查入口：把 `first_problem`、top alert
rules、recommended actions、health report、alert policy、timeline、role 日志和
metrics 证据指针串成固定顺序的 runbook steps。`monitoring/incident_runbook.txt`
提供同样步骤的文本版，适合在 CI artifact 页面直接查看。

`runtime_config.json` 是脱敏后的运行配置 dump，固定记录 schema version、UDP
transport boundary、三角色 factory、selftest 参数、日志/metrics/alerts 运行开关和
bundle 内相对路径、health report、alert policy 和 incident runbook 路径；媒体 bytes、原始帧、鉴权材料和运行机绝对目录只记录为
`omitted` 标记。

离线 verifier 会检查：

- 必需文件存在。
- push/server/play 都有日志、metrics 和 alerts。
- JSONL 都有统一身份字段。
- metrics summary 覆盖三类 role。
- metrics summary 包含最大 process tick gap 和对应身份字段。
- alerts summary 包含首个告警和 role/category/rule 计数。
- weak-network alert 规则齐全。
- timeline 同时包含 log/metric/alert 三类事件，并在 summary 中写出 first problem。
- health report 覆盖三类 role、top alert rules、recommended actions 和 bundle 内
  相对 artifact 指针。
- SLO report 覆盖 availability、media_quality、network_qos 三类目标、当前观测值、
  阈值、状态、排查动作和 bundle 内相对 artifact 指针。
- alert policy 覆盖 availability、media_quality、network_qos 三类规则、默认阈值、
  适用 role、排查动作和本次观测计数。
- incident report 覆盖 first problem、top alert rules、recommended actions、证据
  指针和固定排查步骤。
- push/server/play 日志中都有 `config_dump`，且只包含脱敏配置摘要。
- runtime config 覆盖 push/server/play、日志/metrics/alerts 开关和脱敏标记。
- `files.txt`、`manifest.sha256` 和实际 bundle 文件集合一致，且 `manifest.sha256`
  可校验。
- bundle 中不出现 `payload/annexb_bytes/rtp_bytes/token/secret/password` 类字段。

当前门禁：

```bash
OUTPUT_DIR=/tmp/webrtc_qos_phase5_debug_bundle \
  scripts/collect_phase5_debug_bundle.sh
BUNDLE_DIR=/tmp/webrtc_qos_phase5_debug_bundle \
  scripts/verify_phase5_debug_bundle.sh
```

bundle 必须支持：

- 离线查看当前 session/track/receiver 配置。
- 关联 sender/server/play 三端时间线。
- 找到第一次 error/warn。
- 看到关键 metrics 的前后变化。
- 看到可由 CI/运维直接消费的健康状态和推荐排查动作。
- 看到可由监控和值班直接消费的 SLO/SLA 目标、观测值和状态。
- 看到可离线审计的告警策略、阈值来源和规则覆盖。
- 按 incident runbook 顺序定位 first problem、关联证据并校验 bundle 完整性。
- 校验 files/manifest/实际文件集合一致性，避免证据被改、漏列或额外混入文件。

#### 验收标准

- 任意 Phase-5 runner 失败时自动输出 debug bundle。
- bundle verifier 能检查必需文件存在、files/manifest/实际文件集合一致性、JSON 字段
  和 weak-network alert。
- health report 能按 role 汇总健康状态、首个问题、top alert rules 和推荐动作。
- SLO report 能按 availability、media_quality、network_qos 汇总目标、观测值、
  阈值和状态，且明确不冒充正式生产 SLO 结论。
- alert policy 能证明本次运行的告警规则、阈值和排查动作可离线审计。
- incident report 能给出固定排查步骤和对应 artifact 指针。
- bundle 中无原始媒体 payload 和隐私敏感字段。

### 4.6 P1：外部最小 UDP 业务样板工程

#### 当前问题

仓库内 `demo/webrtc_first_udp` 能证明 SDK 内部路径，但业务集成需要看到正式外部工程：

- 如何 `find_package(WebRtcQosSdk)`。
- 如何链接 `role_push / role_server / role_play` 或 bundle。
- 如何传 `--log-dir` 并拿到日志文件。
- 如何输出 metrics 和 alerts。
- 如何把 encoder/decoder/render 接口与 SDK 隔离。

#### 设计方案

新增长期维护的 external sample：

```text
examples/minimal_udp_app/
  CMakeLists.txt
  README.md
  common/wire_packet.h
  common/udp_socket.h
  common/logging_flags.h
  sender/main.cc
  server/main.cc
  receiver/main.cc
  codec/synthetic_h264_source.h
```

样板工程要求：

- 从安装后的 SDK prefix 构建，不直接 include 仓库 `src/`。
- 默认链接 `WebRtcQosSdk::role_*_bundle`，文档说明普通 `role_*` target。
- UDP envelope 与 `docs/minimal_udp_integration_best_practice.md` 一致。
- sender/server/receiver 可三进程运行。
- 支持 `--log-dir`、`--metrics-dir`、`--frames`、`--tracks`。
- 默认 dual-track。
- 可选接入 FFmpeg H264 encoder/decoder，但默认不强依赖 FFmpeg。

当前已落地 `examples/minimal_udp_app`：

```text
examples/minimal_udp_app/
  CMakeLists.txt
  README.md
  common/options.h
  common/run_loops.h
  common/session.h
  common/udp_socket.h
  common/wire_packet.h
  codec/synthetic_h264_source.h
  sender/main.cc
  server/main.cc
  receiver/main.cc
  selftest/main.cc
```

该工程只通过 `find_package(WebRtcQosSdk)` 消费安装 prefix，CMake 优先链接
`WebRtcQosSdk::role_push_bundle / role_server_bundle / role_play_bundle`，缺失时
fallback 到普通 `role_*` target。四个入口分别是：

- `minimal_udp_sender`
- `minimal_udp_server`
- `minimal_udp_receiver`
- `minimal_udp_selftest`

样板默认 dual-track，支持 `--frames / --tracks / --log-dir / --metrics-dir /
--alerts-dir`。`minimal_udp_selftest` 用三个 localhost UDP socket 串起
sender/server/receiver，验证 `transport=udp`、`peer_connection=false`、弱网下探、
NACK/重传和恢复回升。

当前门禁：

```bash
scripts/verify_phase5_minimal_udp_external_app.sh
```

该脚本会临时安装当前 SDK，从 `examples/minimal_udp_app` 构建外部工程，验证样板不
include SDK `src/` 或 WebRTC PeerConnection 内部头，运行 selftest 并检查
push/server/play 日志、metrics 和 alerts 文件。

#### 验收标准

- `scripts/verify_phase5_minimal_udp_external_app.sh` 可从 install prefix 构建并运行。
- 外部样板输出：
  `backend=webrtc_first_facade transport=udp peer_connection=false tracks=2`
- receiver 输出 `decoded_tracks=2 pass=true`。
- 生成 push/server/play 三个日志文件。
- 样板工程不 include WebRTC 内部头，也不 include SDK `src/`。

### 4.7 P1：错误码与运行契约

#### 当前问题

业务集成时需要知道错误是参数问题、packet malformed、queue full、transport output
失败还是内部状态错误。当前 `StatusCode` 已有基础枚举，但使用和文档还不够系统。

当前已补齐文档和门禁：`docs/minimal_udp_integration_best_practice.md` 已列出
public method 的主要错误条件，`scripts/verify_phase5_error_contract.sh` 会从安装
prefix 构建外部 CMake fixture，验证错误返回、日志事件和 alerts 规则一致。

#### 设计方案

把 role facade 的错误契约文档化并补门禁：

- `kInvalidArgument`：空指针、size=0、未知 track、非法 config。
- `kUnsupported`：before-start 调用、当前 RTCP block 或能力不支持。
- `kMalformedPacket`：RTP/RTCP/H264 payload 解析失败。
- `kQueueFull`：pacer/jitter/packet history 达到容量。
- `kInternalError`：transport output 失败或不可恢复内部错误。

原则：

- transport output 返回失败时，不吞错误。
- 单个 malformed packet 不应导致整个 facade stop。
- config 错误必须在 `Start()` 或工厂创建阶段尽早失败。
- 所有 warn/error 都应写日志文件，并带 status code。

当前错误契约门禁覆盖：

- push/play/server `Start()` 缺必需 callback 返回 `kInvalidArgument` 并写
  `start_failed`。
- 显式启用的 log/metrics/alerts 文件输出不可写时，push/play/server `Start()`
  返回 `kInternalError`，不能静默继续运行。
- push/play/server before-start 调用返回 `kUnsupported` 并写对应 warn 日志。
- malformed H264/RTP 返回 `kMalformedPacket`，写 warn 日志和 malformed alerts。
- push transport output failure、server receiver output failure、play decoded AU
  output failure 返回 `kInternalError`，写 error 日志和 availability/media alerts。
- 日志和 alerts 均包含统一身份字段和 `status_code/reason`，不包含媒体 payload
  bytes。

#### 验收标准

- `scripts/verify_phase5_error_contract.sh` 通过。
- 文档列出每个 public method 的主要错误条件。
- demo 遇到错误会打印 `status_code/reason` summary，同时把完整错误写入日志文件。

### 4.8 P1：发布包与兼容性

#### 当前问题

当前发布包已有 role bundle，但 Phase-5 引入 logging/metrics/alerts 后，需要明确
发布契约。

#### 设计方案

- 保持现有 `CreateVideoPushClient()` / `CreateVideoPlayClient()` /
  `CreateServerQosRouter()` 工厂函数。
- 新增 logging/metrics 字段优先追加到 config 结构尾部。
- 如果要避免 C++ ABI 风险，可新增 V2 config 或 runtime options。
- CMake target 保持：
  - `WebRtcQosSdk::role_push`
  - `WebRtcQosSdk::role_play`
  - `WebRtcQosSdk::role_server`
  - `WebRtcQosSdk::role_*_bundle`
- dist README 增加 Phase-5 minimal UDP external sample、日志目录和 metrics 说明。

当前已新增发布契约门禁：

```bash
scripts/verify_phase5_release_contract.sh
```

该脚本会从当前源码安装临时 SDK prefix，检查 public headers、WebRTC adapter
headers、role archives、role bundle archives 和 CMake package，再用外部 consumer
分别链接普通 `role_*` 与 `role_*_bundle` target，验证 runtime
logging/metrics/alerts 配置字段、三角色工厂函数和 PeerConnection-free 发布边界。

#### 验收标准

- `scripts/verify_phase5_release_contract.sh` 通过。
- public headers、WebRTC adapter headers、role archives 和 role bundle archives 全部
  存在于安装 prefix。
- 外部 CMake consumer 可分别链接普通 `role_*` 和 `role_*_bundle` target。
- consumer 可使用 logging/metrics/alerts 字段并生成对应运行产物。
- 发布包不暴露 PeerConnection 依赖，也不带回旧自研媒体栈。
- 旧外部 CMake consumer 仍能构建和运行。
- 新 external sample 可只用 install prefix 构建。
- 发布包不引入完整 WebRTC PeerConnection 依赖。
- `verify_no_selfmade_media_stack.sh` 仍通过。

### 4.9 P2：多接收端 Fanout 后段工作包

#### 阶段定位

多接收端不是 P5 以前的目标，也不是 Phase-5 第一优先级。只有在以下基础完成后，
才考虑进入这个工作包：

- 生产证据链闭合。
- 文件日志可用。
- metrics/alerts 可用。
- external sample 可用。
- debug bundle 可用。

#### 设计方向

如果 Phase-5 后段启动多接收端 fanout，推荐做法仍然是 server-side receiver
registry：

- `AddReceiver`
- `RemoveReceiver`
- `UpdateReceiver`
- receiver-bound transport output
- per-receiver downlink quality
- per-receiver NACK/PLI/retransmission counters
- worst receiver sender cap policy

但这个工作包不能改变前面的边界：

- 不做完整 SFU。
- 不做转码。
- 不做 SDP/ICE/DTLS/SRTP。
- 不做多 encoding/simulcast。
- 不让 WebRTC 接管业务 socket。

#### 验收标准

- 两个 receiver 同时接收同一 sender，两个都能 decode 指定 track。
- receiver A 弱网产生 NACK/retransmission，不影响 receiver B 的 clean path。
- receiver A disabled 后不再收到 fanout packet。
- 日志、metrics、alerts 能按 receiver_id 定位问题。

这个工作包不作为 Phase-5 基础完成条件。是否纳入 Phase-5 最终完成定义，需要在前面
P0/P1 完成后再确认。

## 5. 日志与监控 API 草案

### 5.1 RuntimeLogConfig

```cpp
#include <string>

enum class LogLevel {
  kTrace = 0,
  kDebug = 1,
  kInfo = 2,
  kWarn = 3,
  kError = 4,
  kOff = 5,
};

struct FileLogConfig {
  bool enabled = false;
  std::string directory;
  std::string basename = "webrtc_qos";
  uint64_t max_file_bytes = 64 * 1024 * 1024;
  uint32_t max_files = 5;
  bool json_lines = true;
};

struct RuntimeLogConfig {
  LogLevel min_level = LogLevel::kInfo;
  FileLogConfig file;
};
```

### 5.2 MetricsRecord

```cpp
enum class MetricsRecordKind {
  kSession = 1,
  kTrack = 2,
  kReceiver = 3,
  kTransport = 4,
  kCodec = 5,
};

struct MetricsRecord {
  MetricsRecordKind kind = MetricsRecordKind::kSession;
  TransportIds ids;
  int64_t timestamp_us = 0;
  QosSnapshot snapshot;
};
```

### 5.3 AlertRecord

```cpp
enum class AlertSeverity {
  kInfo = 1,
  kWarn = 2,
  kCritical = 3,
};

struct AlertRecord {
  AlertSeverity severity = AlertSeverity::kWarn;
  TransportIds ids;
  const char* rule = nullptr;
  const char* message = nullptr;
  double value = 0.0;
  double threshold = 0.0;
  int64_t timestamp_us = 0;
};
```

这些结构可以先用于内部文件输出，后续再决定是否进入正式 public headers。

## 6. 门禁设计

### 6.1 日志门禁

```bash
scripts/verify_phase5_logging.sh
```

覆盖：

- push/server/play 都生成日志文件。
- 日志包含 start/stop/config/error 事件。
- `config_dump` 包含脱敏运行配置摘要和 redaction 标记。
- 正常 `Stop()` 后 stop 事件已 flush 到日志文件。
- 异步日志队列满时记录 `dropped_log_count`，并保留 warn/error/stop。
- 日志文件轮转生效。
- 默认不输出 RTP/H264 payload bytes。
- stdout/stderr 只保留 summary、usage 或退出原因，不承载 SDK 运行日志。
- SDK runtime logger 源码和 public `RuntimeLogConfig` 不允许出现 `std::cout`、
  `std::cerr` 或 stderr fallback 开关。

### 6.2 Metrics 门禁

```bash
scripts/verify_phase5_metrics.sh
```

覆盖：

- push/server/play 都生成 metrics JSONL 文件。
- metrics 包含 session/track scope 和统一身份字段。
- weak network 能看到 bitrate/FPS 下探和恢复。
- server retransmission、play NACK、dual-track track_id 可定位。
- transport failure 总数、当前连续失败次数、最大连续失败次数可定位。
- 默认不输出 RTP/H264 payload bytes。

### 6.3 监控告警门禁

```bash
scripts/verify_phase5_alerts.sh
```

覆盖：

- weak network 产生 QoS 下探指标。
- decode error fixture 触发 media quality alert。
- transport output failure 触发 availability alert。
- consecutive transport output failure 触发 availability alert。
- malformed packet 触发 warn/error 日志和 alert。

### 6.4 错误契约门禁

```bash
scripts/verify_phase5_error_contract.sh
```

覆盖：

- 外部安装包 consumer 只通过 public headers 和 `role_*` target 触发错误路径。
- config error、before-start、malformed packet、transport failure、relay failure、
  decode output failure 返回稳定 `StatusCode`。
- 对应 warn/error 日志和 alerts 规则落盘，并带统一身份字段。

### 6.5 Debug bundle 门禁

```bash
scripts/verify_phase5_debug_bundle.sh
```

覆盖：

- metadata/config/log/metrics/alerts 全部存在。
- manifest sha256 校验通过。
- bundle 不包含原始媒体 payload。

### 6.6 External sample 门禁

```bash
scripts/verify_phase5_minimal_udp_external_app.sh
```

覆盖：

- 从 install prefix 构建 external sample。
- 链接 role bundle。
- 三角色 localhost UDP selftest。
- dual-track decoded。
- no PeerConnection / no SDK src include。
- 日志和 metrics 进入 output dir。

### 6.7 Release contract 门禁

```bash
scripts/verify_phase5_release_contract.sh
```

覆盖：

- 安装 prefix 包含 public headers、WebRTC adapter headers、role archives 和 role
  bundle archives。
- CMake package 导出普通 `role_*` 和 `role_*_bundle` target。
- 外部 consumer 分别链接普通 role target 和 role bundle target。
- runtime logging/metrics/alerts 字段在安装包 consumer 中可用。
- 发布包不暴露 PeerConnection，也不带回旧自研媒体栈。

### 6.8 生产验收门禁

Phase-5 顶层入口：

```bash
scripts/run_phase5_implementation_gate.sh
scripts/verify_phase5_implementation_gate.sh
scripts/verify_phase5_production_readiness.sh
scripts/run_phase5_production_gate.sh
scripts/verify_phase5_production_gate.sh
scripts/verify_phase5_completion_audit.sh
```

底层仍复用：

```bash
scripts/run_webrtc_first_phase2_production_gate.sh
scripts/verify_webrtc_first_phase2_completion_audit.sh
```

覆盖：

- Phase-5 implementation gate：no-selfmade、logging、metrics、alerts、error
  contract、minimal UDP external app、release contract 和 debug bundle 的可离线
  实现证据。
- Phase-5 production readiness preflight。
- Phase-5 release contract gate。
- Phase-5 debug bundle collect/verify。
- WebRTC-first production gate preflight、soak、renderer、capture library 和 audit。
- 可选导入专用测试机生成的 Phase-2 evidence bundle，并复验 `files.txt` /
  `manifest.sha256` / 实际文件集合一致性、completion
  audit、git head、production soak、真实 renderer、正式 capture library manifest 和
  capture manifest sha256、capture QoE CSV/summary 绑定，同时要求 bundle metadata 记录 clean tracked worktree。
- production soak archive 必须记录并验证 clean tracked worktree；只允许未跟踪
  artifacts/build 目录存在，不能用带 tracked 源码修改的 soak 结果作为正式证据。
- 顶层 metadata、summary、logs，以及 `files.txt` / `manifest.sha256` / 实际文件集合一致性。
- 正式 production gate metadata 和 release evidence 必须证明 tracked worktree clean；
  未跟踪 artifacts/build 目录不阻塞，但未提交的 tracked 源码修改不能生成 pass 证据。
- 顶层 `phase5_implementation_gate_metrics.prom` 必须覆盖 implementation gate
  status、step status 和 debug bundle status。
- 顶层 `phase5_production_gate_metrics.prom` 必须覆盖 gate status、step status、
  failure debug bundle status 和 release evidence status。
- 底层 Phase-2 completion audit 必须输出 `phase2_completion_audit_metrics.prom`，
  覆盖 audit/completion status、check status 和 production evidence status。
- production wrapper 必须在进入 readiness/soak 前复验 implementation gate，不能只
  运行不校验。
- 成功路径必须离线复验 `phase5_implementation_gate/`，确认实现证据在 production
  gate 内闭合。
- 成功路径必须离线复验 `git_tracked_status.txt` 和
  `GIT_TRACKED_WORKTREE_CLEAN=1`，确认正式证据对应已提交源码。
- 成功路径 release evidence 必须索引并离线复验
  `phase5_implementation_gate/phase5_implementation_gate_metrics.prom`。
- 成功路径 release evidence 必须索引并离线复验底层
  `phase2_completion_audit/phase2_completion_audit_metrics.prom`。
- 成功路径必须离线复验 `phase5_debug_bundle/`，确认日志、metrics、alerts、
  timeline 和 runtime config 都可用。
- 成功路径必须生成并离线复验 `phase5_release_evidence.json`，确认 production soak、
  production soak 原始 summary/CSV/archive、真实 renderer summary/metrics、正式
  capture library、capture QoE CSV、evidence bundle 和 completion audit 都有 pass
  证据指针，并通过 `verify_webrtc_first_qoe_production_soak_evidence.sh` 确认长时 soak
  summary/CSV/config/archive 一致且满足 P5 下限，通过 `verify_real_renderer_evidence.sh` 确认真实 renderer 非 Xvfb、实际 rendered frames 和 present 预算均通过，通过 `verify_capture_library_evidence.sh` 确认 capture manifest/QoE 绑定和质量门槛均通过，同时写出 production soak rows、real renderer backend 和 capture QoE
  rows/minima 供排障。
- 成功路径必须离线复验底层 Phase-2 evidence bundle 和 completion audit，确认
  production soak、真实 renderer、正式 capture library 均为 pass，且 `.prom`
  指标中的生产证据状态也是 pass。
- 非 dry-run 失败时自动输出 verified `failure_debug_bundle/`，并由顶层 verifier
  强制校验。
- readiness 失败时必须保留并校验 readiness summary、logs、manifest 和
  `readiness_report.json`、`next_required_actions.json`、`risk_milestone_report.json`、
  `phase5_production_readiness_metrics.prom`、`next_required_actions.txt`。
- readiness 风险/里程碑报告必须明确 M1 是否 blocked/ready、R4 生产环境风险状态、
  M6 fanout deferred，以及正式完成仍依赖 passed Phase-5 production gate。
- readiness Prometheus/textfile 指标必须覆盖 readiness 状态、失败/跳过/action 数、
  check status、M1/M6 里程碑、R4/R5 风险和 remediation action。
- completion audit 对“implementation gate 已通过但正式生产证据缺失”和“正式完成”
  做硬区分。
- completion audit 必须输出并自校验 `phase5_completion_audit_metrics.prom`，覆盖
  audit/completion status、check status、production evidence status 和 next required
  action。

## 7. 里程碑

### M1：生产证据闭环

- 准备正式 capture library。
- 在有真实显示环境的机器跑 renderer。
- 跑 `SOAK_MINUTES>=120` production gate。
- 收集 evidence bundle 并 audit 通过。

### M2：日志文件化

- 引入统一 logger。
- role facade 接入 `RuntimeLogConfig`。
- demo/external sample 支持 `--log-dir`。
- stdout 只保留 summary。
- 日志轮转、`Stop()` flush、CI artifact 收集通过。

### M3：Metrics / Alerts / Debug Bundle

- metrics snapshot 文件化。
- alerts 规则落地。
- metrics/alerts 轮转、保留文件数和 artifact 收集通过。
- debug bundle 收集和校验脚本落地。
- weak network、decode error、transport failure 三类问题可定位。

### M4：External Minimal UDP App

- 样板工程落地。
- install prefix 构建通过。
- 三进程和 selftest 通过。
- README 和最小 UDP 文档同步。

### M5：Release Contract

- 错误码和运行契约文档化。
- 发布包 README 更新。
- 外部 CMake consumer 兼容。
- no-selfmade media stack 门禁仍通过。

### M6：多接收端后段评估

- 只在 M1-M5 完成后评估。
- 决定是否把 receiver registry / fanout 纳入 Phase-5 后段。
- 如果纳入，必须先补 receiver 维度日志、metrics、alerts。

## 8. 风险与取舍

### 8.1 日志影响实时性

风险：高频 packet 日志可能阻塞媒体线程。

取舍：

- info 默认只记录状态变化和异常。
- packet 级日志只在 debug/trace。
- 文件写入走缓冲或异步队列。
- 队列满时优先丢 debug/trace，保留 warn/error。

### 8.2 日志泄露敏感信息

风险：日志可能包含 payload、token、用户隐私。

取舍：

- 禁止记录 RTP/H264 payload bytes。
- config dump 支持脱敏。
- 默认只记录 ID、size、sequence、状态和错误原因。

### 8.3 告警过多导致不可用

风险：弱网场景本身会产生 NACK、降码率和重传，不能全部当 fatal。

取舍：

- 区分 expected degradation 和 failure。
- weak network 下 bitrate/FPS 下探是正常事件，不是 fatal。
- decode error、freeze、transport output failure 才是强告警。

### 8.4 生产证据依赖环境

风险：真实 renderer 和正式 capture library 不是本机一定能完成。

取舍：

- 把环境要求写进 release gate。
- 本机短时 smoke 不能冒充正式验收。
- evidence bundle 必须记录环境信息。

### 8.5 多接收端过早进入会放大排障成本

风险：如果没有日志/metrics/alerts，fanout 问题很难定位。

取舍：

- P5 以前不做多接收端产品化。
- P5 内也先做生产集成化，再评估 receiver registry / fanout。

## 9. 完成定义

Phase-5 基础完成必须同时满足：

- `GATE_DIR=<implementation_gate> scripts/verify_phase5_implementation_gate.sh` 通过。
- `PHASE5_GATE_DIR=<passed_gate> scripts/verify_phase5_completion_audit.sh` 通过。
- 正式 production evidence bundle audit 通过。
- push/server/play 正式日志文件化，支持轮转和 artifact 收集。
- metrics snapshot、alerts、debug bundle 可用。
- external minimal UDP app 从 install prefix 构建并 selftest 通过。
- README、最小 UDP 文档、SDK 集成说明、测试方法文档全部同步。
- 旧 single-track / dual-track demo 仍通过。
- `verify_no_selfmade_media_stack.sh` 仍证明旧自研 media stack 没回到 public API。
- 发布包仍不包含完整 PeerConnection / ICE / DTLS / SRTP 路线。

多接收端 fanout 不作为 Phase-5 基础完成条件。只有当团队明确把 M6 纳入本期最终
范围时，才把 receiver registry / fanout runtime smoke 加进完成定义。

## 10. 推荐执行顺序

最合理顺序：

1. 跑生产证据，暴露真实环境问题。
2. 做日志文件化，替换散落 stdout/stderr 运行日志。
3. 做 metrics、alerts、debug bundle。
4. 做 external minimal UDP app，把日志/metrics/alerts 带进去。
5. 固化错误码、发布契约和文档。
6. 最后再评估多接收端 fanout 是否进入 Phase-5 后段。

这个顺序的核心理由：先让单 sender / 单 receiver / 多 track 主路径可验收、可排障、
可监控，再扩展更复杂拓扑。
