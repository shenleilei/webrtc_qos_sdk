# Minimal UDP App

This sample is a Phase-5 external consumer project. It builds only from an
installed `WebRtcQosSdk` prefix and does not include SDK `src/` files or WebRTC
PeerConnection internals.

## Build

```bash
cmake -S examples/minimal_udp_app -B /tmp/minimal_udp_app_build \
  -DCMAKE_PREFIX_PATH=/path/to/webrtc_qos_sdk_prefix
cmake --build /tmp/minimal_udp_app_build -j2
```

The CMake project prefers `WebRtcQosSdk::role_*_bundle` targets when available
and falls back to `WebRtcQosSdk::role_push`, `WebRtcQosSdk::role_server` and
`WebRtcQosSdk::role_play`.

## Selftest

```bash
/tmp/minimal_udp_app_build/minimal_udp_selftest \
  --frames 36 \
  --tracks 2 \
  --log-dir /tmp/minimal_udp_logs \
  --log-max-file-bytes 1048576 \
  --log-max-files 4 \
  --metrics-dir /tmp/minimal_udp_metrics \
  --metrics-max-file-bytes 1048576 \
  --metrics-max-files 4 \
  --alerts-dir /tmp/minimal_udp_alerts \
  --alerts-max-file-bytes 1048576 \
  --alerts-max-files 4
```

Expected output includes:

```text
minimal_udp_selftest backend=webrtc_first_facade transport=udp peer_connection=false tracks=2 ... decoded_tracks=2 ... pass=true
```

## Three Processes

```bash
/tmp/minimal_udp_app_build/minimal_udp_server \
  50000 127.0.0.1:50001 127.0.0.1:50002 \
  --frames 90 --tracks 2 --log-dir /tmp/minimal_udp_logs \
  --log-max-file-bytes 1048576 --log-max-files 4 \
  --metrics-dir /tmp/minimal_udp_metrics \
  --metrics-max-file-bytes 1048576 --metrics-max-files 4 \
  --alerts-dir /tmp/minimal_udp_alerts \
  --alerts-max-file-bytes 1048576 --alerts-max-files 4

/tmp/minimal_udp_app_build/minimal_udp_receiver \
  50002 127.0.0.1:50000 \
  --frames 90 --tracks 2 --log-dir /tmp/minimal_udp_logs \
  --log-max-file-bytes 1048576 --log-max-files 4 \
  --metrics-dir /tmp/minimal_udp_metrics \
  --metrics-max-file-bytes 1048576 --metrics-max-files 4 \
  --alerts-dir /tmp/minimal_udp_alerts \
  --alerts-max-file-bytes 1048576 --alerts-max-files 4

/tmp/minimal_udp_app_build/minimal_udp_sender \
  50001 127.0.0.1:50000 \
  --frames 90 --tracks 2 --log-dir /tmp/minimal_udp_logs \
  --log-max-file-bytes 1048576 --log-max-files 4 \
  --metrics-dir /tmp/minimal_udp_metrics \
  --metrics-max-file-bytes 1048576 --metrics-max-files 4 \
  --alerts-dir /tmp/minimal_udp_alerts \
  --alerts-max-file-bytes 1048576 --alerts-max-files 4
```

The UDP envelope in `common/wire_packet.h` only distinguishes RTP, RTCP,
`DownlinkQuality` and `SenderRateCap`. RTP/RTCP bytes are forwarded unchanged.
The synthetic H264 source is intentionally small so the sample has no FFmpeg
runtime dependency.
