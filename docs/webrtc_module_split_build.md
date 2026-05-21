# WebRTC 子模块拆分编译说明

本文记录当前 SDK 如何从 WebRTC 源码树中拆出可按需链接的小静态库。目标不是编译完整 `libwebrtc.a`，也不是引入 PeerConnection/ICE/DTLS/SRTP，而是只把 Phase-2 主路径需要的 WebRTC QoS、RTP/RTCP、NACK、pacing 和视频 jitter 能力打成独立模块，再由 SDK facade 按角色链接。

## 1. 总原则

- WebRTC 负责成熟媒体/QoS能力：GoogCC、PacingController、RTP/RTCP wire format、H264 RTP payload、NackRequester、video jitter/packet buffer。
- SDK 负责业务边界：`video_push_client`、`video_play_client`、`server_qos_router`、transport callback、session/stream/receiver 映射、rate cap、metrics 和 packet history。
- 不编译非主目标模块：不打完整 `modules/pacing`、完整 `modules/rtp_rtcp`、PeerConnection、ICE、DTLS、SRTP、SDP、protobuf、perfetto、examples、tests。
- 缺 WebRTC 子模块时构建失败，不自动 fallback 到自研 RTP/RTCP/pacer/jitter。
- WebRTC 源码侧改动必须通过 patch 管理，当前 patch 是 `third_party/webrtc_patches/webrtc_qos_sdk.patch`。

## 2. 产物映射

当前发布包中 WebRTC 子模块产物如下：

```text
lib/libwebrtc_qos_webrtc_googcc.a
lib/libwebrtc_qos_webrtc_pacing.a
lib/libwebrtc_qos_webrtc_rtp_rtcp.a
lib/libwebrtc_qos_webrtc_video_jitter.a
lib/libwebrtc_qos_webrtc_nack_requester.a
```

对应公开 adapter 头文件：

```text
include/webrtc_qos/googcc_adapter.h
include/webrtc_qos/pacing_adapter.h
include/webrtc_qos/rtcp_adapter.h
include/webrtc_qos/rtp_packet_adapter.h
include/webrtc_qos/h264_rtp_adapter.h
include/webrtc_qos/video_jitter_adapter.h
include/webrtc_qos/nack_requester_adapter.h
```

模块职责：

| 发布库 | WebRTC 能力 | SDK 使用位置 |
| --- | --- | --- |
| `libwebrtc_qos_webrtc_googcc.a` | `NetworkControllerInterface` / GoogCC | push 端 sender QoS |
| `libwebrtc_qos_webrtc_pacing.a` | `PacingController`、probe、priority、RTP padding | push 端发包节奏 |
| `libwebrtc_qos_webrtc_rtp_rtcp.a` | RTP bytes、TWCC extension、RTCP SR/RR/TWCC/NACK/PLI、H264 RTP payload | push/play/server |
| `libwebrtc_qos_webrtc_video_jitter.a` | H264 packet buffer / jitter 组帧 | play 端 Annex-B AU 输出 |
| `libwebrtc_qos_webrtc_nack_requester.a` | WebRTC NackRequester | play 端丢包检测和 NACK 生成 |

`libwebrtc_qos_webrtc_rtp_rtcp.a` 是聚合库：脚本先构建 RTCP adapter complete archive，再把 H264 RTP adapter 和 RTP packet adapter 的 `.o` 合并进去。这样业务侧只链接一个 `webrtc_rtp_rtcp` 角色库，不需要关心 RTCP/RTP/H264 payload 三个内部拆分。

## 3. WebRTC 源码侧 patch

当前所有 WebRTC 源码侧改动集中在：

```text
third_party/webrtc_patches/webrtc_qos_sdk.patch
```

patch 当前对应本地 WebRTC commit：

```text
1ae6348299bcc008785407e416542fcfb605cfaf
```

patch 增加两类内容。

第一类是新的 `sdk_qos/` adapter target 和 smoke：

```text
sdk_qos/BUILD.gn
sdk_qos/googcc_adapter.*
sdk_qos/pacing_adapter.*
sdk_qos/rtcp_adapter.*
sdk_qos/rtp_packet_adapter.*
sdk_qos/h264_rtp_adapter.*
sdk_qos/video_jitter_adapter.*
sdk_qos/nack_requester_adapter.*
sdk_qos/*_smoke.cc
```

第二类是在 WebRTC 原模块 BUILD.gn 中增加最小 target，避免直接链接完整模块：

```text
modules/congestion_controller/goog_cc:goog_cc_qos_minimal
modules/pacing:pacing_controller_qos_minimal
modules/rtp_rtcp:rtcp_packet_qos_minimal
modules/rtp_rtcp:rtp_packet_qos_minimal
modules/rtp_rtcp:rtp_packet_to_send_qos_minimal
modules/rtp_rtcp:h264_rtp_qos_minimal
modules/rtp_rtcp:h264_jitter_minimal
modules/rtp_rtcp:rtp_video_header_qos_minimal
modules/video_coding:packet_buffer_qos_minimal
```

少量 H264 源文件被复制成 QoS 专用最小版本，例如：

```text
modules/rtp_rtcp/source/rtp_format_h264_qos_minimal.cc
modules/rtp_rtcp/source/video_rtp_depacketizer_qos_minimal.cc
```

这样做的原因是原始 WebRTC target 依赖面很大，直接打包会带出 RTP sender、PacketRouter、event tracer、protobuf/full、tests 或不需要的 codec/FEC 路径；QoS minimal target 只保留 SDK facade 需要的源码和依赖。

## 4. GN target 结构

`sdk_qos/BUILD.gn` 中每个模块一般有三类 target：

```text
rtc_library("<adapter>")
rtc_static_library("<adapter>_complete")
rtc_executable("<adapter>_smoke")
```

`rtc_library` 用于 WebRTC 源码树内部开发；`rtc_static_library(... complete_static_lib = true)` 用于生成可复制到 SDK 发布包的 `.a`；`rtc_executable` 是模块级 smoke。

当前打包脚本实际构建的 target：

```text
sdk_qos
sdk_qos:webrtc_qos_googcc_adapter_complete
sdk_qos:webrtc_qos_h264_rtp_adapter_complete
sdk_qos:webrtc_qos_h264_rtp_adapter_smoke
sdk_qos:webrtc_qos_nack_requester_adapter_complete
sdk_qos:webrtc_qos_nack_requester_adapter_smoke
sdk_qos:webrtc_qos_pacing_adapter_complete
sdk_qos:webrtc_qos_pacing_adapter_smoke
sdk_qos:webrtc_qos_rtp_packet_adapter_complete
sdk_qos:webrtc_qos_rtp_packet_adapter_smoke
sdk_qos:webrtc_qos_rtcp_adapter_complete
sdk_qos:webrtc_qos_rtcp_adapter_smoke
sdk_qos:webrtc_qos_video_jitter_adapter_complete
sdk_qos:webrtc_qos_video_jitter_smoke
```

## 5. GN 参数

`scripts/package_webrtc_modules.sh` 当前使用的 GN 参数如下：

```text
is_debug=false
use_sysroot=false
use_lld=false
use_custom_libcxx=false
use_custom_libcxx_for_host=false
use_safe_libstdcxx=false
use_llvm_libatomic=false
rtc_include_tests=false
rtc_build_examples=false
rtc_build_tools=false
rtc_enable_protobuf=false
rtc_use_perfetto=false
rtc_disable_trace_events=true
rtc_rust=false
enable_rust=false
enable_rust_cxx=false
enable_chromium_prelude=false
rtc_enable_grpc=false
```

关键点：

- `rtc_enable_protobuf=false`：不编译 protobuf 相关路径。
- `rtc_use_perfetto=false`、`rtc_disable_trace_events=true`：避免引入 perfetto/event trace 闭包。
- `rtc_include_tests=false`、`rtc_build_examples=false`、`rtc_build_tools=false`：不编 WebRTC tests/examples/tools。
- `use_custom_libcxx=false`：发布包按系统 libstdc++ ABI 链接，便于 Linux native C++ 项目消费。
- `use_lld=false`、`use_sysroot=false`：当前本机环境下使用系统 toolchain/sysroot。

## 6. 构建和打包流程

默认 WebRTC 源码树在 `/root/src`，输出目录是 `/root/src/out/qos_min`。

```bash
cd /root/webrtc_qos_sdk
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
REQUIRE_ALL=1 \
NINJA_JOBS=2 \
scripts/package_webrtc_modules.sh
```

如果是新的干净 WebRTC checkout，需要显式允许脚本应用 patch：

```bash
WEBRTC_SRC=/path/to/webrtc \
PREFIX=/path/to/output \
APPLY_WEBRTC_PATCH=1 \
NINJA_JOBS=2 \
scripts/package_webrtc_modules.sh
```

脚本主要步骤：

1. 检查 `WEBRTC_SRC` 和 `third_party/webrtc_patches/webrtc_qos_sdk.patch` 是否存在。
2. 如果 patch 未应用且 `APPLY_WEBRTC_PATCH=1`，执行 `git apply`。
3. 使用裁剪 GN 参数执行 `gn gen <WEBRTC_OUT>`。
4. 用 `ninja` 构建 `sdk_qos:*_complete` 和 `sdk_qos:*_smoke`。
5. 复制 `.a` 到 `${PREFIX}/lib`。
6. 复制 adapter headers 到 `${PREFIX}/include/webrtc_qos`。
7. 复制 smoke 可执行文件到 `${PREFIX}/demo`。
8. 立即运行所有 smoke，失败则打包失败。

## 7. 验证流程

WebRTC 子模块产物级验证：

```bash
cd /root/webrtc_qos_sdk
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
REQUIRE_ALL=1 \
scripts/verify_webrtc_modules.sh
```

当前本地关键输出：

```text
pacing_adapter_smoke passed emitted=3 probe_emitted=2 probe_bytes=800 padding_emitted=5 padding_bytes=600
WebRTC module verification passed prefix=/root/webrtc_qos_sdk/dist/linux-x86_64
```

外部 CMake 消费验证：

```bash
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
scripts/verify_cmake_package.sh
```

WebRTC-first media bytes 闭环：

```bash
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
scripts/verify_webrtc_first_loopback.sh
```

push facade probe/pacing 验证：

```bash
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
scripts/verify_webrtc_first_pacing_probe.sh
```

当前本地输出：

```text
webrtc_first_pacing_probe passed rtp_packets=6 probe_packets=6 probe_bytes=745 probe_cluster=1
```

角色级总门禁：

```bash
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
SDK_ROOT=/root/webrtc_qos_sdk \
scripts/verify_webrtc_first_roles.sh
```

弱网 facade 短帧矩阵：

```bash
FRAMES=36 \
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 \
scripts/run_webrtc_first_facade_matrix.sh
```

当前短帧矩阵 8/8 通过，覆盖好网、burst loss、bandwidth cliff、weak-network low-RPS/low-bitrate、multi-receiver worst cap、walking dead-zone、持续弱网和弱网起步。

## 8. CMake 消费方式

WebRTC 子模块被安装到 SDK prefix 后，`cmake/WebRtcQosSdkConfig.cmake.in` 会把它们声明成 optional imported targets：

```text
WebRtcQosSdk::webrtc_googcc
WebRtcQosSdk::webrtc_pacing
WebRtcQosSdk::webrtc_rtp_rtcp
WebRtcQosSdk::webrtc_video_jitter
WebRtcQosSdk::webrtc_nack_requester
```

上层业务通常不直接链接这些底层 target，而是按角色链接：

```text
WebRtcQosSdk::role_push
WebRtcQosSdk::role_play
WebRtcQosSdk::role_server
WebRtcQosSdk::role_transport
```

角色依赖关系：

| 角色 | 链接的 WebRTC 子模块 |
| --- | --- |
| `role_push` | `webrtc_googcc`、`webrtc_pacing`、`webrtc_rtp_rtcp` |
| `role_play` | `webrtc_rtp_rtcp`、`webrtc_video_jitter`、`webrtc_nack_requester` |
| `role_server` | `webrtc_rtp_rtcp`、`transport_packet_history` |
| `role_transport` | SDK transport support，不链接 WebRTC |

## 9. 为什么不直接链接 WebRTC 原 target

直接链接完整 WebRTC target 的问题：

- `modules/pacing` 会带入 `packet_router`、`task_queue_paced_sender`、完整 RTP sender 相关依赖。
- `modules/rtp_rtcp` 会带入完整 RTP/RTCP、FEC、VP8/VP9/AV1 depacketizer、sender/receiver 实现等非 Phase-2 主目标。
- 部分原始 target 容易引入 protobuf、perfetto、tests/examples/tools 或平台 toolchain 相关依赖。
- SDK 的边界是 bytes facade + 自定义传输；如果直接暴露 WebRTC 内部对象，会把 WebRTC task queue、sequence checker、packet router、rtp sender 生命周期泄漏给业务。

因此当前方案不是“重写 WebRTC”，而是在 WebRTC 源码树内建立 QoS 专用 adapter 和 minimal target：源码仍来自 WebRTC，边界由 SDK 固定为 bytes/event/metrics。

## 10. 过程问题和处理记录

本节记录拆分编译过程中实际遇到的问题。后续维护时优先按这些经验判断，不要把 adapter 边界问题误判成 WebRTC 原生 bug。

### 10.1 直接打完整 WebRTC target 会拖入非目标依赖

问题：

- 直接打 `modules/pacing`、`modules/rtp_rtcp` 或相关完整 target 时，依赖闭包明显超出 Phase-2 主目标。
- 典型额外依赖包括 `packet_router`、`task_queue_paced_sender`、完整 RTP sender/receiver、FEC、VP8/VP9/AV1 depacketizer、event tracer、protobuf/perfetto/tests/examples/tools 路径。

原因：

- WebRTC 原 target 面向完整 PeerConnection/media pipeline 复用，不是面向 “bytes facade + 自定义传输” 的最小 SDK 发布包。
- 如果直接链接完整 target，SDK 边界会被 WebRTC 内部对象生命周期、task queue、packet router 和 sender/receiver 状态污染。

解决：

- 在 WebRTC 源码树中新增 QoS 专用 minimal target，例如 `pacing_controller_qos_minimal`、`rtcp_packet_qos_minimal`、`rtp_packet_qos_minimal`、`h264_rtp_qos_minimal`。
- `sdk_qos/*_adapter` 只暴露 SDK 需要的 bytes/event/metrics 接口。
- GN 参数关闭非目标路径：`rtc_enable_protobuf=false`、`rtc_use_perfetto=false`、`rtc_include_tests=false`、`rtc_build_examples=false`、`rtc_build_tools=false`。

防回归：

- `scripts/package_webrtc_modules.sh` 只构建 `sdk_qos:*_complete` 和 smoke target。
- `docs/webrtc_module_split_build.md` 明确禁止直接发布完整 `modules/pacing` 或 `modules/rtp_rtcp`。
- `scripts/verify_webrtc_modules.sh` 检查发布包中必须存在当前五个 WebRTC 子模块 archive。

### 10.2 PacingController 抽出来后 padding 不是 WebRTC bug

问题：

- 独立使用 WebRTC `PacingController` 后，最初 adapter 没有实现真实 RTP padding 生成。
- 后续补 padding 时，`PacingController` 在 probe 初期会请求很小的 padding，例如 1 byte；如果 adapter 直接生成 RTP padding 包，可能导致 padding 先于 probe media 发出，破坏 probe 首包顺序。

原因：

- 完整 WebRTC 栈中 padding 由 `PacketRouter / RTPSender` 链路承接，`PacingController` 本身不负责把 padding 请求变成完整 RTP bytes。
- SDK 拆分后链路变成 `PacingController -> sdk_qos/pacing_adapter -> TransportOutput bytes`，原来由 WebRTC RTP sender 承担的 RTP header、sequence、TWCC extension、padding bit 都必须由 adapter 补齐。

解决：

- `pacing_adapter` 基于已有媒体 RTP 包建立 padding template。
- `size <= 1 byte` 的 probe/keepalive padding 请求返回空，保持 probe media 首包行为。
- 真实 padding 包分配新的 RTP sequence number 和 transport-wide sequence number，设置 RTP padding bit，packet type 标记为 padding。
- SDK facade 用 `TransportPacketMetadata::padding` 向 server/play 传递 padding 语义。
- server 对 padding 包生成 uplink TWCC arrival feedback，但不写入 `transport_packet_history`。
- play 端先把 padding RTP sequence 喂给 NackRequester，避免误判缺包，然后跳过 H264 depacketize/video jitter。

防回归：

- `webrtc_qos_pacing_adapter_smoke` 检查 `padding_emitted>0`、`padding_bytes>0`、RTP padding bit、RTP/TWCC sequence。
- `scripts/verify_webrtc_modules.sh` 解析 smoke 输出并要求 padding packet/bytes 大于 0。
- `verify_webrtc_first_pacing_probe.sh` 验证 push facade probe 主路径仍能输出 `probe_cluster=1`。

### 10.3 RTP/RTCP/H264 拆成多个 adapter 后业务链接复杂

问题：

- RTCP adapter、RTP packet adapter、H264 RTP adapter 逻辑上是三个模块，但 push/play/server 角色都需要其中一部分。
- 如果发布三个独立 archive，外部 CMake consumer 容易漏链，角色 target 也会复杂化。

原因：

- WebRTC 内部 RTP packet、RTCP packet、H264 packetizer/depacketizer 本来属于相邻层；SDK 对外边界则希望只有一个 `webrtc_rtp_rtcp` 能力库。

解决：

- 打包脚本先复制 `libwebrtc_qos_rtcp_adapter_complete.a` 为 `libwebrtc_qos_webrtc_rtp_rtcp.a`。
- 再用 `llvm-ar x/q/s` 把 H264 RTP adapter 和 RTP packet adapter 的 `.o` 合并进同一个 archive。
- CMake 对外只暴露 `WebRtcQosSdk::webrtc_rtp_rtcp`。

防回归：

- `verify_cmake_package.sh` 会创建外部 consumer，并验证 `role_push`、`role_play`、`role_server` 都能单独链接和运行。
- `verify_webrtc_first_loopback.sh` 会验证 H264 payload、RTP packet bytes、pacing、video jitter 的端到端 bytes 闭环。

### 10.4 `complete_static_lib` 和 thin archive

问题：

- 普通 GN `rtc_library` 不是可直接复制给 SDK 用户链接的完整静态库。
- thin archive 在脱离 WebRTC out 目录后可能引用不到真实 `.o`，不适合发布包。

原因：

- WebRTC 默认 build 更偏向内部 target 组合，很多 archive 只是构建图节点，不等价于可分发 SDK 静态库。

解决：

- 每个发布模块增加 `rtc_static_library("<name>_complete")`。
- 设置 `complete_static_lib = true`。
- 设置 `suppressed_configs = [ "//build/config/compiler:thin_archive" ]`，避免生成 thin archive。

防回归：

- `scripts/verify_webrtc_modules.sh` 用 `file` 检查每个发布 archive 是 `current ar archive`。
- 发布包 CMake consumer 验证会真实链接这些 archive。

### 10.5 patch 不能继续依赖 `/root/src` 隐式状态

问题：

- 早期 adapter 实现只存在本机 `/root/src/sdk_qos`，SDK 仓库里只有打出来的 `.a`，不可审计、不可复现。

原因：

- WebRTC 源码树和 SDK 仓库是两个目录；如果不把 WebRTC 侧改动纳入仓库，其他机器无法从源码重建同样的模块。

解决：

- 将 WebRTC 侧 adapter 源码、GN target 和 minimal target 改动导出为 `third_party/webrtc_patches/webrtc_qos_sdk.patch`。
- `scripts/package_webrtc_modules.sh` 默认要求 patch 已应用；干净 checkout 必须显式设置 `APPLY_WEBRTC_PATCH=1` 才会修改 WebRTC 源码树。

防回归：

- patch 一致性检查：

```bash
tmp=$(mktemp)
git -C /root/src diff -- sdk_qos modules/pacing modules/rtp_rtcp modules/congestion_controller/goog_cc modules/video_coding common_video api/video > "$tmp"
cmp -s "$tmp" third_party/webrtc_patches/webrtc_qos_sdk.patch && echo patch_current=true
rm -f "$tmp"
```

### 10.6 系统 toolchain 和静态库 ABI 问题

问题：

- 发布 `.a` 不是和 Linux 版本完全无关的万能二进制。
- 当前环境需要显式处理 libatomic 路径，以及某些 libstdc++ nonshared object。

原因：

- WebRTC 静态库最终仍由业务进程链接，受 libc、libstdc++、compiler ABI、pthread/dl/rt/atomic 等系统 ABI 影响。
- 当前脚本使用系统 libstdc++，不是 WebRTC bundled libc++。

解决：

- GN 参数使用 `use_custom_libcxx=false`、`use_custom_libcxx_for_host=false`、`use_sysroot=false`。
- `scripts/package_webrtc_modules.sh` 通过 `LIBATOMIC_DIR` 把 libatomic 路径加入 `LIBRARY_PATH`。
- 如果存在 `LIBSTDCXX_NONSHARED`，脚本会抽取 `functexcept80.o` 并加入各个发布 archive，避免外部 consumer 在当前 toolchain 组合下漏符号。
- 发布包 CMake imported target 显式链接 `Threads::Threads;dl;rt;atomic`。

防回归：

- `verify_cmake_package.sh` 在发布包外部创建 consumer，真实链接并调用 role factory。
- README 的“二进制可移植性”明确要求生产在最老支持发行版或固定容器/toolchain 中构建。

### 10.7 NackRequester 不能孤立替换

问题：

- WebRTC `NackRequester` 不是单纯的 RTCP NACK parser/generator；它依赖接收侧 packet arrival、sequence、keyframe request、clock/task queue 等事件。

原因：

- 如果先孤立替换 NACK，再接 video receive pipeline，事件语义容易错位，后续还要二次改造。

解决：

- play facade 先接 WebRTC RTP/H264/video jitter 接收路径，再挂 `nack_requester_adapter`。
- play 端收到 RTP 后先通知 NackRequester，再根据是否 padding 决定是否进入 H264 depacketize/video jitter。
- server 只负责路由标准 RTCP NACK/PLI，并通过 `transport_packet_history` 做本地重传，不自研 NACK wire format。

防回归：

- `verify_cmake_package.sh` 覆盖 play 侧 NACK requester 到 server 本地重传的 runtime 验证。
- `run_webrtc_first_facade_matrix.sh` 中 `burst_loss_recover`、`walking_dead_zone_recover` 要求触发 NACK/RTX。

### 10.8 自研模块不能作为 fallback 保留

问题：

- 如果 WebRTC 子模块缺失时自动 fallback 到旧自研 RTP/RTCP/pacer/jitter，测试可能“通过”，但实际架构又回到 Phase-1a。

原因：

- 用户目标是 WebRTC 主路径 + 自定义传输，不是自研轻量栈 + 可选 WebRTC adapter。

解决：

- 删除旧自研 public headers、CMake targets、demo、tests、scripts 和 dist archive。
- `WEBRTC_QOS_ENABLE_WEBRTC_FACADE=ON` 时缺少 WebRTC modules 直接 CMake 配置失败。

防回归：

- `scripts/verify_no_selfmade_media_stack.sh` 检查旧 public paths、CMake target 和 dist archive。
- `scripts/verify_webrtc_first_roles.sh` 会串起 no-selfmade、module smoke、loopback、UDP role demo。

### 10.9 `rtc_enable_protobuf=false` 不等于不会碰到 protobuf

问题：

- GN args 已经设置 `rtc_enable_protobuf=false`，但直接依赖完整 WebRTC target 时仍会遇到 protobuf/perfetto 相关闭包。
- 典型路径是 `modules/rtp_rtcp:rtp_rtcp_format -> rtc_base:event_tracer -> perfetto -> protobuf_full`，或者 H264 depacketizer 通过通用 video API 间接拉回完整 RTP/RTCP format。

原因：

- `rtc_enable_protobuf=false` 只是关闭 WebRTC protobuf 功能开关，不会自动裁掉所有能间接到达 protobuf/perfetto 的 target。
- 如果 adapter 直接依赖 WebRTC 原始大 target，GN 仍会按依赖图把非主目标路径展开。
- 这不是 protobuf “必须依赖”，而是 target 选错导致依赖闭包过大。

定位方法：

```bash
cd /root/src
gn desc out/qos_min //modules/rtp_rtcp:rtp_rtcp_format deps --tree | rg 'protobuf|perfetto|event_tracer'
gn desc out/qos_min //api/video:encoded_image deps --tree | rg 'rtp_rtcp_format|protobuf|perfetto'
```

解决：

- RTCP 只依赖 `rtcp_packet_qos_minimal`，保留 PLI/NACK/TWCC/SR/RR 所需源码。
- RTP packet bytes 只依赖 `rtp_packet_qos_minimal`，保留 `RtpPacket`、`RtpHeaderExtensionMap`、`TransportSequenceNumber`。
- H264 RTP 只依赖 H264-only `h264_rtp_qos_minimal`，避免通用 codec packetizer/depacketizer 路径。
- 不把完整 `rtp_rtcp_format`、完整 `modules/rtp_rtcp` 或通用 video API target 发布到 SDK 基础包。

防回归：

- `docs/webrtc_module_split_build.md` 的 GN target 表只允许列出 QoS minimal target。
- `package_webrtc_modules.sh` 只构建 `sdk_qos:*_complete`，不构建完整 `modules/rtp_rtcp` 或完整 `modules/pacing`。
- 新增 WebRTC adapter 前必须先用 `gn desc ... deps --tree` 检查是否重新拉入 `protobuf`、`perfetto`、`event_tracer`、tests/examples/tools。

### 10.10 CMake role target 定义顺序问题

问题：

- 发布包里 `.a` 和 headers 都存在，但外部工程 `find_package(WebRtcQosSdk CONFIG REQUIRED)` 后可能看不到 `WebRtcQosSdk::role_push / role_play / role_server`。
- 另一种表现是 role target 存在，但链接时缺 WebRTC archive、`Threads::Threads`、`dl`、`rt`、`atomic` 或 facade 实现库。

原因：

- 这是 SDK CMake package 包装层的 target 定义顺序问题，不是 WebRTC bug。
- `WebRtcQosSdkTargets.cmake` 先导入 SDK 自身安装 target，例如 `WebRtcQosSdk::webrtc_qos_facade_video` 和 `WebRtcQosSdk::webrtc_qos_transport_packet_history`。
- WebRTC 子模块 `.a` 不是 CMake install export 生成的 target，而是由 `WebRtcQosSdkConfig.cmake` 根据 `${PACKAGE_PREFIX_DIR}/lib/libwebrtc_qos_webrtc_*.a` 动态创建 imported target。
- 如果先判断 role target、后创建 WebRTC imported target，CMake 会误判依赖不完整，导致 role target 不导出。
- 如果 facade target 没有在 WebRTC imported target 创建后追加 link interface，外部 consumer 只链接 facade 时会缺底层 WebRTC 符号。

解决：

- `cmake/WebRtcQosSdkConfig.cmake.in` 固定顺序：
- 先 `include(WebRtcQosSdkTargets.cmake)`，拿到 SDK 自身 targets。
- 再创建 `WebRtcQosSdk::webrtc_googcc / webrtc_pacing / webrtc_rtp_rtcp / webrtc_video_jitter / webrtc_nack_requester` imported targets。
- 再把 WebRTC imported targets、`transport_packet_history`、`Threads::Threads`、`dl`、`rt`、`atomic` 追加到 `WebRtcQosSdk::webrtc_qos_facade_video`。
- 最后只有在所有依赖都存在时才创建 `WebRtcQosSdk::role_push / role_play / role_server`。

防回归：

- `scripts/verify_cmake_package.sh` 不只做头文件编译检查，而是创建外部 CMake consumer，分别链接 `role_push`、`role_play`、`role_server` 并真实调用 `CreateVideoPushClient()`、`CreateVideoPlayClient()`、`CreateServerQosRouter()`。
- 每次更新 dist 后必须用安装后的 `dist/linux-x86_64/lib/cmake/WebRtcQosSdk/WebRtcQosSdkConfig.cmake` 跑 `verify_cmake_package.sh`，不能只验证 build tree。
- 如果以后拆出独立 server facade 或把 facade archive 再细分，必须保持同样顺序：安装 targets -> WebRTC imported targets -> facade link interface -> role targets。

### 10.11 archive 聚合后必须重新索引

问题：

- `libwebrtc_qos_webrtc_rtp_rtcp.a` 是由 RTCP adapter archive 加上 H264 RTP adapter 和 RTP packet adapter 的 `.o` 聚合出来的。
- 如果只 `ar q` 追加对象文件但不重新生成符号索引，某些系统 linker 会找不到 archive 内部符号，外部 consumer 链接失败。

原因：

- 静态 archive 的 symbol table 需要在对象文件变化后更新。
- WebRTC GN 生成的 complete archive 和 SDK 打包脚本二次聚合 archive 是两个步骤，不能假设第一次 archive 的索引仍然覆盖后续追加对象。

解决：

- `package_webrtc_modules.sh` 聚合后对每个发布 archive 执行 `${LLVM_AR} s <archive>`。
- 优先使用 WebRTC/LLVM toolchain 自带 `llvm-ar`；找不到时才回退系统 `ar`。

防回归：

- `verify_cmake_package.sh` 的 `rtp_packet_adapter_link` 会实际调用 `BuildRtpPacket()` 和 `ParseRtpPacket()`，能覆盖 `webrtc_rtp_rtcp` 聚合 archive 的符号可见性。
- `verify_webrtc_first_loopback.sh` 会进一步覆盖 H264 RTP adapter、RTP packet adapter、RTCP adapter 与 facade 的组合链接。

## 11. 已知边界

- 当前只面向 Linux x86_64 静态库发布；`.a` 仍受 libc、libstdc++、编译器 ABI 和系统库影响。
- WebRTC 源码树必须能应用 `third_party/webrtc_patches/webrtc_qos_sdk.patch`，否则需要先 rebase patch。
- `libwebrtc_qos_webrtc_rtp_rtcp.a` 是聚合产物，内部包含 RTCP、RTP packet 和 H264 RTP adapter 对象文件。
- padding 由 pacing adapter 基于已有媒体 RTP 模板生成；`size <= 1 byte` 的 probe/keepalive padding 请求返回空，避免破坏 probe 首包顺序。
- `transport_packet_history` 不属于 WebRTC 子模块，它只缓存 opaque RTP bytes，供 server/sender 在 WebRTC NACK 路由后查原包重传。

## 12. 维护规则

- 修改 WebRTC adapter 后，先在 `/root/src` 更新并验证，再重新生成 `third_party/webrtc_patches/webrtc_qos_sdk.patch`。
- patch 更新命令：

```bash
git -C /root/src diff -- sdk_qos modules/pacing modules/rtp_rtcp modules/congestion_controller/goog_cc modules/video_coding common_video api/video \
  > /root/webrtc_qos_sdk/third_party/webrtc_patches/webrtc_qos_sdk.patch
```

- 更新后检查 patch 是否和源码树一致：

```bash
cd /root/webrtc_qos_sdk
tmp=$(mktemp)
git -C /root/src diff -- sdk_qos modules/pacing modules/rtp_rtcp modules/congestion_controller/goog_cc modules/video_coding common_video api/video > "$tmp"
cmp -s "$tmp" third_party/webrtc_patches/webrtc_qos_sdk.patch && echo patch_current=true
rm -f "$tmp"
```

- 每次更新至少跑：

```bash
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 REQUIRE_ALL=1 scripts/verify_webrtc_modules.sh
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 scripts/verify_cmake_package.sh
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 scripts/verify_webrtc_first_loopback.sh
PREFIX=/root/webrtc_qos_sdk/dist/linux-x86_64 scripts/verify_webrtc_first_pacing_probe.sh
```
