#include "webrtc_qos/ffmpeg_h264_encoder.h"

#include <algorithm>
#include <string>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/opt.h>
}

namespace webrtc_qos {
namespace {

std::string FfmpegError(int ret) {
  char buffer[AV_ERROR_MAX_STRING_SIZE] = {};
  av_strerror(ret, buffer, sizeof(buffer));
  return buffer;
}

void CopyPlane(const uint8_t* src,
               int src_stride,
               uint8_t* dst,
               int dst_stride,
               int width,
               int height) {
  for (int row = 0; row < height; ++row) {
    std::copy(src + row * src_stride, src + row * src_stride + width,
              dst + row * dst_stride);
  }
}

}  // namespace

struct FfmpegH264Encoder::Impl {
  FfmpegH264EncoderConfig config;
  AVCodecContext* context = nullptr;
  AVFrame* frame = nullptr;
  int64_t next_pts = 0;
};

FfmpegH264Encoder::FfmpegH264Encoder() : impl_(new Impl()) {}

FfmpegH264Encoder::~FfmpegH264Encoder() {
  Close();
}

Status FfmpegH264Encoder::Open(const FfmpegH264EncoderConfig& config) {
  Close();
  if (config.width == 0 || config.height == 0 || config.width % 2 != 0 ||
      config.height % 2 != 0 || config.fps == 0 ||
      config.bitrate_bps == 0) {
    return Status::Error(StatusCode::kInvalidArgument,
                         "invalid H264 encoder config");
  }

  impl_->config = config;
  const AVCodec* codec = avcodec_find_encoder_by_name("libx264");
  if (!codec) {
    codec = avcodec_find_encoder(AV_CODEC_ID_H264);
  }
  if (!codec) {
    return Status::Error(StatusCode::kUnsupported,
                         "FFmpeg H264 encoder not found");
  }

  impl_->context = avcodec_alloc_context3(codec);
  if (!impl_->context) {
    return Status::Error(StatusCode::kInternalError,
                         "avcodec_alloc_context3 failed");
  }

  impl_->context->width = static_cast<int>(config.width);
  impl_->context->height = static_cast<int>(config.height);
  impl_->context->time_base = AVRational{1, static_cast<int>(config.fps)};
  impl_->context->framerate = AVRational{static_cast<int>(config.fps), 1};
  impl_->context->pix_fmt = AV_PIX_FMT_YUV420P;
  impl_->context->bit_rate = config.bitrate_bps;
  impl_->context->gop_size = static_cast<int>(config.gop_size);
  impl_->context->max_b_frames = 0;

  if (impl_->context->priv_data) {
    av_opt_set(impl_->context->priv_data, "preset", "ultrafast", 0);
    av_opt_set(impl_->context->priv_data, "tune", "zerolatency", 0);
    av_opt_set(impl_->context->priv_data, "profile", "baseline", 0);
    av_opt_set(impl_->context->priv_data, "level", "3.1", 0);
    av_opt_set(impl_->context->priv_data, "x264-params",
               "level=3.1:repeat-headers=1:scenecut=0:bframes=0", 0);
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
  impl_->frame->format = impl_->context->pix_fmt;
  impl_->frame->width = impl_->context->width;
  impl_->frame->height = impl_->context->height;
  ret = av_frame_get_buffer(impl_->frame, 32);
  if (ret < 0) {
    const std::string error = FfmpegError(ret);
    Close();
    return Status::Error(StatusCode::kInternalError,
                         "av_frame_get_buffer failed: " + error);
  }

  impl_->next_pts = 0;
  return Status::Ok();
}

Status FfmpegH264Encoder::SetRates(uint32_t bitrate_bps, uint32_t fps) {
  if (!impl_->context) {
    return Status::Error(StatusCode::kInvalidArgument, "encoder is not open");
  }
  FfmpegH264EncoderConfig config = impl_->config;
  config.bitrate_bps = bitrate_bps;
  config.fps = fps;
  return Open(config);
}

Status FfmpegH264Encoder::EncodeI420(
    const uint8_t* y,
    int y_stride,
    const uint8_t* u,
    int u_stride,
    const uint8_t* v,
    int v_stride,
    bool force_keyframe,
    std::vector<uint8_t>* annexb_access_unit) {
  if (!impl_->context || !impl_->frame) {
    return Status::Error(StatusCode::kInvalidArgument, "encoder is not open");
  }
  if (!y || !u || !v || !annexb_access_unit) {
    return Status::Error(StatusCode::kInvalidArgument, "null I420 input");
  }

  annexb_access_unit->clear();
  int ret = av_frame_make_writable(impl_->frame);
  if (ret < 0) {
    return Status::Error(StatusCode::kInternalError,
                         "av_frame_make_writable failed: " + FfmpegError(ret));
  }

  const int width = impl_->context->width;
  const int height = impl_->context->height;
  CopyPlane(y, y_stride, impl_->frame->data[0], impl_->frame->linesize[0],
            width, height);
  CopyPlane(u, u_stride, impl_->frame->data[1], impl_->frame->linesize[1],
            width / 2, height / 2);
  CopyPlane(v, v_stride, impl_->frame->data[2], impl_->frame->linesize[2],
            width / 2, height / 2);
  impl_->frame->pts = impl_->next_pts++;
  impl_->frame->pict_type =
      force_keyframe ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;

  ret = avcodec_send_frame(impl_->context, impl_->frame);
  if (ret < 0) {
    return Status::Error(StatusCode::kInternalError,
                         "avcodec_send_frame failed: " + FfmpegError(ret));
  }

  while (true) {
    AVPacket* packet = av_packet_alloc();
    if (!packet) {
      return Status::Error(StatusCode::kInternalError, "av_packet_alloc failed");
    }
    ret = avcodec_receive_packet(impl_->context, packet);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
      av_packet_free(&packet);
      break;
    }
    if (ret < 0) {
      const std::string error = FfmpegError(ret);
      av_packet_free(&packet);
      return Status::Error(StatusCode::kInternalError,
                           "avcodec_receive_packet failed: " + error);
    }
    annexb_access_unit->insert(annexb_access_unit->end(), packet->data,
                               packet->data + packet->size);
    av_packet_free(&packet);
  }

  if (annexb_access_unit->empty()) {
    return Status::Error(StatusCode::kInternalError,
                         "encoder produced no output packet");
  }
  return Status::Ok();
}

void FfmpegH264Encoder::Close() {
  if (!impl_) {
    return;
  }
  if (impl_->frame) {
    av_frame_free(&impl_->frame);
  }
  if (impl_->context) {
    avcodec_free_context(&impl_->context);
  }
  impl_->next_pts = 0;
}

}  // namespace webrtc_qos
