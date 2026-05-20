#include "webrtc_qos/production_transport_adapter.h"

namespace webrtc_qos {

ProductionTransportAdapter::ProductionTransportAdapter(
    ProductionTransportSendCallback send_callback)
    : send_callback_(std::move(send_callback)),
      port_([this](const TransportMessage& message) {
        return OnTransportSend(message);
      }) {}

Status ProductionTransportAdapter::Send(TransportMessageType type,
                                        const TransportIds& ids,
                                        const std::vector<uint8_t>& payload,
                                        int64_t send_time_us,
                                        uint16_t flags) {
  return port_.Send(type, ids, payload, send_time_us, flags);
}

Status ProductionTransportAdapter::Deliver(
    const OwnedTransportMessage& message,
    const TransportReceiveCallback& receive_callback) const {
  TransportMessage borrowed;
  borrowed.ids = message.ids;
  borrowed.type = message.type;
  borrowed.payload = message.payload.data();
  borrowed.payload_size = message.payload.size();
  borrowed.send_time_us = message.send_time_us;
  borrowed.flags = message.flags;
  return port_.Deliver(borrowed, receive_callback);
}

Status ProductionTransportAdapter::OnTransportSend(
    const TransportMessage& message) {
  if (!send_callback_) {
    return Status::Error(StatusCode::kInvalidArgument,
                         "production transport send callback is not set");
  }
  if (!message.payload && message.payload_size != 0) {
    return Status::Error(StatusCode::kInvalidArgument,
                         "production transport payload is null");
  }

  OwnedTransportMessage owned;
  owned.ids = message.ids;
  owned.type = message.type;
  owned.lane = ProductionTransportLaneForType(message.type);
  owned.send_time_us = message.send_time_us;
  owned.flags = message.flags;
  owned.payload.assign(message.payload, message.payload + message.payload_size);
  return send_callback_(owned);
}

ProductionTransportLane ProductionTransportLaneForType(
    TransportMessageType type) {
  switch (type) {
    case TransportMessageType::kRtp:
      return ProductionTransportLane::kUnreliableMedia;
    case TransportMessageType::kRtcpSr:
    case TransportMessageType::kRtcpRr:
    case TransportMessageType::kRtcpTwcc:
    case TransportMessageType::kRtcpNack:
    case TransportMessageType::kRtcpPli:
      return ProductionTransportLane::kUnreliableControl;
    case TransportMessageType::kDownlinkQuality:
    case TransportMessageType::kSenderRateCap:
    case TransportMessageType::kBye:
      return ProductionTransportLane::kReliableControl;
  }
  return ProductionTransportLane::kReliableControl;
}

const char* ProductionTransportLaneName(ProductionTransportLane lane) {
  switch (lane) {
    case ProductionTransportLane::kUnreliableMedia:
      return "unreliable_media";
    case ProductionTransportLane::kUnreliableControl:
      return "unreliable_control";
    case ProductionTransportLane::kReliableControl:
      return "reliable_control";
  }
  return "unknown";
}

}  // namespace webrtc_qos
