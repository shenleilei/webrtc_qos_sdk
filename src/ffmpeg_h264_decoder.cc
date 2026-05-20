#include "webrtc_qos/ffmpeg_h264_decoder.h"

#include <algorithm>
#include <string>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
}

namespace webrtc_qos {
namespace {

std::string FfmpegError(int ret) {
  char buffer[AV_ERROR_MAX_STRING_SIZE] = {};
  av_strerror(ret, buffer, sizeof(buffer));
  return buffer;
}

}  // namespace

struct FfmpegH264Decoder::Impl {
  AVCodecContext* context = nullptr;
  AVFrame* frame = nullptr;
  FfmpegH264DecoderStats stats;
};

FfmpegH264Decoder::FfmpegH264Decoder() : impl_(new Impl()) {}

FfmpegH264Decoder::~FfmpegH264Decoder() {
  Close();
}

Status FfmpegH264Decoder::Open() {
  Close();
  const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_H264);
  if (!codec) {
    return Status::Error(StatusCode::kUnsupported,
                         "FFmpeg H264 decoder not found");
  }
  impl_->context = avcodec_alloc_context3(codec);
  if (!impl_->context) {
    return Status::Error(StatusCode::kInternalError,
                         "avcodec_alloc_context3 failed");
  }
  int ret = avcodec_open2(impl_->context, codec, nullptr);
  if (ret < 0) {
    const std::string error = FfmpegError(ret);
    Close();
    return Status::Error(StatusCode::kInternalError,
                         "avcodec_open2 failed: " + error);
  }
  impl_->frame = av_frame_alloc();
  if (!impl_->frame) {
    Close();
    return Status::Error(StatusCode::kInternalError, "av_frame_alloc failed");
  }
  return Status::Ok();
}

Status FfmpegH264Decoder::DecodeAnnexB(
    const uint8_t* data,
    size_t size,
    std::vector<DecodedVideoFrame>* decoded_frames) {
  if (!impl_->context || !impl_->frame) {
    return Status::Error(StatusCode::kInvalidArgument, "decoder is not open");
  }
  if (!data || size == 0 || !decoded_frames) {
    return Status::Error(StatusCode::kInvalidArgument, "null H264 input");
  }
  decoded_frames->clear();
  AVPacket* packet = av_packet_alloc();
  if (!packet) {
    return Status::Error(StatusCode::kInternalError, "av_packet_alloc failed");
  }
  int ret = av_new_packet(packet, static_cast<int>(size));
  if (ret < 0) {
    const std::string error = FfmpegError(ret);
    av_packet_free(&packet);
    return Status::Error(StatusCode::kInternalError,
                         "av_new_packet failed: " + error);
  }
  std::copy(data, data + size, packet->data);
  ret = avcodec_send_packet(impl_->context, packet);
  av_packet_free(&packet);
  if (ret < 0) {
    ++impl_->stats.decode_errors;
    return Status::Error(StatusCode::kMalformedPacket,
                         "avcodec_send_packet failed: " + FfmpegError(ret));
  }

  while (true) {
    ret = avcodec_receive_frame(impl_->context, impl_->frame);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
      break;
    }
    if (ret < 0) {
      ++impl_->stats.decode_errors;
      return Status::Error(StatusCode::kMalformedPacket,
                           "avcodec_receive_frame failed: " +
                               FfmpegError(ret));
    }
    decoded_frames->push_back(DecodedVideoFrame{
        static_cast<uint32_t>(std::max(0, impl_->frame->width)),
        static_cast<uint32_t>(std::max(0, impl_->frame->height)),
        impl_->frame->pts,
    });
    ++impl_->stats.decoded_frames;
    av_frame_unref(impl_->frame);
  }
  return Status::Ok();
}

FfmpegH264DecoderStats FfmpegH264Decoder::GetStats() const {
  return impl_->stats;
}

void FfmpegH264Decoder::Close() {
  if (!impl_) {
    return;
  }
  if (impl_->frame) {
    av_frame_free(&impl_->frame);
  }
  if (impl_->context) {
    avcodec_free_context(&impl_->context);
  }
  impl_->stats = {};
}

}  // namespace webrtc_qos
