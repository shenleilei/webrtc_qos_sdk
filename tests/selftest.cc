#include <iostream>
#include <deque>
#include <vector>

#include "webrtc_qos/production_transport_adapter.h"
#include "webrtc_qos/retransmission_cache.h"
#include "webrtc_qos/rtcp_packets.h"
#include "webrtc_qos/rtp_packet.h"
#include "webrtc_qos/sender_pacer.h"
#include "webrtc_qos/sender_qos_controller.h"
#include "webrtc_qos/transport_feedback.h"
#include "webrtc_qos/transport_port.h"
#include "webrtc_qos/video_receiver.h"
#include "webrtc_qos/video_sender.h"

namespace {

bool Expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    return false;
  }
  return true;
}

}  // namespace

int main() {
  using namespace webrtc_qos;
  bool ok = true;

  DownlinkQuality quality;
  quality.ids = TransportIds{1, 2, 3, 4, 5};
  quality.report_seq = 7;
  quality.report_time_us = 1234567890123ull;
  quality.rtt_ms = 33;
  quality.fraction_lost_q8 = 2;
  quality.reorder_ratio_q8 = 1;
  quality.recv_bitrate_bps = 800000;
  auto encoded_quality = SerializeDownlinkQuality(quality);
  DownlinkQuality parsed_quality;
  Status status =
      ParseDownlinkQuality(encoded_quality.data(), encoded_quality.size(),
                           &parsed_quality);
  ok &= Expect(status.code == StatusCode::kOk, "parse downlink quality");
  ok &= Expect(parsed_quality.report_time_us == quality.report_time_us,
               "quality report_time_us keeps u64 precision");
  ok &= Expect(parsed_quality.ids.receiver_id == quality.ids.receiver_id,
               "quality receiver_id roundtrip");

  SenderRateCap cap;
  cap.ids = quality.ids;
  cap.controller_seq = 9;
  cap.cap_bps = 600000;
  cap.expire_ms = 500;
  auto encoded_cap = SerializeSenderRateCap(cap);
  SenderRateCap parsed_cap;
  status = ParseSenderRateCap(encoded_cap.data(), encoded_cap.size(),
                              &parsed_cap);
  ok &= Expect(status.code == StatusCode::kOk, "parse sender rate cap");
  ok &= Expect(parsed_cap.cap_bps == 600000, "sender rate cap roundtrip");

  TransportIds transport_ids{1, 2, 3, 0x12345678, 5};
  TransportPort missing_send_callback(nullptr);
  std::vector<uint8_t> transport_payload = {1, 2, 3, 4};
  status = missing_send_callback.Send(TransportMessageType::kRtp,
                                      transport_ids, transport_payload, 1000);
  ok &= Expect(status.code == StatusCode::kInvalidArgument,
               "transport send requires callback");

  std::vector<uint8_t> copied_payload;
  TransportMessage copied_message;
  TransportPort transport_port([&](const TransportMessage& message) {
    copied_message = message;
    copied_payload.assign(message.payload,
                          message.payload + message.payload_size);
    return Status::Ok();
  });
  status = transport_port.Send(TransportMessageType::kRtcpPli, transport_ids,
                               transport_payload, 2000, 7);
  ok &= Expect(status.code == StatusCode::kOk, "transport send callback runs");
  ok &= Expect(copied_message.type == TransportMessageType::kRtcpPli,
               "transport message type is preserved");
  ok &= Expect(copied_message.flags == 7, "transport flags are preserved");
  transport_payload[0] = 9;
  ok &= Expect(copied_payload == std::vector<uint8_t>({1, 2, 3, 4}),
               "async transport copies payload inside callback");

  TransportMessage invalid_deliver;
  invalid_deliver.payload = nullptr;
  invalid_deliver.payload_size = 1;
  status = transport_port.Deliver(invalid_deliver,
                                  [](const TransportMessage&) {
                                    return Status::Ok();
                                  });
  ok &= Expect(status.code == StatusCode::kInvalidArgument,
               "transport deliver rejects null payload");

  bool delivered = false;
  TransportMessage valid_deliver;
  valid_deliver.ids = transport_ids;
  valid_deliver.type = TransportMessageType::kSenderRateCap;
  valid_deliver.payload = copied_payload.data();
  valid_deliver.payload_size = copied_payload.size();
  status = transport_port.Deliver(
      valid_deliver, [&](const TransportMessage& message) {
        delivered = message.ids.session_id == transport_ids.session_id &&
                    message.type == TransportMessageType::kSenderRateCap &&
                    message.payload_size == copied_payload.size();
        return Status::Ok();
      });
  ok &= Expect(status.code == StatusCode::kOk && delivered,
               "transport deliver invokes receive callback");
  ok &= Expect(std::string(TransportMessageTypeName(TransportMessageType::kRtcpPli)) ==
                   "RTCP_PLI",
               "transport type name");

  std::deque<OwnedTransportMessage> production_wire;
  ProductionTransportAdapter production_adapter(
      [&](const OwnedTransportMessage& message) {
        production_wire.push_back(message);
        return Status::Ok();
      });
  std::vector<uint8_t> production_payload = {5, 6, 7};
  status = production_adapter.Send(TransportMessageType::kSenderRateCap,
                                   transport_ids, production_payload, 3000);
  ok &= Expect(status.code == StatusCode::kOk,
               "production transport adapter send");
  production_payload[0] = 0;
  ok &= Expect(production_wire.size() == 1,
               "production transport adapter queues one message");
  ok &= Expect(production_wire.front().lane ==
                   ProductionTransportLane::kReliableControl,
               "sender rate cap uses reliable control lane");
  ok &= Expect(production_wire.front().payload ==
                   std::vector<uint8_t>({5, 6, 7}),
               "production transport adapter owns payload copy");
  bool production_delivered = false;
  status = production_adapter.Deliver(
      production_wire.front(), [&](const TransportMessage& message) {
        production_delivered =
            message.type == TransportMessageType::kSenderRateCap &&
            message.payload_size == 3;
        return Status::Ok();
      });
  ok &= Expect(status.code == StatusCode::kOk && production_delivered,
               "production transport adapter deliver");

  RtpPacket packet;
  packet.payload_type = kH264PayloadType;
  packet.marker = true;
  packet.sequence_number = 11;
  packet.timestamp = 90000;
  packet.ssrc = 0x12345678;
  packet.transport_sequence_number = 22;
  packet.payload = {0x65, 1, 2, 3};
  auto rtp_bytes = SerializeRtpPacket(packet);
  RtpPacket parsed_packet;
  status = ParseRtpPacket(rtp_bytes.data(), rtp_bytes.size(), &parsed_packet);
  ok &= Expect(status.code == StatusCode::kOk, "parse RTP packet");
  ok &= Expect(parsed_packet.transport_sequence_number == 22,
               "RTP TWCC extension roundtrip");
  ok &= Expect(parsed_packet.payload == packet.payload, "RTP payload roundtrip");

  size_t sent = 0;
  SenderPacer pacer(SenderPacerConfig{300000, 5, 500, 80},
                    [&](const RtpPacket&) {
                      ++sent;
                      return Status::Ok();
                    });
  SendPacket p_packet;
  p_packet.frame_type = VideoFrameType::kP;
  p_packet.media_duration_ms = 33;
  p_packet.packet.payload.assign(200, 0x41);
  pacer.Enqueue(p_packet);
  pacer.Enqueue(p_packet);
  SenderPacerStats stats = pacer.GetStats();
  ok &= Expect(stats.waiting_for_idr, "pacer waits for IDR after P drop");

  size_t aged_sent = 0;
  SenderPacer aged_pacer(
      SenderPacerConfig{80000, 5, 500, 512 * 1024, 100},
      [&](const RtpPacket&) {
        ++aged_sent;
        return Status::Ok();
      });
  SendPacket aged_packet;
  aged_packet.frame_type = VideoFrameType::kP;
  aged_packet.media_duration_ms = 33;
  aged_packet.packet.capture_time_us = 1000000;
  aged_packet.packet.payload.assign(1200, 0x41);
  status = aged_pacer.Enqueue(aged_packet);
  ok &= Expect(status.code == StatusCode::kOk, "enqueue aged P packet");
  aged_pacer.Tick(1200000);
  stats = aged_pacer.GetStats();
  ok &= Expect(aged_sent == 0, "expired P packet not sent");
  ok &= Expect(stats.waiting_for_idr,
               "pacer waits for IDR after expired P drop");

  size_t live_sent = 0;
  SenderPacer live_pacer(
      SenderPacerConfig{80000, 5, 500, 512 * 1024, 100, false},
      [&](const RtpPacket&) {
        ++live_sent;
        return Status::Ok();
      });
  SendPacket live_old_packet;
  live_old_packet.frame_type = VideoFrameType::kP;
  live_old_packet.media_duration_ms = 33;
  live_old_packet.packet.capture_time_us = 1000000;
  live_old_packet.packet.payload.assign(1200, 0x41);
  status = live_pacer.Enqueue(live_old_packet);
  ok &= Expect(status.code == StatusCode::kOk, "enqueue live expired P packet");
  live_pacer.Tick(1200000);
  stats = live_pacer.GetStats();
  ok &= Expect(!stats.waiting_for_idr,
               "live pacer does not require IDR after expired P drop");
  SendPacket live_next_packet = live_old_packet;
  live_next_packet.packet.capture_time_us = 1230000;
  status = live_pacer.Enqueue(live_next_packet);
  ok &= Expect(status.code == StatusCode::kOk,
               "live pacer accepts P after expired P drop");

  size_t atomic_sent = 0;
  SenderPacer atomic_pacer(SenderPacerConfig{300000, 5, 500, 220},
                           [&](const RtpPacket&) {
                             ++atomic_sent;
                             return Status::Ok();
                           });
  SendPacket atomic_packet_a = live_old_packet;
  atomic_packet_a.packet.payload.assign(120, 0x41);
  SendPacket atomic_packet_b = atomic_packet_a;
  atomic_packet_b.packet.sequence_number = 2;
  std::vector<SendPacket> atomic_au = {atomic_packet_a, atomic_packet_b};
  status = atomic_pacer.EnqueueAccessUnit(atomic_au);
  ok &= Expect(status.code == StatusCode::kQueueFull,
               "oversized P access unit is dropped atomically");
  stats = atomic_pacer.GetStats();
  ok &= Expect(stats.queued_packets == 0,
               "atomic P access unit leaves no partial packets queued");

  SenderPacer recovery_pacer(
      SenderPacerConfig{80000, 5, 500, 512 * 1024, 100},
      [&](const RtpPacket&) { return Status::Ok(); });
  SendPacket recovery_old_packet = live_old_packet;
  status = recovery_pacer.Enqueue(recovery_old_packet);
  ok &= Expect(status.code == StatusCode::kOk,
               "enqueue recovery expired P packet");
  recovery_pacer.Tick(1200000);
  SendPacket recovery_idr_packet = recovery_old_packet;
  recovery_idr_packet.frame_type = VideoFrameType::kIdr;
  recovery_idr_packet.packet.capture_time_us = 1230000;
  recovery_idr_packet.packet.payload.assign(1200, 0x65);
  status = recovery_pacer.Enqueue(recovery_idr_packet);
  ok &= Expect(status.code == StatusCode::kOk,
               "IDR clears default pacer recovery wait");
  stats = recovery_pacer.GetStats();
  ok &= Expect(!stats.waiting_for_idr,
               "default pacer exits recovery wait after IDR");

  SenderQosController controller(
      SenderQosControllerConfig{TransportIds{1, 2, 3, 4, 5}, 1200000, 300000,
                                2500000});
  SenderRateCap limited_cap;
  limited_cap.ids = TransportIds{1, 2, 3, 4, 5};
  limited_cap.cap_bps = 500000;
  limited_cap.expire_ms = 1000;
  limited_cap.receive_time_us = 1000000;
  status = controller.OnSenderRateCap(limited_cap);
  ok &= Expect(status.code == StatusCode::kOk, "apply sender rate cap");
  TargetRates rates = controller.GetTargetRates(1100000);
  ok &= Expect(rates.final_target_bps == 500000, "rate cap limits target");
  rates = controller.GetTargetRates(3000000);
  ok &= Expect(rates.sender_rate_cap_bps == kUnlimitedRateCapBps,
               "expired cap returns to unlimited");
  SenderRateCap very_low_cap;
  very_low_cap.ids = TransportIds{1, 2, 3, 4, 5};
  very_low_cap.cap_bps = 180000;
  very_low_cap.expire_ms = 1000;
  very_low_cap.receive_time_us = 3000000;
  status = controller.OnSenderRateCap(very_low_cap);
  ok &= Expect(status.code == StatusCode::kOk, "apply very low sender cap");
  EncoderAdaptation adaptation = controller.GetEncoderAdaptation(3100000);
  ok &= Expect(adaptation.max_fps == 8,
               "very constrained capacity lowers fps to 8");
  ok &= Expect(!adaptation.request_keyframe,
               "very constrained capacity suppresses loss-driven IDR");
  SenderRateCap severe_cap = very_low_cap;
  severe_cap.cap_bps = 90000;
  severe_cap.receive_time_us = 3200000;
  status = controller.OnSenderRateCap(severe_cap);
  ok &= Expect(status.code == StatusCode::kOk, "apply severe sender cap");
  adaptation = controller.GetEncoderAdaptation(3300000);
  ok &= Expect(adaptation.max_fps == 5,
               "severe capacity lowers fps to 5");

  std::vector<RtpPacket> fu_packets;
  SenderPacer fu_pacer(SenderPacerConfig{},
                       [&](const RtpPacket& out) {
                         fu_packets.push_back(out);
                         return Status::Ok();
                       });
  VideoSender video_sender(VideoSenderConfig{TransportIds{1, 2, 3, 0x11111111, 5}},
                           &fu_pacer);
  std::vector<uint8_t> large_au = {0, 0, 0, 1, 0x67, 0x42, 0xe0, 0x1f,
                                   0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80,
                                   0, 0, 0, 1, 0x65};
  large_au.insert(large_au.end(), 3000, 0x88);
  status = video_sender.SendAnnexBAccessUnit(large_au.data(), large_au.size(),
                                             1234);
  ok &= Expect(status.code == StatusCode::kOk, "send large FU-A AU");
  ok &= Expect(fu_packets.empty(), "FU-A packets wait for pacer tick");
  for (int i = 0; i < 40; ++i) {
    fu_pacer.Tick(1000000 + i * 5000);
  }
  ok &= Expect(fu_packets.size() > 3, "large AU is fragmented");
  ok &= Expect(fu_packets.front().timestamp ==
                   video_sender.RtpTimestampForCaptureTime(1234),
               "video sender derives RTP timestamp from capture time");
  VideoReceiver fu_receiver(
      VideoReceiverConfig{TransportIds{1, 2, 3, 0x11111111, 5}},
      VideoReceiverCallbacks{});
  EncodedVideoFrame last_frame;
  size_t fu_frames = 0;
  fu_receiver = VideoReceiver(
      VideoReceiverConfig{TransportIds{1, 2, 3, 0x11111111, 5}},
      VideoReceiverCallbacks{
          [&](const EncodedVideoFrame& frame) {
            last_frame = frame;
            ++fu_frames;
          },
          nullptr,
          nullptr});
  for (const auto& out : fu_packets) {
    status = fu_receiver.OnRtpPacket(out, 2000000);
    ok &= Expect(status.code == StatusCode::kOk, "receive FU-A packet");
  }
  ok &= Expect(fu_frames == 1, "FU-A reassembles one frame");
  ok &= Expect(last_frame.keyframe, "FU-A IDR remains keyframe");
  ok &= Expect(last_frame.capture_time_us == 1234,
               "FU-A frame preserves capture time");
  ok &= Expect(last_frame.first_packet_receive_time_us == 2000000,
               "FU-A frame records first packet receive time");
  ok &= Expect(last_frame.completed_time_us == 2000000,
               "FU-A frame records completion time");

  SenderPacer reject_pacer(SenderPacerConfig{300000, 5, 500, 1},
                           [&](const RtpPacket&) { return Status::Ok(); });
  VideoSender reject_sender(
      VideoSenderConfig{TransportIds{1, 2, 3, 0x33333333, 5}},
      &reject_pacer);
  const uint16_t rejected_rtp_before = reject_sender.next_rtp_sequence_number();
  const uint16_t rejected_twcc_before =
      reject_sender.next_transport_sequence_number();
  status = reject_sender.SendAnnexBAccessUnit(large_au.data(), large_au.size(),
                                              3000);
  ok &= Expect(status.code == StatusCode::kQueueFull,
               "video sender surfaces atomic AU queue full");
  ok &= Expect(reject_sender.next_rtp_sequence_number() == rejected_rtp_before,
               "failed atomic AU enqueue rolls back RTP sequence numbers");
  ok &= Expect(reject_sender.next_transport_sequence_number() ==
                   rejected_twcc_before,
               "failed atomic AU enqueue rolls back TWCC sequence numbers");

  size_t nack_events = 0;
  VideoReceiver loss_receiver(
      VideoReceiverConfig{TransportIds{1, 2, 3, 0x22222222, 5}},
      VideoReceiverCallbacks{
          nullptr,
          nullptr,
          [&](const RecoveryRequest& request) {
            if (request.type == RecoveryRequest::Type::kNack) {
              ++nack_events;
            }
          }});
  RtpPacket first_loss_packet;
  first_loss_packet.payload_type = kH264PayloadType;
  first_loss_packet.sequence_number = 1;
  first_loss_packet.timestamp = 90000;
  first_loss_packet.ssrc = 0x22222222;
  first_loss_packet.transport_sequence_number = 1;
  first_loss_packet.payload = {0x61, 0x01};
  RtpPacket third_loss_packet = first_loss_packet;
  third_loss_packet.sequence_number = 3;
  third_loss_packet.transport_sequence_number = 3;
  third_loss_packet.marker = true;
  loss_receiver.OnRtpPacket(first_loss_packet, 1);
  loss_receiver.OnRtpPacket(third_loss_packet, 2);
  ok &= Expect(nack_events == 1, "missing RTP sequence triggers NACK");

  ReceiverQosObserver observer(
      ReceiverQosObserverConfig{TransportIds{1, 2, 3, 0x33333333, 5}, 200});
  RtpPacket quality_first;
  quality_first.sequence_number = 10;
  quality_first.payload.assign(100, 0);
  observer.OnRtpPacketReceived(quality_first, 1000000);
  RtpPacket quality_third = quality_first;
  quality_third.sequence_number = 12;
  observer.OnRtpPacketReceived(quality_third, 1100000);
  DownlinkQuality interval_quality = observer.BuildReport(1200000);
  ok &= Expect(interval_quality.fraction_lost_q8 > 0,
               "interval quality reports current loss");
  RtpPacket quality_second = quality_first;
  quality_second.sequence_number = 11;
  observer.OnRtpPacketReceived(quality_second, 1300000);
  RtpPacket quality_fourth = quality_first;
  quality_fourth.sequence_number = 13;
  observer.OnRtpPacketReceived(quality_fourth, 1400000);
  interval_quality = observer.BuildReport(1500000);
  ok &= Expect(interval_quality.fraction_lost_q8 == 0,
               "interval quality clears recovered loss");
  ok &= Expect(interval_quality.recv_bitrate_bps > 0,
               "interval quality reports receive bitrate");

  RetransmissionCache cache;
  RtpPacket cached_packet;
  cached_packet.sequence_number = 42;
  cached_packet.timestamp = 123456;
  cached_packet.ssrc = 0x33333333;
  cached_packet.transport_sequence_number = 10;
  cached_packet.payload_type = kH264PayloadType;
  cached_packet.marker = true;
  cached_packet.payload = {0x65, 1, 2};
  cache.Store(cached_packet, 1000000);
  auto retransmission = cache.Find(42, 99);
  ok &= Expect(retransmission.has_value(), "retransmission cache hit");
  ok &= Expect(retransmission->sequence_number == cached_packet.sequence_number,
               "retransmission keeps RTP sequence");
  ok &= Expect(retransmission->timestamp == cached_packet.timestamp,
               "retransmission keeps RTP timestamp");
  ok &= Expect(retransmission->transport_sequence_number == 99,
               "retransmission gets new transport sequence");

  RtcpSenderReport sr;
  sr.sender_ssrc = 0x44444444;
  sr.ntp_timestamp = 0x123456789abcdef0ull;
  sr.rtp_timestamp = 90000;
  sr.packet_count = 10;
  sr.octet_count = 1000;
  auto sr_bytes = SerializeRtcpSenderReport(sr);
  RtcpSenderReport parsed_sr;
  status = ParseRtcpSenderReport(sr_bytes.data(), sr_bytes.size(), &parsed_sr);
  ok &= Expect(status.code == StatusCode::kOk, "RTCP SR roundtrip parse");
  ok &= Expect(parsed_sr.ntp_timestamp == sr.ntp_timestamp,
               "RTCP SR keeps NTP timestamp");

  RtcpReceiverReport rr;
  rr.sender_ssrc = 0x44444444;
  rr.last_sender_report = 0x12345678;
  rr.delay_since_last_sender_report = 0x10000;
  auto rr_bytes = SerializeRtcpReceiverReport(rr);
  RtcpReceiverReport parsed_rr;
  status = ParseRtcpReceiverReport(rr_bytes.data(), rr_bytes.size(), &parsed_rr);
  ok &= Expect(status.code == StatusCode::kOk, "RTCP RR roundtrip parse");
  ok &= Expect(parsed_rr.last_sender_report == rr.last_sender_report,
               "RTCP RR keeps LSR");

  UplinkTransportFeedback twcc;
  twcc.ids.receiver_id = 0x55555555;
  twcc.ids.sender_ssrc = 0x44444444;
  twcc.feedback_seq = 3;
  twcc.reference_time_us = 64000;
  twcc.packets.push_back(PacketFeedback{10, 0, 64000, 100});
  twcc.packets.push_back(PacketFeedback{11, 0, -1, 100});
  twcc.packets.push_back(PacketFeedback{12, 0, 69000, 100});
  auto twcc_bytes = SerializeRtcpTransportFeedback(twcc);
  UplinkTransportFeedback parsed_twcc;
  status =
      ParseRtcpTransportFeedback(twcc_bytes.data(), twcc_bytes.size(),
                                 &parsed_twcc);
  ok &= Expect(status.code == StatusCode::kOk, "RTCP TWCC roundtrip parse");
  ok &= Expect(parsed_twcc.packets.size() == 3, "RTCP TWCC packet count");
  ok &= Expect(parsed_twcc.packets[1].receive_time_us < 0,
               "RTCP TWCC lost packet symbol");

  RtcpNack nack;
  nack.sender_ssrc = 0x55555555;
  nack.media_ssrc = 0x44444444;
  nack.lost_rtp_sequence_numbers = {12, 18};
  auto nack_bytes = SerializeRtcpNack(nack);
  RtcpNack parsed_nack;
  status = ParseRtcpNack(nack_bytes.data(), nack_bytes.size(), &parsed_nack);
  ok &= Expect(status.code == StatusCode::kOk, "RTCP NACK roundtrip parse");
  ok &= Expect(parsed_nack.lost_rtp_sequence_numbers.size() == 2,
               "RTCP NACK lost count");

  RtcpPli pli;
  pli.sender_ssrc = 0x55555555;
  pli.media_ssrc = 0x44444444;
  auto pli_bytes = SerializeRtcpPli(pli);
  RtcpPli parsed_pli;
  status = ParseRtcpPli(pli_bytes.data(), pli_bytes.size(), &parsed_pli);
  ok &= Expect(status.code == StatusCode::kOk, "RTCP PLI roundtrip parse");
  ok &= Expect(parsed_pli.media_ssrc == pli.media_ssrc, "RTCP PLI media SSRC");

  std::cout << (ok ? "selftest passed\n" : "selftest failed\n");
  return ok ? 0 : 1;
}
