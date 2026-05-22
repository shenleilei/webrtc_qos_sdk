#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 3 ]]; then
  echo "usage: $0 <ar> <output.a> <input1.a> [input2.a ...]" >&2
  exit 2
fi

AR_BIN="$1"
OUTPUT_ARCHIVE="$2"
shift 2

mkdir -p "$(dirname "${OUTPUT_ARCHIVE}")"
rm -f "${OUTPUT_ARCHIVE}"

MRI_FILE="$(mktemp)"
trap 'rm -f "${MRI_FILE}"' EXIT

{
  printf 'create %s\n' "${OUTPUT_ARCHIVE}"
  for archive in "$@"; do
    printf 'addlib %s\n' "${archive}"
  done
  printf 'save\nend\n'
} >"${MRI_FILE}"

"${AR_BIN}" -M <"${MRI_FILE}"
"${AR_BIN}" s "${OUTPUT_ARCHIVE}"
