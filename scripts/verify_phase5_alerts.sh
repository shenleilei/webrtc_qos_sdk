#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-/root/webrtc_qos_sdk}"
PREFIX="${PREFIX:-${SDK_ROOT}/dist/linux-x86_64}"
BUILD_DIR="${BUILD_DIR:-/tmp/webrtc_qos_phase5_alerts_build.$$}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/tmp/webrtc_qos_phase5_alerts_install.$$}"
WORK_DIR="${WORK_DIR:-/tmp/webrtc_qos_phase5_alerts_fixture.$$}"
ALERTS_DIR="${ALERTS_DIR:-/tmp/webrtc_qos_phase5_alerts.$$}"
ROTATION_ALERTS_DIR="${ROTATION_ALERTS_DIR:-/tmp/webrtc_qos_phase5_rotation_alerts.$$}"
LOG_DIR="${LOG_DIR:-/tmp/webrtc_qos_phase5_alert_logs.$$}"
FRAMES="${FRAMES:-36}"

cleanup() {
  if [[ "${KEEP_WORK_DIR:-0}" != "1" ]]; then
    rm -rf "${BUILD_DIR}" "${INSTALL_PREFIX}" "${WORK_DIR}" \
      "${ALERTS_DIR}" "${ROTATION_ALERTS_DIR}" "${LOG_DIR}"
  fi
}
trap cleanup EXIT

fail() {
  echo "phase5 alerts verification failed: $*" >&2
  exit 1
}

require_log() {
  local pattern="$1"
  local message="$2"
  if ! rg -q "${pattern}" "${LOG_DIR}"; then
    find "${LOG_DIR}" -maxdepth 1 -type f -print >&2 || true
    fail "${message}"
  fi
}

rm -rf "${BUILD_DIR}" "${INSTALL_PREFIX}" "${WORK_DIR}" \
  "${ALERTS_DIR}" "${ROTATION_ALERTS_DIR}" "${LOG_DIR}"
mkdir -p "${ALERTS_DIR}" "${ROTATION_ALERTS_DIR}" "${LOG_DIR}" "${WORK_DIR}"

cmake -S "${SDK_ROOT}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DWEBRTC_QOS_ENABLE_WEBRTC_FACADE=ON \
  -DWEBRTC_QOS_WEBRTC_MODULE_PREFIX="${PREFIX}" >/dev/null
cmake --build "${BUILD_DIR}" -j2 >/dev/null
cmake --install "${BUILD_DIR}" --prefix "${INSTALL_PREFIX}" >/dev/null

demo="${BUILD_DIR}/webrtc_qos_webrtc_first_udp_demo"
if ! output="$("${demo}" selftest "${FRAMES}" \
  --alerts-dir "${ALERTS_DIR}" --log-dir "${LOG_DIR}" 2>&1)"; then
  echo "${output}" >&2
  fail "UDP selftest with alerts exited with non-zero status"
fi
printf '%s\n' "${output}"
grep -q "udp_selftest .*pass=true" <<<"${output}" ||
  fail "UDP selftest with alerts did not pass"

shopt -s nullglob
push_alerts=("${ALERTS_DIR}"/webrtc_qos_udp_alerts.push.*.jsonl)
server_alerts=("${ALERTS_DIR}"/webrtc_qos_udp_alerts.server.*.jsonl)
play_alerts=("${ALERTS_DIR}"/webrtc_qos_udp_alerts.play.*.jsonl)
(( ${#push_alerts[@]} > 0 )) || fail "missing UDP push alerts file"
(( ${#server_alerts[@]} > 0 )) || fail "missing UDP server alerts file"
(( ${#play_alerts[@]} > 0 )) || fail "missing UDP play alerts file"

python3 - "${ALERTS_DIR}" "udp" <<'PY'
import json
import pathlib
import sys

alerts_dir = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
required_fields = {
    "ts_us",
    "severity",
    "role",
    "rule",
    "category",
    "session_id",
    "stream_id",
    "transport_id",
    "source_id",
    "track_id",
    "sender_ssrc",
    "receiver_id",
}
required_rules = {
    "udp": {
        "high_downlink_loss",
        "video_drop_frames",
        "low_target_bitrate",
        "low_encoder_fps",
        "nack_generated",
        "local_retransmission_hit",
    },
    "fault": {
        "malformed_rtp",
        "transport_output_failed",
        "decode_output_failed",
    },
}[mode]

records = []
for path in alerts_dir.glob("*.jsonl"):
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            if not line.strip():
                continue
            obj = json.loads(line)
            missing = required_fields - obj.keys()
            if missing:
                raise SystemExit(
                    f"{path}:{line_no}: missing fields: {sorted(missing)}"
                )
            if obj["severity"] not in {"WARN", "ERROR"}:
                raise SystemExit(
                    f"{path}:{line_no}: unexpected severity {obj['severity']}"
                )
            if any(key in obj for key in ("payload", "annexb_bytes", "rtp_bytes")):
                raise SystemExit(f"{path}:{line_no}: media payload-like field found")
            records.append(obj)

if not records:
    raise SystemExit("no alert records found")

rules = {record["rule"] for record in records}
missing_rules = required_rules - rules
if missing_rules:
    raise SystemExit(f"missing alert rules: {sorted(missing_rules)}")

roles = {record["role"] for record in records}
if mode == "udp" and not {"push", "server", "play"}.issubset(roles):
    raise SystemExit(f"missing UDP alert roles: {sorted(roles)}")

print(
    "validated_%s_alert_records=%d rules=%s"
    % (mode, len(records), ",".join(sorted(rules)))
)
PY

cat > "${WORK_DIR}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(phase5_alert_fault_fixture LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(WebRtcQosSdk REQUIRED CONFIG)

add_executable(phase5_alert_fault_fixture main.cc)
target_link_libraries(phase5_alert_fault_fixture PRIVATE
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
#include "webrtc_qos/server_qos_router.h"
#include "webrtc_qos/session_config.h"
#include "webrtc_qos/status.h"
#include "webrtc_qos/video_play_client.h"
#include "webrtc_qos/video_push_client.h"

namespace {

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
  session.ids.session_id = 7;
  session.ids.stream_id = 8;
  session.ids.transport_id = 9;
  session.ids.source_id = session.ids.stream_id;
  session.ids.sender_ssrc = 0x12345678u;
  session.ids.receiver_id = 0x2222u;
  session.start_bitrate_bps = 1200000;
  session.min_bitrate_bps = 300000;
  session.max_bitrate_bps = 2500000;
  session.debug_name = "phase5_alert_fault_fixture";
  return session;
}

webrtc_qos::RuntimeAlertConfig MakeAlerts(const std::string& dir,
                                          const std::string& basename,
                                          uint64_t max_file_bytes = 1024 * 1024,
                                          uint32_t max_files = 4) {
  webrtc_qos::RuntimeAlertConfig config;
  config.file.enabled = true;
  config.file.directory = dir;
  config.file.basename = basename;
  config.file.max_file_bytes = max_file_bytes;
  config.file.max_files = max_files;
  config.suppress_repeated_alerts_ms = 0;
  return config;
}

webrtc_qos::RuntimeLogConfig MakeLogs(const std::string& dir) {
  webrtc_qos::RuntimeLogConfig config;
  config.file.enabled = true;
  config.file.directory = dir;
  config.file.basename = "webrtc_qos_fault_logs";
  config.file.json_lines = true;
  config.file.also_stderr = false;
  config.file.max_file_bytes = 1024 * 1024;
  config.file.max_files = 4;
  return config;
}

int Fail(const char* message) {
  std::cerr << message << "\n";
  return 1;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    return Fail("usage: phase5_alert_fault_fixture <alerts_dir> <log_dir> <rotation_alerts_dir>");
  }

  const std::string alerts_dir = argv[1];
  const std::string log_dir = argv[2];
  const std::string rotation_alerts_dir = argv[3];
  const webrtc_qos::SessionConfig session = MakeSession();
  const std::vector<uint8_t> au = MakeIdrAccessUnit(42);

  webrtc_qos::ServerQosRouterConfig server_config;
  server_config.session = session;
  server_config.alerts = MakeAlerts(alerts_dir, "webrtc_qos_fault_alerts");
  server_config.logging = MakeLogs(log_dir);
  server_config.sender_output =
      [](const webrtc_qos::TransportPacketView&) {
        return webrtc_qos::Status::Ok();
      };
  server_config.receiver_output =
      [](const webrtc_qos::TransportPacketView&) {
        return webrtc_qos::Status::Ok();
      };
  std::unique_ptr<webrtc_qos::ServerQosRouter> server =
      webrtc_qos::CreateServerQosRouter(server_config);
  if (!server || !server->Start()) {
    return Fail("failed to start server fixture");
  }
  const uint8_t bad_rtp[] = {0x01, 0x02, 0x03};
  if (server->OnSenderRtp(bad_rtp, sizeof(bad_rtp), 1000000)) {
    return Fail("malformed RTP was unexpectedly accepted");
  }
  server->Stop();

  webrtc_qos::VideoPushClientConfig push_fail_config;
  push_fail_config.session = session;
  push_fail_config.alerts = MakeAlerts(alerts_dir, "webrtc_qos_fault_alerts");
  push_fail_config.logging = MakeLogs(log_dir);
  push_fail_config.transport_output =
      [](const webrtc_qos::TransportPacketView&) {
        return webrtc_qos::Status::Error(
            webrtc_qos::StatusCode::kInternalError,
            "fixture transport output failure");
      };
  std::unique_ptr<webrtc_qos::VideoPushClient> push_fail =
      webrtc_qos::CreateVideoPushClient(push_fail_config);
  if (!push_fail || !push_fail->Start()) {
    return Fail("failed to start push transport-failure fixture");
  }
  webrtc_qos::AnnexBAccessUnitView push_view;
  push_view.bytes = au.data();
  push_view.size = au.size();
  push_view.capture_time_us = 2000000;
  push_view.keyframe = true;
  push_view.ids = session.ids;
  if (!push_fail->PushAnnexBAccessUnit(push_view)) {
    return Fail("failed to enqueue transport-failure AU");
  }
  bool transport_failed = false;
  for (int i = 0; i < 32; ++i) {
    const webrtc_qos::Status status =
        push_fail->Process(2000000 + static_cast<int64_t>(i) * 10000);
    if (!status) {
      transport_failed = true;
      break;
    }
  }
  push_fail->Stop();
  if (!transport_failed) {
    return Fail("transport output failure did not trigger");
  }

  std::vector<std::vector<uint8_t>> rtp_packets;
  webrtc_qos::VideoPushClientConfig producer_config;
  producer_config.session = session;
  producer_config.transport_output =
      [&](const webrtc_qos::TransportPacketView& packet) {
        if (packet.metadata.kind == webrtc_qos::TransportPacketKind::kRtp) {
          rtp_packets.emplace_back(packet.bytes, packet.bytes + packet.size);
        }
        return webrtc_qos::Status::Ok();
      };
  std::unique_ptr<webrtc_qos::VideoPushClient> producer =
      webrtc_qos::CreateVideoPushClient(producer_config);
  if (!producer || !producer->Start()) {
    return Fail("failed to start producer fixture");
  }
  webrtc_qos::AnnexBAccessUnitView producer_view = push_view;
  producer_view.capture_time_us = 3000000;
  if (!producer->PushAnnexBAccessUnit(producer_view)) {
    return Fail("failed to enqueue producer AU");
  }
  for (int i = 0; i < 32; ++i) {
    const webrtc_qos::Status status =
        producer->Process(3000000 + static_cast<int64_t>(i) * 10000);
    if (!status) {
      return Fail("producer process unexpectedly failed");
    }
  }
  producer->Stop();
  if (rtp_packets.empty()) {
    return Fail("producer emitted no RTP packets");
  }

  webrtc_qos::VideoPlayClientConfig play_config;
  play_config.session = session;
  play_config.alerts = MakeAlerts(alerts_dir, "webrtc_qos_fault_alerts");
  play_config.logging = MakeLogs(log_dir);
  play_config.transport_output =
      [](const webrtc_qos::TransportPacketView&) {
        return webrtc_qos::Status::Ok();
      };
  play_config.decoded_access_unit_output =
      [](const webrtc_qos::AnnexBAccessUnitView&) {
        return webrtc_qos::Status::Error(
            webrtc_qos::StatusCode::kInternalError,
            "fixture decode output failure");
      };
  std::unique_ptr<webrtc_qos::VideoPlayClient> play =
      webrtc_qos::CreateVideoPlayClient(play_config);
  if (!play || !play->Start()) {
    return Fail("failed to start play fixture");
  }
  bool decode_failed = false;
  for (const auto& packet : rtp_packets) {
    const webrtc_qos::Status status =
        play->OnRtpPacket(packet.data(), packet.size(), 3100000);
    if (!status) {
      decode_failed = true;
      break;
    }
  }
  play->Stop();
  if (!decode_failed) {
    return Fail("decode output failure did not trigger");
  }

  webrtc_qos::VideoPushClientConfig push_rotation_config;
  push_rotation_config.session = session;
  push_rotation_config.alerts =
      MakeAlerts(rotation_alerts_dir, "webrtc_qos_rotation_alerts", 256, 3);
  push_rotation_config.transport_output =
      [](const webrtc_qos::TransportPacketView&) {
        return webrtc_qos::Status::Ok();
      };
  std::unique_ptr<webrtc_qos::VideoPushClient> push_rotation =
      webrtc_qos::CreateVideoPushClient(push_rotation_config);
  if (!push_rotation || !push_rotation->Start()) {
    return Fail("failed to start push rotation fixture");
  }
  const uint8_t bad_rtcp[] = {0x80, 0xce, 0x00};
  for (int i = 0; i < 12; ++i) {
    if (push_rotation->OnTransportFeedback(bad_rtcp, sizeof(bad_rtcp),
                                           4000000 + i * 1000)) {
      return Fail("malformed push RTCP was unexpectedly accepted");
    }
  }
  push_rotation->Stop();

  webrtc_qos::ServerQosRouterConfig server_rotation_config;
  server_rotation_config.session = session;
  server_rotation_config.alerts =
      MakeAlerts(rotation_alerts_dir, "webrtc_qos_rotation_alerts", 256, 3);
  server_rotation_config.sender_output =
      [](const webrtc_qos::TransportPacketView&) {
        return webrtc_qos::Status::Ok();
      };
  server_rotation_config.receiver_output =
      [](const webrtc_qos::TransportPacketView&) {
        return webrtc_qos::Status::Ok();
      };
  std::unique_ptr<webrtc_qos::ServerQosRouter> server_rotation =
      webrtc_qos::CreateServerQosRouter(server_rotation_config);
  if (!server_rotation || !server_rotation->Start()) {
    return Fail("failed to start server rotation fixture");
  }
  for (int i = 0; i < 12; ++i) {
    if (server_rotation->OnSenderRtp(bad_rtp, sizeof(bad_rtp),
                                     5000000 + i * 1000)) {
      return Fail("malformed rotation RTP was unexpectedly accepted");
    }
  }
  server_rotation->Stop();

  webrtc_qos::VideoPlayClientConfig play_rotation_config;
  play_rotation_config.session = session;
  play_rotation_config.alerts =
      MakeAlerts(rotation_alerts_dir, "webrtc_qos_rotation_alerts", 256, 3);
  play_rotation_config.transport_output =
      [](const webrtc_qos::TransportPacketView&) {
        return webrtc_qos::Status::Ok();
      };
  play_rotation_config.decoded_access_unit_output =
      [](const webrtc_qos::AnnexBAccessUnitView&) {
        return webrtc_qos::Status::Ok();
      };
  std::unique_ptr<webrtc_qos::VideoPlayClient> play_rotation =
      webrtc_qos::CreateVideoPlayClient(play_rotation_config);
  if (!play_rotation || !play_rotation->Start()) {
    return Fail("failed to start play rotation fixture");
  }
  for (int i = 0; i < 12; ++i) {
    if (play_rotation->OnRtpPacket(bad_rtp, sizeof(bad_rtp),
                                   6000000 + i * 1000)) {
      return Fail("malformed play RTP was unexpectedly accepted");
    }
  }
  play_rotation->Stop();

  std::cout << "phase5_alert_fault_fixture pass\n";
  return 0;
}
EOF

cmake -S "${WORK_DIR}" -B "${WORK_DIR}/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="${INSTALL_PREFIX}" >/dev/null
cmake --build "${WORK_DIR}/build" -j2 >/dev/null

if ! fixture_output="$("${WORK_DIR}/build/phase5_alert_fault_fixture" \
  "${ALERTS_DIR}" "${LOG_DIR}" "${ROTATION_ALERTS_DIR}" 2>&1)"; then
  echo "${fixture_output}" >&2
  fail "alert fault fixture exited with non-zero status"
fi
printf '%s\n' "${fixture_output}"
grep -q "phase5_alert_fault_fixture pass" <<<"${fixture_output}" ||
  fail "alert fault fixture did not report pass"

fault_alerts=("${ALERTS_DIR}"/webrtc_qos_fault_alerts.*.jsonl)
(( ${#fault_alerts[@]} > 0 )) || fail "missing fault fixture alert files"

python3 - "${ALERTS_DIR}" "fault" <<'PY'
import json
import pathlib
import sys

alerts_dir = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
required_fields = {
    "ts_us",
    "severity",
    "role",
    "rule",
    "category",
    "session_id",
    "stream_id",
    "transport_id",
    "source_id",
    "track_id",
    "sender_ssrc",
    "receiver_id",
}
required_rules = {
    "malformed_rtp",
    "transport_output_failed",
    "decode_output_failed",
}
records = []
for path in alerts_dir.glob("webrtc_qos_fault_alerts.*.jsonl"):
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            if not line.strip():
                continue
            obj = json.loads(line)
            missing = required_fields - obj.keys()
            if missing:
                raise SystemExit(
                    f"{path}:{line_no}: missing fields: {sorted(missing)}"
                )
            if any(key in obj for key in ("payload", "annexb_bytes", "rtp_bytes")):
                raise SystemExit(f"{path}:{line_no}: media payload-like field found")
            records.append(obj)
if not records:
    raise SystemExit("no fault alert records found")
rules = {record["rule"] for record in records}
missing_rules = required_rules - rules
if missing_rules:
    raise SystemExit(f"missing fault alert rules: {sorted(missing_rules)}")
print(
    "validated_fault_alert_records=%d rules=%s"
    % (len(records), ",".join(sorted(rules)))
)
PY

python3 - "${ROTATION_ALERTS_DIR}" <<'PY'
import json
import pathlib
import sys

alerts_dir = pathlib.Path(sys.argv[1])
roles = {"push", "server", "play"}
files_by_role = {
    role: sorted(alerts_dir.glob(f"webrtc_qos_rotation_alerts.{role}.*.jsonl"))
    for role in roles
}
for role, paths in files_by_role.items():
    grouped = {}
    for path in paths:
        prefix, index, suffix = path.name.rsplit(".", 2)
        if suffix != "jsonl":
            raise SystemExit(f"{path}: unexpected suffix {suffix}")
        grouped.setdefault(prefix, []).append((int(index), path))
    if not grouped:
        raise SystemExit(f"{role}: missing rotated alert files")
    saw_rotation = False
    for prefix, indexed_paths in grouped.items():
        if len(indexed_paths) > 3:
            raise SystemExit(
                f"{role}:{prefix}: max_files=3 exceeded, got {len(indexed_paths)}"
            )
        indexes = sorted(index for index, _ in indexed_paths)
        if indexes != list(range(len(indexes))):
            raise SystemExit(f"{role}:{prefix}: non-contiguous rotation indexes {indexes}")
        saw_rotation = saw_rotation or len(indexed_paths) >= 2
        for _, path in indexed_paths:
            if path.stat().st_size <= 0:
                raise SystemExit(f"{path}: empty rotated alert file")
            with path.open("r", encoding="utf-8") as handle:
                for line_no, line in enumerate(handle, 1):
                    if not line.strip():
                        continue
                    record = json.loads(line)
                    if record.get("role") != role:
                        raise SystemExit(
                            f"{path}:{line_no}: role mismatch {record.get('role')} != {role}"
                        )
                    if any(key in record for key in ("payload", "annexb_bytes", "rtp_bytes")):
                        raise SystemExit(f"{path}:{line_no}: media payload-like field found")
                    break
                else:
                    raise SystemExit(f"{path}: no JSON records")
    if not saw_rotation:
        raise SystemExit(f"{role}: no alert writer instance produced multiple rotated files")
print(
    "validated_alert_rotation "
    + " ".join(f"{role}_files={len(paths)}" for role, paths in sorted(files_by_role.items()))
)
PY

require_log '"event":"malformed_rtp"' \
  "fault fixture did not write malformed RTP log"
require_log '"event":"transport_output_failed"' \
  "fault fixture did not write transport failure log"
require_log '"event":"decode_au_output_failed"' \
  "fault fixture did not write decode output failure log"

echo "phase5_alerts pass alerts_dir=${ALERTS_DIR} log_dir=${LOG_DIR}"
