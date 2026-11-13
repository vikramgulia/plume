#!/usr/bin/env bash
# Create a simple DMG from a built Plume.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Release}"
APP="$ROOT/build/DerivedData/Build/Products/$CONFIG/Plume.app"
OUT="$ROOT/dist"
VERSION="${PLUME_VERSION:-1.0.0}"

if [[ ! -d "$APP" ]]; then
  echo "Building Plume first…"
  "$ROOT/scripts/build-plume.sh" "$CONFIG"
fi

mkdir -p "$OUT"
STAGE="$OUT/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$OUT/Plume-$VERSION-arm64.dmg"
rm -f "$DMG"
hdiutil create -volname "Plume" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# Sign the disk image itself for release builds (see build-plume.sh); notarize with notarize-dmg.sh.
if [[ "${PLUME_RELEASE_SIGNING:-0}" == "1" ]]; then
  codesign --force --timestamp --sign "${PLUME_CODE_SIGN_IDENTITY:?PLUME_CODE_SIGN_IDENTITY is required}" "$DMG"
fi
echo "DMG: $DMG"
