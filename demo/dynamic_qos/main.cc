#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

#include "webrtc_qos/sender_qos_controller.h"

namespace {

struct Phase {
  std::string name;
  uint32_t ack_bps = 0;
  double loss_fraction = 0.0;
  uint32_t rtt_ms = 0;
  int64_t now_us = 0;
};

uint16_t NextSeq(uint16_t* seq) {
  const uint16_t out = *seq;
  *seq = static_cast<uint16_t>(*seq + 1);
  return out;
}

webrtc_qos::UplinkTransportFeedback BuildFeedback(
    const webrtc_qos::TransportIds& ids,
    uint16_t* transport_seq,
    int64_t now_us,
    uint32_t ack_bps,
    double loss_fraction) {
  webrtc_qos::UplinkTransportFeedback feedback;
  feedback.ids = ids;
  feedback.reference_time_us = now_us;
  feedback.feedback_seq = static_cast<uint16_t>(now_us / 100000);

  constexpr size_t kPackets = 20;
  const size_t lost_packets =
      static_cast<size_t>(loss_fraction * static_cast<double>(kPackets) + 0.5);
  const size_t acked_packets = kPackets - lost_packets;
  const size_t packet_size = 1000;
  const int64_t span_us =
      ack_bps > 0
          ? static_cast<int64_t>((acked_packets * packet_size * 8.0 * 1000000.0) /
                                 static_cast<double>(ack_bps))
          : 1000000;
  const int64_t step_us =
      acked_packets > 1 ? span_us / static_cast<int64_t>(acked_packets - 1)
                        : span_us;
  int64_t receive_time_us = now_us;
  for (size_t i = 0; i < kPackets; ++i) {
    const uint16_t seq = NextSeq(transport_seq);
    webrtc_qos::PacketFeedback packet;
    packet.transport_sequence_number = seq;
    packet.send_time_us = now_us - 100000 + static_cast<int64_t>(i) * 3000;
    packet.packet_size = packet_size;
    if (i < lost_packets) {
      packet.receive_time_us = -1;
    } else {
      packet.receive_time_us = receive_time_us;
      receive_time_us += step_us;
    }
    feedback.packets.push_back(packet);
  }
  return feedback;
}

bool Expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    return false;
  }
  return true;
}

}  // namespace

int main() {
  using namespace webrtc_qos;

  TransportIds ids{1, 1, 1, 0x12345678, 2};
  SenderQosControllerConfig config;
  config.ids = ids;
  config.start_bitrate_bps = 1200000;
  config.min_bitrate_bps = 80000;
  config.max_bitrate_bps = 2500000;
  SenderQosController controller(config);

  std::vector<Phase> phases = {
      {"good", 10000000, 0.0, 20, 1000000},
      {"outage", 80000, 0.45, 1000, 2000000},
      {"poor", 120000, 0.25, 650, 3000000},
      {"recovering", 1200000, 0.03, 180, 4000000},
      {"good_again", 10000000, 0.0, 40, 5000000},
  };

  bool ok = true;
  uint16_t transport_seq = 1;
  std::vector<EncoderAdaptation> decisions;

  for (const Phase& phase : phases) {
    for (int i = 0; i < 3; ++i) {
      UplinkTransportFeedback feedback =
          BuildFeedback(ids, &transport_seq, phase.now_us + i * 100000,
                        phase.ack_bps, phase.loss_fraction);
      Status status = controller.OnUplinkTransportFeedback(feedback);
      ok &= Expect(status.code == StatusCode::kOk, "feedback accepted");
    }

    RtcpReceiverReport rr;
    rr.sender_ssrc = ids.sender_ssrc;
    rr.rtt_ms = phase.rtt_ms;
    rr.receive_time_us = phase.now_us + 300000;
    Status status = controller.OnRtcpReceiverReport(rr);
    ok &= Expect(status.code == StatusCode::kOk, "RR accepted");

    EncoderAdaptation decision =
        controller.GetEncoderAdaptation(phase.now_us + 300000);
    decisions.push_back(decision);
    TargetRates rates = controller.GetTargetRates(phase.now_us + 300000);
    std::cout << "dynamic_qos phase=" << phase.name
              << " estimate_bps=" << rates.googcc_target_bps
              << " final_bps=" << rates.final_target_bps
              << " rtt_ms=" << rates.rtt_ms
              << " loss=" << rates.loss_fraction
              << " encoder_bps=" << decision.target_bitrate_bps
              << " max_fps=" << decision.max_fps
              << " keyframe=" << decision.request_keyframe << "\n";
  }

  ok &= Expect(decisions[0].max_fps == 30,
               "good network keeps full frame rate");
  ok &= Expect(decisions[1].target_bitrate_bps < decisions[0].target_bitrate_bps,
               "outage lowers encoder bitrate");
  ok &= Expect(decisions[1].max_fps <= 5, "outage lowers FPS");
  ok &= Expect(decisions[1].request_keyframe, "outage requests keyframe");
  ok &= Expect(decisions[4].target_bitrate_bps > decisions[2].target_bitrate_bps,
               "recovered network raises encoder bitrate");
  ok &= Expect(decisions[4].max_fps == 30, "recovered network restores FPS");

  std::cout << (ok ? "dynamic_qos_demo passed\n" : "dynamic_qos_demo failed\n");
  return ok ? 0 : 1;
}
