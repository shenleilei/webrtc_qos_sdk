#include <cstdlib>
#include <iostream>

#include "common/options.h"
#include "common/run_loops.h"
#include "common/udp_socket.h"

int main(int argc, char** argv) {
  if (argc < 3) {
    std::cerr << "usage: " << argv[0]
              << " <local_port> <server_ip:port> [--frames N]"
              << " [--tracks 1|2] [--log-dir DIR] [--metrics-dir DIR]"
              << " [--alerts-dir DIR]\n";
    return 2;
  }
  sockaddr_in server_addr {};
  if (!minimal_udp::ParseEndpoint(argv[2], &server_addr)) {
    std::cerr << "invalid server endpoint: " << argv[2] << "\n";
    return 2;
  }
  minimal_udp::CommonOptions options;
  options.frames = 90;
  options.tracks = 2;
  if (!minimal_udp::ParseOptionalArgs(argc, argv, 3, &options)) {
    return 2;
  }
  return minimal_udp::RunReceiver(static_cast<uint16_t>(std::atoi(argv[1])),
                                  server_addr, options);
}
