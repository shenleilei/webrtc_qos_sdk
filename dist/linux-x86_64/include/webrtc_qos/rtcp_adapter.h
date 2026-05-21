#ifndef SDK_QOS_RTCP_ADAPTER_H_
#define SDK_QOS_RTCP_ADAPTER_H_

#include <cstddef>
#include <cstdint>
#include <vector>

namespace webrtc_qos {

struct RtcpAdapterReportBlock {
  uint32_t media_ssrc = 0;
  uint8_t fraction_lost = 0;
  int32_t cumulative_lost = 0;
  uint32_t extended_high_seq_num = 0;
  uint32_t jitter = 0;
  uint32_t last_sr = 0;
  uint32_t delay_since_last_sr = 0;
};

struct RtcpAdapterSenderReport {
  uint32_t sender_ssrc = 0;
  uint32_t ntp_seconds = 0;
  uint32_t ntp_fractions = 0;
  uint32_t rtp_timestamp = 0;
  uint32_t packet_count = 0;
  uint32_t octet_count = 0;
  std::vector<RtcpAdapterReportBlock> report_blocks;
};

struct RtcpAdapterReceiverReport {
  uint32_t sender_ssrc = 0;
  std::vector<RtcpAdapterReportBlock> report_blocks;
};

struct RtcpAdapterTransportFeedbackPacket {
  uint16_t sequence_number = 0;
  int64_t delta_since_base_us = -1;
};

struct RtcpAdapterTransportFeedback {
  uint32_t sender_ssrc = 0;
  uint32_t media_ssrc = 0;
  uint16_t base_sequence = 0;
  int64_t base_time_us = 0;
  uint8_t feedback_sequence = 0;
  std::vector<RtcpAdapterTransportFeedbackPacket> packets;
};

struct RtcpAdapterNack {
  uint32_t sender_ssrc = 0;
  uint32_t media_ssrc = 0;
  std::vector<uint16_t> packet_ids;
};

struct RtcpAdapterPli {
  uint32_t sender_ssrc = 0;
  uint32_t media_ssrc = 0;
};

enum class RtcpAdapterPacketType {
  kUnknown = 0,
  kSenderReport,
  kReceiverReport,
  kTransportFeedback,
  kNack,
  kPli,
};

struct RtcpAdapterParsedPacket {
  RtcpAdapterPacketType type = RtcpAdapterPacketType::kUnknown;
  RtcpAdapterSenderReport sender_report;
  RtcpAdapterReceiverReport receiver_report;
  RtcpAdapterTransportFeedback transport_feedback;
  RtcpAdapterNack nack;
  RtcpAdapterPli pli;
};

bool BuildRtcpSenderReport(const RtcpAdapterSenderReport& input,
                           std::vector<uint8_t>* out);
bool ParseRtcpSenderReport(const uint8_t* data,
                           size_t size,
                           RtcpAdapterSenderReport* out);

bool BuildRtcpReceiverReport(const RtcpAdapterReceiverReport& input,
                             std::vector<uint8_t>* out);
bool ParseRtcpReceiverReport(const uint8_t* data,
                             size_t size,
                             RtcpAdapterReceiverReport* out);

bool BuildRtcpTransportFeedback(
    const RtcpAdapterTransportFeedback& input,
    std::vector<uint8_t>* out);
bool ParseRtcpTransportFeedback(const uint8_t* data,
                                size_t size,
                                RtcpAdapterTransportFeedback* out);

bool BuildRtcpNack(const RtcpAdapterNack& input, std::vector<uint8_t>* out);
bool ParseRtcpNack(const uint8_t* data, size_t size, RtcpAdapterNack* out);

bool BuildRtcpPli(const RtcpAdapterPli& input, std::vector<uint8_t>* out);
bool ParseRtcpPli(const uint8_t* data, size_t size, RtcpAdapterPli* out);

bool ParseRtcpPacket(const uint8_t* data,
                     size_t size,
                     RtcpAdapterParsedPacket* out);

}  // namespace webrtc_qos

#endif  // SDK_QOS_RTCP_ADAPTER_H_
