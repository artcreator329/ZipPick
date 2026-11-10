#!/bin/bash
# Regenerates Resources/AppIcon.icns and docs/icon.png from scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift scripts/make-icon.swift "$WORK/icon-1024.png"

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET" docs
for s in 16 32 128 256 512; do
    sips -z $s $s "$WORK/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$WORK/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
sips -z 256 256 "$WORK/icon-1024.png" --out docs/icon.png >/dev/null
echo "Wrote Resources/AppIcon.icns"
