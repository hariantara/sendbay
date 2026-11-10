#!/bin/bash
# Packages build/Sendbay.app into build/Sendbay-<version>.dmg (drag-to-Applications).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP=build/Sendbay.app
DMG="build/Sendbay-${VERSION}.dmg"
STAGE=build/dmg

[ -d "$APP" ] || VERSION="$VERSION" ./scripts/build-app.sh

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Sendbay" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
