# 弱网场景 QoS/QoE 结果

本文记录当前 P5 证据里的弱网场景参数和表现。README 只保留摘要，这里保留可复查的场景、参数、QoS 指标和 QoE 指标。

## 数据来源

当前结果来自 P5 顶层生产门禁证据。具体 git commit 以 evidence 目录内的 `metadata.txt` 为准。

- production gate：`/root/output/phase5_p5_final_gate_imported`
- metadata：`metadata.txt`
- formal soak CSV：`webrtc_first_production_gate/phase2_evidence_bundle/production_soak/webrtc_first_qoe_production_soak.csv`
- formal soak summary：`webrtc_first_production_gate/phase2_evidence_bundle/production_soak/webrtc_first_qoe_production_soak_summary.txt`
- protocol loss matrix log：`webrtc_first_production_gate/phase2_evidence_bundle/qoe/logs/facade_weak_network_matrix.log`

复验入口：

```bash
GATE_DIR=/root/output/phase5_p5_final_gate_imported \
REQUIRE_PASS=1 \
scripts/verify_phase5_production_gate.sh

PHASE5_GATE_DIR=/root/output/phase5_p5_final_gate_imported \
REQUIRE_PRODUCTION_EVIDENCE=1 \
scripts/verify_phase5_completion_audit.sh
```

## 指标口径

- QoS 指标：RTP drop、NACK、重传、发送 AU RPS、RTP pps、目标码率、编码 FPS、renderer proxy latency/gap/jitter、late/drop frames、恢复时间。
- QoE 指标：playable ratio、PSNR-Y、SSIM-Y、decode errors、freeze count。
- renderer proxy latency 是播放调度代理延迟，不是物理网络 RTT 或真实 GPU present latency。
- P5 formal production soak 默认不注入真实 RTP 丢包；它注入 receiver quality 信号触发弱网降级。真实 RTP 丢包恢复由 protocol/facade matrix 单独覆盖。

## Formal P5 Soak 配置

| 参数 | 值 |
| --- | --- |
| soak 时长 | `10min` |
| cycles / rows | `8 cycles` / `64 rows` |
| 分辨率 / 帧率 | `1280x720` / `30fps` |
| 每个 case 帧数 | `120` |
| 初始码率 | `1500000bps` |
| 编码码率范围 | `300000bps` - `2800000bps` |
| renderer proxy target delay | `350ms` |
| renderer proxy max latency gate | `500ms` |
| renderer proxy max gap gate | `150ms` |
| renderer proxy late/drop gate | `0 late frames` / `0 drop frames` |
| 内容 | `block_motion`、`camera_pan`、`scene_cut`、`low_light_noise` |
| 正式场景 | `baseline`、`weak_network_low_rps_low_bitrate` |

`weak_network_low_rps_low_bitrate` 的弱网窗口是第 `30` 到 `90` 帧，也就是 120 帧 case 的 `25%` 到 `75%` 区间。窗口内注入：

| 注入项 | 值 |
| --- | --- |
| `DownlinkQuality.fraction_lost_q8` | `192`，约等于 `75%` receiver-reported loss |
| `DownlinkQuality.video_drop_frames` | `1` |
| `DownlinkQuality.recv_bitrate_bps` | `300000bps` |
| 期望降级 | `target_bps<=750000`，`encoder_fps<=10` |
| 期望恢复 | weak window 后恢复到 `30fps` 和 Mbps 级码率 |

## Formal P5 Soak 汇总

| 场景 | rows/pass | 弱网/丢包参数 | QoS 结果 | QoE 结果 |
| --- | --- | --- | --- | --- |
| `baseline` | `32/32` | 不注入弱网；实际 RTP drop `0` | NACK `0`，重传 `0`，max latency `350ms`，max gap `34ms`，max jitter `0ms`，late/drop frames `0/0` | playable min `0.9833`，PSNR-Y min `31.749`，SSIM-Y min `0.8137`，decode errors `0`，freeze `0` |
| `weak_network_low_rps_low_bitrate` | `32/32` | receiver-reported loss `75%`，video_drop `1`，实际 RTP drop `0` | bad send RPS max `10.3279`，bad RTP pps max `109.672`，target `<=750000bps`，encoder `<=10fps`，max latency `350ms`，max gap `100ms`，max jitter `67ms`，late/drop frames `0/0`，full recovery `0ms` | playable min `0.9625`，PSNR-Y min `31.815`，SSIM-Y min `0.8166`，decode errors `0`，freeze `0` |

结论：弱网窗口内 sender 被压到低 RPS、低 RTP pps、低码率和低 FPS；弱网结束后恢复到 `30fps`，`max_recovery_target_bps` 最低也有 `1746278bps`，且没有 decode error、freeze、renderer late/drop。

## Formal P5 按内容明细

| 内容 | 场景 | rows/pass | QoS 结果 | QoE 结果 |
| --- | --- | --- | --- | --- |
| `block_motion` | baseline | `8/8` | RTP drop `0`，NACK `0`，max latency `350ms`，max jitter `0ms` | playable min `0.9833`，PSNR-Y min `32.1626`，SSIM-Y min `0.9963` |
| `block_motion` | weak | `8/8` | RTP drop `0`，NACK total `208`，bad send RPS max `10.3279`，max jitter `67ms`，full recovery `0ms` | playable min `0.9625`，PSNR-Y min `31.9817`，SSIM-Y min `0.9961` |
| `camera_pan` | baseline | `8/8` | RTP drop `0`，NACK `0`，max latency `350ms`，max jitter `0ms` | playable min `0.9917`，PSNR-Y min `53.1744`，SSIM-Y min `0.9999` |
| `camera_pan` | weak | `8/8` | RTP drop `0`，NACK `0`，bad send RPS max `10.3279`，max jitter `67ms`，full recovery `0ms` | playable min `0.9875`，PSNR-Y min `53.253`，SSIM-Y min `0.9998` |
| `scene_cut` | baseline | `8/8` | RTP drop `0`，NACK `0`，max latency `350ms`，max jitter `0ms` | playable min `0.9917`，PSNR-Y min `39.419`，SSIM-Y min `0.9974` |
| `scene_cut` | weak | `8/8` | RTP drop `0`，NACK `0`，bad send RPS max `10.3279`，max jitter `67ms`，full recovery `0ms` | playable min `0.9875`，PSNR-Y min `38.0901`，SSIM-Y min `0.9955` |
| `low_light_noise` | baseline | `8/8` | RTP drop `0`，NACK `0`，max latency `350ms`，max jitter `0ms` | playable min `0.9917`，PSNR-Y min `31.749`，SSIM-Y min `0.8137` |
| `low_light_noise` | weak | `8/8` | RTP drop `0`，NACK `0`，bad send RPS max `10.3279`，max jitter `67ms`，full recovery `0ms` | playable min `0.975`，PSNR-Y min `31.815`，SSIM-Y min `0.8166` |

`low_light_noise` 的 SSIM-Y 低于其它内容，主要来自内容本身噪声，不是弱网导致的解码错误；同一内容下 weak 的 SSIM-Y min 仍高于 baseline min。

## RTP 丢包恢复扩展矩阵

下面是 protocol/facade 弱网矩阵，用来证明实际 RTP 丢包下的 NACK 和重传链路。它不是 formal P5 production soak 的 H264 QoE 矩阵，但属于当前 P5 证据包中的弱网恢复证据。

| 场景 | 注入方式 | QoS 结果 | 播放结果 |
| --- | --- | --- | --- |
| `burst_loss_recover` | bad window 内按固定间隔丢下行 RTP | RTP drop `19`，NACK `19`，重传 `19`，目标码率保持约 `1201000bps`，FPS `30` | decoded `120/120`，playable ratio `1` |
| `walking_dead_zone_recover` | bad window 内丢非重传 RTP，模拟短 dead-zone | RTP drop `33`，NACK `1`，重传 `30`，bad send RPS `10.6452`，recovery send RPS `30` | decoded `100/100`，playable ratio `1` |
| `weak_network_low_rps_low_bitrate` | receiver quality 触发降级，不丢 RTP | RTP drop `0`，bad send RPS `10.3279`，bad RTP pps `30.9836`，recovery send RPS `30` | decoded `80/80`，playable ratio `1` |
| `sustained_low_bandwidth_low_rps` | 从弱网窗口开始后持续低带宽 | bad send RPS `10`，target `600000bps`，final FPS `10` | decoded `60/60`，playable ratio `1` |
| `weak_start_low_bandwidth_low_rps` | 从首帧开始持续弱网 | bad send RPS `10`，target `600000bps`，final FPS `10` | decoded `40/40`，playable ratio `1` |

结论：实际 RTP drop 场景下，NACK/重传链路可以恢复 burst loss 和 dead-zone；带宽/质量退化场景下，GoogCC/rate-cap/pacer 会把发送降到低 RPS、低 RTP pps、低码率和低 FPS，并在恢复窗口回升。

## 当前限制

- 当前 formal P5 环境没有 GPU/display，也没有真实生产采集素材库；real renderer 和 capture library 是 policy skip。
- formal P5 soak 的延迟指标是 renderer proxy latency/gap/jitter，不等价于真实显示器 present latency。
- formal P5 soak 没有真实 WAN RTT 或 `tc/netem` 网络延迟注入。下一期如果要补全“真实网络延迟/丢包/抖动”证据，应增加 `tc netem delay/loss/jitter` 矩阵，并把 RTT、one-way delay、packet loss rate 纳入 CSV。
