#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}"
BUILD_DIR="${BUILD_DIR:-/tmp/webrtc_qos_phase5_error_contract_build.$$}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/tmp/webrtc_qos_phase5_error_contract_install.$$}"
WORK_DIR="${WORK_DIR:-/tmp/webrtc_qos_phase5_error_contract_fixture.$$}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_phase5_error_contract_logs.$$}"
ALERTS_DIR="${ALERTS_DIR:-/tmp/webrtc_qos_phase5_error_contract_alerts.$$}"

cleanup() {
  if [[ "${KEEP_WORK_DIR:-0}" != "1" ]]; then
    rm -rf "${BUILD_DIR}" "${INSTALL_PREFIX}" "${WORK_DIR}" \
      "${LOG_DIR}" "${ALERTS_DIR}"
  fi
}
trap cleanup EXIT

fail() {
  echo "phase5 error contract verification failed: $*" >&2
  exit 1
}

rm -rf "${BUILD_DIR}" "${INSTALL_PREFIX}" "${WORK_DIR}" \
  "${LOG_DIR}" "${ALERTS_DIR}"
mkdir -p "${WORK_DIR}" "${LOG_DIR}" "${ALERTS_DIR}"

cmake -S "${SDK_ROOT}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DWEBRTC_QOS_ENABLE_WEBRTC_FACADE=ON \
  -DWEBRTC_QOS_WEBRTC_MODULE_PREFIX="${PREFIX}" >/dev/null
cmake --build "${BUILD_DIR}" -j2 >/dev/null
cmake --install "${BUILD_DIR}" --prefix "${INSTALL_PREFIX}" >/dev/null

cat > "${WORK_DIR}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(phase5_error_contract_fixture LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(WebRtcQosSdk REQUIRED CONFIG)

add_executable(phase5_error_contract_fixture main.cc)
target_link_libraries(phase5_error_contract_fixture PRIVATE
  WebRtcQosSdk::role_push
  WebRtcQosSdk::role_play
  WebRtcQosSdk::role_server)
EOF

cat > "${WORK_DIR}/main.cc" <<'EOF'
#include <cstdint>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include "webrtc_qos/runtime_alerts.h"
#include "webrtc_qos/runtime_logging.h"
#include "webrtc_qos/runtime_metrics.h"
#include "webrtc_qos/server_qos_router.h"
#include "webrtc_qos/session_config.h"
#include "webrtc_qos/status.h"
#include "webrtc_qos/transport_io.h"
#include "webrtc_qos/video_play_client.h"
#include "webrtc_qos/video_push_client.h"

namespace {

const char* StatusCodeName(webrtc_qos::StatusCode code) {
  switch (code) {
    case webrtc_qos::StatusCode::kOk:
      return "ok";
    case webrtc_qos::StatusCode::kInvalidArgument:
      return "invalid_argument";
    case webrtc_qos::StatusCode::kUnsupported:
      return "unsupported";
    case webrtc_qos::StatusCode::kMalformedPacket:
      return "malformed_packet";
    case webrtc_qos::StatusCode::kQueueFull:
      return "queue_full";
    case webrtc_qos::StatusCode::kInternalError:
      return "internal_error";
  }
  return "unknown";
}

int Fail(const std::string& message) {
  std::cerr << message << "\n";
  return 1;
}

bool RequireCode(const webrtc_qos::Status& status,
                 webrtc_qos::StatusCode expected,
                 const char* operation) {
  if (status.code == expected) {
    return true;
  }
  std::cerr << operation << " expected " << StatusCodeName(expected) << " got "
            << StatusCodeName(status.code) << " reason=" << status.message
            << "\n";
  return false;
}

bool RequireOk(const webrtc_qos::Status& status, const char* operation) {
  if (status) {
    return true;
  }
  std::cerr << operation << " failed code=" << StatusCodeName(status.code)
            << " reason=" << status.message << "\n";
  return false;
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
  std::vector<uint8_t> out;
  AppendStartCodeAndNalu(sps, sizeof(sps), &out);
  AppendStartCodeAndNalu(pps, sizeof(pps), &out);
  AppendStartCodeAndNalu(idr, sizeof(idr), &out);
  return out;
}

webrtc_qos::SessionConfig MakeSession() {
  webrtc_qos::SessionConfig session;
  session.ids.session_id = 5001;
  session.ids.stream_id = 5002;
  session.ids.transport_id = 5003;
  session.ids.source_id = session.ids.stream_id;
  session.ids.track_id = 1;
  session.ids.sender_ssrc = 0x51020304u;
  session.ids.receiver_id = 0x5005u;
  session.start_bitrate_bps = 1200000;
  session.min_bitrate_bps = 300000;
  session.max_bitrate_bps = 2500000;
  session.debug_name = "phase5_error_contract_fixture";
  return session;
}

webrtc_qos::RuntimeLogConfig MakeLogs(const std::string& dir) {
  webrtc_qos::RuntimeLogConfig config;
  config.file.enabled = true;
  config.file.directory = dir;
  config.file.basename = "webrtc_qos_error_contract_logs";
  config.file.max_file_bytes = 1024 * 1024;
  config.file.max_files = 16;
  config.file.json_lines = true;
  return config;
}

webrtc_qos::RuntimeAlertConfig MakeAlerts(const std::string& dir) {
  webrtc_qos::RuntimeAlertConfig config;
  config.file.enabled = true;
  config.file.directory = dir;
  config.file.basename = "webrtc_qos_error_contract_alerts";
  config.file.max_file_bytes = 1024 * 1024;
  config.file.max_files = 16;
  config.suppress_repeated_alerts_ms = 0;
  return config;
}

webrtc_qos::RuntimeMetricsConfig MakeMetrics(const std::string& dir) {
  webrtc_qos::RuntimeMetricsConfig config;
  config.file.enabled = true;
  config.file.directory = dir;
  config.file.basename = "webrtc_qos_error_contract_metrics";
  config.file.max_file_bytes = 1024 * 1024;
  config.file.max_files = 16;
  return config;
}

webrtc_qos::TransportOutput OkTransport() {
  return [](const webrtc_qos::TransportPacketView&) {
    return webrtc_qos::Status::Ok();
  };
}

webrtc_qos::TransportOutput FailingTransport() {
  return [](const webrtc_qos::TransportPacketView&) {
    return webrtc_qos::Status::Error(
        webrtc_qos::StatusCode::kInternalError,
        "fixture transport output failure");
  };
}

webrtc_qos::AnnexBAccessUnitCallback OkDecode() {
  return [](const webrtc_qos::AnnexBAccessUnitView&) {
    return webrtc_qos::Status::Ok();
  };
}

webrtc_qos::AnnexBAccessUnitCallback FailingDecode() {
  return [](const webrtc_qos::AnnexBAccessUnitView&) {
    return webrtc_qos::Status::Error(
        webrtc_qos::StatusCode::kInternalError,
        "fixture decode output failure");
  };
}

webrtc_qos::AnnexBAccessUnitView MakeView(
    const std::vector<uint8_t>& au,
    const webrtc_qos::SessionConfig& session,
    int64_t capture_time_us) {
  webrtc_qos::AnnexBAccessUnitView view;
  view.bytes = au.data();
  view.size = au.size();
  view.capture_time_us = capture_time_us;
  view.keyframe = true;
  view.ids = session.ids;
  return view;
}

bool ProduceRtpPackets(const webrtc_qos::SessionConfig& session,
                       const std::vector<uint8_t>& au,
                       std::vector<std::vector<uint8_t>>* rtp_packets) {
  webrtc_qos::VideoPushClientConfig config;
  config.session = session;
  config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtp &&
            !packet.metadata.padding) {
          rtp_packets->emplace_back(packet.bytes, packet.bytes + packet.size);
        }
        return webrtc_qos::Status::Ok();
      };
  std::unique_ptr<webrtc_qos::VideoPushClient> producer =
      webrtc_qos::CreateVideoPushClient(config);
  if (!producer || !RequireOk(producer->Start(), "producer start")) {
    return false;
  }
  if (!RequireOk(producer->PushAnnexBAccessUnit(
                     MakeView(au, session, 3000000)),
                 "producer push AU")) {
    return false;
  }
  for (int i = 0; i < 64 && rtp_packets->empty(); ++i) {
    const webrtc_qos::Status status =
        producer->Process(3000000 + static_cast<int64_t>(i) * 10000);
    if (!RequireOk(status, "producer process")) {
      return false;
    }
  }
  if (!RequireOk(producer->Stop(), "producer stop")) {
    return false;
  }
  return !rtp_packets->empty();
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    return Fail("usage: phase5_error_contract_fixture <log_dir> <alerts_dir>");
  }

  const std::string log_dir = argv[1];
  const std::string alerts_dir = argv[2];
  const std::string unwritable_runtime_path = "/dev/null/phase5-runtime-output";
  const webrtc_qos::SessionConfig session = MakeSession();
  const std::vector<uint8_t> au = MakeIdrAccessUnit(42);
  const uint8_t bad_rtp[] = {0x01, 0x02, 0x03};

  {
    webrtc_qos::VideoPushClientConfig config;
    config.session = session;
    config.logging = MakeLogs(unwritable_runtime_path);
    config.transport_output = OkTransport();
    std::unique_ptr<webrtc_qos::VideoPushClient> push =
        webrtc_qos::CreateVideoPushClient(config);
    if (!push ||
        !RequireCode(push->Start(),
                     webrtc_qos::StatusCode::kInternalError,
                     "push start with unwritable log dir")) {
      return 1;
    }
  }

  {
    webrtc_qos::VideoPlayClientConfig config;
    config.session = session;
    config.metrics = MakeMetrics(unwritable_runtime_path);
    config.transport_output = OkTransport();
    config.decoded_access_unit_output = OkDecode();
    std::unique_ptr<webrtc_qos::VideoPlayClient> play =
        webrtc_qos::CreateVideoPlayClient(config);
    if (!play ||
        !RequireCode(play->Start(),
                     webrtc_qos::StatusCode::kInternalError,
                     "play start with unwritable metrics dir")) {
      return 1;
    }
  }

  {
    webrtc_qos::ServerQosRouterConfig config;
    config.session = session;
    config.alerts = MakeAlerts(unwritable_runtime_path);
    config.sender_output = OkTransport();
    config.receiver_output = OkTransport();
    std::unique_ptr<webrtc_qos::ServerQosRouter> server =
        webrtc_qos::CreateServerQosRouter(config);
    if (!server ||
        !RequireCode(server->Start(),
                     webrtc_qos::StatusCode::kInternalError,
                     "server start with unwritable alerts dir")) {
      return 1;
    }
  }

  {
    webrtc_qos::VideoPushClientConfig config;
    config.session = session;
    config.logging = MakeLogs(log_dir);
    std::unique_ptr<webrtc_qos::VideoPushClient> push =
        webrtc_qos::CreateVideoPushClient(config);
    if (!push ||
        !RequireCode(push->Start(),
                     webrtc_qos::StatusCode::kInvalidArgument,
                     "push start without transport_output")) {
      return 1;
    }
  }

  {
    webrtc_qos::VideoPlayClientConfig config;
    config.session = session;
    config.logging = MakeLogs(log_dir);
    config.transport_output = OkTransport();
    std::unique_ptr<webrtc_qos::VideoPlayClient> play =
        webrtc_qos::CreateVideoPlayClient(config);
    if (!play ||
        !RequireCode(play->Start(),
                     webrtc_qos::StatusCode::kInvalidArgument,
                     "play start without decoded_access_unit_output")) {
      return 1;
    }
  }

  {
    webrtc_qos::VideoPlayClientConfig config;
    config.session = session;
    config.logging = MakeLogs(log_dir);
    config.decoded_access_unit_output = OkDecode();
    std::unique_ptr<webrtc_qos::VideoPlayClient> play =
        webrtc_qos::CreateVideoPlayClient(config);
    if (!play ||
        !RequireCode(play->Start(),
                     webrtc_qos::StatusCode::kInvalidArgument,
                     "play start without transport_output")) {
      return 1;
    }
  }

  {
    webrtc_qos::ServerQosRouterConfig config;
    config.session = session;
    config.logging = MakeLogs(log_dir);
    config.sender_output = OkTransport();
    std::unique_ptr<webrtc_qos::ServerQosRouter> server =
        webrtc_qos::CreateServerQosRouter(config);
    if (!server ||
        !RequireCode(server->Start(),
                     webrtc_qos::StatusCode::kInvalidArgument,
                     "server start without receiver_output")) {
      return 1;
    }
  }

  {
    webrtc_qos::VideoPushClientConfig config;
    config.session = session;
    config.logging = MakeLogs(log_dir);
    config.transport_output = OkTransport();
    std::unique_ptr<webrtc_qos::VideoPushClient> push =
        webrtc_qos::CreateVideoPushClient(config);
    if (!push ||
        !RequireCode(push->Process(1000000),
                     webrtc_qos::StatusCode::kUnsupported,
                     "push process before start")) {
      return 1;
    }
  }

  {
    webrtc_qos::VideoPlayClientConfig config;
    config.session = session;
    config.logging = MakeLogs(log_dir);
    config.transport_output = OkTransport();
    config.decoded_access_unit_output = OkDecode();
    std::unique_ptr<webrtc_qos::VideoPlayClient> play =
        webrtc_qos::CreateVideoPlayClient(config);
    if (!play ||
        !RequireCode(play->Process(1000000),
                     webrtc_qos::StatusCode::kUnsupported,
                     "play process before start")) {
      return 1;
    }
  }

  {
    webrtc_qos::ServerQosRouterConfig config;
    config.session = session;
    config.logging = MakeLogs(log_dir);
    config.sender_output = OkTransport();
    config.receiver_output = OkTransport();
    std::unique_ptr<webrtc_qos::ServerQosRouter> server =
        webrtc_qos::CreateServerQosRouter(config);
    if (!server ||
        !RequireCode(server->OnSenderRtp(bad_rtp, sizeof(bad_rtp), 1000000),
                     webrtc_qos::StatusCode::kUnsupported,
                     "server sender RTP before start")) {
      return 1;
    }
  }

  {
    webrtc_qos::VideoPushClientConfig config;
    config.session = session;
    config.logging = MakeLogs(log_dir);
    config.alerts = MakeAlerts(alerts_dir);
    config.transport_output = OkTransport();
    std::unique_ptr<webrtc_qos::VideoPushClient> push =
        webrtc_qos::CreateVideoPushClient(config);
    if (!push || !RequireOk(push->Start(), "malformed H264 push start")) {
      return 1;
    }
    const std::vector<uint8_t> malformed_au = {0x00, 0x00, 0x00, 0x01};
    webrtc_qos::AnnexBAccessUnitView view =
        MakeView(malformed_au, session, 2000000);
    if (!RequireCode(push->PushAnnexBAccessUnit(view),
                     webrtc_qos::StatusCode::kMalformedPacket,
                     "push malformed H264 AU")) {
      return 1;
    }
    if (!RequireOk(push->Stop(), "malformed H264 push stop")) {
      return 1;
    }
  }

  {
    webrtc_qos::VideoPlayClientConfig config;
    config.session = session;
    config.logging = MakeLogs(log_dir);
    config.alerts = MakeAlerts(alerts_dir);
    config.transport_output = OkTransport();
    config.decoded_access_unit_output = OkDecode();
    std::unique_ptr<webrtc_qos::VideoPlayClient> play =
        webrtc_qos::CreateVideoPlayClient(config);
    if (!play || !RequireOk(play->Start(), "malformed RTP play start")) {
      return 1;
    }
    if (!RequireCode(play->OnRtpPacket(bad_rtp, sizeof(bad_rtp), 2100000),
                     webrtc_qos::StatusCode::kMalformedPacket,
                     "play malformed RTP")) {
      return 1;
    }
    if (!RequireOk(play->Stop(), "malformed RTP play stop")) {
      return 1;
    }
  }

  {
    webrtc_qos::ServerQosRouterConfig config;
    config.session = session;
    config.logging = MakeLogs(log_dir);
    config.alerts = MakeAlerts(alerts_dir);
    config.sender_output = OkTransport();
    config.receiver_output = OkTransport();
    std::unique_ptr<webrtc_qos::ServerQosRouter> server =
        webrtc_qos::CreateServerQosRouter(config);
    if (!server || !RequireOk(server->Start(), "malformed RTP server start")) {
      return 1;
    }
    if (!RequireCode(server->OnSenderRtp(bad_rtp, sizeof(bad_rtp), 2200000),
                     webrtc_qos::StatusCode::kMalformedPacket,
                     "server malformed RTP")) {
      return 1;
    }
    if (!RequireOk(server->Stop(), "malformed RTP server stop")) {
      return 1;
    }
  }

  {
    webrtc_qos::VideoPushClientConfig config;
    config.session = session;
    config.logging = MakeLogs(log_dir);
    config.alerts = MakeAlerts(alerts_dir);
    config.transport_output = FailingTransport();
    std::unique_ptr<webrtc_qos::VideoPushClient> push =
        webrtc_qos::CreateVideoPushClient(config);
    if (!push || !RequireOk(push->Start(), "failing transport push start")) {
      return 1;
    }
    if (!RequireOk(push->PushAnnexBAccessUnit(MakeView(au, session, 2300000)),
                   "failing transport push AU")) {
      return 1;
    }
    bool failed = false;
    for (int i = 0; i < 64; ++i) {
      const webrtc_qos::Status status =
          push->Process(2300000 + static_cast<int64_t>(i) * 10000);
      if (!status) {
        if (!RequireCode(status, webrtc_qos::StatusCode::kInternalError,
                         "push transport output failure")) {
          return 1;
        }
        failed = true;
        break;
      }
    }
    if (!RequireOk(push->Stop(), "failing transport push stop")) {
      return 1;
    }
    if (!failed) {
      return Fail("push transport output failure did not trigger");
    }
  }

  std::vector<std::vector<uint8_t>> rtp_packets;
  if (!ProduceRtpPackets(session, au, &rtp_packets)) {
    return Fail("producer emitted no RTP packets");
  }

  {
    webrtc_qos::ServerQosRouterConfig config;
    config.session = session;
    config.logging = MakeLogs(log_dir);
    config.alerts = MakeAlerts(alerts_dir);
    config.sender_output = OkTransport();
    config.receiver_output = FailingTransport();
    std::unique_ptr<webrtc_qos::ServerQosRouter> server =
        webrtc_qos::CreateServerQosRouter(config);
    if (!server || !RequireOk(server->Start(), "receiver failure server start")) {
      return 1;
    }
    const webrtc_qos::Status status =
        server->OnSenderRtp(rtp_packets.front().data(),
                            rtp_packets.front().size(), 3100000);
    if (!RequireCode(status, webrtc_qos::StatusCode::kInternalError,
                     "server receiver output failure")) {
      return 1;
    }
    if (!RequireOk(server->Stop(), "receiver failure server stop")) {
      return 1;
    }
  }

  {
    webrtc_qos::VideoPlayClientConfig config;
    config.session = session;
    config.logging = MakeLogs(log_dir);
    config.alerts = MakeAlerts(alerts_dir);
    config.transport_output = OkTransport();
    config.decoded_access_unit_output = FailingDecode();
    std::unique_ptr<webrtc_qos::VideoPlayClient> play =
        webrtc_qos::CreateVideoPlayClient(config);
    if (!play || !RequireOk(play->Start(), "decode failure play start")) {
      return 1;
    }
    bool failed = false;
    for (const auto& packet : rtp_packets) {
      const webrtc_qos::Status status =
          play->OnRtpPacket(packet.data(), packet.size(), 3200000);
      if (!status) {
        if (!RequireCode(status, webrtc_qos::StatusCode::kInternalError,
                         "play decode output failure")) {
          return 1;
        }
        failed = true;
        break;
      }
    }
    if (!RequireOk(play->Stop(), "decode failure play stop")) {
      return 1;
    }
    if (!failed) {
      return Fail("play decode output failure did not trigger");
    }
  }

  std::cout << "phase5_error_contract_fixture pass\n";
  return 0;
}
EOF

cmake -S "${WORK_DIR}" -B "${WORK_DIR}/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="${INSTALL_PREFIX}" >/dev/null
cmake --build "${WORK_DIR}/build" -j2 >/dev/null

if ! fixture_output="$("${WORK_DIR}/build/phase5_error_contract_fixture" \
  "${LOG_DIR}" "${ALERTS_DIR}" 2>&1)"; then
  echo "${fixture_output}" >&2
  fail "error contract fixture exited with non-zero status"
fi
printf '%s\n' "${fixture_output}"
grep -q "phase5_error_contract_fixture pass" <<<"${fixture_output}" ||
  fail "error contract fixture did not report pass"

shopt -s nullglob
log_files=("${LOG_DIR}"/webrtc_qos_error_contract_logs.*.log)
alert_files=("${ALERTS_DIR}"/webrtc_qos_error_contract_alerts.*.jsonl)
(( ${#log_files[@]} > 0 )) || fail "missing error contract log files"
(( ${#alert_files[@]} > 0 )) || fail "missing error contract alert files"

python3 - "${LOG_DIR}" "${ALERTS_DIR}" <<'PY'
import json
import pathlib
import sys

log_dir = pathlib.Path(sys.argv[1])
alerts_dir = pathlib.Path(sys.argv[2])

identity_fields = {
    "ts_us",
    "role",
    "session_id",
    "stream_id",
    "transport_id",
    "source_id",
    "track_id",
    "sender_ssrc",
    "receiver_id",
}
payload_like_fields = {"payload", "annexb_bytes", "rtp_bytes", "rtcp_bytes"}

def read_jsonl(paths):
    records = []
    for path in paths:
        with path.open("r", encoding="utf-8") as handle:
            for line_no, line in enumerate(handle, 1):
                if not line.strip():
                    continue
                obj = json.loads(line)
                missing = identity_fields - obj.keys()
                if missing:
                    raise SystemExit(
                        f"{path}:{line_no}: missing fields {sorted(missing)}"
                    )
                leaked = payload_like_fields & obj.keys()
                if leaked:
                    raise SystemExit(
                        f"{path}:{line_no}: payload-like fields {sorted(leaked)}"
                    )
                records.append(obj)
    return records

logs = read_jsonl(sorted(log_dir.glob("webrtc_qos_error_contract_logs.*.log")))
alerts = read_jsonl(
    sorted(alerts_dir.glob("webrtc_qos_error_contract_alerts.*.jsonl"))
)
if not logs:
    raise SystemExit("no log records found")
if not alerts:
    raise SystemExit("no alert records found")

expected_logs = [
    ("push", "start_failed", "invalid_argument"),
    ("play", "start_failed", "invalid_argument"),
    ("server", "start_failed", "invalid_argument"),
    ("push", "process_before_start", "unsupported"),
    ("play", "process_before_start", "unsupported"),
    ("server", "sender_rtp_before_start", "unsupported"),
    ("push", "packetize_failed", "malformed_packet"),
    ("play", "malformed_rtp", "malformed_packet"),
    ("server", "malformed_rtp", "malformed_packet"),
    ("push", "transport_output_failed", "internal_error"),
    ("server", "receiver_output_failed", "internal_error"),
    ("play", "decode_au_output_failed", "internal_error"),
]

for role, event, status_code in expected_logs:
    if not any(
        record.get("role") == role
        and record.get("event") == event
        and record.get("status_code") == status_code
        for record in logs
    ):
        raise SystemExit(
            f"missing log contract role={role} event={event} status={status_code}"
        )

expected_alerts = [
    ("push", "malformed_h264", "malformed_packet"),
    ("play", "malformed_rtp", "malformed_packet"),
    ("server", "malformed_rtp", "malformed_packet"),
    ("push", "transport_output_failed", "internal_error"),
    ("server", "receiver_output_failed", "internal_error"),
    ("play", "decode_output_failed", "internal_error"),
]

for role, rule, status_code in expected_alerts:
    if not any(
        record.get("role") == role
        and record.get("rule") == rule
        and record.get("status_code") == status_code
        and record.get("severity") == "ERROR"
        for record in alerts
    ):
        raise SystemExit(
            f"missing alert contract role={role} rule={rule} status={status_code}"
        )

log_statuses = sorted(
    {record.get("status_code") for record in logs if "status_code" in record}
)
alert_rules = sorted({record.get("rule") for record in alerts})
print(
    "validated_error_contract logs=%d alerts=%d statuses=%s alert_rules=%s"
    % (
        len(logs),
        len(alerts),
        ",".join(log_statuses),
        ",".join(alert_rules),
    )
)
PY

echo "phase5_error_contract pass log_dir=${LOG_DIR} alerts_dir=${ALERTS_DIR}"
