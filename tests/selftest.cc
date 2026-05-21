#include <deque>
#include <iostream>
#include <string>
#include <vector>

#include "webrtc_qos/control_messages.h"
#include "webrtc_qos/production_transport_adapter.h"
#include "webrtc_qos/qos_metrics.h"
#include "webrtc_qos/rate_cap.h"
#include "webrtc_qos/server_qos_router.h"
#include "webrtc_qos/session_config.h"
#include "webrtc_qos/status.h"
#include "webrtc_qos/transport_io.h"
#include "webrtc_qos/transport_packet_history.h"
#include "webrtc_qos/transport_port.h"
#include "webrtc_qos/video_play_client.h"
#include "webrtc_qos/video_push_client.h"

namespace {

bool Expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    return false;
  }
  return true;
}

}  // namespace

int main() {
  using namespace webrtc_qos;
  bool ok = true;

  TransportIds ids{1, 2, 3, 0x12345678, 5};
  SessionConfig session_config;
  session_config.ids = ids;
  ok &= Expect(session_config.h264.payload_type == kH264PayloadType,
               "Phase-2 session config defaults to H264 PT 96");
  ok &= Expect(session_config.h264.allow_single_nalu &&
                   session_config.h264.allow_fua &&
                   !session_config.h264.allow_stapa,
               "Phase-2 H264 subset is Single NALU + FU-A only");

  AnnexBAccessUnitView au_view;
  au_view.bytes = nullptr;
  au_view.size = 0;
  VideoPushClientConfig push_config;
  push_config.session = session_config;
  VideoPlayClientConfig play_config;
  play_config.session = session_config;
  ServerQosRouterConfig server_config;
  server_config.session = session_config;
  QosSnapshot snapshot;
  snapshot.ids = ids;
  ControlMessageHeader control_header;
  control_header.type = ControlMessageType::kDownlinkQualityV1;
  ok &= Expect(control_header.version == 1,
               "control message header exposes explicit version");
  (void)au_view;
  (void)push_config;
  (void)play_config;
  (void)server_config;
  (void)snapshot;

  SenderRateCap cap;
  cap.ids = ids;
  cap.controller_seq = 9;
  cap.cap_bps = 600000;
  cap.expire_ms = 500;
  ok &= Expect(!IsUnlimitedRateCap(cap), "finite sender rate cap");
  SenderRateCap unlimited = UnlimitedSenderRateCap(ids, 10, 1234567);
  ok &= Expect(IsUnlimitedRateCap(unlimited),
               "Phase-2 rate cap exposes unlimited helper");
  ok &= Expect(unlimited.reason_code ==
                   static_cast<uint16_t>(RateCapReason::kNone),
               "unlimited sender rate cap has explicit none reason");
  cap.reason_code = static_cast<uint16_t>(RateCapReason::kWorstReceiver);
  ok &= Expect(cap.reason_code ==
                   static_cast<uint16_t>(RateCapReason::kWorstReceiver),
               "sender rate cap exposes worst-receiver reason");

  TransportPort missing_send_callback(nullptr);
  std::vector<uint8_t> transport_payload = {1, 2, 3, 4};
  Status status = missing_send_callback.Send(
      TransportMessageType::kRtp, ids, transport_payload, 1000);
  ok &= Expect(status.code == StatusCode::kInvalidArgument,
               "transport send requires callback");

  std::vector<uint8_t> copied_payload;
  TransportMessage copied_message;
  TransportPort transport_port([&](const TransportMessage& message) {
    copied_message = message;
    copied_payload.assign(message.payload,
                          message.payload + message.payload_size);
    return Status::Ok();
  });
  status = transport_port.Send(TransportMessageType::kRtcpPli, ids,
                               transport_payload, 2000, 7);
  ok &= Expect(status.code == StatusCode::kOk, "transport send callback runs");
  ok &= Expect(copied_message.type == TransportMessageType::kRtcpPli,
               "transport message type is preserved");
  ok &= Expect(copied_message.flags == 7, "transport flags are preserved");
  transport_payload[0] = 9;
  ok &= Expect(copied_payload == std::vector<uint8_t>({1, 2, 3, 4}),
               "async transport copies payload inside callback");
  ok &= Expect(
      std::string(TransportMessageTypeName(TransportMessageType::kRtcpPli)) ==
          "RTCP_PLI",
      "transport type name");

  std::deque<OwnedTransportMessage> production_wire;
  ProductionTransportAdapter production_adapter(
      [&](const OwnedTransportMessage& message) {
        production_wire.push_back(message);
        return Status::Ok();
      });
  std::vector<uint8_t> production_payload = {5, 6, 7};
  status = production_adapter.Send(TransportMessageType::kSenderRateCap, ids,
                                   production_payload, 3000);
  ok &= Expect(status.code == StatusCode::kOk,
               "production transport adapter send");
  production_payload[0] = 0;
  ok &= Expect(production_wire.size() == 1,
               "production transport adapter queues one message");
  ok &= Expect(production_wire.front().lane ==
                   ProductionTransportLane::kReliableControl,
               "sender rate cap uses reliable control lane");
  ok &= Expect(production_wire.front().payload ==
                   std::vector<uint8_t>({5, 6, 7}),
               "production transport adapter owns payload copy");

  TransportPacketHistory packet_history({1000, 3000, 2});
  const std::vector<uint8_t> history_packet_a = {0x80, 0x60, 0x00, 0x2a,
                                                 0x00, 0x01, 0x5f, 0x90};
  const TransportPacketHistoryKey history_key_a{7, 0x12345678, 42};
  packet_history.Store(history_key_a, history_packet_a.data(),
                       history_packet_a.size(), 1000000, false);
  auto history_hit = packet_history.Find(history_key_a);
  ok &= Expect(history_hit.has_value(), "transport packet history hit");
  ok &= Expect(history_hit->key.hop_id == 7,
               "transport packet history preserves hop id");
  ok &= Expect(history_hit->key.ssrc == 0x12345678,
               "transport packet history preserves ssrc");
  ok &= Expect(history_hit->key.rtp_sequence_number == 42,
               "transport packet history preserves RTP sequence");
  ok &= Expect(history_hit->rtp_bytes == history_packet_a,
               "transport packet history stores opaque RTP bytes");

  packet_history.Store(TransportPacketHistoryKey{7, 0x12345678, 43},
                       history_packet_a.data(), history_packet_a.size(),
                       1010000, false);
  packet_history.Store(TransportPacketHistoryKey{8, 0x12345678, 42},
                       history_packet_a.data(), history_packet_a.size(),
                       1020000, true);
  ok &= Expect(packet_history.size() == 2,
               "transport packet history enforces max packet count");
  ok &= Expect(!packet_history.Find(history_key_a).has_value(),
               "transport packet history evicts oldest packet");
  history_hit =
      packet_history.Find(TransportPacketHistoryKey{8, 0x12345678, 42});
  ok &= Expect(history_hit.has_value() && history_hit->retransmission,
               "transport packet history records retransmission flag");

  if (!ok) {
    return 1;
  }
  std::cout << "selftest passed\n";
  return 0;
}
