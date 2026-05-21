#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <vector>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

enum class TransportMessageType : uint16_t {
  kRtp = 1,
  kRtcpSr = 2,
  kRtcpRr = 3,
  kRtcpTwcc = 4,
  kRtcpNack = 5,
  kRtcpPli = 6,
  kDownlinkQuality = 7,
  kSenderRateCap = 8,
  kBye = 9,
};

struct TransportMessage {
  TransportIds ids;
  TransportMessageType type = TransportMessageType::kRtp;
  // Borrowed payload view. The pointer is only valid for the duration of the
  // callback unless the caller explicitly owns a longer lifetime.
  const uint8_t* payload = nullptr;
  size_t payload_size = 0;
  int64_t send_time_us = 0;
  uint16_t flags = 0;
};

// Called synchronously by TransportPort::Send. Async business transports must
// copy payload before returning from this callback.
using TransportSendCallback = std::function<Status(const TransportMessage&)>;
// Called synchronously by TransportPort::Deliver. Receivers must not retain the
// payload pointer unless the delivering transport guarantees the lifetime.
using TransportReceiveCallback = std::function<Status(const TransportMessage&)>;

class TransportPort {
 public:
  explicit TransportPort(TransportSendCallback send_callback);
  ~TransportPort();

  TransportPort(TransportPort&&) noexcept;
  TransportPort& operator=(TransportPort&&) noexcept;
  TransportPort(const TransportPort&) = delete;
  TransportPort& operator=(const TransportPort&) = delete;

  // Builds a TransportMessage that borrows |payload| and invokes the configured
  // send callback immediately. TransportPort does not frame, encrypt, queue, or
  // own socket lifecycle; production code maps the message to its wire protocol.
  Status Send(TransportMessageType type,
              const TransportIds& ids,
              const std::vector<uint8_t>& payload,
              int64_t send_time_us,
              uint16_t flags = 0);
  // Delivers a borrowed network payload to the SDK/session receive callback.
  Status Deliver(const TransportMessage& message,
                 const TransportReceiveCallback& receive_callback) const;

 private:
  TransportSendCallback send_callback_;
};

const char* TransportMessageTypeName(TransportMessageType type);

}  // namespace webrtc_qos
