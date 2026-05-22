# QoS 测试与验证方法

本文档回答 4 个问题：

1. 为什么 QoS 不能只靠感觉判断
2. 为什么我们的测试要分成这么多层
3. 我们到底看哪些指标
4. 怎样才能说“这个 QoS 是可信的”

## 1. 为什么一定要做系统化测试

QoS 正不正确，通常不是靠单一场景能看出来的。

如果只看“能不能播出画面”，很容易漏掉：

- 弱网进入时 sender 下探不够快
- 网络恢复时 sender 回升不够快
- 瞬时 RTT/丢包被掩盖，长流里才出问题
- 多接收端场景里 worst receiver 策略失真
- server history miss 时恢复链路断掉

所以我们不把 QoS 理解成“码率降下来了就行”，而是理解成：

- 进入弱网时能不能及时降
- 网络恢复时能不能稳定升
- 丢包后能不能恢复
- 持续弱网时能不能继续保持低发送
- 多接收端时能不能选对约束源
- 上述行为是不是可重复、可量化、可归档

## 2. 我们的测试分层

### 2.1 Smoke

目的：

- 先验证基本链路没断
- 保证 source build / package / role facade / demo 都能跑

代表脚本：

- `scripts/verify_webrtc_modules.sh`
- `scripts/verify_cmake_package.sh`
- `scripts/verify_webrtc_first_loopback.sh`
- `scripts/verify_webrtc_first_pacing_probe.sh`
- `scripts/verify_webrtc_first_roles.sh`
- `scripts/verify_webrtc_first_phase2.sh VERIFY_LEVEL=smoke`

它证明的是：

- 代码没坏
- WebRTC-first 主路径能跑
- 安装包和 role target 可消费

它**不证明**：

- 真实 QoS 一定最优
- 生产级长时间稳定性

### 2.2 Synthetic 弱网矩阵

目的：

- 把进入弱网、恢复、持续弱网、弱网起步、多接收端、dead-zone 这些关键控制场景拆开验

代表脚本：

- `scripts/run_webrtc_first_facade_matrix.sh`

它证明的是：

- sender 能不能在弱网窗口里持续低发送
- 恢复段能不能回升
- server 的 rate cap 策略是不是按预期工作
- NACK/重传/PLI 链路是不是可观测

### 2.3 真实 H264 QoE

目的：

- 不只验证控制逻辑，还验证真实编码输出经过 push/server/play/decoder 后的实际效果

代表脚本：

- `scripts/run_webrtc_first_ffmpeg_qoe.sh`
- `scripts/run_webrtc_first_qoe_low_rps_low_bitrate_check.sh`
- `scripts/run_webrtc_first_qoe_stability_720p.sh`
- `scripts/run_webrtc_first_qoe_multiseed_720p.sh`
- `scripts/run_webrtc_first_qoe_long_dynamic.sh`
- `scripts/run_webrtc_first_qoe_soak_720p.sh`
- `scripts/run_webrtc_first_qoe_high_complexity_720p.sh`
- `scripts/run_webrtc_first_qoe_content_library_720p.sh`
- `scripts/run_webrtc_first_qoe_capture_library_720p.sh`

它证明的是：

- QoS 控制逻辑最终有没有转化成稳定画面
- 真实编码器在弱网窗口内有没有真的降 FPS / 降 RPS / 降码率
- 解码是否稳定
- 恢复速度是否足够快

### 2.4 Production Gate

目的：

- 把正式验收条件固化成一条命令

代表脚本：

- `scripts/run_webrtc_first_phase2_production_gate.sh`

它做三件事：

1. preflight：模块、真实 renderer、正式 capture manifest
2. production verify：`VERIFY_LEVEL=production`
3. evidence bundle + completion audit

### 2.5 Completion Audit

目的：

- 防止“短时 smoke 看起来像是完成了”

代表脚本：

- `scripts/verify_webrtc_first_phase2_completion_audit.sh`

它只认强证据：

- `smoke` 通过
- `qoe` 通过
- `SOAK_MINUTES>=120` 的正式 production soak
- `real_renderer_status=pass`
- 正式 capture manifest

## 3. 为什么场景要这样设计

### 3.1 Good Static

作用：

- 证明好网下没有被 QoS 自己搞坏

如果这个场景都不稳，后面的弱网结论都没意义。

### 3.2 Burst Loss Recover

作用：

- 看短 burst loss 时，系统能不能靠 `NACK/重传` 恢复，而不是无意义地降码率

这类场景不要求 sender 下探码率，因为它不是持续带宽问题。

### 3.3 Bandwidth Cliff Recover

作用：

- 看 sender 遇到突发带宽 cliff 时，能不能尽快下探，再在恢复段回升

这是最典型的“QoS 是否真的在起作用”的场景。

### 3.4 Weak Network Low-RPS Low-Bitrate

作用：

- 专门验证弱网窗口内 sender 能不能以较低 RPS 和较低码率持续发送

这不是“瞬时触底”测试，而是“整个弱网窗口都要压住”。

### 3.5 Sustained Low Bandwidth

作用：

- 验证 sender 在持续弱网里不会自己回升

如果这条不过，说明 sender 对坏网过于乐观。

### 3.6 Weak Start

作用：

- 验证从第一帧开始就是坏网时，sender 不会先按好网码率猛冲一段

### 3.7 Walking Dead Zone Recover

作用：

- 验证“弱网 + 实际下行丢包 + 本地/远端恢复链路”这条组合场景

这里不只看码率/FPS，还看 `NACK/重传` 是否真的发生。

### 3.8 Multi-Receiver Worst Cap

作用：

- 验证 server 是否真的按最差 receiver 限 sender，而不是被健康 receiver 冲掉 cap

### 3.9 Oscillating Edge Recover

作用：

- 验证链路反复变坏/变好时，sender 能不能多次下探、多次回升

### 3.10 High Complexity / Content Library / Capture Library

作用：

- 避免只在“简单画面”上得到好结论
- 让结果对真实业务内容更可信

## 4. 我们看哪些指标

### 4.1 QoS 控制指标

这些指标回答“控制逻辑有没有按预期工作”：

- `bad_send_rps`
- `bad_rtp_pps`
- `max_bad_target_bps`
- `max_bad_encoder_fps`
- `recovery_send_rps`
- `max_recovery_target_bps`
- `max_recovery_encoder_fps`
- `target_recovery_time_ms`
- `fps_recovery_time_ms`
- `full_recovery_time_ms`
- `sender_rate_cap_bps`
- `rtt_ms`
- `nack_count`
- `pli_count`
- `retransmission_count`

### 4.2 QoE 输出指标

这些指标回答“用户看到的结果是不是还能接受”：

- `playable_ratio`
- `decode_errors`
- `avg_psnr_y`
- `avg_ssim_y`
- `freeze_count`
- `freeze_duration_ms`
- `max_inter_render_gap_ms`
- `renderer_proxy_late_frames`
- `renderer_proxy_drop_frames`
- `renderer_proxy_max_gap_ms`
- `renderer_proxy_max_jitter_ms`

### 4.3 为什么要同时看 QoS 和 QoE

只看 QoS，会漏掉：

- sender 虽然降码率了，但画面已经崩了

只看 QoE，会漏掉：

- 画面碰巧还行，但 sender 的控制策略其实不稳定

所以我们必须两类指标一起看。

## 5. 我们怎么通过结果判定“正确”

### 5.1 不是看单个数字，而是看因果链

可信的结论必须满足：

1. 弱网窗口里 sender 真的下探
2. 恢复窗口里 sender 真的回升
3. 丢包场景里 NACK/重传/PLI 真的发生
4. 解码/播放结果仍然可接受
5. 长流和多 seed 场景里结论可重复

### 5.2 典型判定方式

#### 弱网下探成立

看：

- `bad_send_rps <= 阈值`
- `bad_rtp_pps <= 阈值`
- `max_bad_target_bps <= 阈值`
- `max_bad_encoder_fps <= 阈值`

这几项同时满足，才说明 sender 在整个弱网窗口都压住了。

#### 恢复成立

看：

- `recovery_send_rps >= 阈值`
- `max_recovery_target_bps >= 阈值`
- `max_recovery_encoder_fps >= 阈值`
- `full_recovery_time_ms <= 阈值`

#### 持续弱网成立

看：

- 最终 `final_target_bps` 仍然低
- 最终 `final_encoder_fps` 仍然低
- sender 没在没有恢复的情况下自己回升

#### 恢复链路成立

看：

- `nack_count > 0`
- `retransmission_count > 0`
- 必要时 `pli_count > 0`

#### QoE 可接受

看：

- `playable_ratio` 不低于门槛
- `decode_errors == 0`
- `freeze_count == 0`
- `avg_psnr_y / avg_ssim_y` 不低于门槛

## 6. 为什么这些结果是“可信的”

可信不是因为“数值看起来不错”，而是因为我们做了下面这些约束：

- 同一套 facade 主路径覆盖 smoke / matrix / qoe / production
- 不再拿旧自研链路做 Phase-2 结论
- 有 synthetic，也有真实 H264 encode/decode
- 有短流，也有长流、multi-seed、oscillating、high-complexity、content-library
- 有 evidence bundle、archive、sha256 manifest
- 有 completion audit，防止把 short smoke 当完成

## 7. 当前测试仍不能证明什么

当前 smoke / matrix / qoe 已经补上并验证了这些三期逻辑点：

- sender 收到 NACK 后不会在 `OnTransportFeedback()` 调用栈里同步直发 RTP；重传会重新进入 WebRTC pacer，并由后续 `Process(now_us)` 出队。
- RTCP SR 的 media packet/octet count 不再重复统计原 RTP 包重传。
- play 侧 receiver feedback SSRC 和 server 侧 uplink feedback SSRC 已经和业务 `receiver_id` 显式拆开。
- compound RTCP 中 unsupported block 的 drop 行为已经可观测，server 会累计 unsupported RTCP packet 计数。

当前仍不能当成已经被测试完全证明的，主要只剩正式验收闭环：

- `SOAK_MINUTES>=120` 的 production soak
- 真实 renderer `pass`
- 正式 `capture_library/manifest.csv`

因此，当前测试结论更准确的表述应该是：

- WebRTC-first 主路径已经可运行、可验证、可归档。
- 主要弱网控制、恢复、RTCP 身份拆分和 compound RTCP drop 行为已经有证据。
- 但正式验收边界仍有未完成项，详见 [Phase-3 逻辑正确性收敛计划](../webrtc_first_phase3_plan.md) 和 [Phase-2 主实施文档](../webrtc_first_phase2_master_plan.md)。

## 8. 推荐阅读顺序

如果你要完整理解这个项目，建议按下面顺序读：

1. [WebRTC QoS 总览与 SDK 设计说明](webrtc_qos_overview.md)
2. 本文
3. [推拉客户端 SDK 集成说明](sdk_push_play_integration.md)
4. [WebRTC 子模块拆分编译说明](webrtc_module_split_build.md)
5. [Phase-2 主实施文档](../webrtc_first_phase2_master_plan.md)
6. [Phase-3 逻辑正确性收敛计划](../webrtc_first_phase3_plan.md)
