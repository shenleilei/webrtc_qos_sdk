#ifndef SDK_QOS_H264_RTP_ADAPTER_H_
#define SDK_QOS_H264_RTP_ADAPTER_H_

#include <cstddef>
#include <cstdint>
#include <vector>

namespace webrtc_qos {

struct H264RtpPacketizerConfig {
  size_t max_payload_size = 1200;
};

struct H264RtpPayload {
  bool marker = false;
  bool first_packet_in_frame = false;
  bool keyframe = false;
  std::vector<uint8_t> payload;
};

struct H264DepacketizedPayload {
  bool first_packet_in_frame = false;
  bool keyframe = false;
  bool valid = false;
  uint8_t nalu_type = 0;
  std::vector<uint8_t> video_payload;
};

bool PacketizeH264AnnexB(const uint8_t* annexb_access_unit,
                         size_t annexb_access_unit_size,
                         const H264RtpPacketizerConfig& config,
                         std::vector<H264RtpPayload>* out);

bool DepacketizeH264Payload(const uint8_t* rtp_payload,
                            size_t rtp_payload_size,
                            H264DepacketizedPayload* out);

}  // namespace webrtc_qos

#endif  // SDK_QOS_H264_RTP_ADAPTER_H_
