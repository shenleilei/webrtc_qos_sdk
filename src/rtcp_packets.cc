#include "webrtc_qos/rtcp_packets.h"

#include <algorithm>

#include "byte_io.h"

namespace webrtc_qos {
namespace {

constexpr uint8_t kRtcpSr = 200;
constexpr uint8_t kRtcpRr = 201;
constexpr uint8_t kRtcpRtpfb = 205;
constexpr uint8_t kRtcpPsfb = 206;
constexpr uint8_t kFmtNack = 1;
constexpr uint8_t kFmtTwcc = 15;
constexpr uint8_t kFmtPli = 1;

void WriteRtcpHeader(std::vector<uint8_t>* out,
                     uint8_t fmt_or_count,
                     uint8_t packet_type,
                     uint16_t length_words_minus_one) {
  WriteU8(out, static_cast<uint8_t>(0x80 | (fmt_or_count & 0x1f)));
  WriteU8(out, packet_type);
  WriteU16(out, length_words_minus_one);
}

Status HeaderError(const char* message) {
  return Status::Error(StatusCode::kMalformedPacket, message);
}

bool ReadRtcpHeader(const uint8_t* data,
                    size_t size,
                    uint8_t* fmt_or_count,
                    uint8_t* packet_type,
                    uint16_t* length_words_minus_one) {
  if (size < 4 || (data[0] >> 6) != 2) {
    return false;
  }
  *fmt_or_count = data[0] & 0x1f;
  *packet_type = data[1];
  *length_words_minus_one = static_cast<uint16_t>((data[2] << 8) | data[3]);
  return true;
}

uint16_t RtcpLengthWordsMinusOne(size_t packet_size_bytes) {
  return static_cast<uint16_t>((packet_size_bytes / 4) - 1);
}

uint16_t MakeTwccRunLengthChunk(uint8_t symbol, uint16_t run_length) {
  return static_cast<uint16_t>(((symbol & 0x03) << 13) |
                               (run_length & 0x1fff));
}

void PatchRtcpLength(std::vector<uint8_t>* out) {
  const uint16_t length = RtcpLengthWordsMinusOne(out->size());
  (*out)[2] = static_cast<uint8_t>(length >> 8);
  (*out)[3] = static_cast<uint8_t>(length);
}

}  // namespace

std::vector<uint8_t> SerializeRtcpSenderReport(const RtcpSenderReport& report) {
  std::vector<uint8_t> out;
  WriteRtcpHeader(&out, 0, kRtcpSr, 6);
  WriteU32(&out, report.sender_ssrc);
  WriteU64(&out, report.ntp_timestamp);
  WriteU32(&out, report.rtp_timestamp);
  WriteU32(&out, report.packet_count);
  WriteU32(&out, report.octet_count);
  return out;
}

Status ParseRtcpSenderReport(const uint8_t* data,
                             size_t size,
                             RtcpSenderReport* report) {
  if (!data || !report) {
    return Status::Error(StatusCode::kInvalidArgument, "null SR input");
  }
  uint8_t count = 0;
  uint8_t pt = 0;
  uint16_t length = 0;
  if (!ReadRtcpHeader(data, size, &count, &pt, &length) || pt != kRtcpSr ||
      length != 6 || size < 28) {
    return HeaderError("invalid RTCP SR");
  }
  size_t pos = 4;
  return ReadU32(data, size, &pos, &report->sender_ssrc) &&
                 ReadU64(data, size, &pos, &report->ntp_timestamp) &&
                 ReadU32(data, size, &pos, &report->rtp_timestamp) &&
                 ReadU32(data, size, &pos, &report->packet_count) &&
                 ReadU32(data, size, &pos, &report->octet_count)
             ? Status::Ok()
             : HeaderError("short RTCP SR");
}

std::vector<uint8_t> SerializeRtcpReceiverReport(
    const RtcpReceiverReport& report) {
  std::vector<uint8_t> out;
  WriteRtcpHeader(&out, 1, kRtcpRr, 7);
  WriteU32(&out, report.sender_ssrc);
  WriteU32(&out, report.sender_ssrc);
  WriteU32(&out, 0);
  WriteU32(&out, 0);
  WriteU32(&out, 0);
  WriteU32(&out, report.last_sender_report);
  WriteU32(&out, report.delay_since_last_sender_report);
  return out;
}

Status ParseRtcpReceiverReport(const uint8_t* data,
                               size_t size,
                               RtcpReceiverReport* report) {
  if (!data || !report) {
    return Status::Error(StatusCode::kInvalidArgument, "null RR input");
  }
  uint8_t count = 0;
  uint8_t pt = 0;
  uint16_t length = 0;
  if (!ReadRtcpHeader(data, size, &count, &pt, &length) || pt != kRtcpRr ||
      count != 1 || length != 7 || size < 32) {
    return HeaderError("invalid RTCP RR");
  }
  size_t pos = 4;
  uint32_t reporter_ssrc = 0;
  uint32_t media_ssrc = 0;
  uint32_t ignored = 0;
  if (!ReadU32(data, size, &pos, &reporter_ssrc) ||
      !ReadU32(data, size, &pos, &media_ssrc) ||
      !ReadU32(data, size, &pos, &ignored) ||
      !ReadU32(data, size, &pos, &ignored) ||
      !ReadU32(data, size, &pos, &ignored) ||
      !ReadU32(data, size, &pos, &report->last_sender_report) ||
      !ReadU32(data, size, &pos, &report->delay_since_last_sender_report)) {
    return HeaderError("short RTCP RR");
  }
  report->sender_ssrc = media_ssrc;
  return Status::Ok();
}

std::vector<uint8_t> SerializeRtcpTransportFeedback(
    const UplinkTransportFeedback& feedback) {
  const size_t packet_count = std::min<size_t>(feedback.packets.size(), 0xffff);
  std::vector<uint8_t> out;
  WriteRtcpHeader(&out, kFmtTwcc, kRtcpRtpfb, 0);
  WriteU32(&out, feedback.ids.receiver_id);
  WriteU32(&out, feedback.ids.sender_ssrc);
  const uint16_t base_seq =
      packet_count == 0 ? 0 : feedback.packets.front().transport_sequence_number;
  WriteU16(&out, base_seq);
  WriteU16(&out, static_cast<uint16_t>(packet_count));
  const uint32_t reference_time_64ms =
      static_cast<uint32_t>(feedback.reference_time_us / 64000);
  WriteU8(&out, static_cast<uint8_t>(reference_time_64ms >> 16));
  WriteU8(&out, static_cast<uint8_t>(reference_time_64ms >> 8));
  WriteU8(&out, static_cast<uint8_t>(reference_time_64ms));
  WriteU8(&out, static_cast<uint8_t>(feedback.feedback_seq));

  std::vector<uint8_t> symbols;
  symbols.reserve(packet_count);
  for (size_t i = 0; i < packet_count; ++i) {
    symbols.push_back(feedback.packets[i].receive_time_us < 0 ? 0 : 2);
  }

  size_t index = 0;
  while (index < symbols.size()) {
    const uint8_t symbol = symbols[index];
    uint16_t run = 1;
    while (index + run < symbols.size() && symbols[index + run] == symbol &&
           run < 0x1fff) {
      ++run;
    }
    WriteU16(&out, MakeTwccRunLengthChunk(symbol, run));
    index += run;
  }

  for (size_t i = 0; i < packet_count; ++i) {
    const auto& packet = feedback.packets[i];
    if (packet.receive_time_us < 0) {
      continue;
    }
    int64_t delta_250us =
        (packet.receive_time_us - feedback.reference_time_us) / 250;
    delta_250us = std::max<int64_t>(-32768, std::min<int64_t>(32767, delta_250us));
    WriteU16(&out, static_cast<uint16_t>(static_cast<int16_t>(delta_250us)));
  }

  while (out.size() % 4 != 0) {
    out.push_back(0);
  }
  PatchRtcpLength(&out);
  return out;
}

Status ParseRtcpTransportFeedback(const uint8_t* data,
                                  size_t size,
                                  UplinkTransportFeedback* feedback) {
  if (!data || !feedback) {
    return Status::Error(StatusCode::kInvalidArgument, "null TWCC input");
  }
  uint8_t fmt = 0;
  uint8_t pt = 0;
  uint16_t length = 0;
  if (!ReadRtcpHeader(data, size, &fmt, &pt, &length) || pt != kRtcpRtpfb ||
      fmt != kFmtTwcc || size < 24) {
    return HeaderError("invalid RTCP TWCC");
  }
  size_t pos = 4;
  if (!ReadU32(data, size, &pos, &feedback->ids.receiver_id) ||
      !ReadU32(data, size, &pos, &feedback->ids.sender_ssrc)) {
    return HeaderError("short RTCP TWCC sender fields");
  }
  uint16_t base_seq = 0;
  uint16_t packet_count = 0;
  uint8_t ref_hi = 0;
  uint8_t ref_mid = 0;
  uint8_t ref_lo = 0;
  uint8_t fb_seq = 0;
  if (!ReadU16(data, size, &pos, &base_seq) ||
      !ReadU16(data, size, &pos, &packet_count) ||
      !ReadU8(data, size, &pos, &ref_hi) ||
      !ReadU8(data, size, &pos, &ref_mid) ||
      !ReadU8(data, size, &pos, &ref_lo) ||
      !ReadU8(data, size, &pos, &fb_seq)) {
    return HeaderError("short RTCP TWCC header fields");
  }
  feedback->feedback_seq = fb_seq;
  const uint32_t ref_64ms =
      (static_cast<uint32_t>(ref_hi) << 16) |
      (static_cast<uint32_t>(ref_mid) << 8) | ref_lo;
  feedback->reference_time_us = static_cast<int64_t>(ref_64ms) * 64000;
  std::vector<uint8_t> symbols;
  symbols.reserve(packet_count);
  while (symbols.size() < packet_count && pos + 2 <= size) {
    uint16_t chunk = 0;
    if (!ReadU16(data, size, &pos, &chunk)) {
      return HeaderError("short RTCP TWCC status chunk");
    }
    const bool status_vector = (chunk & 0x8000) != 0;
    if (status_vector) {
      return HeaderError("TWCC status vector chunks are not supported");
    }
    const uint8_t symbol = static_cast<uint8_t>((chunk >> 13) & 0x03);
    const uint16_t run = chunk & 0x1fff;
    for (uint16_t i = 0; i < run && symbols.size() < packet_count; ++i) {
      symbols.push_back(symbol);
    }
  }
  if (symbols.size() != packet_count) {
    return HeaderError("RTCP TWCC status chunks do not cover packet count");
  }
  feedback->packets.clear();
  feedback->packets.reserve(packet_count);
  for (uint16_t i = 0; i < packet_count; ++i) {
    PacketFeedback packet;
    packet.transport_sequence_number = static_cast<uint16_t>(base_seq + i);
    if (symbols[i] == 0) {
      packet.receive_time_us = -1;
    } else if (symbols[i] == 1) {
      uint8_t delta = 0;
      if (!ReadU8(data, size, &pos, &delta)) {
        return HeaderError("short RTCP TWCC small delta");
      }
      packet.receive_time_us =
          feedback->reference_time_us + static_cast<int64_t>(delta) * 250;
    } else if (symbols[i] == 2) {
      uint16_t raw_delta = 0;
      if (!ReadU16(data, size, &pos, &raw_delta)) {
        return HeaderError("short RTCP TWCC large delta");
      }
      const int16_t signed_delta = static_cast<int16_t>(raw_delta);
      packet.receive_time_us =
          feedback->reference_time_us + static_cast<int64_t>(signed_delta) * 250;
    } else {
      return HeaderError("invalid RTCP TWCC symbol");
    }
    feedback->packets.push_back(packet);
  }
  return Status::Ok();
}

std::vector<uint8_t> SerializeRtcpNack(const RtcpNack& nack) {
  std::vector<uint8_t> out;
  const uint16_t pair_count =
      static_cast<uint16_t>(nack.lost_rtp_sequence_numbers.size());
  WriteRtcpHeader(&out, kFmtNack, kRtcpRtpfb,
                  static_cast<uint16_t>(2 + pair_count));
  WriteU32(&out, nack.sender_ssrc);
  WriteU32(&out, nack.media_ssrc);
  for (uint16_t seq : nack.lost_rtp_sequence_numbers) {
    WriteU16(&out, seq);
    WriteU16(&out, 0);
  }
  return out;
}

Status ParseRtcpNack(const uint8_t* data, size_t size, RtcpNack* nack) {
  if (!data || !nack) {
    return Status::Error(StatusCode::kInvalidArgument, "null NACK input");
  }
  uint8_t fmt = 0;
  uint8_t pt = 0;
  uint16_t length = 0;
  if (!ReadRtcpHeader(data, size, &fmt, &pt, &length) || pt != kRtcpRtpfb ||
      fmt != kFmtNack || size < 12) {
    return HeaderError("invalid RTCP NACK");
  }
  size_t pos = 4;
  if (!ReadU32(data, size, &pos, &nack->sender_ssrc) ||
      !ReadU32(data, size, &pos, &nack->media_ssrc)) {
    return HeaderError("short RTCP NACK");
  }
  nack->lost_rtp_sequence_numbers.clear();
  while (pos + 4 <= size) {
    uint16_t pid = 0;
    uint16_t blp = 0;
    ReadU16(data, size, &pos, &pid);
    ReadU16(data, size, &pos, &blp);
    nack->lost_rtp_sequence_numbers.push_back(pid);
    for (int bit = 0; bit < 16; ++bit) {
      if ((blp & (1u << bit)) != 0) {
        nack->lost_rtp_sequence_numbers.push_back(
            static_cast<uint16_t>(pid + bit + 1));
      }
    }
  }
  return Status::Ok();
}

std::vector<uint8_t> SerializeRtcpPli(const RtcpPli& pli) {
  std::vector<uint8_t> out;
  WriteRtcpHeader(&out, kFmtPli, kRtcpPsfb, 2);
  WriteU32(&out, pli.sender_ssrc);
  WriteU32(&out, pli.media_ssrc);
  return out;
}

Status ParseRtcpPli(const uint8_t* data, size_t size, RtcpPli* pli) {
  if (!data || !pli) {
    return Status::Error(StatusCode::kInvalidArgument, "null PLI input");
  }
  uint8_t fmt = 0;
  uint8_t pt = 0;
  uint16_t length = 0;
  if (!ReadRtcpHeader(data, size, &fmt, &pt, &length) || pt != kRtcpPsfb ||
      fmt != kFmtPli || length != 2 || size < 12) {
    return HeaderError("invalid RTCP PLI");
  }
  size_t pos = 4;
  if (!ReadU32(data, size, &pos, &pli->sender_ssrc) ||
      !ReadU32(data, size, &pos, &pli->media_ssrc)) {
    return HeaderError("short RTCP PLI");
  }
  return Status::Ok();
}

}  // namespace webrtc_qos
