#include <cstdint>
#include <deque>
#include <iostream>
#include <vector>

#include "webrtc_qos/rtcp_packets.h"
#include "webrtc_qos/rtp_packet.h"
#include "webrtc_qos/transport_feedback.h"
#include "webrtc_qos/transport_port.h"

namespace {

struct QueuedMessage {
  webrtc_qos::TransportIds ids;
  webrtc_qos::TransportMessageType type =
      webrtc_qos::TransportMessageType::kRtp;
  std::vector<uint8_t> payload;
  int64_t send_time_us = 0;
  uint16_t flags = 0;
};

}  // namespace

int main() {
  using namespace webrtc_qos;

  TransportIds ids;
  ids.session_id = 1;
  ids.stream_id = 2;
  ids.transport_id = 3;
  ids.sender_ssrc = 0x12345678;
  ids.receiver_id = 9;

  std::deque<QueuedMessage> wire;
  TransportPort port([&](const TransportMessage& message) {
    if (!message.payload && message.payload_size != 0) {
      return Status::Error(StatusCode::kInvalidArgument, "null payload");
    }
    QueuedMessage queued;
    queued.ids = message.ids;
    queued.type = message.type;
    queued.payload.assign(message.payload,
                          message.payload + message.payload_size);
    queued.send_time_us = message.send_time_us;
    queued.flags = message.flags;
    wire.push_back(std::move(queued));
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
      port.Send(TransportMessageType::kRtp, ids, rtp_bytes, 1000000);
  if (!status) {
    std::cerr << status.message << "\n";
    return 1;
  }

  RtcpPli pli;
  pli.sender_ssrc = ids.receiver_id;
  pli.media_ssrc = ids.sender_ssrc;
  std::vector<uint8_t> pli_bytes = SerializeRtcpPli(pli);
  status = port.Send(TransportMessageType::kRtcpPli, ids, pli_bytes, 1010000);
  if (!status) {
    std::cerr << status.message << "\n";
    return 2;
  }

  SenderRateCap cap;
  cap.ids = ids;
  cap.controller_seq = 1;
  cap.cap_bps = 1000000;
  cap.expire_ms = 500;
  std::vector<uint8_t> cap_bytes = SerializeSenderRateCap(cap);
  status =
      port.Send(TransportMessageType::kSenderRateCap, ids, cap_bytes, 1020000);
  if (!status) {
    std::cerr << status.message << "\n";
    return 3;
  }

  size_t delivered = 0;
  size_t rtp_seen = 0;
  size_t pli_seen = 0;
  size_t cap_seen = 0;
  while (!wire.empty()) {
    QueuedMessage queued = std::move(wire.front());
    wire.pop_front();
    TransportMessage delivered_message;
    delivered_message.ids = queued.ids;
    delivered_message.type = queued.type;
    delivered_message.payload = queued.payload.data();
    delivered_message.payload_size = queued.payload.size();
    delivered_message.send_time_us = queued.send_time_us;
    delivered_message.flags = queued.flags;

    status = port.Deliver(delivered_message, [&](const TransportMessage& msg) {
      if (msg.ids.session_id != ids.session_id ||
          msg.ids.stream_id != ids.stream_id ||
          msg.ids.sender_ssrc != ids.sender_ssrc) {
        return Status::Error(StatusCode::kInvalidArgument,
                             "transport id mismatch");
      }
      if (msg.type == TransportMessageType::kRtp) {
        RtpPacket parsed;
        Status parse_status =
            ParseRtpPacket(msg.payload, msg.payload_size, &parsed);
        if (!parse_status) {
          return parse_status;
        }
        ++rtp_seen;
      } else if (msg.type == TransportMessageType::kRtcpPli) {
        RtcpPli parsed;
        Status parse_status = ParseRtcpPli(msg.payload, msg.payload_size,
                                           &parsed);
        if (!parse_status) {
          return parse_status;
        }
        ++pli_seen;
      } else if (msg.type == TransportMessageType::kSenderRateCap) {
        SenderRateCap parsed;
        Status parse_status = ParseSenderRateCap(msg.payload,
                                                 msg.payload_size, &parsed);
        if (!parse_status) {
          return parse_status;
        }
        ++cap_seen;
      }
      ++delivered;
      return Status::Ok();
    });
    if (!status) {
      std::cerr << "deliver failed: " << status.message << "\n";
      return 4;
    }
  }

  std::cout << "transport_port_demo delivered=" << delivered
            << " rtp=" << rtp_seen
            << " pli=" << pli_seen
            << " cap=" << cap_seen
            << " type_name="
            << TransportMessageTypeName(TransportMessageType::kRtcpPli)
            << "\n";
  return delivered == 3 && rtp_seen == 1 && pli_seen == 1 && cap_seen == 1
             ? 0
             : 5;
}
