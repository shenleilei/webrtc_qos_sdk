# WebRTC SDK QoS Adapter Source Ownership

The WebRTC-side adapter sources are tracked as a patch in:

```text
third_party/webrtc_patches/webrtc_qos_sdk.patch
```

The SDK repository intentionally does not vendor the full WebRTC source tree.
The patch is the reproducible packaging layer used by
`scripts/package_webrtc_modules.sh`; it creates `//sdk_qos` inside an external
WebRTC checkout and adds the minimal BUILD.gn targets needed by the SDK.

Pinned source state:

- WebRTC fork commit used for the current local build:
  `1ae6348299bcc008785407e416542fcfb605cfaf`
- Upstream base recorded in the local fork history:
  `7974ac0 Update WebRTC code version (2026-05-20T04:05:36)`

Current module coverage:

- `webrtc_googcc`: WebRTC `network_control / goog_cc` adapter.
- `webrtc_video_jitter`: WebRTC H264 packet buffer based video jitter adapter.

Pending Phase-2 modules:

- `webrtc_pacing`
- `webrtc_rtp_rtcp`
- `webrtc_nack_requester`
