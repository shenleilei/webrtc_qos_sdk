#include <deque>
#include <iostream>
#include <vector>

#include "webrtc_qos/production_transport_adapter.h"
#include "webrtc_qos/rtcp_packets.h"
#include "webrtc_qos/rtp_packet.h"
#include "webrtc_qos/transport_feedback.h"

int main() {
  using namespace webrtc_qos;

  TransportIds ids;
  ids.session_id = 1;
  ids.stream_id = 2;
  ids.transport_id = 3;
  ids.sender_ssrc = 0x12345678;
  ids.receiver_id = 9;

  std::deque<OwnedTransportMessage> unreliable_media;
  std::deque<OwnedTransportMessage> unreliable_control;
  std::deque<OwnedTransportMessage> reliable_control;

  ProductionTransportAdapter adapter(
      [&](const OwnedTransportMessage& message) {
        switch (message.lane) {
          case ProductionTransportLane::kUnreliableMedia:
            unreliable_media.push_back(message);
            break;
          case ProductionTransportLane::kUnreliableControl:
            unreliable_control.push_back(message);
            break;
          case ProductionTransportLane::kReliableControl:
            reliable_control.push_back(message);
            break;
        }
        return Status::Ok();
      });

  RtpPacket rtp;
  rtp.sequence_number = 7;
  rtp.timestamp = 90000;
  rtp.ssrc = ids.sender_ssrc;
  rtp.transport_sequence_number = 11;
  rtp.payload = {0x65, 1, 2, 3};
  std::vector<uint8_t> rtp_bytes = SerializeRtpPacket(rtp);
  Status status =
      adapter.Send(TransportMessageType::kRtp, ids, rtp_bytes, 1000000);
  if (!status) {
    std::cerr << status.message << "\n";
    return 1;
  }

  RtcpPli pli;
  pli.sender_ssrc = ids.receiver_id;
  pli.media_ssrc = ids.sender_ssrc;
  std::vector<uint8_t> pli_bytes = SerializeRtcpPli(pli);
  status = adapter.Send(TransportMessageType::kRtcpPli, ids, pli_bytes,
                        1010000);
  if (!status) {
    std::cerr << status.message << "\n";
    return 2;
  }

  SenderRateCap cap;
  cap.ids = ids;
  cap.controller_seq = 1;
  cap.cap_bps = 800000;
  cap.expire_ms = 500;
  std::vector<uint8_t> cap_bytes = SerializeSenderRateCap(cap);
  status = adapter.Send(TransportMessageType::kSenderRateCap, ids, cap_bytes,
                        1020000);
  if (!status) {
    std::cerr << status.message << "\n";
    return 3;
  }

  // Mutate original buffers to prove the adapter copied payloads for async
  // business transport queues.
  rtp_bytes.assign(rtp_bytes.size(), 0);
  pli_bytes.assign(pli_bytes.size(), 0);
  cap_bytes.assign(cap_bytes.size(), 0);

  size_t delivered = 0;
  auto deliver = [&](const OwnedTransportMessage& message) {
    return adapter.Deliver(message, [&](const TransportMessage& delivered_msg) {
      if (delivered_msg.ids.session_id != ids.session_id ||
          delivered_msg.ids.stream_id != ids.stream_id ||
          delivered_msg.ids.sender_ssrc != ids.sender_ssrc) {
        return Status::Error(StatusCode::kInvalidArgument,
                             "transport id mismatch");
      }
      ++delivered;
      return Status::Ok();
    });
  };

  status = deliver(unreliable_media.front());
  if (!status) {
    std::cerr << status.message << "\n";
    return 4;
  }
  status = deliver(unreliable_control.front());
  if (!status) {
    std::cerr << status.message << "\n";
    return 5;
  }
  status = deliver(reliable_control.front());
  if (!status) {
    std::cerr << status.message << "\n";
    return 6;
  }

  std::cout << "production_transport_demo delivered=" << delivered
            << " media_lane="
            << ProductionTransportLaneName(unreliable_media.front().lane)
            << " control_lane="
            << ProductionTransportLaneName(unreliable_control.front().lane)
            << " reliable_lane="
            << ProductionTransportLaneName(reliable_control.front().lane)
            << "\n";

  return delivered == 3 && unreliable_media.size() == 1 &&
                 unreliable_control.size() == 1 && reliable_control.size() == 1
             ? 0
             : 7;
}
