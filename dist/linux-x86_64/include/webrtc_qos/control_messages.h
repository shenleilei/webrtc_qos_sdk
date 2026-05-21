#pragma once

#include <cstddef>
#include <cstdint>

#include "webrtc_qos/rate_cap.h"
#include "webrtc_qos/status.h"
#include "webrtc_qos/types.h"

namespace webrtc_qos {

enum class ControlMessageType : uint16_t {
  kUnknown = 0,
  kSenderRateCapV1 = 1,
  kDownlinkQualityV1 = 2,
};

struct ControlMessageHeader {
  uint16_t version = 1;
  ControlMessageType type = ControlMessageType::kUnknown;
  TransportIds ids;
  uint32_t sequence_number = 0;
  uint64_t timestamp_us = 0;
};

struct ControlMessageView {
  ControlMessageHeader header;
  const uint8_t* payload = nullptr;
  size_t payload_size = 0;
};

}  // namespace webrtc_qos
