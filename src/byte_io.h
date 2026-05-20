#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace webrtc_qos {

inline void WriteU8(std::vector<uint8_t>* out, uint8_t value) {
  out->push_back(value);
}

inline void WriteU16(std::vector<uint8_t>* out, uint16_t value) {
  out->push_back(static_cast<uint8_t>(value >> 8));
  out->push_back(static_cast<uint8_t>(value));
}

inline void WriteU32(std::vector<uint8_t>* out, uint32_t value) {
  WriteU16(out, static_cast<uint16_t>(value >> 16));
  WriteU16(out, static_cast<uint16_t>(value));
}

inline void WriteU64(std::vector<uint8_t>* out, uint64_t value) {
  WriteU32(out, static_cast<uint32_t>(value >> 32));
  WriteU32(out, static_cast<uint32_t>(value));
}

inline bool ReadU8(const uint8_t* data, size_t size, size_t* pos, uint8_t* out) {
  if (*pos + 1 > size) {
    return false;
  }
  *out = data[*pos];
  *pos += 1;
  return true;
}

inline bool ReadU16(const uint8_t* data,
                    size_t size,
                    size_t* pos,
                    uint16_t* out) {
  if (*pos + 2 > size) {
    return false;
  }
  *out = static_cast<uint16_t>((data[*pos] << 8) | data[*pos + 1]);
  *pos += 2;
  return true;
}

inline bool ReadU32(const uint8_t* data,
                    size_t size,
                    size_t* pos,
                    uint32_t* out) {
  uint16_t hi = 0;
  uint16_t lo = 0;
  if (!ReadU16(data, size, pos, &hi) || !ReadU16(data, size, pos, &lo)) {
    return false;
  }
  *out = (static_cast<uint32_t>(hi) << 16) | lo;
  return true;
}

inline bool ReadU64(const uint8_t* data,
                    size_t size,
                    size_t* pos,
                    uint64_t* out) {
  uint32_t hi = 0;
  uint32_t lo = 0;
  if (!ReadU32(data, size, pos, &hi) || !ReadU32(data, size, pos, &lo)) {
    return false;
  }
  *out = (static_cast<uint64_t>(hi) << 32) | lo;
  return true;
}

}  // namespace webrtc_qos
