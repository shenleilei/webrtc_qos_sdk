#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

std::vector<uint8_t> SerializeRtpPacket(const RtpPacket& packet);
Status ParseRtpPacket(const uint8_t* data, size_t size, RtpPacket* packet);

}  // namespace webrtc_qos
