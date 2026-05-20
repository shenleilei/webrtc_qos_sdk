#include "webrtc_qos/transport_port.h"

namespace webrtc_qos {

TransportPort::TransportPort(TransportSendCallback send_callback)
    : send_callback_(std::move(send_callback)) {}

Status TransportPort::Send(TransportMessageType type,
                           const TransportIds& ids,
                           const std::vector<uint8_t>& payload,
                           int64_t send_time_us,
                           uint16_t flags) {
  if (!send_callback_) {
    return Status::Error(StatusCode::kInvalidArgument,
                         "transport send callback is not set");
  }
  TransportMessage message;
  message.ids = ids;
  message.type = type;
  message.payload = payload.data();
  message.payload_size = payload.size();
  message.send_time_us = send_time_us;
  message.flags = flags;
  return send_callback_(message);
}

Status TransportPort::Deliver(
    const TransportMessage& message,
    const TransportReceiveCallback& receive_callback) const {
  if (!receive_callback) {
    return Status::Error(StatusCode::kInvalidArgument,
                         "transport receive callback is not set");
  }
  if (!message.payload && message.payload_size != 0) {
    return Status::Error(StatusCode::kInvalidArgument,
                         "transport message payload is null");
  }
  return receive_callback(message);
}

const char* TransportMessageTypeName(TransportMessageType type) {
  switch (type) {
    case TransportMessageType::kRtp:
      return "RTP";
    case TransportMessageType::kRtcpSr:
      return "RTCP_SR";
    case TransportMessageType::kRtcpRr:
      return "RTCP_RR";
    case TransportMessageType::kRtcpTwcc:
      return "RTCP_TWCC";
    case TransportMessageType::kRtcpNack:
      return "RTCP_NACK";
    case TransportMessageType::kRtcpPli:
      return "RTCP_PLI";
    case TransportMessageType::kDownlinkQuality:
      return "DOWNLINK_QUALITY_V1";
    case TransportMessageType::kSenderRateCap:
      return "SENDER_RATE_CAP_V1";
    case TransportMessageType::kBye:
      return "BYE";
  }
  return "UNKNOWN";
}

}  // namespace webrtc_qos
