#include <algorithm>
#include <cstdint>
#include <iostream>
#include <vector>

#include "webrtc_qos/ffmpeg_h264_encoder.h"
#include "webrtc_qos/sender_pacer.h"
#include "webrtc_qos/video_sender.h"

namespace {

bool ContainsStartCode(const std::vector<uint8_t>& data) {
  for (size_t i = 0; i + 4 <= data.size(); ++i) {
    if (data[i] == 0 && data[i + 1] == 0 &&
        ((data[i + 2] == 1) ||
         (i + 3 < data.size() && data[i + 2] == 0 && data[i + 3] == 1))) {
      return true;
    }
  }
  return false;
}

void FillI420Frame(uint32_t width,
                   uint32_t height,
                   int frame_index,
                   std::vector<uint8_t>* y,
                   std::vector<uint8_t>* u,
                   std::vector<uint8_t>* v) {
  y->resize(width * height);
  u->resize(width * height / 4);
  v->resize(width * height / 4);
  for (uint32_t row = 0; row < height; ++row) {
    for (uint32_t col = 0; col < width; ++col) {
      (*y)[row * width + col] =
          static_cast<uint8_t>((row + col + frame_index * 7) & 0xff);
    }
  }
  std::fill(u->begin(), u->end(),
            static_cast<uint8_t>(96 + (frame_index % 16)));
  std::fill(v->begin(), v->end(),
            static_cast<uint8_t>(160 - (frame_index % 16)));
}

}  // namespace

int main() {
  using namespace webrtc_qos;

  FfmpegH264EncoderConfig encoder_config;
  encoder_config.width = 320;
  encoder_config.height = 180;
  encoder_config.fps = 30;
  encoder_config.bitrate_bps = 800000;
  encoder_config.gop_size = 30;

  FfmpegH264Encoder encoder;
  Status status = encoder.Open(encoder_config);
  if (!status) {
    std::cerr << "encoder open failed: " << status.message << "\n";
    return 1;
  }

  std::vector<RtpPacket> sent_packets;
  SenderPacer pacer(
      SenderPacerConfig{encoder_config.bitrate_bps, kPacerTickMs,
                        kPacerMaxQueueMs, kPacerMaxQueueBytes},
      [&](const RtpPacket& packet) {
        sent_packets.push_back(packet);
        return Status::Ok();
      });
  TransportIds ids{1, 1, 1, 0x12345678, 2};
  VideoSender sender(VideoSenderConfig{ids}, &pacer);

  std::vector<uint8_t> y;
  std::vector<uint8_t> u;
  std::vector<uint8_t> v;
  std::vector<uint8_t> annexb;
  bool ok = true;

  for (int i = 0; i < 3; ++i) {
    const bool force_keyframe = i == 0;
    FillI420Frame(encoder_config.width, encoder_config.height, i, &y, &u, &v);
    status = encoder.EncodeI420(y.data(), encoder_config.width, u.data(),
                                encoder_config.width / 2, v.data(),
                                encoder_config.width / 2, force_keyframe,
                                &annexb);
    if (!status) {
      std::cerr << "encode failed: " << status.message << "\n";
      return 2;
    }
    if (!ContainsStartCode(annexb)) {
      std::cerr << "encoded H264 is not Annex-B\n";
      return 3;
    }
    status = sender.SendAnnexBAccessUnit(annexb.data(), annexb.size(),
                                         1000000 + i * 33333);
    if (!status) {
      std::cerr << "video sender failed: " << status.message << "\n";
      return 4;
    }
    for (int tick = 0; tick < 30; ++tick) {
      status = pacer.Tick(1000000 + i * 33333 + tick * 5000);
      if (!status) {
        std::cerr << "pacer tick failed: " << status.message << "\n";
        return 5;
      }
    }
    std::cout << "ffmpeg_encoder frame=" << i << " force_keyframe="
              << force_keyframe << " annexb_bytes=" << annexb.size()
              << " total_rtp=" << sent_packets.size() << "\n";
    ok &= !annexb.empty();
  }

  EncoderAdaptation degraded;
  degraded.target_bitrate_bps = 120000;
  degraded.max_fps = 5;
  degraded.request_keyframe = true;
  status = encoder.SetRates(degraded.target_bitrate_bps, degraded.max_fps);
  if (!status) {
    std::cerr << "set rates failed: " << status.message << "\n";
    return 6;
  }
  FillI420Frame(encoder_config.width, encoder_config.height, 4, &y, &u, &v);
  status = encoder.EncodeI420(y.data(), encoder_config.width, u.data(),
                              encoder_config.width / 2, v.data(),
                              encoder_config.width / 2,
                              degraded.request_keyframe, &annexb);
  if (!status) {
    std::cerr << "degraded encode failed: " << status.message << "\n";
    return 7;
  }
  ok &= !annexb.empty() && ContainsStartCode(annexb);
  std::cout << "ffmpeg_encoder adapted_bitrate_bps="
            << degraded.target_bitrate_bps << " adapted_fps="
            << degraded.max_fps << " keyframe="
            << degraded.request_keyframe
            << " annexb_bytes=" << annexb.size() << "\n";

  SenderPacerStats stats = pacer.GetStats();
  ok &= !sent_packets.empty();
  std::cout << "ffmpeg_encoder_demo packets=" << sent_packets.size()
            << " pacer_sent=" << stats.sent_packets
            << " dropped=" << stats.dropped_packets << "\n";
  std::cout << (ok ? "ffmpeg_encoder_demo passed\n"
                   : "ffmpeg_encoder_demo failed\n");
  return ok ? 0 : 1;
}
