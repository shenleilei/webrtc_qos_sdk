#include <cstdlib>
#include <iostream>
#include <vector>

#include "demo/udp_common.h"
#include "webrtc_qos/receiver_qos_observer.h"
#include "webrtc_qos/rtcp_packets.h"
#include "webrtc_qos/rtp_packet.h"
#include "webrtc_qos/transport_feedback.h"
#include "webrtc_qos/video_jitter_bridge.h"

namespace {

void Usage(const char* argv0) {
  std::cerr << "usage: " << argv0
            << " <local_port> <server_ip> <server_port>\n";
}

}  // namespace

int main(int argc, char** argv) {
  using namespace webrtc_qos;
  using namespace webrtc_qos::demo;

  if (argc != 4) {
    Usage(argv[0]);
    return 2;
  }

  const uint16_t local_port = static_cast<uint16_t>(std::atoi(argv[1]));
  const std::string server_ip = argv[2];
  const uint16_t server_port = static_cast<uint16_t>(std::atoi(argv[3]));

  int fd = CreateUdpSocket(local_port);
  sockaddr_in server = MakeIpv4Address(server_ip, server_port);

  TransportIds ids = DemoTransportIds();

  ReceiverQosObserver observer(ReceiverQosObserverConfig{ids, 200});
  observer.SetDownlinkRttMs(12);
  VideoJitterPlayer jitter =
      CreateWebRtcVideoJitterPlayer(VideoJitterPlayerConfig{ids.sender_ssrc});

  size_t rtp_packets = 0;
  size_t frames = 0;
  size_t nack_sent = 0;
  size_t pli_sent = 0;
  bool bye = false;
  int64_t synthetic_arrival_us = 2000000;
  const int64_t deadline_us = NowUs() + 15000000;

  while (NowUs() < deadline_us && !bye) {
    DemoEnvelopeHeader header;
    std::vector<uint8_t> payload;
    sockaddr_in from{};
    if (!ReceiveEnvelope(fd, 200, &header, &payload, &from)) {
      continue;
    }

    if (header.session_id != ids.session_id || header.stream_id != ids.stream_id) {
      continue;
    }

    if (header.type == EnvelopeType::kRtp) {
      RtpPacket packet;
      Status status = ParseRtpPacket(payload.data(), payload.size(), &packet);
      if (!status) {
        std::cerr << "udp_receiver: parse RTP failed: " << status.message
                  << "\n";
        return 1;
      }
      ++rtp_packets;
      synthetic_arrival_us += 3000;
      const int64_t arrival_us = synthetic_arrival_us;
      observer.OnRtpPacketReceived(packet, arrival_us);
      status = jitter.InsertPacket(packet, arrival_us);
      if (!status) {
        std::cerr << "udp_receiver: jitter insert failed: " << status.message
                  << "\n";
        return 1;
      }
      while (jitter.HasFrame()) {
        EncodedVideoFrame frame;
        status = jitter.PopFrame(&frame);
        if (!status) {
          std::cerr << "udp_receiver: jitter pop failed: " << status.message
                    << "\n";
          return 1;
        }
        observer.OnFrameDecoded(frame.rtp_timestamp);
        ++frames;
        std::cout << "udp_receiver frame ts=" << frame.rtp_timestamp
                  << " bytes=" << frame.annexb_access_unit.size()
                  << " keyframe=" << frame.keyframe << "\n";
        if (frame.keyframe && pli_sent == 0) {
          RtcpPli pli;
          pli.sender_ssrc = ids.receiver_id;
          pli.media_ssrc = ids.sender_ssrc;
          SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kPli, ids),
                       SerializeRtcpPli(pli));
          ++pli_sent;
        }
      }

      std::vector<uint16_t> missing = observer.TakeMissingSequenceNumbers();
      if (!missing.empty()) {
        RtcpNack nack;
        nack.sender_ssrc = ids.receiver_id;
        nack.media_ssrc = ids.sender_ssrc;
        nack.lost_rtp_sequence_numbers = missing;
        SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kNack, ids),
                     SerializeRtcpNack(nack));
        ++nack_sent;
      }

      if (observer.ShouldReport(NowUs())) {
        DownlinkQuality report = observer.BuildReport(NowUs());
        const VideoJitterStats stats = jitter.GetStats();
        report.video_jitter_frames = stats.jitter_frames;
        report.video_decodable_queue_depth = stats.decodable_queue_depth;
        report.video_drop_frames =
            static_cast<uint16_t>(std::min<uint32_t>(
                stats.dropped_frames, 0xffff));
        SendEnvelope(fd, server,
                     MakeEnvelopeHeader(EnvelopeType::kDownlinkQuality, ids),
                     SerializeDownlinkQuality(report));
      }
    } else if (header.type == EnvelopeType::kBye) {
      bye = true;
    }
  }

  DownlinkQuality final_report = observer.BuildReport(NowUs());
  SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kDownlinkQuality, ids),
               SerializeDownlinkQuality(final_report));
  SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kBye, ids), {});

  const VideoJitterStats stats = jitter.GetStats();
  std::cout << "udp_receiver rtp=" << rtp_packets
            << " nack_sent=" << nack_sent
            << " pli_sent=" << pli_sent
            << " frames=" << frames
            << " jitter_frames=" << stats.completed_frames << "\n";
  close(fd);
  return frames >= 3 && nack_sent >= 1 && pli_sent >= 1 ? 0 : 1;
}
