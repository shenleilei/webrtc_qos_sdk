#pragma once

#include <cstdint>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

enum class RateCapReason : uint16_t {
  kNone = 0,
  kWorstReceiver = 1,
  kReceiverLoss = 2,
  kReceiverFreeze = 3,
  kOperatorPolicy = 4,
};

inline SenderRateCap UnlimitedSenderRateCap(const TransportIds& ids,
                                            uint32_t controller_seq,
                                            int64_t receive_time_us) {
  SenderRateCap cap;
  cap.ids = ids;
  cap.controller_seq = controller_seq;
  cap.cap_bps = kUnlimitedRateCapBps;
  cap.expire_ms = 0;
  cap.reason_code = static_cast<uint16_t>(RateCapReason::kNone);
  cap.receive_time_us = receive_time_us;
  return cap;
}

inline bool IsUnlimitedRateCap(const SenderRateCap& cap) {
  return cap.cap_bps == kUnlimitedRateCapBps;
}

}  // namespace webrtc_qos
