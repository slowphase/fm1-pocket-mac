#!/bin/bash
# Builds "build/FM-1 Pocket.app" (Apple Silicon) from the Swift package and signs it ad hoc (no Apple account needed).
#   VERSION=0.9.0 BUILD_NUMBER=1 scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.9.1}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP="build/FM-1 Pocket.app"

swift build -c release --arch arm64 --product FM1Pocket
BIN="$(swift build -c release --arch arm64 --show-bin-path)/FM1Pocket"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FM1Pocket"
cp Resources/h1.rfm1 "$APP/Contents/Resources/h1.rfm1"
# emu blocks for a catalogue that does not publish them yet (ignored once Pocket does; see CatalogueV2.withPreview)
# (left out of release builds: NO_PREVIEW=1)
if [ -z "${NO_PREVIEW:-}" ] && [ -f Resources/emu-preview.json ]; then
  cp Resources/emu-preview.json "$APP/Contents/Resources/emu-preview.json"
fi
cp THIRD-PARTY-NOTICES.md LICENSE "$APP/Contents/Resources/"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"   # the app icon (scripts/make-icon.py)
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
lipo -info "$APP/Contents/MacOS/FM1Pocket"
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
