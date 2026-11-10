#!/bin/bash
# Builds build/Sendbay.app (release, arm64) with libusb bundled inside.
# Ad-hoc signed for local use; distribution needs a Developer ID + notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP=build/Sendbay.app
LIBUSB=$(pkg-config --variable=libdir libusb-1.0)/libusb-1.0.0.dylib

swift build -c release --product Sendbay
BIN=$(swift build -c release --show-bin-path)/Sendbay

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sendbay"
cp "$LIBUSB" "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod u+w "$APP/Contents/Frameworks/libusb-1.0.0.dylib"

# Point the binary at the bundled libusb instead of Homebrew's.
OLD=$(otool -L "$APP/Contents/MacOS/Sendbay" | awk '/libusb/ {print $1}')
install_name_tool -change "$OLD" "@executable_path/../Frameworks/libusb-1.0.0.dylib" "$APP/Contents/MacOS/Sendbay"
install_name_tool -id "@executable_path/../Frameworks/libusb-1.0.0.dylib" "$APP/Contents/Frameworks/libusb-1.0.0.dylib"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Sendbay</string>
    <key>CFBundleDisplayName</key><string>Sendbay</string>
    <key>CFBundleIdentifier</key><string>com.hariantara.sendbay</string>
    <key>CFBundleExecutable</key><string>Sendbay</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Sendbay. Portions derived from OpenMTP (MIT) and go-mtpfs (BSD).</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
codesign --force --sign - "$APP"
echo "Built $APP"
