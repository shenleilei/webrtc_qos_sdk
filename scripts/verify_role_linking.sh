#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-/root/output}"
LIBATOMIC_DIR="${LIBATOMIC_DIR:-/usr/lib/gcc/x86_64-redhat-linux/10}"
CXX="${CXX:-g++}"
WORK_DIR="${WORK_DIR:-/tmp/webrtc_qos_role_linking}"

mkdir -p "${WORK_DIR}"

"${SDK_ROOT}/scripts/build_googcc_bridge.sh"
"${SDK_ROOT}/scripts/build_video_jitter_bridge.sh"

cat > "${WORK_DIR}/push_client.cc" <<'EOF'
#include "webrtc_qos/sender_pacer.h"
#include "webrtc_qos/sender_qos_googcc_bridge.h"
#include "webrtc_qos/video_sender.h"

int main() {
  webrtc_qos::TransportIds ids{1, 1, 1, 0x12345678, 2};
  webrtc_qos::SenderQosControllerConfig qos_config;
  qos_config.ids = ids;
  auto qos = webrtc_qos::CreateGoogCcSenderQosController(qos_config, 1000000);
  webrtc_qos::SenderPacer pacer(
      webrtc_qos::SenderPacerConfig{},
      [&](const webrtc_qos::RtpPacket& packet) {
        return qos.OnPacketSent(packet.transport_sequence_number,
                                packet.payload.size() + 20, 1000000);
      });
  webrtc_qos::VideoSender sender(webrtc_qos::VideoSenderConfig{ids}, &pacer);
  const uint8_t au[] = {0, 0, 0, 1, 0x67, 0x42, 0xe0, 0x1f,
                        0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80,
                        0, 0, 0, 1, 0x65, 1,    2,    3};
  return sender.SendAnnexBAccessUnit(au, sizeof(au), 1000000) ? 0 : 1;
}
EOF

cat > "${WORK_DIR}/server_relay.cc" <<'EOF'
#include "webrtc_qos/retransmission_cache.h"
#include "webrtc_qos/rtcp_packets.h"
#include "webrtc_qos/rtp_packet.h"
#include "webrtc_qos/transport_feedback.h"

int main() {
  webrtc_qos::RtpPacket packet;
  packet.sequence_number = 7;
  packet.transport_sequence_number = 9;
  packet.ssrc = 0x12345678;
  packet.payload = {0x65, 1, 2, 3};
  auto encoded = webrtc_qos::SerializeRtpPacket(packet);
  webrtc_qos::RtpPacket parsed;
  if (!webrtc_qos::ParseRtpPacket(encoded.data(), encoded.size(), &parsed)) {
    return 1;
  }
  webrtc_qos::RetransmissionCache cache;
  cache.Store(parsed, 1000000);
  if (!cache.Find(7, 10).has_value()) {
    return 1;
  }
  webrtc_qos::RtcpNack nack;
  nack.sender_ssrc = 2;
  nack.media_ssrc = packet.ssrc;
  nack.lost_rtp_sequence_numbers = {7};
  auto nack_bytes = webrtc_qos::SerializeRtcpNack(nack);
  return nack_bytes.empty() ? 1 : 0;
}
EOF

cat > "${WORK_DIR}/play_client.cc" <<'EOF'
#include "webrtc_qos/receiver_qos_observer.h"
#include "webrtc_qos/rtp_packet.h"
#include "webrtc_qos/video_jitter_bridge.h"

int main() {
  webrtc_qos::TransportIds ids{1, 1, 1, 0x12345678, 2};
  webrtc_qos::ReceiverQosObserver observer(
      webrtc_qos::ReceiverQosObserverConfig{ids, 200});
  auto jitter =
      webrtc_qos::CreateWebRtcVideoJitterPlayer(
          webrtc_qos::VideoJitterPlayerConfig{ids.sender_ssrc});
  webrtc_qos::RtpPacket packet;
  packet.marker = true;
  packet.sequence_number = 1;
  packet.timestamp = 90000;
  packet.ssrc = ids.sender_ssrc;
  packet.transport_sequence_number = 1;
  packet.payload = {0x65, 1, 2, 3};
  observer.OnRtpPacketReceived(packet, 1000000);
  return jitter.InsertPacket(packet, 1000000) ? 0 : 1;
}
EOF

cat > "${WORK_DIR}/transport_app.cc" <<'EOF'
#include <deque>
#include <vector>

#include "webrtc_qos/transport_port.h"

int main() {
  webrtc_qos::TransportIds ids{1, 1, 1, 0x12345678, 2};
  std::deque<std::vector<uint8_t>> wire;
  webrtc_qos::TransportPort port([&](const webrtc_qos::TransportMessage& msg) {
    wire.emplace_back(msg.payload, msg.payload + msg.payload_size);
    return webrtc_qos::Status::Ok();
  });
  std::vector<uint8_t> payload = {1, 2, 3};
  if (!port.Send(webrtc_qos::TransportMessageType::kRtcpPli, ids, payload,
                 1000000)) {
    return 1;
  }
  webrtc_qos::TransportMessage delivered;
  delivered.ids = ids;
  delivered.type = webrtc_qos::TransportMessageType::kRtcpPli;
  delivered.payload = wire.front().data();
  delivered.payload_size = wire.front().size();
  int received = 0;
  if (!port.Deliver(delivered, [&](const webrtc_qos::TransportMessage& msg) {
        received +=
            msg.type == webrtc_qos::TransportMessageType::kRtcpPli ? 1 : 0;
        return webrtc_qos::Status::Ok();
      })) {
    return 2;
  }
  return received == 1 ? 0 : 3;
}
EOF

COMMON_FLAGS=(-std=c++20 -I"${PREFIX}/include")
COMMON_SYSTEM_LIBS=(-L"${LIBATOMIC_DIR}" -lpthread -ldl -lrt -latomic)

"${CXX}" "${COMMON_FLAGS[@]}" "${WORK_DIR}/push_client.cc" \
  "${PREFIX}/lib/libwebrtc_qos_googcc_bridge.a" \
  "${PREFIX}/lib/libwebrtc_qos_video.a" \
  "${PREFIX}/lib/libwebrtc_qos_pacer.a" \
  "${PREFIX}/lib/libwebrtc_qos_feedback.a" \
  "${PREFIX}/lib/libwebrtc_qos_rtp.a" \
  "${PREFIX}/lib/libwebrtc_qos_core.a" \
  "${PREFIX}/lib/libwebrtc_qos_googcc_adapter.a" \
  "${COMMON_SYSTEM_LIBS[@]}" \
  -o "${WORK_DIR}/push_client"

"${CXX}" "${COMMON_FLAGS[@]}" "${WORK_DIR}/server_relay.cc" \
  "${PREFIX}/lib/libwebrtc_qos_rtp.a" \
  "${PREFIX}/lib/libwebrtc_qos_rtcp.a" \
  "${PREFIX}/lib/libwebrtc_qos_feedback.a" \
  "${PREFIX}/lib/libwebrtc_qos_nack.a" \
  "${COMMON_SYSTEM_LIBS[@]}" \
  -o "${WORK_DIR}/server_relay"

"${CXX}" "${COMMON_FLAGS[@]}" "${WORK_DIR}/play_client.cc" \
  "${PREFIX}/lib/libwebrtc_qos_video_jitter_bridge.a" \
  "${PREFIX}/lib/libwebrtc_qos_video.a" \
  "${PREFIX}/lib/libwebrtc_qos_nack.a" \
  "${PREFIX}/lib/libwebrtc_qos_rtp.a" \
  "${PREFIX}/lib/libwebrtc_qos_core.a" \
  "${PREFIX}/lib/libwebrtc_qos_video_jitter_adapter.a" \
  "${COMMON_SYSTEM_LIBS[@]}" \
  -o "${WORK_DIR}/play_client"

"${CXX}" "${COMMON_FLAGS[@]}" "${WORK_DIR}/transport_app.cc" \
  "${PREFIX}/lib/libwebrtc_qos_transport.a" \
  "${COMMON_SYSTEM_LIBS[@]}" \
  -o "${WORK_DIR}/transport_app"

"${WORK_DIR}/push_client"
"${WORK_DIR}/server_relay"
"${WORK_DIR}/play_client"
"${WORK_DIR}/transport_app"

echo "role linking passed"
