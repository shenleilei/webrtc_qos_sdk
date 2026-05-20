#pragma once

#include <vector>

#include "webrtc_qos/types.h"

namespace webrtc_qos {

struct RtcpSenderReport {
  uint32_t sender_ssrc = 0;
  uint64_t ntp_timestamp = 0;
  uint32_t rtp_timestamp = 0;
  uint32_t packet_count = 0;
  uint32_t octet_count = 0;
};

struct RtcpNack {
  uint32_t sender_ssrc = 0;
  uint32_t media_ssrc = 0;
  std::vector<uint16_t> lost_rtp_sequence_numbers;
};

struct RtcpPli {
  uint32_t sender_ssrc = 0;
  uint32_t media_ssrc = 0;
};

std::vector<uint8_t> SerializeRtcpSenderReport(const RtcpSenderReport& report);
Status ParseRtcpSenderReport(const uint8_t* data,
                             size_t size,
                             RtcpSenderReport* report);

std::vector<uint8_t> SerializeRtcpReceiverReport(
    const RtcpReceiverReport& report);
Status ParseRtcpReceiverReport(const uint8_t* data,
                               size_t size,
                               RtcpReceiverReport* report);

std::vector<uint8_t> SerializeRtcpTransportFeedback(
    const UplinkTransportFeedback& feedback);
Status ParseRtcpTransportFeedback(const uint8_t* data,
                                  size_t size,
                                  UplinkTransportFeedback* feedback);

std::vector<uint8_t> SerializeRtcpNack(const RtcpNack& nack);
Status ParseRtcpNack(const uint8_t* data, size_t size, RtcpNack* nack);

std::vector<uint8_t> SerializeRtcpPli(const RtcpPli& pli);
Status ParseRtcpPli(const uint8_t* data, size_t size, RtcpPli* pli);

}  // namespace webrtc_qos
