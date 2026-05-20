#include <chrono>
#include <cstdint>
#include <iostream>
#include <optional>
#include <vector>

#include "webrtc_qos/receiver_qos_observer.h"
#include "webrtc_qos/retransmission_cache.h"
#include "webrtc_qos/sender_qos_googcc_bridge.h"
#include "webrtc_qos/sender_pacer.h"
#include "webrtc_qos/video_jitter_bridge.h"
#include "webrtc_qos/video_sender.h"

namespace {

int64_t NowUs() {
  using Clock = std::chrono::steady_clock;
  return std::chrono::duration_cast<std::chrono::microseconds>(
             Clock::now().time_since_epoch())
      .count();
}

void AppendStartCode(std::vector<uint8_t>* au) {
  au->insert(au->end(), {0x00, 0x00, 0x00, 0x01});
}

void AppendNalu(std::vector<uint8_t>* au, std::initializer_list<uint8_t> nalu) {
  AppendStartCode(au);
  au->insert(au->end(), nalu.begin(), nalu.end());
}

std::vector<uint8_t> SyntheticIdrAu() {
  std::vector<uint8_t> au;
  AppendNalu(&au, {0x67, 0x42, 0xe0, 0x1f, 0x8c, 0x68, 0x14, 0x19,
                   0x79, 0xe0, 0x1e, 0x11, 0x08, 0xd4, 0x00, 0x04});
  AppendNalu(&au, {0x68, 0xce, 0x3c, 0x80, 0x00, 0x2e});
  AppendNalu(&au, {0x65, 0xb8, 0x00, 0x04, 0x08, 0x79, 0x31, 0x40,
                   0x00, 0x42, 0xae, 0x4d});
  return au;
}

std::vector<uint8_t> SyntheticLargeIdrAu() {
  std::vector<uint8_t> au;
  AppendNalu(&au, {0x67, 0x42, 0xe0, 0x1f, 0x8c, 0x68, 0x14, 0x19,
                   0x79, 0xe0, 0x1e, 0x11, 0x08, 0xd4, 0x00, 0x04});
  AppendNalu(&au, {0x68, 0xce, 0x3c, 0x80, 0x00, 0x2e});

  AppendStartCode(&au);
  au.insert(au.end(), {0x65, 0x85, 0xb8, 0x00, 0x04, 0x00, 0x00, 0x13,
                       0x93, 0x12, 0x00, 0x02, 0x03, 0x04, 0x05, 0x06});
  for (int i = 0; i < 1600; ++i) {
    au.push_back(static_cast<uint8_t>(i & 0xff));
  }
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

  SenderQosControllerConfig qos_config;
  qos_config.ids = ids;
  qos_config.start_bitrate_bps = 1200000;
  qos_config.min_bitrate_bps = 300000;
  qos_config.max_bitrate_bps = 2500000;
  SenderQosController qos =
      CreateGoogCcSenderQosController(qos_config, 1000000);
  qos.OnProcessInterval(1000000);

  std::vector<RtpPacket> server_packets;
  std::vector<PacketFeedback> feedback;
  RetransmissionCache server_cache;
  int64_t send_time_us = 1000000;

  SenderPacer pacer(
      SenderPacerConfig{},
      [&](const RtpPacket& packet) {
        server_packets.push_back(packet);
        server_cache.Store(packet, send_time_us);
        qos.OnPacketSent(packet.transport_sequence_number,
                         packet.payload.size() + 20, send_time_us);
        feedback.push_back(PacketFeedback{
            packet.transport_sequence_number,
            send_time_us,
            send_time_us + 12000,
            packet.payload.size() + 20,
        });
        return Status::Ok();
      });

  VideoSender sender(VideoSenderConfig{ids}, &pacer);
  const auto idr = SyntheticIdrAu();
  const auto large_idr = SyntheticLargeIdrAu();
  Status status = sender.SendAnnexBAccessUnit(idr.data(), idr.size(), 900000);
  if (!status) {
    std::cerr << "send idr failed: " << status.message << "\n";
    return 1;
  }
  status = sender.SendAnnexBAccessUnit(large_idr.data(), large_idr.size(),
                                       933000);
  if (!status) {
    std::cerr << "send large idr failed: " << status.message << "\n";
    return 2;
  }

  for (int i = 0; i < 60; ++i) {
    send_time_us = 1000000 + i * 5000;
    status = pacer.Tick(send_time_us);
    if (!status) {
      std::cerr << "pacer failed: " << status.message << "\n";
      return 3;
    }
  }

  if (server_packets.size() < 6) {
    std::cerr << "expected at least 6 RTP packets, got "
              << server_packets.size() << "\n";
    return 4;
  }

  UplinkTransportFeedback uplink_feedback;
  uplink_feedback.ids = ids;
  uplink_feedback.feedback_seq = 1;
  uplink_feedback.reference_time_us = 1450000;
  uplink_feedback.packets = feedback;
  qos.OnUplinkTransportFeedback(uplink_feedback);
  qos.OnProcessInterval(1450000);
  RtcpReceiverReport rr;
  rr.sender_ssrc = ids.sender_ssrc;
  rr.rtt_ms = 24;
  rr.receive_time_us = 1500000;
  qos.OnRtcpReceiverReport(rr);
  qos.OnProcessInterval(1500000);
  const TargetRates rates = qos.GetTargetRates(1500000);

  ReceiverQosObserver observer(ReceiverQosObserverConfig{ids, 200});
  VideoJitterPlayer jitter =
      CreateWebRtcVideoJitterPlayer(VideoJitterPlayerConfig{ids.sender_ssrc});
  const size_t drop_index = 1;
  std::optional<uint16_t> dropped_rtp_sequence;
  size_t frames = 0;

  for (size_t i = 0; i < server_packets.size(); ++i) {
    const RtpPacket& packet = server_packets[i];
    if (i == drop_index) {
      dropped_rtp_sequence = packet.sequence_number;
      continue;
    }
    const int64_t arrival_time_us = 2000000 + static_cast<int64_t>(i) * 3000;
    observer.OnRtpPacketReceived(packet, arrival_time_us);
    status = jitter.InsertPacket(packet, arrival_time_us);
    if (!status) {
      std::cerr << "jitter insert failed: " << status.message << "\n";
      return 8;
    }
    while (jitter.HasFrame()) {
      EncodedVideoFrame frame;
      status = jitter.PopFrame(&frame);
      if (!status) {
        std::cerr << "jitter pop failed: " << status.message << "\n";
        return 9;
      }
      observer.OnFrameDecoded(frame.rtp_timestamp);
      ++frames;
    }
  }

  std::vector<uint16_t> missing = observer.TakeMissingSequenceNumbers();
  if (!dropped_rtp_sequence || missing.empty()) {
    std::cerr << "expected NACK candidate for dropped packet\n";
    return 5;
  }

  const uint16_t retransmit_twcc = sender.next_transport_sequence_number();
  std::optional<RtpPacket> retransmission =
      server_cache.Find(*dropped_rtp_sequence, retransmit_twcc);
  if (!retransmission) {
    std::cerr << "server cache missed dropped RTP seq "
              << *dropped_rtp_sequence << "\n";
    return 6;
  }

  const int64_t retransmit_arrival_us = 2300000;
  observer.OnRtpPacketReceived(*retransmission, retransmit_arrival_us);
  status = jitter.InsertPacket(*retransmission, retransmit_arrival_us);
  if (!status) {
    std::cerr << "jitter retransmit insert failed: " << status.message << "\n";
    return 10;
  }
  while (jitter.HasFrame()) {
    EncodedVideoFrame frame;
    status = jitter.PopFrame(&frame);
    if (!status) {
      std::cerr << "jitter retransmit pop failed: " << status.message << "\n";
      return 11;
    }
    observer.OnFrameDecoded(frame.rtp_timestamp);
    ++frames;
  }

  DownlinkQuality report = observer.BuildReport(2500000);
  const SenderPacerStats pacer_stats = pacer.GetStats();
  const VideoJitterStats jitter_stats = jitter.GetStats();

  std::cout << "rtp_packets=" << server_packets.size()
            << " retransmitted_seq=" << *dropped_rtp_sequence
            << " nack_count=" << missing.size() << "\n";
  std::cout << "googcc_target_bps=" << rates.googcc_target_bps
            << " final_target_bps=" << rates.final_target_bps << "\n";
  std::cout << "frames=" << frames
            << " jitter_frames=" << jitter_stats.completed_frames
            << " pacer_sent=" << pacer_stats.sent_packets
            << " loss_q8=" << report.fraction_lost_q8 << "\n";

  return frames >= 2 && rates.googcc_target_bps > 0 &&
                 jitter_stats.completed_frames >= 2
             ? 0
             : 7;
}
