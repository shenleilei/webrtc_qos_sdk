#include <cstdint>
#include <iostream>
#include <map>
#include <string>
#include <vector>

#include "webrtc_qos/sender_qos_controller.h"

namespace {

struct Phase {
  std::string name;
  uint32_t ack_bps = 0;
  double loss_fraction = 0.0;
  uint32_t rtt_ms = 0;
  int repeat_feedback = 3;
};

struct Scenario {
  std::string name;
  std::vector<Phase> phases;
};

struct DecisionRow {
  std::string scenario;
  std::string phase;
  webrtc_qos::TargetRates rates;
  webrtc_qos::EncoderAdaptation decision;
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

  constexpr size_t kPackets = 30;
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

bool Expect(bool condition, const std::string& message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    return false;
  }
  return true;
}

const DecisionRow* FindPhase(const std::vector<DecisionRow>& rows,
                             const std::string& scenario,
                             const std::string& phase) {
  for (const DecisionRow& row : rows) {
    if (row.scenario == scenario && row.phase == phase) {
      return &row;
    }
  }
  return nullptr;
}

bool ValidateScenario(const std::vector<DecisionRow>& rows,
                      const std::string& scenario) {
  bool ok = true;
  auto phase = [&](const std::string& name) {
    const DecisionRow* row = FindPhase(rows, scenario, name);
    ok &= Expect(row != nullptr, scenario + ":" + name + " exists");
    return row;
  };

  if (scenario == "walk_outage_recover") {
    const DecisionRow* good = phase("good");
    const DecisionRow* outage = phase("outage");
    const DecisionRow* poor = phase("poor");
    const DecisionRow* recovered = phase("good_again");
    if (good && outage && poor && recovered) {
      ok &= Expect(good->decision.max_fps == 30, scenario + " good fps=30");
      ok &= Expect(outage->decision.max_fps <= 8,
                   scenario + " outage fps<=8");
      ok &= Expect(!outage->decision.request_keyframe,
                   scenario + " outage suppresses low-cap loss keyframe");
      ok &= Expect(poor->decision.max_fps <= 10, scenario + " poor fps<=10");
      ok &= Expect(outage->decision.target_bitrate_bps <
                       good->decision.target_bitrate_bps,
                   scenario + " bitrate drops in outage");
      ok &= Expect(recovered->decision.max_fps == 30,
                   scenario + " recovery fps=30");
      ok &= Expect(recovered->decision.target_bitrate_bps >
                       poor->decision.target_bitrate_bps,
                   scenario + " bitrate recovers");
    }
  } else if (scenario == "bandwidth_cliff_recover") {
    const DecisionRow* good = phase("good");
    const DecisionRow* cliff = phase("bandwidth_cliff");
    const DecisionRow* recovered = phase("recovered");
    if (good && cliff && recovered) {
      ok &= Expect(good->decision.max_fps == 30, scenario + " good fps=30");
      ok &= Expect(cliff->decision.max_fps <= 10,
                   scenario + " cliff fps<=10");
      ok &= Expect(cliff->decision.target_bitrate_bps <
                       good->decision.target_bitrate_bps,
                   scenario + " cliff bitrate drops");
      ok &= Expect(recovered->decision.max_fps == 30,
                   scenario + " recovered fps=30");
      ok &= Expect(recovered->decision.target_bitrate_bps >
                       cliff->decision.target_bitrate_bps,
                   scenario + " recovered bitrate rises");
    }
  } else if (scenario == "rtt_jitter_spike_recover") {
    const DecisionRow* good = phase("good");
    const DecisionRow* spike = phase("rtt_spike");
    const DecisionRow* recovered = phase("recovered");
    if (good && spike && recovered) {
      ok &= Expect(spike->decision.max_fps <= 10,
                   scenario + " RTT spike reduces fps");
      ok &= Expect(!spike->decision.request_keyframe,
                   scenario + " RTT spike does not request keyframe");
      ok &= Expect(recovered->decision.max_fps == 30,
                   scenario + " recovered fps=30");
      ok &= Expect(recovered->decision.target_bitrate_bps >=
                       good->decision.target_bitrate_bps / 2,
                   scenario + " recovered bitrate not stuck low");
    }
  } else if (scenario == "oscillating_edge") {
    const DecisionRow* good1 = phase("good_1");
    const DecisionRow* poor1 = phase("poor_1");
    const DecisionRow* good2 = phase("good_2");
    const DecisionRow* poor2 = phase("poor_2");
    const DecisionRow* good3 = phase("good_3");
    if (good1 && poor1 && good2 && poor2 && good3) {
      ok &= Expect(poor1->decision.max_fps < good1->decision.max_fps,
                   scenario + " poor_1 lowers fps");
      ok &= Expect(poor2->decision.max_fps < good2->decision.max_fps,
                   scenario + " poor_2 lowers fps");
      ok &= Expect(good3->decision.max_fps == 30,
                   scenario + " final good restores fps");
      ok &= Expect(good3->decision.target_bitrate_bps >
                       poor2->decision.target_bitrate_bps,
                   scenario + " final good restores bitrate");
    }
  } else if (scenario == "loss_burst_recover") {
    const DecisionRow* good = phase("good");
    const DecisionRow* burst = phase("loss_burst");
    const DecisionRow* recovered = phase("recovered");
    if (good && burst && recovered) {
      ok &= Expect(burst->decision.max_fps <= 10,
                   scenario + " burst loss fps<=10");
      ok &= Expect(!burst->decision.request_keyframe,
                   scenario + " burst loss suppresses low-cap keyframe");
      ok &= Expect(burst->decision.target_bitrate_bps <
                       good->decision.target_bitrate_bps,
                   scenario + " burst loss bitrate drops");
      ok &= Expect(recovered->decision.max_fps == 30,
                   scenario + " recovered fps=30");
    }
  }

  return ok;
}

}  // namespace

int main() {
  using namespace webrtc_qos;

  const std::vector<Scenario> scenarios = {
      {"walk_outage_recover",
       {{"good", 10000000, 0.0, 20, 3},
        {"outage", 80000, 0.45, 1000, 4},
        {"poor", 120000, 0.25, 650, 3},
        {"recovering", 1200000, 0.03, 180, 4},
        {"good_again", 10000000, 0.0, 40, 6}}},
      {"bandwidth_cliff_recover",
       {{"good", 8000000, 0.0, 25, 4},
        {"bandwidth_cliff", 90000, 0.02, 80, 5},
        {"recovered", 8000000, 0.0, 30, 8}}},
      {"rtt_jitter_spike_recover",
       {{"good", 5000000, 0.0, 35, 3},
        {"rtt_spike", 700000, 0.08, 900, 4},
        {"recovered", 5000000, 0.0, 45, 7}}},
      {"oscillating_edge",
       {{"good_1", 5000000, 0.0, 30, 3},
        {"poor_1", 180000, 0.18, 550, 3},
        {"good_2", 5000000, 0.0, 40, 5},
        {"poor_2", 130000, 0.22, 700, 3},
        {"good_3", 5000000, 0.0, 35, 7}}},
      {"loss_burst_recover",
       {{"good", 6000000, 0.0, 25, 3},
        {"loss_burst", 500000, 0.60, 220, 4},
        {"recovered", 6000000, 0.0, 35, 8}}},
  };

  bool ok = true;
  std::vector<DecisionRow> rows;

  for (const Scenario& scenario : scenarios) {
    TransportIds ids{1, 1, 1, 0x12345678, 2};
    SenderQosControllerConfig config;
    config.ids = ids;
    config.start_bitrate_bps = 1200000;
    config.min_bitrate_bps = 80000;
    config.max_bitrate_bps = 2500000;
    SenderQosController controller(config);
    uint16_t transport_seq = 1;
    int64_t now_us = 1000000;

    for (const Phase& phase : scenario.phases) {
      for (int i = 0; i < phase.repeat_feedback; ++i) {
        UplinkTransportFeedback feedback =
            BuildFeedback(ids, &transport_seq, now_us + i * 100000,
                          phase.ack_bps, phase.loss_fraction);
        Status status = controller.OnUplinkTransportFeedback(feedback);
        ok &= Expect(status.code == StatusCode::kOk,
                     scenario.name + ":" + phase.name + " feedback accepted");
      }

      RtcpReceiverReport rr;
      rr.sender_ssrc = ids.sender_ssrc;
      rr.rtt_ms = phase.rtt_ms;
      rr.receive_time_us = now_us + phase.repeat_feedback * 100000;
      Status status = controller.OnRtcpReceiverReport(rr);
      ok &= Expect(status.code == StatusCode::kOk,
                   scenario.name + ":" + phase.name + " RR accepted");

      const int64_t decision_time_us = rr.receive_time_us;
      EncoderAdaptation decision =
          controller.GetEncoderAdaptation(decision_time_us);
      TargetRates rates = controller.GetTargetRates(decision_time_us);
      rows.push_back(DecisionRow{scenario.name, phase.name, rates, decision});
      std::cout << "dynamic_qos scenario=" << scenario.name
                << " phase=" << phase.name
                << " estimate_bps=" << rates.googcc_target_bps
                << " final_bps=" << rates.final_target_bps
                << " rtt_ms=" << rates.rtt_ms
                << " loss=" << rates.loss_fraction
                << " encoder_bps=" << decision.target_bitrate_bps
                << " max_fps=" << decision.max_fps
                << " keyframe=" << decision.request_keyframe << "\n";
      now_us += 1000000;
    }

    ok &= ValidateScenario(rows, scenario.name);
  }

  std::cout << (ok ? "dynamic_qos_demo passed\n" : "dynamic_qos_demo failed\n");
  return ok ? 0 : 1;
}
