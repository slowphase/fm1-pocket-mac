#!/bin/bash
# Packs "build/FM-1 Pocket.app" into build/FM1-Pocket-<version>.zip, the download for releases and test builds,
# then checks the zip the way a person would install it: unpack it somewhere new and confirm the app is complete,
# its executable is still executable, its signature is intact and it starts.
# ditto keeps the app's signature, permissions and extended attributes intact (a plain zip can break them).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.9.0}"
APP="build/FM-1 Pocket.app"
ZIP="build/FM1-Pocket-$VERSION.zip"
rm -f "$ZIP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
ls -lh "$ZIP"

CHECK="$(mktemp -d)"
ditto -x -k "$ZIP" "$CHECK"
GOT="$CHECK/FM-1 Pocket.app"
test -d "$GOT" || { echo "The zip does not contain 'FM-1 Pocket.app' at its top level"; exit 1; }
list() { (cd "$1" && find . -type f -exec stat -f '%N %z %Lp' {} + | sort); }
diff <(list "$APP") <(list "$GOT") || { echo "The unpacked app differs from the built one (files, sizes or permissions)"; exit 1; }
test -x "$GOT/Contents/MacOS/FM1Pocket" || { echo "The unpacked app's executable lost its execute permission"; exit 1; }
codesign --verify --deep --strict --verbose=2 "$GOT"
"$GOT/Contents/MacOS/FM1Pocket" --selftest "$CHECK/selftest.json" > /dev/null
python3 -c "import json,sys; r=json.load(open(sys.argv[1])); assert r.get('ok') is True, r; print('unpacked app self-test ok')" "$CHECK/selftest.json"
echo "Zip checked: $(list "$GOT" | wc -l | tr -d ' ') files, permissions and signature intact, app starts"
rm -rf "$CHECK"
