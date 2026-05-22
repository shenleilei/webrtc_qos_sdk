#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "webrtc_qos/rate_cap.h"
#include "webrtc_qos/transport_io.h"

namespace minimal_udp {

constexpr uint8_t kRetransmissionFlag = 0x01;
constexpr uint8_t kPaddingFlag = 0x02;
constexpr uint8_t kWireVersion = 1;

enum class WireKind : uint8_t {
  kRtp = 1,
  kRtcp = 2,
  kDownlinkQuality = 3,
  kSenderRateCap = 4,
};

struct WirePacket {
  WireKind kind = WireKind::kRtp;
  uint8_t flags = 0;
  int64_t time_us = 0;
  std::vector<uint8_t> payload;
};

inline void PutU16(uint16_t value, std::vector<uint8_t>* out) {
  out->push_back(static_cast<uint8_t>(value & 0xff));
  out->push_back(static_cast<uint8_t>((value >> 8) & 0xff));
}

inline void PutU32(uint32_t value, std::vector<uint8_t>* out) {
  for (int i = 0; i < 4; ++i) {
    out->push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xff));
  }
}

inline void PutU64(uint64_t value, std::vector<uint8_t>* out) {
  for (int i = 0; i < 8; ++i) {
    out->push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xff));
  }
}

inline bool ReadU16(const std::vector<uint8_t>& in,
                    size_t* offset,
                    uint16_t* value) {
  if (*offset + 2 > in.size()) {
    return false;
  }
  *value = static_cast<uint16_t>(in[*offset]) |
           (static_cast<uint16_t>(in[*offset + 1]) << 8);
  *offset += 2;
  return true;
}

inline bool ReadU32(const std::vector<uint8_t>& in,
                    size_t* offset,
                    uint32_t* value) {
  if (*offset + 4 > in.size()) {
    return false;
  }
  *value = 0;
  for (int i = 0; i < 4; ++i) {
    *value |= static_cast<uint32_t>(in[*offset + i]) << (i * 8);
  }
  *offset += 4;
  return true;
}

inline bool ReadU64(const std::vector<uint8_t>& in,
                    size_t* offset,
                    uint64_t* value) {
  if (*offset + 8 > in.size()) {
    return false;
  }
  *value = 0;
  for (int i = 0; i < 8; ++i) {
    *value |= static_cast<uint64_t>(in[*offset + i]) << (i * 8);
  }
  *offset += 8;
  return true;
}

inline std::vector<uint8_t> EncodeWirePacket(const WirePacket& packet) {
  std::vector<uint8_t> out;
  out.push_back('W');
  out.push_back('Q');
  out.push_back('U');
  out.push_back('D');
  out.push_back(kWireVersion);
  out.push_back(static_cast<uint8_t>(packet.kind));
  out.push_back(packet.flags);
  out.push_back(0);
  PutU64(static_cast<uint64_t>(packet.time_us), &out);
  PutU32(static_cast<uint32_t>(packet.payload.size()), &out);
  out.insert(out.end(), packet.payload.begin(), packet.payload.end());
  return out;
}

inline bool DecodeWirePacket(const std::vector<uint8_t>& bytes,
                             WirePacket* packet) {
  if (bytes.size() < 20 || bytes[0] != 'W' || bytes[1] != 'Q' ||
      bytes[2] != 'U' || bytes[3] != 'D' || bytes[4] != kWireVersion) {
    return false;
  }
  packet->kind = static_cast<WireKind>(bytes[5]);
  packet->flags = bytes[6];
  size_t offset = 8;
  uint64_t time_us = 0;
  uint32_t payload_size = 0;
  if (!ReadU64(bytes, &offset, &time_us) ||
      !ReadU32(bytes, &offset, &payload_size) ||
      offset + payload_size > bytes.size()) {
    return false;
  }
  packet->time_us = static_cast<int64_t>(time_us);
  packet->payload.assign(bytes.begin() + static_cast<ptrdiff_t>(offset),
                         bytes.begin() + static_cast<ptrdiff_t>(offset) +
                             payload_size);
  return true;
}

inline WireKind WireKindFromTransport(webrtc_qos::TransportPacketKind kind) {
  return kind == webrtc_qos::TransportPacketKind::kRtp ? WireKind::kRtp
                                                       : WireKind::kRtcp;
}

inline std::vector<uint8_t> EncodeTransportPacket(
    const webrtc_qos::TransportPacketView& packet) {
  WirePacket wire;
  wire.kind = WireKindFromTransport(packet.metadata.kind);
  wire.flags = packet.metadata.retransmission ? kRetransmissionFlag : 0;
  if (packet.metadata.padding) {
    wire.flags |= kPaddingFlag;
  }
  wire.time_us = packet.metadata.send_time_us;
  wire.payload.assign(packet.bytes, packet.bytes + packet.size);
  return EncodeWirePacket(wire);
}

inline std::vector<uint8_t> EncodeDownlinkQuality(
    const webrtc_qos::DownlinkQuality& quality) {
  std::vector<uint8_t> out;
  PutU32(quality.ids.receiver_id, &out);
  PutU32(quality.report_seq, &out);
  PutU64(quality.report_time_us, &out);
  PutU16(quality.fraction_lost_q8, &out);
  PutU16(quality.video_drop_frames, &out);
  PutU32(quality.recv_bitrate_bps, &out);
  return out;
}

inline bool DecodeDownlinkQuality(const std::vector<uint8_t>& payload,
                                  const webrtc_qos::TransportIds& ids,
                                  webrtc_qos::DownlinkQuality* quality) {
  size_t offset = 0;
  uint32_t receiver_id = 0;
  uint32_t report_seq = 0;
  uint64_t report_time_us = 0;
  uint16_t fraction_lost_q8 = 0;
  uint16_t video_drop_frames = 0;
  uint32_t recv_bitrate_bps = 0;
  if (!ReadU32(payload, &offset, &receiver_id) ||
      !ReadU32(payload, &offset, &report_seq) ||
      !ReadU64(payload, &offset, &report_time_us) ||
      !ReadU16(payload, &offset, &fraction_lost_q8) ||
      !ReadU16(payload, &offset, &video_drop_frames) ||
      !ReadU32(payload, &offset, &recv_bitrate_bps)) {
    return false;
  }
  quality->ids = ids;
  quality->ids.receiver_id = receiver_id;
  quality->report_seq = report_seq;
  quality->report_time_us = report_time_us;
  quality->fraction_lost_q8 = fraction_lost_q8;
  quality->video_drop_frames = video_drop_frames;
  quality->recv_bitrate_bps = recv_bitrate_bps;
  return true;
}

inline std::vector<uint8_t> EncodeSenderRateCap(
    const webrtc_qos::SenderRateCap& cap) {
  std::vector<uint8_t> out;
  PutU32(cap.ids.receiver_id, &out);
  PutU32(cap.controller_seq, &out);
  PutU32(cap.cap_bps, &out);
  PutU16(cap.expire_ms, &out);
  PutU16(cap.reason_code, &out);
  PutU64(static_cast<uint64_t>(cap.receive_time_us), &out);
  return out;
}

inline bool DecodeSenderRateCap(const std::vector<uint8_t>& payload,
                                const webrtc_qos::TransportIds& ids,
                                webrtc_qos::SenderRateCap* cap) {
  size_t offset = 0;
  uint32_t receiver_id = 0;
  uint32_t controller_seq = 0;
  uint32_t cap_bps = 0;
  uint16_t expire_ms = 0;
  uint16_t reason_code = 0;
  uint64_t receive_time_us = 0;
  if (!ReadU32(payload, &offset, &receiver_id) ||
      !ReadU32(payload, &offset, &controller_seq) ||
      !ReadU32(payload, &offset, &cap_bps) ||
      !ReadU16(payload, &offset, &expire_ms) ||
      !ReadU16(payload, &offset, &reason_code) ||
      !ReadU64(payload, &offset, &receive_time_us)) {
    return false;
  }
  cap->ids = ids;
  cap->ids.receiver_id = receiver_id;
  cap->controller_seq = controller_seq;
  cap->cap_bps = cap_bps;
  cap->expire_ms = expire_ms;
  cap->reason_code = reason_code;
  cap->receive_time_us = static_cast<int64_t>(receive_time_us);
  return true;
}

}  // namespace minimal_udp
