#include <chrono>
#include <iostream>
#include <vector>

#include "webrtc_qos/retransmission_cache.h"
#include "webrtc_qos/sender_pacer.h"
#include "webrtc_qos/video_receiver.h"
#include "webrtc_qos/video_sender.h"

namespace {

int64_t NowUs() {
  using Clock = std::chrono::steady_clock;
  return std::chrono::duration_cast<std::chrono::microseconds>(
             Clock::now().time_since_epoch())
      .count();
}

std::vector<uint8_t> SyntheticIdrAu() {
  std::vector<uint8_t> au;
  auto add = [&](std::initializer_list<uint8_t> bytes) {
    au.insert(au.end(), {0, 0, 0, 1});
    au.insert(au.end(), bytes.begin(), bytes.end());
  };
  add({0x67, 0x42, 0xe0, 0x1f, 0x89, 0x8b, 0x60});
  add({0x68, 0xce, 0x3c, 0x80});
  add({0x65, 0x88, 0x84, 0x21, 0xa0, 0xff, 0x00, 0x11});
  return au;
}

std::vector<uint8_t> SyntheticPAu() {
  std::vector<uint8_t> au;
  au.insert(au.end(), {0, 0, 0, 1});
  au.insert(au.end(), {0x41, 0x9a, 0x22, 0x11, 0x00, 0x44});
  return au;
}

}  // namespace

int main() {
  using namespace webrtc_qos;

  TransportIds ids;
  ids.session_id = 1;
  ids.stream_id = 1;
  ids.transport_id = 1;
  ids.sender_ssrc = 0x12345678;
  ids.receiver_id = 2;

  std::vector<RtpPacket> sent_packets;
  RetransmissionCache server_cache;
  SenderPacer pacer(SenderPacerConfig{},
                    [&](const RtpPacket& packet) {
                      sent_packets.push_back(packet);
                      server_cache.Store(packet, NowUs());
                      return Status::Ok();
                    });
  VideoSender sender(VideoSenderConfig{ids}, &pacer);

  size_t frames = 0;
  size_t recovery = 0;
  std::vector<uint16_t> pending_retransmissions;
  VideoReceiver receiver(
      VideoReceiverConfig{ids},
      VideoReceiverCallbacks{
          [&](const EncodedVideoFrame& frame) {
            ++frames;
            std::cout << "frame timestamp=" << frame.rtp_timestamp
                      << " bytes=" << frame.annexb_access_unit.size()
                      << " keyframe=" << frame.keyframe << "\n";
          },
          [&](const DownlinkQuality& report) {
            std::cout << "quality seq=" << report.report_seq
                      << " lost_q8=" << report.fraction_lost_q8
                      << " rtt_ms=" << report.rtt_ms << "\n";
          },
          [&](const RecoveryRequest& request) {
            ++recovery;
            std::cout << "recovery type="
                      << static_cast<int>(request.type)
                      << " missing=" << request.missing_rtp_sequence_numbers.size()
                      << "\n";
            pending_retransmissions.insert(
                pending_retransmissions.end(),
                request.missing_rtp_sequence_numbers.begin(),
                request.missing_rtp_sequence_numbers.end());
          }});
  receiver.SetDownlinkRttMs(12);
  const auto drain_retransmissions = [&]() {
    std::vector<uint16_t> missing;
    missing.swap(pending_retransmissions);
    for (uint16_t sequence_number : missing) {
      auto retransmission = server_cache.Find(sequence_number, 500);
      if (retransmission) {
        receiver.OnRtpPacket(*retransmission, NowUs());
      }
    }
  };

  const auto idr = SyntheticIdrAu();
  const auto p = SyntheticPAu();
  const int64_t first_capture_us = NowUs();
  sender.SendAnnexBAccessUnit(idr.data(), idr.size(), first_capture_us);
  sender.SendAnnexBAccessUnit(p.data(), p.size(), first_capture_us + 33333);

  for (int i = 0; i < 20; ++i) {
    pacer.Tick(NowUs() + i * 5000);
  }

  std::vector<RtpPacket> network_packets;
  for (size_t i = 0; i < sent_packets.size(); ++i) {
    if (i == 1) {
      continue;
    }
    network_packets.push_back(sent_packets[i]);
  }
  for (const auto& packet : network_packets) {
    receiver.OnRtpPacket(packet, NowUs());
    drain_retransmissions();
  }
  drain_retransmissions();
  receiver.MaybeReport(NowUs() + 250000);

  const SenderPacerStats stats = pacer.GetStats();
  std::cout << "sent_packets=" << stats.sent_packets
            << " dropped_packets=" << stats.dropped_packets
            << " decoded_frames=" << frames
            << " recovery_events=" << recovery << "\n";

  return frames == 2 ? 0 : 1;
}
