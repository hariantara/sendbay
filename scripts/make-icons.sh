#!/bin/bash
# Renders the icon and regenerates Resources/AppIcon.icns plus the Xcode
# asset catalog sizes from it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift scripts/make-icon.swift Resources/AppIcon-1024.png
TMP=$(mktemp -d)
SET="$TMP/AppIcon.iconset"
ASSETS=Resources/Assets.xcassets/AppIcon.appiconset
mkdir -p "$SET" "$ASSETS"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$SET"/*.png "$ASSETS/"
rm -rf "$TMP"
echo "Icons updated"
