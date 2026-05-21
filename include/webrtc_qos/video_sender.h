#pragma once

#include "webrtc_qos/sender_pacer.h"
#include "webrtc_qos/types.h"

namespace webrtc_qos {

struct VideoSenderConfig {
  TransportIds ids;
  uint16_t initial_rtp_sequence_number = 1;
  uint16_t initial_transport_sequence_number = 1;
  uint32_t initial_rtp_timestamp = 90000;
};

class VideoSender {
 public:
  VideoSender(VideoSenderConfig config, SenderPacer* pacer);

  Status SendAnnexBAccessUnit(const uint8_t* data,
                              size_t size,
                              int64_t capture_time_us);
  uint16_t next_rtp_sequence_number() const { return next_rtp_sequence_number_; }
  uint16_t next_transport_sequence_number() const {
    return next_transport_sequence_number_;
  }
  uint32_t RtpTimestampForCaptureTime(int64_t capture_time_us) const;

 private:
  Status ValidateAccessUnit(const std::vector<std::vector<uint8_t>>& nalus,
                            VideoFrameType* frame_type) const;
  Status EnqueueNalu(const std::vector<uint8_t>& nalu,
                     bool marker,
                     VideoFrameType frame_type,
                     int64_t capture_time_us,
                     uint32_t rtp_timestamp);

  VideoSenderConfig config_;
  SenderPacer* pacer_ = nullptr;
  uint16_t next_rtp_sequence_number_ = 0;
  uint16_t next_transport_sequence_number_ = 0;
};

}  // namespace webrtc_qos
