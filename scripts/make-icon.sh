#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${PROJECT_DIR}/Resources/NathPaint-logo.png"
ICONSET="${PROJECT_DIR}/build/icon-NathPaint.iconset"
OUTPUT="${PROJECT_DIR}/Resources/AppIcon.icns"

if [[ ! -f "${SOURCE}" ]]; then
  echo "Missing icon source: ${SOURCE}" >&2
  exit 1
fi

mkdir -p "${ICONSET}"
for size in 16 32 128 256 512; do
  sips -z "${size}" "${size}" "${SOURCE}" --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "${double}" "${double}" "${SOURCE}" --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns "${ICONSET}" --output "${OUTPUT}"
echo "Created ${OUTPUT}"
