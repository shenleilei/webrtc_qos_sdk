#include <chrono>
#include <iostream>
#include <vector>

#include "webrtc_qos/sender_pacer.h"
#include "webrtc_qos/video_sender.h"

namespace {

int64_t NowUs() {
  using Clock = std::chrono::steady_clock;
  return std::chrono::duration_cast<std::chrono::microseconds>(
             Clock::now().time_since_epoch())
      .count();
}

std::vector<uint8_t> SyntheticIdrAu() {
  return {0, 0, 0, 1, 0x67, 0x42, 0xe0, 0x1f, 0x89, 0x8b, 0x60,
          0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80,
          0, 0, 0, 1, 0x65, 0x88, 0x84, 0x21, 0xa0};
}

}  // namespace

int main() {
  using namespace webrtc_qos;
  TransportIds ids{1, 1, 1, 0x12345678, 2};
  size_t sent = 0;
  SenderPacer pacer(SenderPacerConfig{}, [&](const RtpPacket& packet) {
    ++sent;
    std::cout << "send rtp_seq=" << packet.sequence_number
              << " twcc_seq=" << packet.transport_sequence_number
              << " marker=" << packet.marker
              << " payload=" << packet.payload.size() << "\n";
    return Status::Ok();
  });
  VideoSender sender(VideoSenderConfig{ids}, &pacer);
  const auto au = SyntheticIdrAu();
  Status status = sender.SendAnnexBAccessUnit(au.data(), au.size(), NowUs());
  if (!status) {
    std::cerr << status.message << "\n";
    return 1;
  }
  for (int i = 0; i < 10; ++i) {
    pacer.Tick(NowUs() + i * 5000);
  }
  std::cout << "capture_push_demo packets=" << sent << "\n";
  return sent > 0 ? 0 : 1;
}
