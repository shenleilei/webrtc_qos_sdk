#include "webrtc_qos/ffmpeg_h264_decoder.h"

#include <algorithm>
#include <string>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libswscale/swscale.h>
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
  SwsContext* sws_context = nullptr;
  AVFrame* i420_frame = nullptr;
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
  impl_->context->thread_count = 1;
  impl_->context->thread_type = 0;
  impl_->context->flags |= AV_CODEC_FLAG_LOW_DELAY;
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
  impl_->i420_frame = av_frame_alloc();
  if (!impl_->i420_frame) {
    Close();
    return Status::Error(StatusCode::kInternalError,
                         "i420 av_frame_alloc failed");
  }
  return Status::Ok();
}

Status FfmpegH264Decoder::DecodeAnnexB(
    const uint8_t* data,
    size_t size,
    std::vector<DecodedVideoFrame>* decoded_frames) {
  return DecodeAnnexB(data, size, AV_NOPTS_VALUE, decoded_frames);
}

Status FfmpegH264Decoder::DecodeAnnexB(
    const uint8_t* data,
    size_t size,
    int64_t pts,
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
  packet->pts = pts;
  packet->dts = pts;
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
    const int width = impl_->frame->width;
    const int height = impl_->frame->height;
    if (width <= 0 || height <= 0 || width % 2 != 0 || height % 2 != 0) {
      ++impl_->stats.decode_errors;
      av_frame_unref(impl_->frame);
      return Status::Error(StatusCode::kMalformedPacket,
                           "invalid decoded frame dimensions");
    }
    impl_->sws_context = sws_getCachedContext(
        impl_->sws_context, width, height,
        static_cast<AVPixelFormat>(impl_->frame->format), width, height,
        AV_PIX_FMT_YUV420P, SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
    if (!impl_->sws_context) {
      ++impl_->stats.decode_errors;
      av_frame_unref(impl_->frame);
      return Status::Error(StatusCode::kInternalError,
                           "sws_getCachedContext failed");
    }
    impl_->i420_frame->format = AV_PIX_FMT_YUV420P;
    impl_->i420_frame->width = width;
    impl_->i420_frame->height = height;
    ret = av_frame_get_buffer(impl_->i420_frame, 32);
    if (ret < 0) {
      ++impl_->stats.decode_errors;
      av_frame_unref(impl_->frame);
      return Status::Error(StatusCode::kInternalError,
                           "i420 av_frame_get_buffer failed: " +
                               FfmpegError(ret));
    }
    ret = sws_scale(impl_->sws_context, impl_->frame->data,
                    impl_->frame->linesize, 0, height,
                    impl_->i420_frame->data, impl_->i420_frame->linesize);
    if (ret != height) {
      ++impl_->stats.decode_errors;
      av_frame_unref(impl_->frame);
      av_frame_unref(impl_->i420_frame);
      return Status::Error(StatusCode::kInternalError, "sws_scale failed");
    }

    DecodedVideoFrame decoded;
    decoded.width = static_cast<uint32_t>(width);
    decoded.height = static_cast<uint32_t>(height);
    decoded.pts = impl_->frame->pts;
    decoded.y_stride = static_cast<uint32_t>(width);
    decoded.u_stride = static_cast<uint32_t>(width / 2);
    decoded.v_stride = static_cast<uint32_t>(width / 2);
    decoded.y_plane.resize(static_cast<size_t>(width) * height);
    decoded.u_plane.resize(static_cast<size_t>(width / 2) * (height / 2));
    decoded.v_plane.resize(static_cast<size_t>(width / 2) * (height / 2));
    for (int row = 0; row < height; ++row) {
      std::copy(impl_->i420_frame->data[0] +
                    row * impl_->i420_frame->linesize[0],
                impl_->i420_frame->data[0] +
                    row * impl_->i420_frame->linesize[0] + width,
                decoded.y_plane.data() + row * width);
    }
    for (int row = 0; row < height / 2; ++row) {
      std::copy(impl_->i420_frame->data[1] +
                    row * impl_->i420_frame->linesize[1],
                impl_->i420_frame->data[1] +
                    row * impl_->i420_frame->linesize[1] + width / 2,
                decoded.u_plane.data() + row * (width / 2));
      std::copy(impl_->i420_frame->data[2] +
                    row * impl_->i420_frame->linesize[2],
                impl_->i420_frame->data[2] +
                    row * impl_->i420_frame->linesize[2] + width / 2,
                decoded.v_plane.data() + row * (width / 2));
    }
    decoded_frames->push_back(std::move(decoded));
    ++impl_->stats.decoded_frames;
    av_frame_unref(impl_->frame);
    av_frame_unref(impl_->i420_frame);
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
  if (impl_->i420_frame) {
    av_frame_free(&impl_->i420_frame);
  }
  if (impl_->sws_context) {
    sws_freeContext(impl_->sws_context);
    impl_->sws_context = nullptr;
  }
  if (impl_->context) {
    avcodec_free_context(&impl_->context);
  }
  impl_->stats = {};
}

}  // namespace webrtc_qos
