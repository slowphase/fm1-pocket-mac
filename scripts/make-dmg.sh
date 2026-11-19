#!/bin/bash
# Packs "build/FM-1 Pocket.app" into build/FM1-Pocket-<version>.dmg, with an Applications shortcut and a note on
# opening an app that is not notarised.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
APP="build/FM-1 Pocket.app"
STAGE="build/dmg"
DMG="build/FM1-Pocket-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "docs/If the app will not open.txt" "$STAGE/"

# hdiutil is occasionally "busy" on CI machines: try a few times
for i in 1 2 3 4 5; do
  if hdiutil create -volname "FM-1 Pocket" -srcfolder "$STAGE" -ov -format UDZO "$DMG"; then break; fi
  echo "hdiutil failed (attempt $i), retrying"; sleep 5
done
test -f "$DMG"
hdiutil verify "$DMG"
codesign --force --sign - "$DMG"
ls -lh "$DMG"
