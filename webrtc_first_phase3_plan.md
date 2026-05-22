# WebRTC-first Phase-3 计划：逻辑正确性与生产边界收敛

## 1. 背景

Phase-2 已经把 SDK 主路径推进到 WebRTC-first：业务侧继续掌握网络 IO、连接生命周期、会话/流/接收端映射和控制策略；SDK 只把媒体和 QoS 相关能力封装成 push/play/server 三类 facade；WebRTC 负责成熟的 RTP/RTCP、H264 RTP、GoogCC、pacing、NACK/PLI、jitter/reorder 和统计能力。

Phase-3 不建议继续横向扩大量，而是先把当前实现里会影响长期正确性的逻辑问题收敛掉。核心目标是：让当前 WebRTC-first 链路在 sender 重传、server 侧 receiver_id / RTCP 身份边界、RTCP compound 处理和指标命名上经得住生产场景，而不是只通过 smoke/demo。

当前 review 基于代码 HEAD：

```text
44835d163c6d9c773988eb7b0b04d5e31d0c544d
```

## 1.1 当前审核状态

基于当前仓库工作区的最新实现，Phase-3 的核心逻辑工作包已经基本落地：

- `4.1 sender NACK retransmission via pacer` 已实现，并已进入 `verify_cmake_package.sh` 自动化门禁。
- `4.2 SR count excludes original-packet retransmission` 已实现，并已进入 `verify_cmake_package.sh` 自动化门禁。
- `4.3 RTCP identity split` 已实现到当前 SDK 边界：`receiver_id` 继续作为业务路由身份，RTCP sender SSRC 则通过 `receiver_feedback_ssrc / server_feedback_ssrc` 显式配置或自动派生，不再直接等同于业务 `receiver_id`。
- `4.4 compound RTCP unsupported visibility` 已实现：unsupported RTCP packet 会被显式计数并默认 drop。
- `4.5 RTX naming audit` 已完成到当前公开文档、demo 和脚本输出边界：当前统一对外表述为 `retransmission`，并明确“不支持 RFC4588 RTX”。

当前仍未完成的，主要已经收敛为正式验收证据而不是新的核心实现：

- `SOAK_MINUTES>=120` 的 production soak 实跑和归档
- 真实 renderer `pass`
- 正式 `capture_library/manifest.csv` 和业务素材库

阶段边界说明：Phase-3 里提到的多 receiver 只指业务 `receiver_id` 与 RTCP
SSRC 不混用、反馈路由身份不串这类逻辑正确性问题；它不是多接收端产品化，不包含
receiver registry，也不包含 sender RTP 自动 fanout。P5 以前不做多接收端
fanout 工程化。

## 2. Phase-3 原则

1. 能用 WebRTC 的能力必须继续用 WebRTC。
   sender 侧 pacing、重传优先级、probe/queue 调度不应绕过 WebRTC `PacingController`。

2. 业务只掌握传输和策略外壳。
   业务可以决定 bytes 怎么送、送给谁、何时切路由、如何映射 receiver，但不在 SDK facade 里重新实现 RTP/RTCP/NACK/pacer/jitter 策略。

3. 当前继续固定 H264。
   Phase-3 不引入多 codec 协商，也不做 PeerConnection/ICE/DTLS/SRTP。

4. RTX 命名必须准确。
   当前实现是 NACK 后原 RTP 包重传，不是 RFC4588 RTX。除非正式实现 RTX payload type、apt、OSN 和 RTX SSRC，否则文档和指标不应把它叫 RTX。

5. 优先修逻辑正确性，再补生产级验收。
   三期的重点不是新增 demo，而是让已有路径在 burst loss、receiver_id / RTCP 身份边界、compound RTCP 和长时间运行下不出语义错误。

## 3. 总体结论

当前代码已经达到 Phase-3 计划的主要逻辑目标：push/play/server 继续复用 WebRTC 的核心媒体 QoS 能力；业务 IO 和路由仍在 facade 外部；sender NACK 重传入 pacer、SR 去重、receiver_id 与 RTCP SSRC 身份拆分、compound RTCP unsupported 可观测性和当前能力命名清理，已经落到当前实现和自动化门禁。

当前真正仍未闭合的，主要是正式生产证据而不是新的核心逻辑实现：

- `SOAK_MINUTES>=120` 的正式 production soak
- 真实 renderer `pass`
- 正式 `capture_library/manifest.csv` 和业务素材库

## 4. Phase-3 工作包

### 4.1 P1：sender 侧 NACK 重传必须进入 WebRTC pacer

#### 当前问题

`VideoPushClient::HandleNack()` 查到 sender packet history 后，会重建 RTP 包并直接调用 `EmitPacketNow()` 发出。这个路径绕过了 `PacingAdapter`，导致两个问题：

- 重传不受 WebRTC `PacingController` 的 retransmission priority、queue、probe 和发送时机控制。
- `EmitPacketNow()` 会递增 `emitted_packets_`，但这类直接重传没有递增 `queued_packets_`。如果发生 NACK burst，可能出现 `emitted_packets_ > queued_packets_`，后续 `DrainPacer()` 因 `emitted_packets_ < queued_packets_` 条件不满足而不再 drain 新入队媒体包。

#### 最合理方案

sender 侧重传不直接发。重建出 `PacingAdapterPacket` 后，设置 `retransmission=true`，调用 `pacer_->EnqueuePacket(packet)`，并由 `Process(now_us)` 通过 `DrainPacer()` 发出。

同时，去掉或弱化 facade 外部的 `queued_packets_ / emitted_packets_` 门控。更合理的做法是信任 `PacingAdapter::Process()` 和 `PacingAdapter::stats()`，facade 只负责把 WebRTC pacer 出队的包送给业务 transport output。

#### 实施要点

- 新增 `EnqueueRetransmission()` 内部函数，复用普通媒体包入 pacer 的错误处理。
- 重传包入队失败时，不 reset 整个 pacer 队列；优先记录 dropped/retransmission dropped 指标，并允许后续媒体继续发送。
- `DrainPacer()` 不再依赖 `emitted_packets_ < queued_packets_` 作为唯一门控。
- `PacingAdapter` 已经支持 retransmission priority，facade 不再自行决定重传立即发送。

#### 验收标准

- sender 收到 NACK 后，不在 `OnTransportFeedback()` 调用栈内直接输出 RTP 重传包。
- 调用 `Process(now_us)` 后，重传包从 pacer 出队，`TransportPacketMetadata::retransmission=true`。
- NACK burst 后继续 push 新 AU，不出现 pacer 队列卡死。
- pacing adapter 的 retransmission priority 测试仍通过。

### 4.2 P1：RTCP SR 发送统计区分原始媒体和重传

#### 当前问题

`EmitPacketNow()` 对所有非 padding RTP 都递增 `sent_rtp_packet_count_` 和 `sent_rtp_octet_count_`。当前 sender 重传不是 RFC4588 RTX，而是同 SSRC、同 RTP sequence 的原媒体包重发。把这类包重复计入 SR media packet/octet count，会让 RTCP SR 统计偏大。

#### 最合理方案

当前原 RTP 包重传不计入 SR 的 media packet/octet count，只单独计入 recovery/retransmission 指标。未来如果实现 RFC4588 RTX，再为 RTX SSRC/PT 建立独立统计语义。

#### 实施要点

- `!packet.padding && !packet.retransmission` 时才递增 SR media packet/octet count。
- `QosSnapshot` 可以补一个 sender-side retransmission counter，或者复用现有 `retransmission_count` 但明确它是累计重传输出。
- packet history 可以继续保存重传包，但需要避免它覆盖原包语义后导致下一次 NACK 查到的是重传副本而不是原始媒体包。

#### 验收标准

- 发送 N 个原始媒体 RTP 后，SR packet_count 等于 N。
- 触发 M 次原 RTP 重传后，SR packet_count 仍等于 N。
- 重传指标能单独体现 M。

### 4.3 P1：server 侧 receiver_id / RTCP 身份和状态拆分

#### 当前问题

server 转发 NACK/PLI 时已经能把 metadata 的 receiver_id 带对，但 server 自己生成的 uplink TWCC 和 Receiver Report 仍使用全局 `config_.session.ids.receiver_id` 作为 RTCP sender SSRC。与此同时，`pending_twcc_packets_`、`last_sender_report_lsr_`、`last_rr_send_time_us_` 等状态也是全局的。

单 receiver smoke 可以通过，但一旦业务侧输入多个 receiver_id 的反馈事件：

- 业务 receiver_id 和 RTCP sender SSRC 容易混用。
- 不同 receiver 的 RR/TWCC 节奏和状态可能串扰。
- server 作为 relay/router 时，RTCP 身份不够清晰。

#### 最合理方案

把业务 receiver_id 与 RTCP SSRC 显式分离：

- `receiver_id`：业务路由身份，决定包发给哪个下游。
- `receiver_rtcp_ssrc`：下游 receiver 产生 RTCP 时使用的 sender SSRC。
- `server_rtcp_ssrc`：server 为 uplink feedback 或 server-generated RR 使用的 RTCP sender SSRC。

server 内部维护 per-receiver RTCP state。对于上行 sender -> server 的 TWCC，server 作为接收者可以使用稳定的 `server_rtcp_ssrc`；对于 receiver 下行质量、RR/NACK/PLI 路由，使用 per-receiver state 和业务 receiver_id 做映射。

#### 实施要点

- 扩展 `SessionConfig` 或新增 role-specific config，避免继续把 `TransportIds::receiver_id` 当 RTCP SSRC 使用。
- 将 RR 发送节奏、last SR 信息、下行质量状态按 receiver 或按方向拆分。
- `ServerQosRouter::OnReceiverRtcp(receiver_id, ...)` 保持业务路由入口不变。
- metadata 的 receiver_id 继续作为业务分发字段，不替代 RTCP packet 内部 SSRC。

#### 验收标准

- 两个 receiver 同时接入时，本地重传只回到请求的 receiver。
- 两个 receiver 的 NACK/PLI metadata receiver_id 不串。
- server-generated RTCP sender SSRC 不再等于业务 receiver_id。
- 多个 receiver_id 的下行质量输入下，worst-receiver sender cap 仍能正确选择最差接收端。

### 4.4 P2：compound RTCP 的 unsupported block 策略显式化

#### 当前问题

`ForEachSupportedRtcpPacket()` 当前只处理 SR/RR/TWCC/NACK/PLI。compound RTCP 中其它 block 会被静默跳过。短期没问题，但作为 server relay，未来遇到 SDES、FIR、XR、BYE、REMB 等 RTCP block 时会被悄悄吞掉。

#### 最合理方案

短期把策略写死并显式化：

- SDK 当前只承诺 SR/RR/TWCC/NACK/PLI。
- unsupported RTCP block 默认 drop，并计数或日志可观测。
- 如果业务需要 RTCP 透明 relay，再引入 passthrough mode，而不是默认半解析半转发。

#### 实施要点

- `ForEachSupportedRtcpPacket()` 返回 supported/unsupported 统计。
- server 对 unsupported block 增加 snapshot/debug counter。
- 文档明确当前 RTCP 支持边界。
- 如果开启 passthrough，必须保证不会把已处理的 NACK/PLI 重复转发。

#### 验收标准

- compound RTCP 包含 supported + unsupported block 时，supported block 正常处理。
- unsupported block 的 drop 行为可观测。
- 文档不再暗示 server 会透明保留所有 RTCP。

### 4.5 P2：清理 RTX 命名，保留 RFC4588 作为未来能力

#### 当前问题

代码和文档中大量使用 `RTX`、`rtx`、`local RTX` 来描述当前重传。但当前实现没有 RTX payload type、apt、OSN、RTX SSRC，不是 RFC4588 RTX。

#### 最合理方案

Phase-3 不实现 RFC4588 RTX，先统一命名为：

- `NACK retransmission`
- `local retransmission`
- `original RTP retransmission`

只有真正实现 RFC4588 时，才恢复使用 `RTX`。

#### 实施要点

- README、docs、scripts 输出里的 `rtx` 字段改成 `retransmission`。
- 测试场景名可以继续表达“丢包恢复”，但不要用 RTX 作为当前能力名。
- 增加一个文档小节说明：当前支持 NACK + 原包重传，不支持 RFC4588 RTX。

#### 验收标准

- 文档中不存在把当前实现称为 RFC4588 RTX 的描述。
- CSV/header/log 中 `rtx` 字段迁移为 `retransmission`，或者明确标注为 legacy alias。
- 用户问“是否支持 RTX”时，答案能直接从文档得到：当前不支持 RFC4588 RTX。

## 5. 测试与门禁计划

### 5.1 必补测试

1. sender NACK retransmission via pacer
   - 构造 sender packet history。
   - 注入 NACK。
   - 确认 `OnTransportFeedback()` 不直接输出 RTP。
   - `Process()` 后输出 retransmission RTP。

2. sender pacer no-deadlock under NACK burst
   - 连续注入多个 NACK。
   - 再 push 新 AU。
   - 多次 tick 后新 AU 能继续出队。

3. SR count excludes original-packet retransmission
   - 发送 N 个原始 RTP。
   - 触发 M 次重传。
   - 验证 SR packet/octet count 不重复计算重传。

4. server receiver-id NACK routing identity
   - receiver A 和 receiver B 分别请求不同 packet。
   - 本地命中包只回对应 receiver。
   - miss NACK 只带 miss packet ids 上抛 sender。

5. RTCP identity split
   - server-generated TWCC/RR 的 sender SSRC 不等于业务 receiver_id。
   - 不同 receiver_id 的状态不串。

6. compound RTCP unsupported visibility
   - supported block 正常处理。
   - unsupported block drop counter 增加。

7. RTX naming audit
   - docs/scripts 中当前能力统一叫 retransmission。

### 5.2 应继续保留的门禁

- no-selfmade RTP/RTCP/NACK/pacer/video jitter public fallback。
- WebRTC module smoke。
- 外部 CMake package consumer。
- WebRTC-first loopback。
- pacing probe。
- role facade smoke。
- synthetic 弱网矩阵。
- FFmpeg H264 QoE smoke。
- 多 seed / 长流 / production soak。
- capture library 和真实 renderer gate。

### 5.3 Phase-3 完成判定

Phase-3 完成不能只看 demo 输出，需要满足：

- 上述必补测试全部进入自动化门禁。
- sender 重传路径没有绕过 WebRTC pacer。
- receiver_id、RTCP sender SSRC 和业务路由身份不混用。
- 所有当前文档都准确说明“不支持 RFC4588 RTX，只支持 NACK 原包重传”。
- production soak 中没有 pacer drain 卡死、RTCP 状态串扰、重传统计异常。

## 6. 非目标

Phase-3 暂不做以下内容：

- 不实现完整 PeerConnection。
- 不接管业务网络 IO、连接、鉴权、会话管理。
- 不引入多 codec 协商。
- 不默认实现 RFC4588 RTX。
- 不引入 FEC、SVC、Simulcast。
- 不把 server 做成完整 SFU。

这些能力可以进入后续期，但不应阻塞 Phase-3 的逻辑正确性收敛。

## 7. 推荐执行顺序

1. 先修 sender 重传入 pacer，并移除 `queued_packets_ / emitted_packets_` 的死锁风险。
2. 修 SR 重传统计语义。
3. 拆 server RTCP SSRC 与业务 receiver_id，并补 receiver_id 维度状态。
4. 明确 compound RTCP unsupported block 策略。
5. 全仓清理 RTX 命名。
6. 补齐自动化测试和 production soak 证据。

这个顺序的原因是：sender 重传和 pacer 是当前最可能影响单链路正确性的风险；server 侧 receiver_id / RTCP 身份边界是进入真实业务拓扑前必须解决的语义风险；RTCP unsupported 和 RTX 命名属于边界清晰度问题，应该在三期收尾时统一落地。
