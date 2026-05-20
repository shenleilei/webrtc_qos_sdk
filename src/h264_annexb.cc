#include "h264_annexb.h"

#include <algorithm>

namespace webrtc_qos {
namespace {

bool IsStartCode3(const uint8_t* data, size_t pos, size_t size) {
  return pos + 3 <= size && data[pos] == 0 && data[pos + 1] == 0 &&
         data[pos + 2] == 1;
}

bool IsStartCode4(const uint8_t* data, size_t pos, size_t size) {
  return pos + 4 <= size && data[pos] == 0 && data[pos + 1] == 0 &&
         data[pos + 2] == 0 && data[pos + 3] == 1;
}

bool FindStartCode(const uint8_t* data,
                   size_t size,
                   size_t from,
                   size_t* start,
                   size_t* prefix_len) {
  for (size_t i = from; i + 3 <= size; ++i) {
    if (IsStartCode3(data, i, size)) {
      *start = i;
      *prefix_len = 3;
      return true;
    }
    if (IsStartCode4(data, i, size)) {
      *start = i;
      *prefix_len = 4;
      return true;
    }
  }
  return false;
}

std::vector<uint8_t> RemoveEmulationPreventionBytes(
    const std::vector<uint8_t>& nalu) {
  std::vector<uint8_t> rbsp;
  rbsp.reserve(nalu.size());
  int zero_count = 0;
  for (uint8_t byte : nalu) {
    if (zero_count == 2 && byte == 0x03) {
      zero_count = 0;
      continue;
    }
    rbsp.push_back(byte);
    if (byte == 0) {
      ++zero_count;
    } else {
      zero_count = 0;
    }
  }
  return rbsp;
}

class BitReader {
 public:
  explicit BitReader(const std::vector<uint8_t>& data) : data_(data) {}

  bool ReadBit(uint32_t* bit) {
    if (bit_offset_ >= data_.size() * 8) {
      return false;
    }
    const size_t byte_offset = bit_offset_ / 8;
    const size_t bit_in_byte = 7 - (bit_offset_ % 8);
    *bit = (data_[byte_offset] >> bit_in_byte) & 1;
    ++bit_offset_;
    return true;
  }

  bool ReadUE(uint32_t* value) {
    uint32_t zeros = 0;
    uint32_t bit = 0;
    while (ReadBit(&bit)) {
      if (bit == 1) {
        break;
      }
      ++zeros;
      if (zeros > 31) {
        return false;
      }
    }
    uint32_t suffix = 0;
    for (uint32_t i = 0; i < zeros; ++i) {
      if (!ReadBit(&bit)) {
        return false;
      }
      suffix = (suffix << 1) | bit;
    }
    *value = ((1u << zeros) - 1u) + suffix;
    return true;
  }

 private:
  const std::vector<uint8_t>& data_;
  size_t bit_offset_ = 0;
};

}  // namespace

Status SplitAnnexB(const uint8_t* data,
                   size_t size,
                   std::vector<std::vector<uint8_t>>* nalus) {
  if (!data || !nalus) {
    return Status::Error(StatusCode::kInvalidArgument, "null Annex-B input");
  }
  nalus->clear();
  size_t start = 0;
  size_t prefix = 0;
  if (!FindStartCode(data, size, 0, &start, &prefix)) {
    return Status::Error(StatusCode::kMalformedPacket,
                         "Annex-B start code not found");
  }

  size_t nalu_start = start + prefix;
  while (nalu_start < size) {
    size_t next_start = size;
    size_t next_prefix = 0;
    if (FindStartCode(data, size, nalu_start, &next_start, &next_prefix)) {
      if (next_start > nalu_start) {
        nalus->emplace_back(data + nalu_start, data + next_start);
      }
      nalu_start = next_start + next_prefix;
    } else {
      nalus->emplace_back(data + nalu_start, data + size);
      break;
    }
  }

  nalus->erase(std::remove_if(nalus->begin(), nalus->end(),
                              [](const auto& nalu) { return nalu.empty(); }),
               nalus->end());
  if (nalus->empty()) {
    return Status::Error(StatusCode::kMalformedPacket, "no NALU in Annex-B AU");
  }
  return Status::Ok();
}

std::vector<uint8_t> JoinAnnexB(const std::vector<std::vector<uint8_t>>& nalus) {
  std::vector<uint8_t> out;
  for (const auto& nalu : nalus) {
    if (nalu.empty()) {
      continue;
    }
    AppendAnnexBStartCode(&out);
    out.insert(out.end(), nalu.begin(), nalu.end());
  }
  return out;
}

void AppendAnnexBStartCode(std::vector<uint8_t>* out) {
  out->push_back(0x00);
  out->push_back(0x00);
  out->push_back(0x00);
  out->push_back(0x01);
}

H264NaluType GetNaluType(const std::vector<uint8_t>& nalu) {
  if (nalu.empty()) {
    return H264NaluType::kUnspecified;
  }
  return static_cast<H264NaluType>(nalu[0] & 0x1f);
}

VideoFrameType ClassifyAccessUnit(
    const std::vector<std::vector<uint8_t>>& nalus) {
  bool has_idr = false;
  bool has_non_idr = false;
  bool only_parameter_sets = true;
  for (const auto& nalu : nalus) {
    const H264NaluType type = GetNaluType(nalu);
    if (!IsParameterSet(type) && type != H264NaluType::kAud &&
        type != H264NaluType::kSei) {
      only_parameter_sets = false;
    }
    if (type == H264NaluType::kIdr) {
      has_idr = true;
    } else if (type == H264NaluType::kNonIdr) {
      has_non_idr = true;
    }
  }
  if (has_idr) {
    return VideoFrameType::kIdr;
  }
  if (has_non_idr) {
    return VideoFrameType::kP;
  }
  if (only_parameter_sets) {
    return VideoFrameType::kParameterSet;
  }
  return VideoFrameType::kUnknown;
}

bool IsParameterSet(H264NaluType type) {
  return type == H264NaluType::kSps || type == H264NaluType::kPps;
}

bool IsBFrameSlice(const std::vector<uint8_t>& nalu) {
  const H264NaluType type = GetNaluType(nalu);
  if (type != H264NaluType::kNonIdr && type != H264NaluType::kIdr) {
    return false;
  }
  std::vector<uint8_t> rbsp = RemoveEmulationPreventionBytes(nalu);
  if (rbsp.size() <= 1) {
    return false;
  }
  std::vector<uint8_t> slice_header(rbsp.begin() + 1, rbsp.end());
  BitReader reader(slice_header);
  uint32_t first_mb_in_slice = 0;
  uint32_t slice_type = 0;
  if (!reader.ReadUE(&first_mb_in_slice) || !reader.ReadUE(&slice_type)) {
    return false;
  }
  (void)first_mb_in_slice;
  return slice_type == 1 || slice_type == 6;
}

}  // namespace webrtc_qos
