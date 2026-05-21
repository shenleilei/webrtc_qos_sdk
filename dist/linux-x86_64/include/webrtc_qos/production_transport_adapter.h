#pragma once

#include <cstdint>
#include <functional>
#include <vector>

#include "webrtc_qos/transport_port.h"
#include "webrtc_qos/types.h"

namespace webrtc_qos {

enum class ProductionTransportLane {
  kUnreliableMedia = 0,
  kUnreliableControl,
  kReliableControl,
};

struct OwnedTransportMessage {
  TransportIds ids;
  TransportMessageType type = TransportMessageType::kRtp;
  ProductionTransportLane lane = ProductionTransportLane::kUnreliableMedia;
  std::vector<uint8_t> payload;
  int64_t send_time_us = 0;
  uint16_t flags = 0;
};

using ProductionTransportSendCallback =
    std::function<Status(const OwnedTransportMessage&)>;

// Template adapter for production transports. It keeps TransportPort as the
// stable SDK boundary, but converts borrowed callback payloads into owned
// messages before handing them to async business transport code.
class ProductionTransportAdapter {
 public:
  explicit ProductionTransportAdapter(
      ProductionTransportSendCallback send_callback);

  ProductionTransportAdapter(const ProductionTransportAdapter&) = delete;
  ProductionTransportAdapter& operator=(const ProductionTransportAdapter&) =
      delete;
  ProductionTransportAdapter(ProductionTransportAdapter&&) = delete;
  ProductionTransportAdapter& operator=(ProductionTransportAdapter&&) = delete;

  TransportPort& port() { return port_; }
  const TransportPort& port() const { return port_; }

  Status Send(TransportMessageType type,
              const TransportIds& ids,
              const std::vector<uint8_t>& payload,
              int64_t send_time_us,
              uint16_t flags = 0);

  Status Deliver(const OwnedTransportMessage& message,
                 const TransportReceiveCallback& receive_callback) const;

 private:
  Status OnTransportSend(const TransportMessage& message);

  ProductionTransportSendCallback send_callback_;
  TransportPort port_;
};

ProductionTransportLane ProductionTransportLaneForType(
    TransportMessageType type);
const char* ProductionTransportLaneName(ProductionTransportLane lane);

}  // namespace webrtc_qos
