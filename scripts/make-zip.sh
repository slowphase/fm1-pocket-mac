#!/bin/bash
# Packs "build/FM-1 Pocket.app" into build/FM1-Pocket-<version>.zip, the download for releases and test builds.
# ditto keeps the app's signature, permissions and extended attributes intact (a plain zip can break them).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.9.0}"
APP="build/FM-1 Pocket.app"
ZIP="build/FM1-Pocket-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
codesign --verify --deep --strict "$APP"
ls -lh "$ZIP"
