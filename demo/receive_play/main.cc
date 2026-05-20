#include <chrono>
#include <iostream>

#include "webrtc_qos/video_receiver.h"

namespace {

int64_t NowUs() {
  using Clock = std::chrono::steady_clock;
  return std::chrono::duration_cast<std::chrono::microseconds>(
             Clock::now().time_since_epoch())
      .count();
}

}  // namespace

int main() {
  using namespace webrtc_qos;
  TransportIds ids{1, 1, 1, 0x12345678, 2};
  size_t frames = 0;
  VideoReceiver receiver(
      VideoReceiverConfig{ids},
      VideoReceiverCallbacks{
          [&](const EncodedVideoFrame& frame) {
            ++frames;
            std::cout << "receive frame timestamp=" << frame.rtp_timestamp
                      << " bytes=" << frame.annexb_access_unit.size() << "\n";
          },
          [&](const DownlinkQuality& report) {
            std::cout << "downlink_quality seq=" << report.report_seq << "\n";
          },
          [&](const RecoveryRequest& request) {
            std::cout << "recovery request type="
                      << static_cast<int>(request.type) << "\n";
          }});
  receiver.SetDownlinkRttMs(10);

  RtpPacket packet;
  packet.payload_type = kH264PayloadType;
  packet.marker = true;
  packet.sequence_number = 1;
  packet.timestamp = 90000;
  packet.ssrc = ids.sender_ssrc;
  packet.transport_sequence_number = 1;
  packet.payload = {0x65, 0x88, 0x84, 0x21};
  Status status = receiver.OnRtpPacket(packet, NowUs());
  if (!status) {
    std::cerr << status.message << "\n";
    return 1;
  }
  receiver.MaybeReport(NowUs() + 250000);
  return frames == 1 ? 0 : 1;
}
