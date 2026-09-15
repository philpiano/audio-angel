#!/bin/bash
# Builds Audio Angel.app with only the Command Line Tools (no Xcode needed).
#
#   ./build.sh          test the engine, then build build/Audio Angel.app
#   ./build.sh test     engine self-test only
#
# This script is the tested way to build. Package.swift is there for opening
# the project in Xcode; that route hasn't been tested.
set -euo pipefail
cd "$(dirname "$0")"

ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos13.0"
OUT="build"
OBJ="$OUT/obj"
APP="$OUT/Audio Angel.app"
mkdir -p "$OBJ"

echo "› Compiling the real-time engine (C)"
clang -std=c11 -O2 -Wall -Wextra -Werror -target "$TARGET" \
    -I Sources/RouterCore/include \
    -c Sources/RouterCore/router_core.c -o "$OBJ/router_core.o"

echo "› Engine self-test"
clang -std=c11 -O2 -Wall -target "$TARGET" \
    -I Sources/RouterCore/include \
    Sources/RouterCoreSelfTest/main.c "$OBJ/router_core.o" \
    -framework CoreAudio -o "$OBJ/RouterCoreSelfTest"
"$OBJ/RouterCoreSelfTest"

[ "${1:-}" = "test" ] && exit 0

echo "› Compiling the app (Swift)"
swiftc -O -parse-as-library -target "$TARGET" \
    -I Sources/RouterCore/include \
    Sources/AudioAngel/*.swift "$OBJ/router_core.o" \
    -framework CoreAudio -framework AVFoundation -framework AppKit -framework SwiftUI \
    -o "$OBJ/AudioAngel"

echo "› Packaging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OBJ/AudioAngel" "$APP/Contents/MacOS/AudioAngel"
cp Resources/Logo.png "$APP/Contents/Resources/Logo.png"

# The app icon, generated from the logo at every size macOS asks for.
ICONSET="$OBJ/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/Logo.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/Logo.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Audio Angel</string>
    <key>CFBundleDisplayName</key><string>Audio Angel</string>
    <key>CFBundleIdentifier</key><string>com.philipwarda.audioangel</string>
    <key>CFBundleExecutable</key><string>AudioAngel</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>NSHumanReadableCopyright</key><string>Created by Philip Warda with the instrumental help of Claude Opus 5.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Audio Angel routes your microphone, piano and other audio inputs to Zoom and your headphones.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for macOS to run it locally.
codesign --force --sign - "$APP"

# The bundle is rebuilt at the same path each time, so macOS keeps showing
# whatever icon it cached first. Touch it and re-register it with Launch
# Services so Finder and the Dock pick up changes.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo
echo "Built: $APP"
echo "Run it:  open \"$APP\""
