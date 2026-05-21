#ifndef SDK_QOS_NACK_REQUESTER_ADAPTER_H_
#define SDK_QOS_NACK_REQUESTER_ADAPTER_H_

#include <cstdint>
#include <memory>
#include <vector>

namespace webrtc_qos {

struct NackRequesterAdapterConfig {
  int64_t rtt_ms = 100;
};

enum class NackRequesterAdapterEventType {
  kNack,
  kKeyFrameRequest,
};

struct NackRequesterAdapterEvent {
  NackRequesterAdapterEventType type = NackRequesterAdapterEventType::kNack;
  bool buffering_allowed = false;
  std::vector<uint16_t> rtp_sequence_numbers;
};

class NackRequesterAdapter {
 public:
  explicit NackRequesterAdapter(const NackRequesterAdapterConfig& config);
  ~NackRequesterAdapter();

  NackRequesterAdapter(const NackRequesterAdapter&) = delete;
  NackRequesterAdapter& operator=(const NackRequesterAdapter&) = delete;

  int OnReceivedPacket(uint16_t rtp_sequence_number, bool is_recovered);
  void ClearUpTo(uint16_t rtp_sequence_number);
  void UpdateRtt(int64_t rtt_ms);
  void ProcessNacks();
  std::vector<NackRequesterAdapterEvent> DrainEvents();

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

NackRequesterAdapter* CreateNackRequesterAdapter(
    const NackRequesterAdapterConfig& config);
void DestroyNackRequesterAdapter(NackRequesterAdapter* adapter);

}  // namespace webrtc_qos

#endif  // SDK_QOS_NACK_REQUESTER_ADAPTER_H_
