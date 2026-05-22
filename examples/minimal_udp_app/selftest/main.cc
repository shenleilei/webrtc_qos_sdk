#include <iostream>

#include "common/options.h"
#include "common/run_loops.h"

int main(int argc, char** argv) {
  minimal_udp::CommonOptions options;
  options.frames = 36;
  options.tracks = 2;
  if (!minimal_udp::ParseOptionalArgs(argc, argv, 1, &options)) {
    std::cerr << "usage: " << argv[0]
              << " [--frames N] [--tracks 1|2] [--log-dir DIR]"
              << " [--metrics-dir DIR] [--alerts-dir DIR]\n";
    return 2;
  }
  options.frames = std::max(12, options.frames);
  return minimal_udp::RunSelftest(options);
}
