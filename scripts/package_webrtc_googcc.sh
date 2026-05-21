#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "package_webrtc_googcc.sh is a compatibility wrapper." >&2
echo "Use package_webrtc_modules.sh for WebRTC-first Phase-2 packaging." >&2

REQUIRE_ALL="${REQUIRE_ALL:-0}" \
  "${SCRIPT_DIR}/package_webrtc_modules.sh"
