#ifndef SDK_QOS_RTP_PACKET_ADAPTER_H_
#define SDK_QOS_RTP_PACKET_ADAPTER_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

namespace webrtc_qos {

struct RtpPacketAdapterConfig {
  uint8_t payload_type = 96;
  uint8_t transport_sequence_extension_id = 1;
  bool enable_transport_sequence_extension = true;
};

struct RtpPacketAdapterBuildInput {
  uint8_t payload_type = 96;
  bool marker = false;
  uint16_t sequence_number = 0;
  uint32_t timestamp = 0;
  uint32_t ssrc = 0;
  std::optional<uint16_t> transport_sequence_number;
  const uint8_t* payload = nullptr;
  size_t payload_size = 0;
};

struct RtpPacketAdapterParsedPacket {
  uint8_t payload_type = 0;
  bool marker = false;
  uint16_t sequence_number = 0;
  uint32_t timestamp = 0;
  uint32_t ssrc = 0;
  std::optional<uint16_t> transport_sequence_number;
  std::vector<uint8_t> payload;
};

bool BuildRtpPacket(const RtpPacketAdapterBuildInput& input,
                    const RtpPacketAdapterConfig& config,
                    std::vector<uint8_t>* out);

bool ParseRtpPacket(const uint8_t* data,
                    size_t size,
                    const RtpPacketAdapterConfig& config,
                    RtpPacketAdapterParsedPacket* out);

}  // namespace webrtc_qos

#endif  // SDK_QOS_RTP_PACKET_ADAPTER_H_
