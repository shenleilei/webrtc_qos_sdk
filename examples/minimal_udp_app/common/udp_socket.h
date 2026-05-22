#pragma once

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

namespace minimal_udp {

class UdpSocket {
 public:
  UdpSocket() = default;
  ~UdpSocket() { Close(); }

  UdpSocket(const UdpSocket&) = delete;
  UdpSocket& operator=(const UdpSocket&) = delete;

  bool Bind(uint16_t port) {
    fd_ = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd_ < 0) {
      return false;
    }
    int reuse = 1;
    (void)setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);
    if (bind(fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
      return false;
    }
    socklen_t len = sizeof(local_addr_);
    if (getsockname(fd_, reinterpret_cast<sockaddr*>(&local_addr_), &len) !=
        0) {
      return false;
    }
    const int flags = fcntl(fd_, F_GETFL, 0);
    return flags >= 0 && fcntl(fd_, F_SETFL, flags | O_NONBLOCK) == 0;
  }

  void Close() {
    if (fd_ >= 0) {
      close(fd_);
      fd_ = -1;
    }
  }

  bool SendTo(const sockaddr_in& peer, const std::vector<uint8_t>& bytes) {
    const ssize_t sent = sendto(fd_, bytes.data(), bytes.size(), 0,
                                reinterpret_cast<const sockaddr*>(&peer),
                                sizeof(peer));
    return sent == static_cast<ssize_t>(bytes.size());
  }

  bool Recv(std::vector<uint8_t>* bytes, sockaddr_in* from) {
    bytes->assign(2048, 0);
    socklen_t from_len = sizeof(*from);
    const ssize_t received =
        recvfrom(fd_, bytes->data(), bytes->size(), 0,
                 reinterpret_cast<sockaddr*>(from), &from_len);
    if (received < 0) {
      return false;
    }
    bytes->resize(static_cast<size_t>(received));
    return true;
  }

  const sockaddr_in& local_addr() const { return local_addr_; }
  uint16_t port() const { return ntohs(local_addr_.sin_port); }

 private:
  int fd_ = -1;
  sockaddr_in local_addr_ {};
};

inline bool ParseEndpoint(const std::string& spec, sockaddr_in* out) {
  std::string host = "127.0.0.1";
  std::string port_text = spec;
  const size_t colon = spec.rfind(':');
  if (colon != std::string::npos) {
    host = spec.substr(0, colon);
    port_text = spec.substr(colon + 1);
  }
  if (port_text.empty()) {
    return false;
  }
  char* end = nullptr;
  const long port = std::strtol(port_text.c_str(), &end, 10);
  if (end == nullptr || *end != '\0' || port <= 0 || port > 65535) {
    return false;
  }
  sockaddr_in addr {};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(static_cast<uint16_t>(port));
  if (inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
    return false;
  }
  *out = addr;
  return true;
}

inline std::string EndpointToString(const sockaddr_in& addr) {
  char host[INET_ADDRSTRLEN] = {};
  const char* printed =
      inet_ntop(AF_INET, &addr.sin_addr, host, sizeof(host));
  return std::string(printed == nullptr ? "0.0.0.0" : printed) + ":" +
         std::to_string(ntohs(addr.sin_port));
}

inline bool SameAddress(const sockaddr_in& lhs, const sockaddr_in& rhs) {
  return lhs.sin_family == rhs.sin_family &&
         lhs.sin_addr.s_addr == rhs.sin_addr.s_addr &&
         lhs.sin_port == rhs.sin_port;
}

}  // namespace minimal_udp
