#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>

#include "webrtc_qos/rtcp_adapter.h"
#include "webrtc_qos/status.h"

namespace webrtc_qos {

struct RtcpPacketIterationStats {
  size_t supported_packets = 0;
  size_t unsupported_packets = 0;
};

inline Status ForEachSupportedRtcpPacket(
    const uint8_t* data,
    size_t size,
    const std::function<Status(const uint8_t*, size_t,
                               const RtcpAdapterParsedPacket&)>& handler,
    RtcpPacketIterationStats* stats = nullptr) {
  if (data == nullptr || size == 0) {
    return Status::Error(StatusCode::kInvalidArgument, "empty RTCP packet");
  }

  constexpr uint8_t kRtcpVersion = 2;
  constexpr uint8_t kPacketTypeSenderReport = 200;
  constexpr uint8_t kPacketTypeReceiverReport = 201;
  constexpr uint8_t kPacketTypeRtpfb = 205;
  constexpr uint8_t kPacketTypePsfb = 206;
  constexpr uint8_t kFeedbackNack = 1;
  constexpr uint8_t kFeedbackTransportCc = 15;
  constexpr uint8_t kFeedbackPli = 1;

  size_t offset = 0;
  while (offset < size) {
    if (size - offset < 4) {
      return Status::Error(StatusCode::kMalformedPacket,
                           "truncated RTCP common header");
    }
    const uint8_t version = data[offset] >> 6;
    if (version != kRtcpVersion) {
      return Status::Error(StatusCode::kMalformedPacket,
                           "unexpected RTCP version");
    }
    const uint8_t fmt = data[offset] & 0x1f;
    const uint8_t packet_type = data[offset + 1];
    const uint16_t length_words =
        static_cast<uint16_t>(data[offset + 2] << 8) | data[offset + 3];
    const size_t packet_size = (static_cast<size_t>(length_words) + 1u) * 4u;
    if (packet_size < 4 || offset + packet_size > size) {
      return Status::Error(StatusCode::kMalformedPacket,
                           "invalid RTCP packet size");
    }

    const bool supported =
        packet_type == kPacketTypeSenderReport ||
        packet_type == kPacketTypeReceiverReport ||
        (packet_type == kPacketTypeRtpfb &&
         (fmt == kFeedbackNack || fmt == kFeedbackTransportCc)) ||
        (packet_type == kPacketTypePsfb && fmt == kFeedbackPli);
    if (supported) {
      if (stats != nullptr) {
        ++stats->supported_packets;
      }
      RtcpAdapterParsedPacket parsed;
      if (!ParseRtcpPacket(data + offset, packet_size, &parsed)) {
        return Status::Error(StatusCode::kMalformedPacket,
                             "failed to parse RTCP packet");
      }
      Status status = handler(data + offset, packet_size, parsed);
      if (!status) {
        return status;
      }
    } else if (stats != nullptr) {
      ++stats->unsupported_packets;
    }

    offset += packet_size;
  }
  return Status::Ok();
}

}  // namespace webrtc_qos
