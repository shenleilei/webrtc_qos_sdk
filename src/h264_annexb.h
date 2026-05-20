#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

enum class H264NaluType : uint8_t {
  kUnspecified = 0,
  kNonIdr = 1,
  kIdr = 5,
  kSei = 6,
  kSps = 7,
  kPps = 8,
  kAud = 9,
};

Status SplitAnnexB(const uint8_t* data,
                   size_t size,
                   std::vector<std::vector<uint8_t>>* nalus);
std::vector<uint8_t> JoinAnnexB(const std::vector<std::vector<uint8_t>>& nalus);
void AppendAnnexBStartCode(std::vector<uint8_t>* out);
H264NaluType GetNaluType(const std::vector<uint8_t>& nalu);
VideoFrameType ClassifyAccessUnit(const std::vector<std::vector<uint8_t>>& nalus);
bool IsParameterSet(H264NaluType type);
bool IsBFrameSlice(const std::vector<uint8_t>& nalu);

}  // namespace webrtc_qos
