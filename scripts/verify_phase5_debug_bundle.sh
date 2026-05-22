#!/usr/bin/env bash
set -euo pipefail

BUNDLE_DIR="${BUNDLE_DIR:-${1:-/root/webrtc_qos_sdk/artifacts/phase5_debug_bundle}}"
REQUIRE_SELFTEST_PASS="${REQUIRE_SELFTEST_PASS:-1}"

fail() {
  echo "phase5 debug bundle verification failed: $*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -s "${path}" ]] || fail "missing or empty file: ${path}"
}

require_no_payload_like_fields() {
  local path="$1"
  if rg -q '"payload"|"annexb_bytes"|"rtp_bytes"|token|secret|password' "${path}"; then
    fail "bundle file contains payload-like or sensitive field: ${path}"
  fi
}

[[ -d "${BUNDLE_DIR}" ]] || fail "missing bundle directory: ${BUNDLE_DIR}"

required_files=(
  metadata.txt
  build_config.txt
  git_status.txt
  session_config.json
  runtime_config.json
  debug_bundle_summary.txt
  manifest.sha256
  files.txt
  log/push.log
  log/server.log
  log/play.log
  metrics/push_metrics.jsonl
  metrics/server_metrics.jsonl
  metrics/play_metrics.jsonl
  metrics/summary.csv
  alerts/push_alerts.jsonl
  alerts/server_alerts.jsonl
  alerts/play_alerts.jsonl
  alerts/alerts.jsonl
  alerts/alerts_summary.txt
  timeline/events.jsonl
  timeline/first_problem.json
  timeline/summary.txt
  evidence/udp_selftest_output.txt
)

for rel in "${required_files[@]}"; do
  require_file "${BUNDLE_DIR}/${rel}"
done

if [[ "${REQUIRE_SELFTEST_PASS}" == "1" ]]; then
  rg -q 'udp_selftest .*pass=true' "${BUNDLE_DIR}/evidence/udp_selftest_output.txt" ||
    fail "UDP selftest output did not show pass=true"
fi

(
  cd "${BUNDLE_DIR}"
  sha256sum -c manifest.sha256 >/dev/null
)

python3 - "${BUNDLE_DIR}" <<'PY'
import csv
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

required_identity = {
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

def read_jsonl(path):
    records = []
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            if not line.strip():
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{line_no}: invalid JSON: {exc}")
    return records

roles = {"push", "server", "play"}
for role in roles:
    log_records = read_jsonl(root / "log" / f"{role}.log")
    metric_records = read_jsonl(root / "metrics" / f"{role}_metrics.jsonl")
    alert_records = read_jsonl(root / "alerts" / f"{role}_alerts.jsonl")
    if not log_records:
        raise SystemExit(f"missing log records for role {role}")
    if not metric_records:
        raise SystemExit(f"missing metric records for role {role}")
    if not alert_records:
        raise SystemExit(f"missing alert records for role {role}")
    for collection_name, records in [
        ("log", log_records),
        ("metric", metric_records),
        ("alert", alert_records),
    ]:
        for index, record in enumerate(records, 1):
            missing = required_identity - record.keys()
            if missing:
                raise SystemExit(
                    f"{collection_name}:{role}:{index}: missing fields {sorted(missing)}"
                )

with (root / "metrics" / "summary.csv").open("r", encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle))
if {row["role"] for row in rows} != roles:
    raise SystemExit("metrics summary does not cover push/server/play")
if min(int(row["records"]) for row in rows) <= 0:
    raise SystemExit("metrics summary has empty role")

alerts = read_jsonl(root / "alerts" / "alerts.jsonl")
rules = {record.get("rule") for record in alerts}
expected_rules = {
    "high_downlink_loss",
    "video_drop_frames",
    "low_target_bitrate",
    "low_encoder_fps",
    "nack_generated",
    "local_retransmission_hit",
}
missing_rules = expected_rules - rules
if missing_rules:
    raise SystemExit(f"missing expected alert rules: {sorted(missing_rules)}")

timeline = read_jsonl(root / "timeline" / "events.jsonl")
if not timeline:
    raise SystemExit("empty timeline")
event_types = {event.get("type") for event in timeline}
if not {"log", "metric", "alert"}.issubset(event_types):
    raise SystemExit(f"timeline missing event types: {sorted(event_types)}")

first_problem = json.loads((root / "timeline" / "first_problem.json").read_text())
if first_problem.get("status") != "found":
    raise SystemExit("first_problem.json did not identify a WARN/ERROR or alert")

session = json.loads((root / "session_config.json").read_text())
profiles = session.get("profiles", [])
if len(profiles) < 2:
    raise SystemExit("session_config.json missing single/dual track profiles")
dual = next((profile for profile in profiles if profile.get("label") == "dual_track"), None)
if not dual or len(dual.get("tracks", [])) != 2:
    raise SystemExit("session_config.json missing dual-track definition")

runtime = json.loads((root / "runtime_config.json").read_text())
if runtime.get("schema_version") != 1:
    raise SystemExit("runtime_config.json missing schema_version=1")
transport = runtime.get("transport", {})
if transport.get("kind") != "udp" or transport.get("peer_connection") is not False:
    raise SystemExit("runtime_config.json has unexpected transport boundary")
selftest = runtime.get("selftest", {})
if selftest.get("frames", 0) <= 0:
    raise SystemExit("runtime_config.json missing positive selftest frames")
runtime_section = runtime.get("runtime", {})
for section in ("logging", "metrics", "alerts"):
    if runtime_section.get(section, {}).get("enabled") is not True:
        raise SystemExit(f"runtime_config.json missing enabled {section}")
roles_config = runtime.get("roles", [])
if {item.get("role") for item in roles_config} != roles:
    raise SystemExit("runtime_config.json does not cover push/server/play roles")
for item in roles_config:
    artifacts = item.get("artifacts", {})
    for artifact_kind in ("log", "metrics", "alerts"):
        rel = artifacts.get(artifact_kind)
        if not rel or not (root / rel).exists():
            raise SystemExit(
                f"runtime_config.json role {item.get('role')} bad {artifact_kind} artifact"
            )
redaction = runtime.get("redaction", {})
for key in ("media_bytes", "raw_frames", "auth_material", "absolute_runtime_paths"):
    if redaction.get(key) != "omitted":
        raise SystemExit(f"runtime_config.json missing redaction marker {key}")

print(
    "validated_phase5_debug_bundle roles=%s alerts=%d timeline=%d"
    % (",".join(sorted(roles)), len(alerts), len(timeline))
)
PY

while IFS= read -r rel; do
  require_no_payload_like_fields "${BUNDLE_DIR}/${rel}"
done <"${BUNDLE_DIR}/files.txt"

echo "phase5_debug_bundle pass bundle_dir=${BUNDLE_DIR}"
