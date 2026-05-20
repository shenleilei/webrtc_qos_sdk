#include <iostream>
#include <vector>

#include "webrtc_qos/video_jitter_bridge.h"

int main() {
  using namespace webrtc_qos;

  VideoJitterPlayer jitter =
      CreateWebRtcVideoJitterPlayer(VideoJitterPlayerConfig{0x12345678});

  const uint8_t sps[] = {0x67, 0x42, 0xe0, 0x1f, 0x8c, 0x68, 0x14, 0x19,
                         0x79, 0xe0, 0x1e, 0x11, 0x08, 0xd4, 0x00, 0x04};
  const uint8_t pps[] = {0x68, 0xce, 0x3c, 0x80, 0x00, 0x2e};
  const uint8_t idr[] = {0x65, 0xb8, 0x00, 0x04, 0x08, 0x79,
                         0x31, 0x40, 0x00, 0x42, 0xae, 0x4d};

  auto make_packet = [](uint16_t seq, bool marker, const uint8_t* payload,
                        size_t size) {
    RtpPacket packet;
    packet.payload_type = kH264PayloadType;
    packet.marker = marker;
    packet.sequence_number = seq;
    packet.timestamp = 90000;
    packet.ssrc = 0x12345678;
    packet.transport_sequence_number = seq;
    packet.payload.assign(payload, payload + size);
    return packet;
  };

  Status status = jitter.InsertPacket(make_packet(100, false, sps, sizeof(sps)),
                                      1000);
  if (!status) {
    std::cerr << status.message << "\n";
    return 1;
  }
  status = jitter.InsertPacket(make_packet(101, false, pps, sizeof(pps)), 2000);
  if (!status) {
    std::cerr << status.message << "\n";
    return 2;
  }
  status = jitter.InsertPacket(make_packet(102, true, idr, sizeof(idr)), 3000);
  if (!status) {
    std::cerr << status.message << "\n";
    return 3;
  }
  if (!jitter.HasFrame()) {
    std::cerr << "no completed frame\n";
    return 4;
  }
  EncodedVideoFrame frame;
  status = jitter.PopFrame(&frame);
  if (!status) {
    std::cerr << status.message << "\n";
    return 5;
  }
  const VideoJitterStats stats = jitter.GetStats();
  std::cout << "frames=" << stats.completed_frames
            << " bytes=" << frame.annexb_access_unit.size()
            << " keyframe=" << frame.keyframe << "\n";
  return stats.completed_frames == 1 && frame.keyframe ? 0 : 6;
}
