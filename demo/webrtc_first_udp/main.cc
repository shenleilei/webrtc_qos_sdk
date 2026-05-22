#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "webrtc_qos/rate_cap.h"
#include "webrtc_qos/runtime_logging.h"
#include "webrtc_qos/runtime_metrics.h"
#include "webrtc_qos/server_qos_router.h"
#include "webrtc_qos/video_play_client.h"
#include "webrtc_qos/video_push_client.h"

namespace {

constexpr uint8_t kRetransmissionFlag = 0x01;
constexpr uint8_t kPaddingFlag = 0x02;
constexpr uint8_t kWireVersion = 1;

enum class WireKind : uint8_t {
  kRtp = 1,
  kRtcp = 2,
  kDownlinkQuality = 3,
  kSenderRateCap = 4,
};

struct WirePacket {
  WireKind kind = WireKind::kRtp;
  uint8_t flags = 0;
  int64_t time_us = 0;
  std::vector<uint8_t> payload;
};

struct Metrics {
  int pushed_frames = 0;
  int decoded_frames = 0;
  int sender_rtp = 0;
  int sender_rtcp = 0;
  int receiver_rtcp = 0;
  int downlink_dropped = 0;
  int retransmissions = 0;
  int sender_rate_caps = 0;
  int bad_ticks = 0;
  int bad_pushed_frames = 0;
  int recovery_ticks = 0;
  int recovery_pushed_frames = 0;
  std::set<uint32_t> decoded_track_ids;
  uint32_t min_bad_target_bps = UINT32_MAX;
  uint32_t max_recovery_target_bps = 0;
  uint32_t min_bad_fps = UINT32_MAX;
  uint32_t max_recovery_fps = 0;
  uint32_t final_target_bps = 0;
  uint32_t final_fps = 0;
};

struct CommonOptions {
  int frames = 36;
  std::string log_dir;
  std::string metrics_dir;
};

void PutU16(uint16_t value, std::vector<uint8_t>* out) {
  out->push_back(static_cast<uint8_t>(value & 0xff));
  out->push_back(static_cast<uint8_t>((value >> 8) & 0xff));
}

void PutU32(uint32_t value, std::vector<uint8_t>* out) {
  for (int i = 0; i < 4; ++i) {
    out->push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xff));
  }
}

void PutU64(uint64_t value, std::vector<uint8_t>* out) {
  for (int i = 0; i < 8; ++i) {
    out->push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xff));
  }
}

bool ReadU16(const std::vector<uint8_t>& in, size_t* offset, uint16_t* value) {
  if (*offset + 2 > in.size()) {
    return false;
  }
  *value = static_cast<uint16_t>(in[*offset]) |
           (static_cast<uint16_t>(in[*offset + 1]) << 8);
  *offset += 2;
  return true;
}

bool ReadU32(const std::vector<uint8_t>& in, size_t* offset, uint32_t* value) {
  if (*offset + 4 > in.size()) {
    return false;
  }
  *value = 0;
  for (int i = 0; i < 4; ++i) {
    *value |= static_cast<uint32_t>(in[*offset + i]) << (i * 8);
  }
  *offset += 4;
  return true;
}

bool ReadU64(const std::vector<uint8_t>& in, size_t* offset, uint64_t* value) {
  if (*offset + 8 > in.size()) {
    return false;
  }
  *value = 0;
  for (int i = 0; i < 8; ++i) {
    *value |= static_cast<uint64_t>(in[*offset + i]) << (i * 8);
  }
  *offset += 8;
  return true;
}

std::vector<uint8_t> EncodeWirePacket(const WirePacket& packet) {
  std::vector<uint8_t> out;
  out.push_back('W');
  out.push_back('Q');
  out.push_back('U');
  out.push_back('D');
  out.push_back(kWireVersion);
  out.push_back(static_cast<uint8_t>(packet.kind));
  out.push_back(packet.flags);
  out.push_back(0);
  PutU64(static_cast<uint64_t>(packet.time_us), &out);
  PutU32(static_cast<uint32_t>(packet.payload.size()), &out);
  out.insert(out.end(), packet.payload.begin(), packet.payload.end());
  return out;
}

bool DecodeWirePacket(const std::vector<uint8_t>& bytes, WirePacket* packet) {
  if (bytes.size() < 20 || bytes[0] != 'W' || bytes[1] != 'Q' ||
      bytes[2] != 'U' || bytes[3] != 'D' || bytes[4] != kWireVersion) {
    return false;
  }
  packet->kind = static_cast<WireKind>(bytes[5]);
  packet->flags = bytes[6];
  size_t offset = 8;
  uint64_t time_us = 0;
  uint32_t payload_size = 0;
  if (!ReadU64(bytes, &offset, &time_us) ||
      !ReadU32(bytes, &offset, &payload_size) ||
      offset + payload_size > bytes.size()) {
    return false;
  }
  packet->time_us = static_cast<int64_t>(time_us);
  packet->payload.assign(bytes.begin() + static_cast<ptrdiff_t>(offset),
                         bytes.begin() + static_cast<ptrdiff_t>(offset) +
                             payload_size);
  return true;
}

std::vector<uint8_t> EncodeDownlinkQuality(
    const webrtc_qos::DownlinkQuality& quality) {
  std::vector<uint8_t> out;
  PutU32(quality.ids.receiver_id, &out);
  PutU32(quality.report_seq, &out);
  PutU64(quality.report_time_us, &out);
  PutU16(quality.fraction_lost_q8, &out);
  PutU16(quality.video_drop_frames, &out);
  PutU32(quality.recv_bitrate_bps, &out);
  return out;
}

bool DecodeDownlinkQuality(const std::vector<uint8_t>& payload,
                           const webrtc_qos::TransportIds& ids,
                           webrtc_qos::DownlinkQuality* quality) {
  size_t offset = 0;
  uint32_t receiver_id = 0;
  uint32_t report_seq = 0;
  uint64_t report_time_us = 0;
  uint16_t fraction_lost_q8 = 0;
  uint16_t video_drop_frames = 0;
  uint32_t recv_bitrate_bps = 0;
  if (!ReadU32(payload, &offset, &receiver_id) ||
      !ReadU32(payload, &offset, &report_seq) ||
      !ReadU64(payload, &offset, &report_time_us) ||
      !ReadU16(payload, &offset, &fraction_lost_q8) ||
      !ReadU16(payload, &offset, &video_drop_frames) ||
      !ReadU32(payload, &offset, &recv_bitrate_bps)) {
    return false;
  }
  quality->ids = ids;
  quality->ids.receiver_id = receiver_id;
  quality->report_seq = report_seq;
  quality->report_time_us = report_time_us;
  quality->fraction_lost_q8 = fraction_lost_q8;
  quality->video_drop_frames = video_drop_frames;
  quality->recv_bitrate_bps = recv_bitrate_bps;
  return true;
}

std::vector<uint8_t> EncodeSenderRateCap(
    const webrtc_qos::SenderRateCap& cap) {
  std::vector<uint8_t> out;
  PutU32(cap.ids.receiver_id, &out);
  PutU32(cap.controller_seq, &out);
  PutU32(cap.cap_bps, &out);
  PutU16(cap.expire_ms, &out);
  PutU16(cap.reason_code, &out);
  PutU64(static_cast<uint64_t>(cap.receive_time_us), &out);
  return out;
}

bool DecodeSenderRateCap(const std::vector<uint8_t>& payload,
                         const webrtc_qos::TransportIds& ids,
                         webrtc_qos::SenderRateCap* cap) {
  size_t offset = 0;
  uint32_t receiver_id = 0;
  uint32_t controller_seq = 0;
  uint32_t cap_bps = 0;
  uint16_t expire_ms = 0;
  uint16_t reason_code = 0;
  uint64_t receive_time_us = 0;
  if (!ReadU32(payload, &offset, &receiver_id) ||
      !ReadU32(payload, &offset, &controller_seq) ||
      !ReadU32(payload, &offset, &cap_bps) ||
      !ReadU16(payload, &offset, &expire_ms) ||
      !ReadU16(payload, &offset, &reason_code) ||
      !ReadU64(payload, &offset, &receive_time_us)) {
    return false;
  }
  cap->ids = ids;
  cap->ids.receiver_id = receiver_id;
  cap->controller_seq = controller_seq;
  cap->cap_bps = cap_bps;
  cap->expire_ms = expire_ms;
  cap->reason_code = reason_code;
  cap->receive_time_us = static_cast<int64_t>(receive_time_us);
  return true;
}

class UdpEndpoint {
 public:
  UdpEndpoint() = default;
  ~UdpEndpoint() { Close(); }

  UdpEndpoint(const UdpEndpoint&) = delete;
  UdpEndpoint& operator=(const UdpEndpoint&) = delete;

  bool Bind(uint16_t port) {
    fd_ = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd_ < 0) {
      return false;
    }
    int reuse = 1;
    (void)setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);
    if (bind(fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
      return false;
    }
    socklen_t len = sizeof(local_addr_);
    if (getsockname(fd_, reinterpret_cast<sockaddr*>(&local_addr_), &len) !=
        0) {
      return false;
    }
    const int flags = fcntl(fd_, F_GETFL, 0);
    return flags >= 0 && fcntl(fd_, F_SETFL, flags | O_NONBLOCK) == 0;
  }

  void Close() {
    if (fd_ >= 0) {
      close(fd_);
      fd_ = -1;
    }
  }

  bool SendTo(const sockaddr_in& peer, const std::vector<uint8_t>& bytes) {
    const ssize_t sent = sendto(fd_, bytes.data(), bytes.size(), 0,
                                reinterpret_cast<const sockaddr*>(&peer),
                                sizeof(peer));
    return sent == static_cast<ssize_t>(bytes.size());
  }

  bool Recv(std::vector<uint8_t>* bytes, sockaddr_in* from) {
    bytes->assign(2048, 0);
    socklen_t from_len = sizeof(*from);
    const ssize_t received =
        recvfrom(fd_, bytes->data(), bytes->size(), 0,
                 reinterpret_cast<sockaddr*>(from), &from_len);
    if (received < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        return false;
      }
      return false;
    }
    bytes->resize(static_cast<size_t>(received));
    return true;
  }

  const sockaddr_in& local_addr() const { return local_addr_; }
  uint16_t port() const { return ntohs(local_addr_.sin_port); }

 private:
  int fd_ = -1;
  sockaddr_in local_addr_ {};
};

bool SameAddress(const sockaddr_in& lhs, const sockaddr_in& rhs) {
  return lhs.sin_family == rhs.sin_family &&
         lhs.sin_addr.s_addr == rhs.sin_addr.s_addr &&
         lhs.sin_port == rhs.sin_port;
}

bool ParseEndpoint(const std::string& spec, sockaddr_in* out) {
  std::string host = "127.0.0.1";
  std::string port_text = spec;
  const size_t colon = spec.rfind(':');
  if (colon != std::string::npos) {
    host = spec.substr(0, colon);
    port_text = spec.substr(colon + 1);
  }
  if (port_text.empty()) {
    return false;
  }
  char* end = nullptr;
  const long port = std::strtol(port_text.c_str(), &end, 10);
  if (end == nullptr || *end != '\0' || port <= 0 || port > 65535) {
    return false;
  }
  sockaddr_in addr {};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(static_cast<uint16_t>(port));
  if (inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
    return false;
  }
  *out = addr;
  return true;
}

std::string EndpointToString(const sockaddr_in& addr) {
  char host[INET_ADDRSTRLEN] = {};
  const char* printed =
      inet_ntop(AF_INET, &addr.sin_addr, host, sizeof(host));
  return std::string(printed == nullptr ? "0.0.0.0" : printed) + ":" +
         std::to_string(ntohs(addr.sin_port));
}

void AppendTrack(webrtc_qos::SessionConfig* session,
                 uint32_t track_id,
                 uint32_t sender_ssrc,
                 bool base_track,
                 uint32_t weight) {
  webrtc_qos::VideoTrackConfig track;
  track.ids = session->ids;
  track.ids.track_id = track_id;
  track.ids.sender_ssrc = sender_ssrc;
  track.base_track = base_track;
  track.weight = weight;
  session->video_tracks.push_back(track);
}

webrtc_qos::SessionConfig MakeBaseSession(const char* debug_name) {
  webrtc_qos::SessionConfig session;
  session.ids.session_id = 1;
  session.ids.stream_id = 1;
  session.ids.transport_id = 1;
  session.ids.receiver_id = 0x2222;
  session.ids.source_id = session.ids.stream_id;
  session.start_bitrate_bps = 1200000;
  session.min_bitrate_bps = 300000;
  session.max_bitrate_bps = 2500000;
  session.debug_name = debug_name;
  return session;
}

webrtc_qos::SessionConfig MakeSingleTrackSession(const char* debug_name) {
  webrtc_qos::SessionConfig session = MakeBaseSession(debug_name);
  AppendTrack(&session, 101, 0x12345678u, true, 100);
  session.ids.sender_ssrc = session.video_tracks.front().ids.sender_ssrc;
  return session;
}

webrtc_qos::SessionConfig MakeDualTrackSession(const char* debug_name) {
  webrtc_qos::SessionConfig session = MakeBaseSession(debug_name);
  AppendTrack(&session, 101, 0x12345678u, true, 70);
  AppendTrack(&session, 202, 0x13355779u, false, 30);
  session.ids.sender_ssrc = session.video_tracks.front().ids.sender_ssrc;
  return session;
}

void AppendStartCodeAndNalu(const uint8_t* nalu,
                            size_t nalu_size,
                            std::vector<uint8_t>* out) {
  out->push_back(0x00);
  out->push_back(0x00);
  out->push_back(0x00);
  out->push_back(0x01);
  out->insert(out->end(), nalu, nalu + nalu_size);
}

std::vector<uint8_t> MakeIdrAccessUnit(uint8_t frame_id) {
  const uint8_t sps[] = {0x67, 0x42, 0xc0, 0x15, 0x8c, 0x68, 0x14, 0x19,
                         0x79, 0xe0, 0x1e, 0x11, 0x08, 0xd4, 0x00, 0x04};
  const uint8_t pps[] = {0x68, 0xce, 0x3c, 0x80, 0x00, 0x2e};
  const uint8_t idr[] = {0x65, 0xb8, 0x00, 0x04, 0x08, 0x79,
                         0x31, 0x40, frame_id, 0x42, 0xae, 0x4d};
  std::vector<uint8_t> au;
  AppendStartCodeAndNalu(sps, sizeof(sps), &au);
  AppendStartCodeAndNalu(pps, sizeof(pps), &au);
  AppendStartCodeAndNalu(idr, sizeof(idr), &au);
  return au;
}

bool InBadWindow(int frame, int frames) {
  return frame >= frames / 4 && frame <= frames / 2;
}

bool InRecoveryWindow(int frame, int frames) {
  return frame > frames / 2;
}

int FpsInterval(uint32_t fps) {
  if (fps >= 25) {
    return 1;
  }
  if (fps >= 15) {
    return 2;
  }
  return fps >= 10 ? 3 : 6;
}

double TickRate(int count, int ticks) {
  return ticks <= 0 ? 0.0 : static_cast<double>(count) * 30.0 / ticks;
}

void RequireStatus(const webrtc_qos::Status& status, const char* operation) {
  if (status) {
    return;
  }
  std::cerr << operation << " failed: " << status.message << "\n";
  std::exit(2);
}

webrtc_qos::RuntimeLogConfig MakeLogConfig(const std::string& log_dir) {
  webrtc_qos::RuntimeLogConfig config;
  if (!log_dir.empty()) {
    config.file.enabled = true;
    config.file.directory = log_dir;
    config.file.basename = "webrtc_qos_udp";
    config.file.json_lines = true;
    config.file.also_stderr = false;
    config.file.max_file_bytes = 1024 * 1024;
    config.file.max_files = 4;
  }
  return config;
}

webrtc_qos::RuntimeMetricsConfig MakeMetricsConfig(
    const std::string& metrics_dir) {
  webrtc_qos::RuntimeMetricsConfig config;
  if (!metrics_dir.empty()) {
    config.file.enabled = true;
    config.file.directory = metrics_dir;
    config.file.basename = "webrtc_qos_udp_metrics";
    config.file.max_file_bytes = 1024 * 1024;
    config.file.max_files = 4;
    config.interval_ms = 100;
    config.include_track_snapshots = true;
  }
  return config;
}

bool ParseOptionalArgs(int argc,
                       char** argv,
                       int start_index,
                       CommonOptions* options) {
  for (int i = start_index; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--log-dir") {
      if (i + 1 >= argc) {
        std::cerr << "--log-dir requires a directory\n";
        return false;
      }
      options->log_dir = argv[++i];
      continue;
    }
    if (arg == "--metrics-dir") {
      if (i + 1 >= argc) {
        std::cerr << "--metrics-dir requires a directory\n";
        return false;
      }
      options->metrics_dir = argv[++i];
      continue;
    }
    char* end = nullptr;
    const long frames = std::strtol(arg.c_str(), &end, 10);
    if (end != nullptr && *end == '\0') {
      options->frames = static_cast<int>(frames);
      continue;
    }
    std::cerr << "unknown argument: " << arg << "\n";
    return false;
  }
  return true;
}

WireKind WireKindFromTransport(webrtc_qos::TransportPacketKind kind) {
  return kind == webrtc_qos::TransportPacketKind::kRtp ? WireKind::kRtp
                                                       : WireKind::kRtcp;
}

std::vector<uint8_t> EncodeTransportPacket(
    const webrtc_qos::TransportPacketView& packet) {
  WirePacket wire;
  wire.kind = WireKindFromTransport(packet.metadata.kind);
  wire.flags = packet.metadata.retransmission ? kRetransmissionFlag : 0;
  if (packet.metadata.padding) {
    wire.flags |= kPaddingFlag;
  }
  wire.time_us = packet.metadata.send_time_us;
  wire.payload.assign(packet.bytes, packet.bytes + packet.size);
  return EncodeWirePacket(wire);
}

bool SendDownlinkQuality(UdpEndpoint* endpoint,
                         const sockaddr_in& server_addr,
                         const webrtc_qos::DownlinkQuality& quality,
                         int64_t now_us) {
  WirePacket wire;
  wire.kind = WireKind::kDownlinkQuality;
  wire.time_us = now_us;
  wire.payload = EncodeDownlinkQuality(quality);
  return endpoint->SendTo(server_addr, EncodeWirePacket(wire));
}

bool SendSenderRateCap(UdpEndpoint* endpoint,
                       const sockaddr_in& sender_addr,
                       const webrtc_qos::SenderRateCap& cap,
                       int64_t now_us) {
  WirePacket wire;
  wire.kind = WireKind::kSenderRateCap;
  wire.time_us = now_us;
  wire.payload = EncodeSenderRateCap(cap);
  return endpoint->SendTo(sender_addr, EncodeWirePacket(wire));
}

bool CheckMetrics(const Metrics& metrics, size_t track_total) {
  const double playable_ratio =
      metrics.pushed_frames == 0
          ? 0.0
          : static_cast<double>(metrics.decoded_frames) /
                metrics.pushed_frames;
  const uint32_t max_bad_fps = track_total > 1 ? 15u : 10u;
  const double max_bad_send_rps = track_total > 1 ? 30.0 : 15.0;
  const double min_recovery_send_rps = track_total > 1 ? 50.0 : 25.0;
  return playable_ratio >= 0.85 && metrics.sender_rtp > 0 &&
         metrics.decoded_track_ids.size() == track_total &&
         metrics.sender_rtcp > 0 && metrics.receiver_rtcp > 0 &&
         metrics.sender_rate_caps > 0 && metrics.downlink_dropped > 0 &&
         metrics.retransmissions > 0 && metrics.min_bad_target_bps > 0 &&
         metrics.min_bad_target_bps <= 600000 &&
         metrics.min_bad_fps <= max_bad_fps &&
         TickRate(metrics.bad_pushed_frames, metrics.bad_ticks) <=
             max_bad_send_rps &&
         metrics.max_recovery_target_bps >= 1000000 &&
         metrics.max_recovery_fps >= 25 &&
         TickRate(metrics.recovery_pushed_frames, metrics.recovery_ticks) >=
             min_recovery_send_rps;
}

int RunUdpSender(uint16_t local_port,
                 const sockaddr_in& server_addr,
                 const CommonOptions& options) {
  UdpEndpoint udp;
  if (!udp.Bind(local_port)) {
    std::cerr << "failed to bind sender UDP port\n";
    return 2;
  }

  Metrics metrics;
  const webrtc_qos::SessionConfig session =
      MakeDualTrackSession("webrtc_first_udp_sender");
  webrtc_qos::VideoPushClientConfig push_config;
  push_config.session = session;
  push_config.logging = MakeLogConfig(options.log_dir);
  push_config.metrics = MakeMetricsConfig(options.metrics_dir);
  push_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtp) {
          ++metrics.sender_rtp;
        } else {
          ++metrics.sender_rtcp;
        }
        return udp.SendTo(server_addr, EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "sender UDP send failed");
      };

  std::unique_ptr<webrtc_qos::VideoPushClient> push =
      webrtc_qos::CreateVideoPushClient(push_config);
  if (!push) {
    std::cerr << "failed to create sender facade\n";
    return 3;
  }
  RequireStatus(push->Start(), "sender start");

  auto pump_feedback = [&](int64_t now_us) {
    bool progressed = false;
    std::vector<uint8_t> datagram;
    sockaddr_in from {};
    while (udp.Recv(&datagram, &from)) {
      WirePacket wire;
      if (!DecodeWirePacket(datagram, &wire)) {
        continue;
      }
      if (wire.kind == WireKind::kRtcp) {
        RequireStatus(push->OnTransportFeedback(wire.payload.data(),
                                                wire.payload.size(), now_us),
                      "sender RTCP feedback");
        progressed = true;
      } else if (wire.kind == WireKind::kSenderRateCap) {
        webrtc_qos::SenderRateCap cap;
        if (DecodeSenderRateCap(wire.payload, session.ids, &cap)) {
          ++metrics.sender_rate_caps;
          RequireStatus(push->OnSenderRateCap(cap), "sender rate cap");
          progressed = true;
        }
      }
    }
    return progressed;
  };

  for (int frame = 0; frame < options.frames; ++frame) {
    const int64_t now_us = 1000000 + static_cast<int64_t>(frame) * 33333;
    RequireStatus(push->Process(now_us), "sender process");
    for (int guard = 0; guard < 32 && pump_feedback(now_us); ++guard) {
    }

    const auto adaptation = push->GetEncoderAdaptation(now_us);
    const auto snapshot = push->GetQosSnapshot(now_us);
    metrics.final_target_bps = snapshot.sender_rates.final_target_bps;
    metrics.final_fps = adaptation.max_fps;
    for (size_t track_index = 0; track_index < session.video_tracks.size();
         ++track_index) {
      const auto& track = session.video_tracks[track_index];
      webrtc_qos::EncoderAdaptation track_adaptation;
      if (!push->GetTrackEncoderAdaptation(track.ids.track_id, now_us,
                                           &track_adaptation)) {
        continue;
      }
      if (frame % FpsInterval(track_adaptation.max_fps) != 0) {
        continue;
      }
      const std::vector<uint8_t> au = MakeIdrAccessUnit(
          static_cast<uint8_t>((frame + track_index * 67) & 0xff));
      webrtc_qos::AnnexBAccessUnitView view;
      view.bytes = au.data();
      view.size = au.size();
      view.capture_time_us = now_us;
      view.keyframe = true;
      view.ids = track.ids;
      RequireStatus(push->PushAnnexBAccessUnit(view), "sender push AU");
      ++metrics.pushed_frames;
      const int64_t post_push_time_us =
          now_us + 1000 + static_cast<int64_t>(track_index) * 1000;
      RequireStatus(push->Process(post_push_time_us), "sender process after AU");
      for (int guard = 0; guard < 32 && pump_feedback(post_push_time_us);
           ++guard) {
      }
    }
  }

  const int64_t final_time_us =
      1000000 + static_cast<int64_t>(options.frames) * 33333 + 1000000;
  RequireStatus(push->Process(final_time_us), "sender final process");
  for (int guard = 0; guard < 64 && pump_feedback(final_time_us); ++guard) {
  }

  std::cout << "udp_sender backend=webrtc_first_facade"
            << " transport=udp"
            << " peer_connection=false"
            << " tracks=" << session.video_tracks.size()
            << " local=" << EndpointToString(udp.local_addr())
            << " server=" << EndpointToString(server_addr)
            << " pushed=" << metrics.pushed_frames
            << " sender_rtp=" << metrics.sender_rtp
            << " sender_rtcp=" << metrics.sender_rtcp
            << " sender_rate_caps=" << metrics.sender_rate_caps
            << " final_target=" << metrics.final_target_bps
            << " final_fps=" << metrics.final_fps
            << "\n";
  return metrics.pushed_frames > 0 && metrics.sender_rtp > 0 ? 0 : 1;
}

int RunUdpServer(uint16_t local_port,
                 const sockaddr_in& sender_addr,
                 const sockaddr_in& receiver_addr,
                 const CommonOptions& options) {
  UdpEndpoint udp;
  if (!udp.Bind(local_port)) {
    std::cerr << "failed to bind server UDP port\n";
    return 2;
  }

  Metrics metrics;
  const webrtc_qos::SessionConfig session =
      MakeDualTrackSession("webrtc_first_udp_server");
  webrtc_qos::ServerQosRouterConfig server_config;
  server_config.session = session;
  server_config.logging = MakeLogConfig(options.log_dir);
  server_config.metrics = MakeMetricsConfig(options.metrics_dir);
  server_config.sender_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        return udp.SendTo(sender_addr, EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "server sender-output UDP send failed");
      };
  server_config.receiver_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        return udp.SendTo(receiver_addr, EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "server receiver-output UDP send failed");
      };

  std::unique_ptr<webrtc_qos::ServerQosRouter> server =
      webrtc_qos::CreateServerQosRouter(server_config);
  if (!server) {
    std::cerr << "failed to create server facade\n";
    return 3;
  }
  RequireStatus(server->Start(), "server start");

  for (int frame = 0; frame < options.frames; ++frame) {
    const int64_t now_us = 1000000 + static_cast<int64_t>(frame) * 33333;
    std::vector<uint8_t> datagram;
    sockaddr_in from {};
    while (udp.Recv(&datagram, &from)) {
      WirePacket wire;
      if (!DecodeWirePacket(datagram, &wire)) {
        continue;
      }
      if (SameAddress(from, sender_addr)) {
        if (wire.kind == WireKind::kRtp) {
          ++metrics.sender_rtp;
          RequireStatus(server->OnSenderRtp(wire.payload.data(),
                                            wire.payload.size(), now_us),
                        "server sender RTP");
        } else if (wire.kind == WireKind::kRtcp) {
          ++metrics.sender_rtcp;
          RequireStatus(server->OnSenderRtcp(wire.payload.data(),
                                             wire.payload.size(), now_us),
                        "server sender RTCP");
        }
      } else if (SameAddress(from, receiver_addr)) {
        if (wire.kind == WireKind::kRtcp) {
          ++metrics.receiver_rtcp;
          RequireStatus(server->OnReceiverRtcp(session.ids.receiver_id,
                                              wire.payload.data(),
                                              wire.payload.size(), now_us),
                        "server receiver RTCP");
        } else if (wire.kind == WireKind::kDownlinkQuality) {
          webrtc_qos::DownlinkQuality quality;
          if (DecodeDownlinkQuality(wire.payload, session.ids, &quality)) {
            RequireStatus(server->OnDownlinkQuality(quality),
                          "server downlink quality");
            const auto cap = server->CurrentSenderRateCap(now_us);
            if (!SendSenderRateCap(&udp, sender_addr, cap, now_us)) {
              std::cerr << "server sender cap UDP send failed\n";
              return 4;
            }
            ++metrics.sender_rate_caps;
          }
        }
      }
    }
  }

  const auto snapshot =
      server->GetQosSnapshot(1000000 +
                             static_cast<int64_t>(options.frames) * 33333);
  std::cout << "udp_server backend=webrtc_first_facade"
            << " transport=udp"
            << " peer_connection=false"
            << " tracks=" << session.video_tracks.size()
            << " local=" << EndpointToString(udp.local_addr())
            << " sender=" << EndpointToString(sender_addr)
            << " receiver=" << EndpointToString(receiver_addr)
            << " sender_rtp=" << metrics.sender_rtp
            << " sender_rtcp=" << metrics.sender_rtcp
            << " receiver_rtcp=" << metrics.receiver_rtcp
            << " sender_rate_caps=" << metrics.sender_rate_caps
            << " retransmission=" << snapshot.retransmission_count
            << "\n";
  return 0;
}

int RunUdpReceiver(uint16_t local_port,
                   const sockaddr_in& server_addr,
                   const CommonOptions& options) {
  UdpEndpoint udp;
  if (!udp.Bind(local_port)) {
    std::cerr << "failed to bind receiver UDP port\n";
    return 2;
  }

  Metrics metrics;
  const webrtc_qos::SessionConfig session =
      MakeDualTrackSession("webrtc_first_udp_receiver");
  webrtc_qos::VideoPlayClientConfig play_config;
  play_config.session = session;
  play_config.logging = MakeLogConfig(options.log_dir);
  play_config.metrics = MakeMetricsConfig(options.metrics_dir);
  play_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        ++metrics.receiver_rtcp;
        return udp.SendTo(server_addr, EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "receiver UDP send failed");
      };
  play_config.decoded_access_unit_output =
      [&](const webrtc_qos::AnnexBAccessUnitView& access_unit) {
        if (access_unit.bytes == nullptr || access_unit.size == 0) {
          return webrtc_qos::Status::Error(
              webrtc_qos::StatusCode::kInternalError, "empty decoded AU");
        }
        ++metrics.decoded_frames;
        metrics.decoded_track_ids.insert(access_unit.ids.track_id);
        return webrtc_qos::Status::Ok();
      };

  std::unique_ptr<webrtc_qos::VideoPlayClient> play =
      webrtc_qos::CreateVideoPlayClient(play_config);
  if (!play) {
    std::cerr << "failed to create receiver facade\n";
    return 3;
  }
  RequireStatus(play->Start(), "receiver start");

  for (int frame = 0; frame < options.frames; ++frame) {
    const int64_t now_us = 1000000 + static_cast<int64_t>(frame) * 33333;
    webrtc_qos::DownlinkQuality quality;
    quality.ids = session.ids;
    quality.report_seq = static_cast<uint32_t>(frame + 1);
    quality.report_time_us = static_cast<uint64_t>(now_us);
    if (InBadWindow(frame, options.frames)) {
      quality.fraction_lost_q8 = 192;
      quality.video_drop_frames = 1;
      quality.recv_bitrate_bps = session.min_bitrate_bps;
    }
    if (!SendDownlinkQuality(&udp, server_addr, quality, now_us)) {
      std::cerr << "receiver downlink quality UDP send failed\n";
      return 4;
    }

    std::vector<uint8_t> datagram;
    sockaddr_in from {};
    while (udp.Recv(&datagram, &from)) {
      WirePacket wire;
      if (!DecodeWirePacket(datagram, &wire)) {
        continue;
      }
      if (wire.kind == WireKind::kRtcp) {
        RequireStatus(play->OnRtcpPacket(wire.payload.data(),
                                         wire.payload.size(), now_us),
                      "receiver RTCP");
      } else if (wire.kind == WireKind::kRtp) {
        const bool retransmission = (wire.flags & kRetransmissionFlag) != 0;
        if (InBadWindow(frame, options.frames) && !retransmission) {
          ++metrics.downlink_dropped;
          continue;
        }
        if (retransmission) {
          ++metrics.retransmissions;
        }
        RequireStatus(play->OnRtpPacket(wire.payload.data(),
                                        wire.payload.size(), now_us),
                      "receiver RTP");
      }
    }
    RequireStatus(play->Process(now_us), "receiver process");
  }

  std::cout << "udp_receiver backend=webrtc_first_facade"
            << " transport=udp"
            << " peer_connection=false"
            << " tracks=" << session.video_tracks.size()
            << " local=" << EndpointToString(udp.local_addr())
            << " server=" << EndpointToString(server_addr)
            << " decoded=" << metrics.decoded_frames
            << " decoded_tracks=" << metrics.decoded_track_ids.size()
            << " receiver_rtcp=" << metrics.receiver_rtcp
            << " dropped=" << metrics.downlink_dropped
            << " retransmission=" << metrics.retransmissions
            << "\n";
  return 0;
}

int RunUdpSelftestProfile(const webrtc_qos::SessionConfig& session,
                          const char* label,
                          const CommonOptions& options) {
  UdpEndpoint sender_udp;
  UdpEndpoint server_udp;
  UdpEndpoint receiver_udp;
  if (!sender_udp.Bind(0) || !server_udp.Bind(0) || !receiver_udp.Bind(0)) {
    std::cerr << "failed to bind UDP loopback sockets\n";
    return 2;
  }

  Metrics metrics;

  webrtc_qos::VideoPushClientConfig push_config;
  push_config.session = session;
  push_config.logging = MakeLogConfig(options.log_dir);
  push_config.metrics = MakeMetricsConfig(options.metrics_dir);
  push_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtp) {
          ++metrics.sender_rtp;
        } else {
          ++metrics.sender_rtcp;
        }
        return sender_udp.SendTo(server_udp.local_addr(),
                                 EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "sender UDP send failed");
      };

  webrtc_qos::VideoPlayClientConfig play_config;
  play_config.session = session;
  play_config.logging = MakeLogConfig(options.log_dir);
  play_config.metrics = MakeMetricsConfig(options.metrics_dir);
  play_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        ++metrics.receiver_rtcp;
        return receiver_udp.SendTo(server_udp.local_addr(),
                                   EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "receiver UDP send failed");
      };
  play_config.decoded_access_unit_output =
      [&](const webrtc_qos::AnnexBAccessUnitView& access_unit) {
        if (access_unit.bytes == nullptr || access_unit.size == 0) {
          return webrtc_qos::Status::Error(
              webrtc_qos::StatusCode::kInternalError, "empty decoded AU");
        }
        ++metrics.decoded_frames;
        metrics.decoded_track_ids.insert(access_unit.ids.track_id);
        return webrtc_qos::Status::Ok();
      };

  webrtc_qos::ServerQosRouterConfig server_config;
  server_config.session = session;
  server_config.logging = MakeLogConfig(options.log_dir);
  server_config.metrics = MakeMetricsConfig(options.metrics_dir);
  server_config.sender_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        return server_udp.SendTo(sender_udp.local_addr(),
                                 EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "server sender-output UDP send failed");
      };
  server_config.receiver_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        return server_udp.SendTo(receiver_udp.local_addr(),
                                 EncodeTransportPacket(packet))
                   ? webrtc_qos::Status::Ok()
                   : webrtc_qos::Status::Error(
                         webrtc_qos::StatusCode::kInternalError,
                         "server receiver-output UDP send failed");
      };

  std::unique_ptr<webrtc_qos::VideoPushClient> push =
      webrtc_qos::CreateVideoPushClient(push_config);
  std::unique_ptr<webrtc_qos::VideoPlayClient> play =
      webrtc_qos::CreateVideoPlayClient(play_config);
  std::unique_ptr<webrtc_qos::ServerQosRouter> server =
      webrtc_qos::CreateServerQosRouter(server_config);
  if (!push || !play || !server) {
    std::cerr << "failed to create role facades\n";
    return 3;
  }
  RequireStatus(push->Start(), "push start");
  RequireStatus(play->Start(), "play start");
  RequireStatus(server->Start(), "server start");

  auto pump_sender = [&](int64_t now_us) {
    bool progressed = false;
    std::vector<uint8_t> datagram;
    sockaddr_in from {};
    while (sender_udp.Recv(&datagram, &from)) {
      WirePacket wire;
      if (!DecodeWirePacket(datagram, &wire)) {
        continue;
      }
      if (wire.kind == WireKind::kRtcp) {
        RequireStatus(push->OnTransportFeedback(wire.payload.data(),
                                                wire.payload.size(), now_us),
                      "push UDP RTCP feedback");
        progressed = true;
      } else if (wire.kind == WireKind::kSenderRateCap) {
        webrtc_qos::SenderRateCap cap;
        if (DecodeSenderRateCap(wire.payload, session.ids, &cap)) {
          ++metrics.sender_rate_caps;
          RequireStatus(push->OnSenderRateCap(cap), "push UDP sender cap");
          progressed = true;
        }
      }
    }
    return progressed;
  };

  auto pump_receiver = [&](int frame, int64_t now_us) {
    bool progressed = false;
    std::vector<uint8_t> datagram;
    sockaddr_in from {};
    while (receiver_udp.Recv(&datagram, &from)) {
      WirePacket wire;
      if (!DecodeWirePacket(datagram, &wire)) {
        continue;
      }
      if (wire.kind == WireKind::kRtcp) {
        RequireStatus(play->OnRtcpPacket(wire.payload.data(),
                                         wire.payload.size(), now_us),
                      "play UDP RTCP");
        progressed = true;
      } else if (wire.kind == WireKind::kRtp) {
        const bool retransmission = (wire.flags & kRetransmissionFlag) != 0;
        if (InBadWindow(frame, options.frames) && !retransmission) {
          ++metrics.downlink_dropped;
          progressed = true;
          continue;
        }
        if (retransmission) {
          ++metrics.retransmissions;
        }
        RequireStatus(play->OnRtpPacket(wire.payload.data(),
                                        wire.payload.size(), now_us),
                      "play UDP RTP");
        progressed = true;
      }
    }
    return progressed;
  };

  auto pump_server = [&](int64_t now_us) {
    bool progressed = false;
    std::vector<uint8_t> datagram;
    sockaddr_in from {};
    while (server_udp.Recv(&datagram, &from)) {
      WirePacket wire;
      if (!DecodeWirePacket(datagram, &wire)) {
        continue;
      }
      if (SameAddress(from, sender_udp.local_addr())) {
        if (wire.kind == WireKind::kRtp) {
          RequireStatus(server->OnSenderRtp(wire.payload.data(),
                                            wire.payload.size(), now_us),
                        "server UDP sender RTP");
          progressed = true;
        } else if (wire.kind == WireKind::kRtcp) {
          RequireStatus(server->OnSenderRtcp(wire.payload.data(),
                                             wire.payload.size(), now_us),
                        "server UDP sender RTCP");
          progressed = true;
        }
      } else if (SameAddress(from, receiver_udp.local_addr())) {
        if (wire.kind == WireKind::kRtcp) {
          RequireStatus(server->OnReceiverRtcp(session.ids.receiver_id,
                                              wire.payload.data(),
                                              wire.payload.size(), now_us),
                        "server UDP receiver RTCP");
          progressed = true;
        } else if (wire.kind == WireKind::kDownlinkQuality) {
          webrtc_qos::DownlinkQuality quality;
          if (DecodeDownlinkQuality(wire.payload, session.ids, &quality)) {
            RequireStatus(server->OnDownlinkQuality(quality),
                          "server UDP downlink quality");
            RequireStatus(push->OnSenderRateCap(
                              server->CurrentSenderRateCap(now_us)),
                          "local cap mirror");
            if (!SendSenderRateCap(&server_udp, sender_udp.local_addr(),
                                   server->CurrentSenderRateCap(now_us),
                                   now_us)) {
              std::cerr << "server UDP sender cap send failed\n";
              std::exit(4);
            }
            progressed = true;
          }
        }
      }
    }
    return progressed;
  };

  auto pump_all = [&](int frame, int64_t now_us) {
    int idle_polls = 0;
    for (int guard = 0; guard < 128; ++guard) {
      const bool server_progressed = pump_server(now_us);
      const bool sender_progressed = pump_sender(now_us);
      const bool receiver_progressed = pump_receiver(frame, now_us);
      const bool progressed =
          server_progressed || sender_progressed || receiver_progressed;
      if (!progressed) {
        if (++idle_polls <= 4) {
          const timespec wait_time {0, 1000000};
          nanosleep(&wait_time, nullptr);
          continue;
        }
        break;
      }
      idle_polls = 0;
    }
    RequireStatus(play->Process(now_us), "play UDP process");
  };

  for (int frame = 0; frame < options.frames; ++frame) {
    const int64_t now_us = 1000000 + static_cast<int64_t>(frame) * 33333;
    RequireStatus(push->Process(now_us), "push process");
    pump_all(frame, now_us);

    webrtc_qos::DownlinkQuality quality;
    quality.ids = session.ids;
    quality.report_seq = static_cast<uint32_t>(frame + 1);
    quality.report_time_us = static_cast<uint64_t>(now_us);
    if (InBadWindow(frame, options.frames)) {
      quality.fraction_lost_q8 = 192;
      quality.video_drop_frames = 1;
      quality.recv_bitrate_bps = session.min_bitrate_bps;
    }
    if (!SendDownlinkQuality(&receiver_udp, server_udp.local_addr(), quality,
                             now_us)) {
      std::cerr << "receiver UDP downlink quality send failed\n";
      return 4;
    }
    pump_all(frame, now_us);

    const auto adaptation = push->GetEncoderAdaptation(now_us);
    const auto snapshot = push->GetQosSnapshot(now_us);
    metrics.final_target_bps = snapshot.sender_rates.final_target_bps;
    metrics.final_fps = adaptation.max_fps;
    if (InBadWindow(frame, options.frames)) {
      ++metrics.bad_ticks;
      metrics.min_bad_target_bps =
          std::min(metrics.min_bad_target_bps,
                   snapshot.sender_rates.final_target_bps);
      metrics.min_bad_fps = std::min(metrics.min_bad_fps, adaptation.max_fps);
    }
    if (InRecoveryWindow(frame, options.frames)) {
      ++metrics.recovery_ticks;
      metrics.max_recovery_target_bps =
          std::max(metrics.max_recovery_target_bps,
                   snapshot.sender_rates.final_target_bps);
      metrics.max_recovery_fps =
          std::max(metrics.max_recovery_fps, adaptation.max_fps);
    }
    for (size_t track_index = 0; track_index < session.video_tracks.size();
         ++track_index) {
      const auto& track = session.video_tracks[track_index];
      webrtc_qos::EncoderAdaptation track_adaptation;
      if (!push->GetTrackEncoderAdaptation(track.ids.track_id, now_us,
                                           &track_adaptation)) {
        continue;
      }
      if (frame % FpsInterval(track_adaptation.max_fps) != 0) {
        continue;
      }
      if (InBadWindow(frame, options.frames)) {
        ++metrics.bad_pushed_frames;
      }
      if (InRecoveryWindow(frame, options.frames)) {
        ++metrics.recovery_pushed_frames;
      }
      const std::vector<uint8_t> au = MakeIdrAccessUnit(
          static_cast<uint8_t>((frame + track_index * 67) & 0xff));
      webrtc_qos::AnnexBAccessUnitView view;
      view.bytes = au.data();
      view.size = au.size();
      view.capture_time_us = now_us;
      view.keyframe = true;
      view.ids = track.ids;
      RequireStatus(push->PushAnnexBAccessUnit(view), "push UDP AU");
      ++metrics.pushed_frames;
      const int64_t post_push_time_us =
          now_us + 1000 + static_cast<int64_t>(track_index) * 1000;
      RequireStatus(push->Process(post_push_time_us), "push process after AU");
      pump_all(frame, post_push_time_us + 1000);
    }
  }

  const int64_t final_time_us =
      1000000 + static_cast<int64_t>(options.frames) * 33333 + 1000000;
  RequireStatus(push->OnSenderRateCap(server->CurrentSenderRateCap(final_time_us)),
                "final push UDP sender cap");
  RequireStatus(push->Process(final_time_us), "final push process");
  pump_all(options.frames, final_time_us);
  const auto server_snapshot = server->GetQosSnapshot(final_time_us);
  metrics.retransmissions =
      std::max<int>(metrics.retransmissions,
                    static_cast<int>(server_snapshot.retransmission_count));
  if (metrics.min_bad_target_bps == UINT32_MAX) {
    metrics.min_bad_target_bps = 0;
  }
  if (metrics.min_bad_fps == UINT32_MAX) {
    metrics.min_bad_fps = 0;
  }

  const double playable_ratio =
      metrics.pushed_frames == 0
          ? 0.0
          : static_cast<double>(metrics.decoded_frames) /
                metrics.pushed_frames;
  const bool pass = CheckMetrics(metrics, session.video_tracks.size());
  std::cout << "udp_selftest_" << label
            << " backend=webrtc_first_facade"
            << " transport=udp"
            << " peer_connection=false"
            << " tracks=" << session.video_tracks.size()
            << " sender_port=" << sender_udp.port()
            << " server_port=" << server_udp.port()
            << " receiver_port=" << receiver_udp.port()
            << " pushed=" << metrics.pushed_frames
            << " decoded=" << metrics.decoded_frames
            << " decoded_tracks=" << metrics.decoded_track_ids.size()
            << " playable_ratio=" << playable_ratio
            << " sender_rtp=" << metrics.sender_rtp
            << " sender_rtcp=" << metrics.sender_rtcp
            << " receiver_rtcp=" << metrics.receiver_rtcp
            << " dropped=" << metrics.downlink_dropped
            << " retransmission=" << metrics.retransmissions
            << " sender_rate_caps=" << metrics.sender_rate_caps
            << " bad_send_rps="
            << TickRate(metrics.bad_pushed_frames, metrics.bad_ticks)
            << " recovery_send_rps="
            << TickRate(metrics.recovery_pushed_frames,
                        metrics.recovery_ticks)
            << " min_bad_target=" << metrics.min_bad_target_bps
            << " max_recovery_target=" << metrics.max_recovery_target_bps
            << " min_bad_fps=" << metrics.min_bad_fps
            << " max_recovery_fps=" << metrics.max_recovery_fps
            << " final_target=" << metrics.final_target_bps
            << " final_fps=" << metrics.final_fps
            << " pass=" << (pass ? "true" : "false")
            << "\n";
  return pass ? 0 : 1;
}

int RunUdpSelftest(const CommonOptions& options) {
  const auto single_track_session =
      MakeSingleTrackSession("webrtc_first_udp_selftest_single_track");
  const auto dual_track_session =
      MakeDualTrackSession("webrtc_first_udp_selftest_dual_track");

  const int single_status =
      RunUdpSelftestProfile(single_track_session, "single_track", options);
  const int dual_status =
      RunUdpSelftestProfile(dual_track_session, "dual_track", options);

  const bool pass = single_status == 0 && dual_status == 0;
  std::cout << "udp_selftest backend=webrtc_first_facade"
            << " transport=udp"
            << " peer_connection=false"
            << " profiles=single_track,dual_track"
            << " pass=" << (pass ? "true" : "false")
            << "\n";
  return pass ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string mode = argc >= 2 ? argv[1] : "selftest";
  if (mode == "selftest") {
    CommonOptions options;
    options.frames = 36;
    if (!ParseOptionalArgs(argc, argv, 2, &options)) {
      return 2;
    }
    options.frames = std::max(12, options.frames);
    return RunUdpSelftest(options);
  }

  if (mode == "sender") {
    if (argc < 4) {
      std::cerr << "usage: " << argv[0]
                << " sender <local_port> <server_ip:port> [frames]"
                << " [--log-dir DIR] [--metrics-dir DIR]\n";
      return 2;
    }
    sockaddr_in server_addr {};
    if (!ParseEndpoint(argv[3], &server_addr)) {
      std::cerr << "invalid server endpoint: " << argv[3] << "\n";
      return 2;
    }
    CommonOptions options;
    options.frames = 90;
    if (!ParseOptionalArgs(argc, argv, 4, &options)) {
      return 2;
    }
    options.frames = std::max(1, options.frames);
    return RunUdpSender(static_cast<uint16_t>(std::atoi(argv[2])),
                        server_addr, options);
  }

  if (mode == "server") {
    if (argc < 5) {
      std::cerr << "usage: " << argv[0]
                << " server <local_port> <sender_ip:port>"
                << " <receiver_ip:port> [frames] [--log-dir DIR]"
                << " [--metrics-dir DIR]\n";
      return 2;
    }
    sockaddr_in sender_addr {};
    sockaddr_in receiver_addr {};
    if (!ParseEndpoint(argv[3], &sender_addr)) {
      std::cerr << "invalid sender endpoint: " << argv[3] << "\n";
      return 2;
    }
    if (!ParseEndpoint(argv[4], &receiver_addr)) {
      std::cerr << "invalid receiver endpoint: " << argv[4] << "\n";
      return 2;
    }
    CommonOptions options;
    options.frames = 90;
    if (!ParseOptionalArgs(argc, argv, 5, &options)) {
      return 2;
    }
    options.frames = std::max(1, options.frames);
    return RunUdpServer(static_cast<uint16_t>(std::atoi(argv[2])),
                        sender_addr, receiver_addr, options);
  }

  if (mode == "receiver") {
    if (argc < 4) {
      std::cerr << "usage: " << argv[0]
                << " receiver <local_port> <server_ip:port> [frames]"
                << " [--log-dir DIR] [--metrics-dir DIR]\n";
      return 2;
    }
    sockaddr_in server_addr {};
    if (!ParseEndpoint(argv[3], &server_addr)) {
      std::cerr << "invalid server endpoint: " << argv[3] << "\n";
      return 2;
    }
    CommonOptions options;
    options.frames = 90;
    if (!ParseOptionalArgs(argc, argv, 4, &options)) {
      return 2;
    }
    options.frames = std::max(1, options.frames);
    return RunUdpReceiver(static_cast<uint16_t>(std::atoi(argv[2])),
                          server_addr, options);
  }

  std::cerr << "usage:\n"
            << "  " << argv[0] << " selftest [frames] [--log-dir DIR]"
            << " [--metrics-dir DIR]\n"
            << "  " << argv[0]
            << " sender <local_port> <server_ip:port> [frames]"
            << " [--log-dir DIR] [--metrics-dir DIR]\n"
            << "  " << argv[0]
            << " server <local_port> <sender_ip:port> <receiver_ip:port>"
            << " [frames] [--log-dir DIR] [--metrics-dir DIR]\n"
            << "  " << argv[0]
            << " receiver <local_port> <server_ip:port> [frames]"
            << " [--log-dir DIR] [--metrics-dir DIR]\n";
  return 2;
}
