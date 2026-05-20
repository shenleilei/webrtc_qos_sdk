#include <iostream>

#include "webrtc_qos/sender_qos_googcc_bridge.h"

int main() {
  using namespace webrtc_qos;

  SenderQosControllerConfig config;
  config.ids = TransportIds{1, 2, 3, 0x12345678, 9001};
  config.start_bitrate_bps = 1200000;
  config.min_bitrate_bps = 300000;
  config.max_bitrate_bps = 2500000;

  SenderQosController controller =
      CreateGoogCcSenderQosController(config, 1000000);

  Status status = controller.OnPacketSent(1, 1200, 1000000);
  if (!status) {
    std::cerr << status.message << "\n";
    return 1;
  }

  UplinkTransportFeedback feedback;
  feedback.ids = config.ids;
  feedback.feedback_seq = 1;
  feedback.reference_time_us = 1012000;
  feedback.packets.push_back(PacketFeedback{1, 1000000, 1012000, 1200});
  status = controller.OnUplinkTransportFeedback(feedback);
  if (!status) {
    std::cerr << status.message << "\n";
    return 2;
  }

  RtcpReceiverReport rr;
  rr.sender_ssrc = config.ids.sender_ssrc;
  rr.rtt_ms = 24;
  rr.receive_time_us = 1020000;
  status = controller.OnRtcpReceiverReport(rr);
  if (!status) {
    std::cerr << status.message << "\n";
    return 3;
  }

  SenderRateCap cap;
  cap.ids = config.ids;
  cap.cap_bps = 600000;
  cap.expire_ms = 1000;
  cap.receive_time_us = 1030000;
  status = controller.OnSenderRateCap(cap);
  if (!status) {
    std::cerr << status.message << "\n";
    return 4;
  }

  TargetRates rates = controller.GetTargetRates(1040000);
  std::cout << "googcc_target_bps=" << rates.googcc_target_bps
            << " final_target_bps=" << rates.final_target_bps
            << " rtt_ms=" << rates.rtt_ms << "\n";
  return rates.googcc_target_bps > 0 && rates.final_target_bps == 600000
             ? 0
             : 5;
}
