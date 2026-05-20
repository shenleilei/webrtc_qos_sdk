#include "rtp_packet.h"

namespace webrtc_qos {

std::vector<uint8_t> SerializeRtpPacket(const RtpPacket& packet) {
  std::vector<uint8_t> out;
  const bool has_extension = true;
  out.reserve(12 + 8 + packet.payload.size());
  out.push_back(static_cast<uint8_t>(0x80 | (has_extension ? 0x10 : 0x00)));
  out.push_back(static_cast<uint8_t>((packet.marker ? 0x80 : 0x00) |
                                    (packet.payload_type & 0x7f)));
  out.push_back(static_cast<uint8_t>(packet.sequence_number >> 8));
  out.push_back(static_cast<uint8_t>(packet.sequence_number));
  out.push_back(static_cast<uint8_t>(packet.timestamp >> 24));
  out.push_back(static_cast<uint8_t>(packet.timestamp >> 16));
  out.push_back(static_cast<uint8_t>(packet.timestamp >> 8));
  out.push_back(static_cast<uint8_t>(packet.timestamp));
  out.push_back(static_cast<uint8_t>(packet.ssrc >> 24));
  out.push_back(static_cast<uint8_t>(packet.ssrc >> 16));
  out.push_back(static_cast<uint8_t>(packet.ssrc >> 8));
  out.push_back(static_cast<uint8_t>(packet.ssrc));

  // RFC 8285 one-byte RTP header extension with id=1 and a 2-byte TWCC value.
  out.push_back(0xbe);
  out.push_back(0xde);
  out.push_back(0x00);
  out.push_back(0x01);
  out.push_back(static_cast<uint8_t>((kTransportWideCcExtensionId << 4) | 0x01));
  out.push_back(static_cast<uint8_t>(packet.transport_sequence_number >> 8));
  out.push_back(static_cast<uint8_t>(packet.transport_sequence_number));
  out.push_back(0x00);

  out.insert(out.end(), packet.payload.begin(), packet.payload.end());
  return out;
}

Status ParseRtpPacket(const uint8_t* data, size_t size, RtpPacket* packet) {
  if (!data || !packet) {
    return Status::Error(StatusCode::kInvalidArgument, "null RTP input");
  }
  if (size < 12) {
    return Status::Error(StatusCode::kMalformedPacket, "short RTP packet");
  }
  const uint8_t version = data[0] >> 6;
  if (version != 2) {
    return Status::Error(StatusCode::kMalformedPacket, "invalid RTP version");
  }
  const bool has_extension = (data[0] & 0x10) != 0;
  const uint8_t csrc_count = data[0] & 0x0f;
  size_t pos = 12 + csrc_count * 4;
  if (size < pos) {
    return Status::Error(StatusCode::kMalformedPacket, "short RTP CSRC");
  }
  packet->marker = (data[1] & 0x80) != 0;
  packet->payload_type = data[1] & 0x7f;
  packet->sequence_number =
      static_cast<uint16_t>((data[2] << 8) | data[3]);
  packet->timestamp = (static_cast<uint32_t>(data[4]) << 24) |
                      (static_cast<uint32_t>(data[5]) << 16) |
                      (static_cast<uint32_t>(data[6]) << 8) | data[7];
  packet->ssrc = (static_cast<uint32_t>(data[8]) << 24) |
                 (static_cast<uint32_t>(data[9]) << 16) |
                 (static_cast<uint32_t>(data[10]) << 8) | data[11];
  packet->transport_sequence_number = 0;
  if (has_extension) {
    if (size < pos + 4) {
      return Status::Error(StatusCode::kMalformedPacket, "short RTP extension");
    }
    const uint16_t profile =
        static_cast<uint16_t>((data[pos] << 8) | data[pos + 1]);
    const uint16_t length_words =
        static_cast<uint16_t>((data[pos + 2] << 8) | data[pos + 3]);
    pos += 4;
    const size_t extension_end = pos + length_words * 4;
    if (size < extension_end) {
      return Status::Error(StatusCode::kMalformedPacket,
                           "truncated RTP extension");
    }
    if (profile == 0xbede) {
      while (pos < extension_end) {
        const uint8_t header = data[pos++];
        if (header == 0) {
          continue;
        }
        const uint8_t id = header >> 4;
        const uint8_t len = (header & 0x0f) + 1;
        if (pos + len > extension_end) {
          return Status::Error(StatusCode::kMalformedPacket,
                               "invalid one-byte RTP extension");
        }
        if (id == kTransportWideCcExtensionId && len == 2) {
          packet->transport_sequence_number =
              static_cast<uint16_t>((data[pos] << 8) | data[pos + 1]);
        }
        pos += len;
      }
    } else {
      pos = extension_end;
    }
  }
  packet->payload.assign(data + pos, data + size);
  return Status::Ok();
}

}  // namespace webrtc_qos
