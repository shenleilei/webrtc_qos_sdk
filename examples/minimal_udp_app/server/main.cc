#include <cstdlib>
#include <iostream>

#include "common/options.h"
#include "common/run_loops.h"
#include "common/udp_socket.h"

int main(int argc, char** argv) {
  if (argc < 4) {
    std::cerr << "usage: " << argv[0]
              << " <local_port> <sender_ip:port> <receiver_ip:port>"
              << " [--frames N] [--tracks 1|2] [--log-dir DIR]"
              << " [--metrics-dir DIR] [--alerts-dir DIR]\n";
    return 2;
  }
  sockaddr_in sender_addr {};
  sockaddr_in receiver_addr {};
  if (!minimal_udp::ParseEndpoint(argv[2], &sender_addr)) {
    std::cerr << "invalid sender endpoint: " << argv[2] << "\n";
    return 2;
  }
  if (!minimal_udp::ParseEndpoint(argv[3], &receiver_addr)) {
    std::cerr << "invalid receiver endpoint: " << argv[3] << "\n";
    return 2;
  }
  minimal_udp::CommonOptions options;
  options.frames = 90;
  options.tracks = 2;
  if (!minimal_udp::ParseOptionalArgs(argc, argv, 4, &options)) {
    return 2;
  }
  return minimal_udp::RunServer(static_cast<uint16_t>(std::atoi(argv[1])),
                                sender_addr, receiver_addr, options);
}
