#include <cstdlib>
#include <iostream>
#include <limits>
#include <string>
#include <unordered_map>
#include <vector>

#include "demo/qoe_common.h"
#include "demo/udp_common.h"
#include "webrtc_qos/ffmpeg_h264_decoder.h"
#include "webrtc_qos/receiver_qos_observer.h"
#include "webrtc_qos/rtcp_packets.h"
#include "webrtc_qos/rtp_packet.h"
#include "webrtc_qos/transport_feedback.h"
#include "webrtc_qos/video_jitter_player.h"

namespace {

void Usage(const char* argv0) {
  std::cerr << "usage: " << argv0
            << " <local_port> <server_ip> <server_port>"
            << " [--width=N] [--height=N] [--content=motion|low_motion|detail_motion]"
            << " [--expect-frames=N]\n";
}

bool ParseUint32Arg(const std::string& arg,
                    const std::string& prefix,
                    uint32_t* value) {
  if (arg.rfind(prefix, 0) != 0 || !value) {
    return false;
  }
  *value = static_cast<uint32_t>(std::strtoul(arg.c_str() + prefix.size(),
                                             nullptr, 10));
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  using namespace webrtc_qos;
  using namespace webrtc_qos::demo;

  if (argc < 4) {
    Usage(argv[0]);
    return 2;
  }
  const uint16_t local_port = static_cast<uint16_t>(std::atoi(argv[1]));
  const std::string server_ip = argv[2];
  const uint16_t server_port = static_cast<uint16_t>(std::atoi(argv[3]));
  uint32_t width = 320;
  uint32_t height = 180;
  uint32_t expected_frames = 60;
  std::string content = "motion";
  for (int i = 4; i < argc; ++i) {
    const std::string arg = argv[i];
    if (ParseUint32Arg(arg, "--width=", &width) ||
        ParseUint32Arg(arg, "--height=", &height) ||
        ParseUint32Arg(arg, "--expect-frames=", &expected_frames)) {
      continue;
    }
    const std::string content_prefix = "--content=";
    if (arg.rfind(content_prefix, 0) == 0) {
      content = arg.substr(content_prefix.size());
      continue;
    }
    Usage(argv[0]);
    return 2;
  }

  const int fd = CreateUdpSocket(local_port);
  const sockaddr_in server = MakeIpv4Address(server_ip, server_port);
  const TransportIds ids = DemoTransportIds();
  ReceiverQosObserver observer(ReceiverQosObserverConfig{ids, 200});
  observer.SetDownlinkRttMs(12);
  VideoJitterPlayer jitter(VideoJitterPlayerConfig{ids.sender_ssrc});
  FfmpegH264Decoder decoder;
  Status status = decoder.Open();
  if (!status) {
    std::cerr << "udp_long_receiver: decoder open failed: " << status.message
              << "\n";
    return 1;
  }

  uint64_t rtp_packets = 0;
  uint64_t nack_sent = 0;
  uint64_t completed_frames = 0;
  uint64_t decoded_frames = 0;
  uint64_t decode_errors = 0;
  uint64_t quality_samples = 0;
  uint64_t downlink_reports = 0;
  double psnr_sum = 0.0;
  double psnr_min = std::numeric_limits<double>::infinity();
  int64_t last_frame_time_us = -1;
  int64_t max_frame_gap_ms = 0;
  bool bye = false;
  const int64_t start_us = NowUs();
  const int64_t deadline_us = start_us + 20000000;
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
      status = ParseRtpPacket(payload.data(), payload.size(), &packet);
      if (!status) {
        std::cerr << "udp_long_receiver: parse RTP failed: " << status.message
                  << "\n";
        return 1;
      }
      ++rtp_packets;
      const int64_t now_us = NowUs();
      observer.OnRtpPacketReceived(packet, now_us);
      status = jitter.InsertPacket(packet, now_us);
      if (!status) {
        std::cerr << "udp_long_receiver: jitter insert failed: " << status.message
                  << "\n";
        return 1;
      }
      while (jitter.HasFrame()) {
        EncodedVideoFrame frame;
        status = jitter.PopFrame(&frame);
        if (!status) {
          std::cerr << "udp_long_receiver: jitter pop failed: " << status.message
                    << "\n";
          return 1;
        }
        observer.OnFrameDecoded(frame.rtp_timestamp);
        ++completed_frames;
        if (last_frame_time_us >= 0) {
          max_frame_gap_ms =
              std::max<int64_t>(max_frame_gap_ms,
                                (now_us - last_frame_time_us) / 1000);
        }
        last_frame_time_us = now_us;
        std::vector<DecodedVideoFrame> decoded;
        status = decoder.DecodeAnnexB(frame.annexb_access_unit.data(),
                                      frame.annexb_access_unit.size(),
                                      frame.rtp_timestamp, &decoded);
        if (!status) {
          ++decode_errors;
          continue;
        }
        decoded_frames += decoded.size();
        for (const DecodedVideoFrame& out : decoded) {
          const int64_t pts = out.pts >= 0 ? out.pts : frame.rtp_timestamp;
          const int64_t timestamp_delta =
              pts >= 90000 ? pts - 90000 : static_cast<int64_t>(pts);
          const int frame_index =
              static_cast<int>((timestamp_delta + 1500) / 3000);
          I420Frame reference = MakeI420Frame(width, height, content, frame_index);
          const double psnr = ComputeI420Psnr(reference, out);
          if (psnr > 0.0) {
            psnr_sum += psnr;
            psnr_min = std::min(psnr_min, psnr);
            ++quality_samples;
          }
        }
      }
      std::vector<uint16_t> missing = observer.TakeMissingSequenceNumbers();
      if (!missing.empty()) {
        RtcpNack nack;
        nack.sender_ssrc = ids.receiver_id;
        nack.media_ssrc = ids.sender_ssrc;
        nack.lost_rtp_sequence_numbers = std::move(missing);
        SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kNack, ids),
                     SerializeRtcpNack(nack));
        ++nack_sent;
      }
      if (observer.ShouldReport(now_us)) {
        DownlinkQuality report = observer.BuildReport(now_us);
        const VideoJitterStats stats = jitter.GetStats();
        report.video_jitter_frames = stats.jitter_frames;
        report.video_decodable_queue_depth = stats.decodable_queue_depth;
        report.video_drop_frames = static_cast<uint16_t>(
            std::min<uint32_t>(stats.dropped_frames, 0xffff));
        SendEnvelope(fd, server,
                     MakeEnvelopeHeader(EnvelopeType::kDownlinkQuality, ids),
                     SerializeDownlinkQuality(report));
        ++downlink_reports;
      }
    } else if (header.type == EnvelopeType::kBye) {
      bye = true;
    }
  }
  DownlinkQuality final_report = observer.BuildReport(NowUs());
  const VideoJitterStats final_stats = jitter.GetStats();
  final_report.video_jitter_frames = final_stats.jitter_frames;
  final_report.video_decodable_queue_depth = final_stats.decodable_queue_depth;
  final_report.video_drop_frames = static_cast<uint16_t>(
      std::min<uint32_t>(final_stats.dropped_frames, 0xffff));
  SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kDownlinkQuality, ids),
               SerializeDownlinkQuality(final_report));
  ++downlink_reports;
  SendEnvelope(fd, server, MakeEnvelopeHeader(EnvelopeType::kBye, ids), {});
  const double psnr_avg =
      quality_samples > 0 ? psnr_sum / static_cast<double>(quality_samples) : 0.0;
  const double safe_psnr_min = quality_samples > 0 ? psnr_min : 0.0;
  std::cout << "udp_long_receiver rtp=" << rtp_packets
            << " completed_frames=" << completed_frames
            << " decoded_frames=" << decoded_frames
            << " decode_errors=" << decode_errors
            << " quality_samples=" << quality_samples
            << " psnr_avg=" << psnr_avg
            << " psnr_min=" << safe_psnr_min
            << " max_frame_gap_ms=" << max_frame_gap_ms
            << " nack_sent=" << nack_sent
            << " downlink_reports=" << downlink_reports << "\n";
  close(fd);
  return completed_frames >= expected_frames && decoded_frames >= expected_frames &&
                 decode_errors == 0 && quality_samples >= expected_frames &&
                 psnr_avg >= 25.0 && max_frame_gap_ms <= 1000
             ? 0
             : 1;
}
