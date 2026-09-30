#!/bin/bash
# Build Omidi.app: the ring's pitch and roll as a MIDI controller, in its own window.
#   ./build.sh            builds Omidi.app here
#   ./build.sh --open     builds it and starts it
#   ./build.sh --package  builds a copy to share: dist/Omidi.zip (send that file, not the .app)
#
# Needs the open_oura client from the folder above (built by ../setup.sh); override with OURA_BIN.
# Rings are paired inside the app. A developer build also points at ../ring.json (from ../pair.sh,
# override with RING_CONFIG) so a ring paired that way keeps working; a --package build doesn't.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
OURA=${OURA_BIN:-$ROOT/open_oura/target/release/oura}
RING=${RING_CONFIG:-$ROOT/ring.json}
if [ ! -x "$OURA" ]; then
  echo "The ring client isn't built ($OURA). Run ../setup.sh first." >&2
  exit 1
fi
MODE=${1:-}
APP=Omidi.app
if [ "$MODE" = "--package" ]; then
  mkdir -p dist
  APP=dist/Omidi.app
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
# A developer build can pick up a ring paired with ../pair.sh; a shared copy mustn't carry this Mac's paths.
if [ "$MODE" != "--package" ] && [ -f "$RING" ]; then
  /usr/libexec/PlistBuddy -c "Add :RingConfig string $RING" "$APP/Contents/Info.plist"
fi
# The ring client goes inside the app, next to the app's own program.
cp "$OURA" "$APP/Contents/MacOS/oura"
swiftc -O -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  Sources/*.swift -o "$APP/Contents/MacOS/Omidi"
xattr -cr "$APP"  # files from the Desktop or a download carry metadata that codesign refuses
# Ad-hoc signing sometimes fails on the first try; try a few times.
for attempt in 1 2 3; do
  codesign -s - --force "$APP/Contents/MacOS/oura" 2>/dev/null \
    && codesign -s - --force "$APP" 2>/dev/null && break
  [ "$attempt" = 3 ] && { echo "codesign failed: run ./build.sh again" >&2; exit 1; }
  sleep 1
done
echo "Built $(pwd)/$APP"
if [ "$MODE" = "--package" ]; then
  # ditto keeps the app a proper app (folder structure, permissions, signature); plain zips can break it.
  rm -f dist/Omidi.zip
  ditto -c -k --keepParent "$APP" dist/Omidi.zip
  echo "Share this file: $(pwd)/dist/Omidi.zip ($(du -h dist/Omidi.zip | cut -f1))"
fi
if [ "$MODE" = "--open" ]; then
  osascript -e 'quit app "Omidi"' 2>/dev/null || true  # a clean quit also stops the ring
  sleep 2
  open "$APP"
fi
