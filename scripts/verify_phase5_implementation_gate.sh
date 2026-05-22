#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${SDK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GATE_DIR="${GATE_DIR:-${1:-${SDK_ROOT}/artifacts/phase5_implementation_gate/latest}}"
REQUIRE_PASS="${REQUIRE_PASS:-1}"
SUMMARY_FILE="${GATE_DIR}/phase5_implementation_gate_summary.txt"

fail() {
  echo "phase5 implementation gate verification failed: $*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -s "${path}" ]] || fail "missing or empty file: ${path}"
}

summary_has() {
  local pattern="$1"
  rg -q "${pattern}" "${SUMMARY_FILE}"
}

log_has() {
  local log_file="$1"
  local pattern="$2"
  local message="$3"
  rg -q "${pattern}" "${log_file}" || fail "${message}: ${log_file}"
}

require_step() {
  local step="$1"
  summary_has "^step=${step} status=pass " ||
    fail "required implementation step did not pass: ${step}"
  require_file "${GATE_DIR}/logs/${step}.log"
}

require_role_file() {
  local dir="$1"
  local pattern="$2"
  local message="$3"
  shopt -s nullglob
  local files=("${dir}"/${pattern})
  shopt -u nullglob
  (( ${#files[@]} > 0 )) || fail "${message}: ${dir}/${pattern}"
  for file in "${files[@]}"; do
    require_file "${file}"
  done
}

require_any_nonempty_file() {
  local dir="$1"
  local pattern="$2"
  local message="$3"
  shopt -s nullglob
  local files=("${dir}"/${pattern})
  shopt -u nullglob
  (( ${#files[@]} > 0 )) || fail "${message}: ${dir}/${pattern}"
  for file in "${files[@]}"; do
    if [[ -s "${file}" ]]; then
      return
    fi
  done
  fail "${message}: no non-empty file matched ${dir}/${pattern}"
}

[[ -d "${GATE_DIR}" ]] || fail "missing gate directory: ${GATE_DIR}"
require_file "${GATE_DIR}/metadata.txt"
require_file "${SUMMARY_FILE}"
require_file "${GATE_DIR}/files.txt"
require_file "${GATE_DIR}/manifest.sha256"
require_file "${GATE_DIR}/phase5_implementation_gate_metrics.prom"

(
  cd "${GATE_DIR}"
  sha256sum -c manifest.sha256 >/dev/null
)

verify_top_manifest_consistency() {
  python3 - "${GATE_DIR}" <<'PY'
import os
import sys

gate_dir = sys.argv[1]
files_path = os.path.join(gate_dir, "files.txt")
manifest_path = os.path.join(gate_dir, "manifest.sha256")

with open(files_path, "r", encoding="utf-8") as handle:
    files = [line.strip() for line in handle if line.strip()]
with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest_files = []
    for line_no, line in enumerate(handle, 1):
        line = line.rstrip("\n")
        if len(line) < 67:
            raise SystemExit(
                f"implementation gate manifest line {line_no} is too short"
            )
        digest, rel = line.split(None, 1)
        if len(digest) != 64 or not all(
            ch in "0123456789abcdefABCDEF" for ch in digest
        ):
            raise SystemExit(
                f"implementation gate manifest line {line_no} has invalid sha256"
            )
        manifest_files.append(rel.lstrip("*"))

actual_files = []
for root, _, names in os.walk(gate_dir):
    for name in names:
        path = os.path.join(root, name)
        rel = os.path.relpath(path, gate_dir)
        if rel in {"manifest.sha256", "files.txt"}:
            continue
        actual_files.append(rel)
actual_files.sort()

if files != sorted(files):
    raise SystemExit("implementation gate files.txt is not sorted")
if files != manifest_files:
    raise SystemExit(
        "implementation gate files.txt and manifest.sha256 file sets differ"
    )
if files != actual_files:
    raise SystemExit("implementation gate files.txt does not match actual files")
PY
}

verify_top_manifest_consistency

summary_has '^phase5_implementation_gate=running$' ||
  fail "summary missing implementation gate start marker"

verify_gate_metrics() {
  local expected_status="$1"
  python3 - "${GATE_DIR}/phase5_implementation_gate_metrics.prom" "${expected_status}" <<'PY'
import pathlib
import re
import sys

path, expected_status = sys.argv[1:3]
text = pathlib.Path(path).read_text(encoding="utf-8")
for required_text in (
    "# TYPE webrtc_qos_phase5_implementation_gate_info gauge",
    "webrtc_qos_phase5_implementation_gate_info",
    "webrtc_qos_phase5_implementation_gate_steps_total",
    "webrtc_qos_phase5_implementation_gate_step_status",
    "webrtc_qos_phase5_implementation_gate_debug_bundle_status",
):
    if required_text not in text:
        raise SystemExit(f"implementation gate metrics missing {required_text}")

line_re = re.compile(
    r"^([A-Za-z_:][A-Za-z0-9_:]*)(\{([^{}]*)\})?\s+"
    r"([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|[+-]?Inf|NaN)$"
)
label_re = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)="((?:\\.|[^"\\])*)"')
records = []
for line_no, line in enumerate(text.splitlines(), 1):
    if not line.strip() or line.startswith("#"):
        continue
    match = line_re.match(line)
    if not match:
        raise SystemExit(
            f"implementation gate metrics line {line_no} is invalid: {line}"
        )
    labels = {}
    raw_labels = match.group(3) or ""
    position = 0
    while position < len(raw_labels):
        label_match = label_re.match(raw_labels, position)
        if not label_match:
            raise SystemExit(
                f"implementation gate metrics line {line_no} has invalid labels"
            )
        labels[label_match.group(1)] = label_match.group(2)
        position = label_match.end()
        if position < len(raw_labels):
            if raw_labels[position] != ",":
                raise SystemExit(
                    f"implementation gate metrics line {line_no} has malformed labels"
                )
            position += 1
    records.append({
        "name": match.group(1),
        "labels": labels,
        "value": float(match.group(4)),
    })
if not records:
    raise SystemExit("implementation gate metrics file has no samples")


def has(name, value=None, **labels):
    for record in records:
        if record["name"] != name:
            continue
        if not all(record["labels"].get(key) == label for key, label in labels.items()):
            continue
        if value is not None and record["value"] != value:
            continue
        return True
    return False


def sample_value(name, **labels):
    for record in records:
        if record["name"] != name:
            continue
        if all(record["labels"].get(key) == label for key, label in labels.items()):
            return record["value"]
    return None


if not has(
    "webrtc_qos_phase5_implementation_gate_info",
    value=1,
    status=expected_status,
):
    raise SystemExit("implementation gate metrics missing expected gate status")

required_steps = (
    "no_selfmade_media_stack",
    "phase5_logging",
    "phase5_metrics",
    "phase5_alerts",
    "phase5_error_contract",
    "phase5_minimal_udp_external_app",
    "phase5_release_contract",
)
if expected_status == "pass":
    for step in required_steps:
        if not has(
            "webrtc_qos_phase5_implementation_gate_step_status",
            value=1,
            step=step,
            status="pass",
        ):
            raise SystemExit(f"implementation gate metrics missing pass step {step}")
    if not has(
        "webrtc_qos_phase5_implementation_gate_debug_bundle_status",
        value=1,
        status="pass",
    ):
        raise SystemExit("passed implementation metrics missing debug bundle pass")
elif expected_status == "fail":
    fail_count = sample_value(
        "webrtc_qos_phase5_implementation_gate_steps_total",
        status="fail",
    )
    if fail_count is None or fail_count <= 0:
        raise SystemExit("failed implementation metrics missing failed step count")
    if not has(
        "webrtc_qos_phase5_implementation_gate_step_status",
        value=1,
        status="fail",
    ):
        raise SystemExit("failed implementation metrics missing failed step marker")
PY
}

if [[ "${REQUIRE_PASS}" == "1" ]]; then
  summary_has '^phase5_implementation_gate_status=pass$' ||
    fail "phase5 implementation gate did not pass"
  verify_gate_metrics pass
else
  summary_has '^phase5_implementation_gate_status=(pass|fail)$' ||
    fail "summary missing pass/fail status"
  if summary_has '^phase5_implementation_gate_status=pass$'; then
    verify_gate_metrics pass
  else
    verify_gate_metrics fail
  fi
fi

if summary_has '^phase5_implementation_gate_status=fail$'; then
  summary_has '^step=[^ ]+ status=fail ' ||
    fail "failed implementation gate summary missing failed step"
  echo "phase5_implementation_gate_verify pass gate_dir=${GATE_DIR} require_pass=${REQUIRE_PASS}"
  exit 0
fi

require_step no_selfmade_media_stack
require_step phase5_logging
require_step phase5_metrics
require_step phase5_alerts
require_step phase5_error_contract
require_step phase5_minimal_udp_external_app
require_step phase5_release_contract
require_step collect_phase5_debug_bundle
require_step verify_phase5_debug_bundle

log_has "${GATE_DIR}/logs/no_selfmade_media_stack.log" \
  'self-made media stack verification passed' \
  "no-selfmade media stack verifier did not pass"

log_has "${GATE_DIR}/logs/phase5_logging.log" \
  'phase5_logging pass ' "logging gate did not report pass"
log_has "${GATE_DIR}/logs/phase5_logging.log" \
  'validated_config_dump' "logging gate missing config dump validation"
log_has "${GATE_DIR}/logs/phase5_logging.log" \
  'validated_stop_flush' "logging gate missing stop flush validation"
log_has "${GATE_DIR}/logs/phase5_logging.log" \
  'validated_log_rotation' "logging gate missing rotation validation"
log_has "${GATE_DIR}/logs/phase5_logging.log" \
  'validated_async_log_queue' "logging gate missing async queue validation"
log_has "${GATE_DIR}/logs/phase5_logging.log" \
  'dropped_log_count=' "logging gate missing dropped log count validation"

log_has "${GATE_DIR}/logs/phase5_metrics.log" \
  'phase5_metrics pass ' "metrics gate did not report pass"
log_has "${GATE_DIR}/logs/phase5_metrics.log" \
  'validated_metrics_records=' "metrics gate missing records validation"
log_has "${GATE_DIR}/logs/phase5_metrics.log" \
  'validated_metrics_rotation' "metrics gate missing rotation validation"

log_has "${GATE_DIR}/logs/phase5_alerts.log" \
  'phase5_alerts pass ' "alerts gate did not report pass"
log_has "${GATE_DIR}/logs/phase5_alerts.log" \
  'validated_udp_alert_records=' "alerts gate missing UDP validation"
log_has "${GATE_DIR}/logs/phase5_alerts.log" \
  'validated_fault_alert_records=' "alerts gate missing fault validation"
log_has "${GATE_DIR}/logs/phase5_alerts.log" \
  'validated_alert_rotation' "alerts gate missing rotation validation"
log_has "${GATE_DIR}/logs/phase5_alerts.log" \
  'validated_process_tick_gap_alert' "alerts gate missing process gap validation"
log_has "${GATE_DIR}/logs/phase5_alerts.log" \
  'validated_media_flow_gap_alert' "alerts gate missing media flow validation"
log_has "${GATE_DIR}/logs/phase5_alerts.log" \
  'validated_consecutive_transport_failure_alert' \
  "alerts gate missing consecutive transport failure validation"

log_has "${GATE_DIR}/logs/phase5_error_contract.log" \
  'phase5_error_contract pass ' "error contract gate did not report pass"
log_has "${GATE_DIR}/logs/phase5_error_contract.log" \
  'validated_error_contract' "error contract gate missing validation marker"

log_has "${GATE_DIR}/logs/phase5_minimal_udp_external_app.log" \
  'phase5_minimal_udp_external_app pass ' \
  "external minimal UDP gate did not report pass"
log_has "${GATE_DIR}/logs/phase5_minimal_udp_external_app.log" \
  'minimal_udp_selftest .*pass=true' \
  "external minimal UDP gate missing selftest pass"
log_has "${GATE_DIR}/logs/phase5_minimal_udp_external_app.log" \
  'validated_external_records' \
  "external minimal UDP gate missing runtime record validation"

log_has "${GATE_DIR}/logs/phase5_release_contract.log" \
  'phase5_release_contract pass ' "release contract gate did not report pass"
log_has "${GATE_DIR}/logs/phase5_release_contract.log" \
  'validated_contract_role_targets_release_records' \
  "release contract gate missing role target validation"
log_has "${GATE_DIR}/logs/phase5_release_contract.log" \
  'validated_contract_role_bundles_release_records' \
  "release contract gate missing role bundle validation"

log_has "${GATE_DIR}/logs/verify_phase5_debug_bundle.log" \
  'phase5_debug_bundle pass ' "debug bundle verifier did not report pass"

require_role_file "${GATE_DIR}/artifacts/logging/main" \
  'webrtc_qos_udp.push.*.log' "missing push logging artifact"
require_role_file "${GATE_DIR}/artifacts/logging/main" \
  'webrtc_qos_udp.server.*.log' "missing server logging artifact"
require_role_file "${GATE_DIR}/artifacts/logging/main" \
  'webrtc_qos_udp.play.*.log' "missing play logging artifact"
require_role_file "${GATE_DIR}/artifacts/logging/rotation" \
  'webrtc_qos_udp.push.*.log' "missing rotated push logging artifact"
require_role_file "${GATE_DIR}/artifacts/logging/queue" \
  'webrtc_qos_udp.push.*.log' "missing bounded queue logging artifact"

require_role_file "${GATE_DIR}/artifacts/metrics/main" \
  'webrtc_qos_udp_metrics.push.*.jsonl' "missing push metrics artifact"
require_role_file "${GATE_DIR}/artifacts/metrics/main" \
  'webrtc_qos_udp_metrics.server.*.jsonl' "missing server metrics artifact"
require_role_file "${GATE_DIR}/artifacts/metrics/main" \
  'webrtc_qos_udp_metrics.play.*.jsonl' "missing play metrics artifact"
require_role_file "${GATE_DIR}/artifacts/metrics/rotation" \
  'webrtc_qos_udp_metrics.push.*.jsonl' "missing rotated push metrics artifact"

require_role_file "${GATE_DIR}/artifacts/alerts/main" \
  'webrtc_qos_udp_alerts.push.*.jsonl' "missing push alerts artifact"
require_role_file "${GATE_DIR}/artifacts/alerts/main" \
  'webrtc_qos_udp_alerts.server.*.jsonl' "missing server alerts artifact"
require_role_file "${GATE_DIR}/artifacts/alerts/main" \
  'webrtc_qos_udp_alerts.play.*.jsonl' "missing play alerts artifact"
require_role_file "${GATE_DIR}/artifacts/alerts/rotation" \
  'webrtc_qos_rotation_alerts.push.*.jsonl' "missing rotated push alerts artifact"
require_role_file "${GATE_DIR}/artifacts/alerts/logs" \
  'webrtc_qos_fault_logs.push.*.log' "missing alert fault log artifact"

require_role_file "${GATE_DIR}/artifacts/error_contract/logs" \
  'webrtc_qos_error_contract_logs.*.log' "missing error contract logs"
require_role_file "${GATE_DIR}/artifacts/error_contract/alerts" \
  'webrtc_qos_error_contract_alerts.*.jsonl' "missing error contract alerts"

require_role_file "${GATE_DIR}/artifacts/minimal_udp_external/logs" \
  'minimal_udp.push.*.log' "missing external minimal push logs"
require_role_file "${GATE_DIR}/artifacts/minimal_udp_external/metrics" \
  'minimal_udp_metrics.push.*.jsonl' "missing external minimal push metrics"
require_role_file "${GATE_DIR}/artifacts/minimal_udp_external/alerts" \
  'minimal_udp_alerts.push.*.jsonl' "missing external minimal push alerts"

require_role_file "${GATE_DIR}/artifacts/release_contract/logs" \
  'phase5_release_contract.*.log' "missing release contract logs"
require_role_file "${GATE_DIR}/artifacts/release_contract/metrics" \
  'phase5_release_contract_metrics.*.jsonl' "missing release contract metrics"
require_any_nonempty_file "${GATE_DIR}/artifacts/release_contract/alerts" \
  'phase5_release_contract_alerts.*.jsonl' "missing release contract alerts"

require_file "${GATE_DIR}/artifacts/debug_bundle/manifest.sha256"
require_file "${GATE_DIR}/artifacts/debug_bundle/runtime_config.json"
require_file "${GATE_DIR}/artifacts/debug_bundle/log/push.log"
require_file "${GATE_DIR}/artifacts/debug_bundle/metrics/push_metrics.jsonl"
require_file "${GATE_DIR}/artifacts/debug_bundle/alerts/alerts.jsonl"
require_file "${GATE_DIR}/artifacts/debug_bundle/timeline/events.jsonl"
(
  cd "${GATE_DIR}/artifacts/debug_bundle"
  sha256sum -c manifest.sha256 >/dev/null
)
BUNDLE_DIR="${GATE_DIR}/artifacts/debug_bundle" \
  "${SDK_ROOT}/scripts/verify_phase5_debug_bundle.sh" >/dev/null

python3 - "${GATE_DIR}" <<'PY'
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
payload_like = {
    "payload",
    "annexb_bytes",
    "rtp_bytes",
    "rtcp_bytes",
    "token",
    "secret",
    "password",
}

checked = 0
roles = set()
for path in sorted((root / "artifacts").rglob("*")):
    if path.suffix not in {".jsonl", ".log"}:
        continue
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            if not line.strip() or not line.lstrip().startswith("{"):
                continue
            record = json.loads(line)
            if "event" in record or "scope" in record or "rule" in record:
                missing = required_identity - record.keys()
                if missing:
                    raise SystemExit(
                        f"{path}:{line_no}: missing identity fields {sorted(missing)}"
                    )
                leaked = payload_like & record.keys()
                if leaked:
                    raise SystemExit(
                        f"{path}:{line_no}: payload-like fields {sorted(leaked)}"
                    )
                if record.get("role"):
                    roles.add(record["role"])
                checked += 1

if checked == 0:
    raise SystemExit("no runtime JSON records checked")
if not {"push", "server", "play"}.issubset(roles):
    raise SystemExit(f"runtime evidence missing roles: {sorted(roles)}")
print(f"validated_phase5_implementation_records={checked} roles={','.join(sorted(roles))}")
PY

if rg -q 'payload|annexb_bytes|rtp_bytes|rtcp_bytes|token|secret|password' \
  "${GATE_DIR}/metadata.txt" "${SUMMARY_FILE}"; then
  fail "implementation gate metadata/summary contains payload-like or sensitive field"
fi

echo "phase5_implementation_gate_verify pass gate_dir=${GATE_DIR} require_pass=${REQUIRE_PASS}"
