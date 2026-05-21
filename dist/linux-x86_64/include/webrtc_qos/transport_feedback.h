#pragma once

#include <vector>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

constexpr uint8_t kMsgTypeDownlinkQualityV1 = 1;
constexpr uint8_t kMsgTypeSenderRateCapV1 = 2;

std::vector<uint8_t> SerializeDownlinkQuality(const DownlinkQuality& report);
Status ParseDownlinkQuality(const uint8_t* data,
                            size_t size,
                            DownlinkQuality* report);

std::vector<uint8_t> SerializeSenderRateCap(const SenderRateCap& cap);
Status ParseSenderRateCap(const uint8_t* data,
                          size_t size,
                          SenderRateCap* cap);

}  // namespace webrtc_qos
