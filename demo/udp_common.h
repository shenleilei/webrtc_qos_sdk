#pragma once

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

#include "webrtc_qos/types.h"

namespace webrtc_qos::demo {

constexpr uint32_t kEnvelopeMagic = 0x57514f53;  // WQOS
constexpr uint8_t kEnvelopeVersion = 1;
constexpr size_t kEnvelopeHeaderBytes = 36;

enum class EnvelopeType : uint16_t {
  kRtp = 1,
  kUplinkTwcc = 2,
  kNack = 3,
  kDownlinkQuality = 4,
  kBye = 5,
  kRtcpSr = 6,
  kRtcpRr = 7,
  kSenderRateCap = 8,
  kPli = 9,
};

struct DemoEnvelopeHeader {
  EnvelopeType type = EnvelopeType::kBye;
  uint32_t session_id = 0;
  uint32_t stream_id = 0;
  uint32_t sender_ssrc = 0;
  uint32_t receiver_id = 0;
  uint16_t flags = 0;
};

struct NetworkSimulationConfig {
  uint16_t drop_rtp_seq = 2;
  uint16_t reorder_rtp_seq = 0;
  uint32_t delay_ms = 0;
};

struct DelayedPacket {
  std::vector<uint8_t> payload;
  int64_t release_time_us = 0;
  bool counted_forwarded = false;
};

inline int64_t NowUs() {
  using Clock = std::chrono::steady_clock;
  return std::chrono::duration_cast<std::chrono::microseconds>(
             Clock::now().time_since_epoch())
      .count();
}

inline void WriteU16(std::vector<uint8_t>* out, uint16_t value) {
  out->push_back(static_cast<uint8_t>(value >> 8));
  out->push_back(static_cast<uint8_t>(value));
}

inline void WriteU32(std::vector<uint8_t>* out, uint32_t value) {
  out->push_back(static_cast<uint8_t>(value >> 24));
  out->push_back(static_cast<uint8_t>(value >> 16));
  out->push_back(static_cast<uint8_t>(value >> 8));
  out->push_back(static_cast<uint8_t>(value));
}

inline void WriteU64(std::vector<uint8_t>* out, uint64_t value) {
  WriteU32(out, static_cast<uint32_t>(value >> 32));
  WriteU32(out, static_cast<uint32_t>(value));
}

inline uint16_t ReadU16(const uint8_t* data) {
  return static_cast<uint16_t>((data[0] << 8) | data[1]);
}

inline uint32_t ReadU32(const uint8_t* data) {
  return (static_cast<uint32_t>(data[0]) << 24) |
         (static_cast<uint32_t>(data[1]) << 16) |
         (static_cast<uint32_t>(data[2]) << 8) | data[3];
}

inline uint64_t ReadU64(const uint8_t* data) {
  return (static_cast<uint64_t>(ReadU32(data)) << 32) | ReadU32(data + 4);
}

inline TransportIds DemoTransportIds() {
  TransportIds ids;
  ids.session_id = 1;
  ids.stream_id = 1;
  ids.transport_id = 1;
  ids.sender_ssrc = 0x12345678;
  ids.receiver_id = 2;
  return ids;
}

inline DemoEnvelopeHeader MakeEnvelopeHeader(EnvelopeType type,
                                             const TransportIds& ids) {
  DemoEnvelopeHeader header;
  header.type = type;
  header.session_id = ids.session_id;
  header.stream_id = ids.stream_id;
  header.sender_ssrc = ids.sender_ssrc;
  header.receiver_id = ids.receiver_id;
  return header;
}

inline std::vector<uint8_t> PackEnvelope(const DemoEnvelopeHeader& header,
                                         const std::vector<uint8_t>& payload) {
  std::vector<uint8_t> out;
  out.reserve(kEnvelopeHeaderBytes + payload.size());
  WriteU32(&out, kEnvelopeMagic);
  out.push_back(kEnvelopeVersion);
  out.push_back(0);
  WriteU16(&out, static_cast<uint16_t>(header.type));
  WriteU32(&out, header.session_id);
  WriteU32(&out, header.stream_id);
  WriteU32(&out, header.sender_ssrc);
  WriteU32(&out, header.receiver_id);
  WriteU16(&out, header.flags);
  WriteU16(&out, static_cast<uint16_t>(payload.size()));
  WriteU64(&out, static_cast<uint64_t>(NowUs()));
  out.insert(out.end(), payload.begin(), payload.end());
  return out;
}

inline bool UnpackEnvelope(const uint8_t* data,
                           size_t size,
                           DemoEnvelopeHeader* header,
                           std::vector<uint8_t>* payload) {
  if (!data || !header || !payload || size < kEnvelopeHeaderBytes) {
    return false;
  }
  if (ReadU32(data) != kEnvelopeMagic) {
    return false;
  }
  if (data[4] != kEnvelopeVersion) {
    return false;
  }
  const uint16_t length = ReadU16(data + 26);
  if (size != kEnvelopeHeaderBytes + length) {
    return false;
  }
  header->type = static_cast<EnvelopeType>(ReadU16(data + 6));
  header->session_id = ReadU32(data + 8);
  header->stream_id = ReadU32(data + 12);
  header->sender_ssrc = ReadU32(data + 16);
  header->receiver_id = ReadU32(data + 20);
  header->flags = ReadU16(data + 24);
  payload->assign(data + kEnvelopeHeaderBytes,
                  data + kEnvelopeHeaderBytes + length);
  return true;
}

inline sockaddr_in MakeIpv4Address(const std::string& ip, uint16_t port) {
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  if (inet_pton(AF_INET, ip.c_str(), &addr.sin_addr) != 1) {
    std::cerr << "invalid IPv4 address: " << ip << "\n";
    std::exit(2);
  }
  return addr;
}

inline std::string AddressToString(const sockaddr_in& addr) {
  char ip[INET_ADDRSTRLEN] = {};
  inet_ntop(AF_INET, &addr.sin_addr, ip, sizeof(ip));
  return std::string(ip) + ":" + std::to_string(ntohs(addr.sin_port));
}

inline int CreateUdpSocket(uint16_t bind_port) {
  int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) {
    perror("socket");
    std::exit(2);
  }
  int reuse = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

  sockaddr_in local{};
  local.sin_family = AF_INET;
  local.sin_port = htons(bind_port);
  local.sin_addr.s_addr = htonl(INADDR_ANY);
  if (::bind(fd, reinterpret_cast<sockaddr*>(&local), sizeof(local)) != 0) {
    perror("bind");
    ::close(fd);
    std::exit(2);
  }
  return fd;
}

inline bool SendEnvelope(int fd,
                         const sockaddr_in& to,
                         const DemoEnvelopeHeader& header,
                         const std::vector<uint8_t>& payload) {
  const std::vector<uint8_t> datagram = PackEnvelope(header, payload);
  const ssize_t sent =
      ::sendto(fd, datagram.data(), datagram.size(), 0,
               reinterpret_cast<const sockaddr*>(&to), sizeof(to));
  return sent == static_cast<ssize_t>(datagram.size());
}

inline bool ReceiveEnvelope(int fd,
                            int timeout_ms,
                            DemoEnvelopeHeader* header,
                            std::vector<uint8_t>* payload,
                            sockaddr_in* from) {
  pollfd pfd{};
  pfd.fd = fd;
  pfd.events = POLLIN;
  const int ready = ::poll(&pfd, 1, timeout_ms);
  if (ready <= 0 || (pfd.revents & POLLIN) == 0) {
    return false;
  }

  uint8_t buffer[2048];
  socklen_t from_len = sizeof(*from);
  const ssize_t size =
      ::recvfrom(fd, buffer, sizeof(buffer), 0,
                 reinterpret_cast<sockaddr*>(from), &from_len);
  if (size <= 0) {
    return false;
  }
  return UnpackEnvelope(buffer, static_cast<size_t>(size), header, payload);
}

inline bool ParseUint16Option(const std::string& arg,
                              const std::string& prefix,
                              uint16_t* value) {
  if (arg.rfind(prefix, 0) != 0 || !value) {
    return false;
  }
  *value = static_cast<uint16_t>(std::strtoul(arg.c_str() + prefix.size(),
                                             nullptr, 10));
  return true;
}

inline bool ParseUint32Option(const std::string& arg,
                              const std::string& prefix,
                              uint32_t* value) {
  if (arg.rfind(prefix, 0) != 0 || !value) {
    return false;
  }
  *value = static_cast<uint32_t>(std::strtoul(arg.c_str() + prefix.size(),
                                             nullptr, 10));
  return true;
}

inline void AppendStartCode(std::vector<uint8_t>* au) {
  au->insert(au->end(), {0x00, 0x00, 0x00, 0x01});
}

inline void AppendNalu(std::vector<uint8_t>* au,
                       std::initializer_list<uint8_t> nalu) {
  AppendStartCode(au);
  au->insert(au->end(), nalu.begin(), nalu.end());
}

inline std::vector<uint8_t> SyntheticIdrAu() {
  std::vector<uint8_t> au;
  AppendNalu(&au, {0x67, 0x42, 0xe0, 0x1f, 0x8c, 0x68, 0x14, 0x19,
                   0x79, 0xe0, 0x1e, 0x11, 0x08, 0xd4, 0x00, 0x04});
  AppendNalu(&au, {0x68, 0xce, 0x3c, 0x80, 0x00, 0x2e});
  AppendNalu(&au, {0x65, 0xb8, 0x00, 0x04, 0x08, 0x79, 0x31, 0x40,
                   0x00, 0x42, 0xae, 0x4d});
  return au;
}

inline std::vector<uint8_t> SyntheticLargeIdrAu() {
  std::vector<uint8_t> au;
  AppendNalu(&au, {0x67, 0x42, 0xe0, 0x1f, 0x8c, 0x68, 0x14, 0x19,
                   0x79, 0xe0, 0x1e, 0x11, 0x08, 0xd4, 0x00, 0x04});
  AppendNalu(&au, {0x68, 0xce, 0x3c, 0x80, 0x00, 0x2e});
  AppendStartCode(&au);
  au.insert(au.end(), {0x65, 0x85, 0xb8, 0x00, 0x04, 0x00, 0x00, 0x13,
                       0x93, 0x12, 0x00, 0x02, 0x03, 0x04, 0x05, 0x06});
  for (int i = 0; i < 1600; ++i) {
    au.push_back(static_cast<uint8_t>(i & 0xff));
  }
  return au;
}

}  // namespace webrtc_qos::demo
