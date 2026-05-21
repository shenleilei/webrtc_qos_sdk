#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>

#include "webrtc_qos/status.h"
#include "webrtc_qos/types.h"

namespace webrtc_qos {

enum class TransportPacketKind {
  kRtp = 1,
  kRtcp = 2,
  kControl = 3,
};

struct TransportPacketMetadata {
  TransportIds ids;
  TransportPacketKind kind = TransportPacketKind::kRtp;
  int64_t send_time_us = 0;
  bool retransmission = false;
  bool padding = false;
};

struct TransportPacketView {
  const uint8_t* bytes = nullptr;
  size_t size = 0;
  TransportPacketMetadata metadata;
};

using TransportOutput =
    std::function<Status(const TransportPacketView& packet)>;

}  // namespace webrtc_qos
