#!/usr/bin/env bash
# Build Plume.app (requires full Xcode) and copy ffmpeg into Resources.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUME="$ROOT/Plume"
CONFIG="${1:-Release}"
DERIVED="$ROOT/build/DerivedData"
IDENTITY="${PLUME_CODE_SIGN_IDENTITY:-Ad-hoc}"

if [[ "$IDENTITY" == "Ad-hoc" ]]; then
  IDENTITY="-"
fi

# Self-signed certs can't reach Apple's timestamp servers.
TIMESTAMP_FLAG=""
if [[ "$IDENTITY" != "-" ]]; then
  TIMESTAMP_FLAG="--timestamp=none"
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "ERROR: Full Xcode is required (xcode-select -s /Applications/Xcode.app)."
  exit 1
fi

mkdir -p "$DERIVED"
cd "$PLUME"
xcodegen generate
xcodebuild \
  -project Plume.xcodeproj \
  -scheme Plume \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -arch arm64 \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="" \
  CODE_SIGNING_ALLOWED=YES \
  OTHER_CODE_SIGN_FLAGS="$TIMESTAMP_FLAG" \
  build

APP="$DERIVED/Build/Products/$CONFIG/Plume.app"
RES="$APP/Contents/Resources"

# Bundle the diarization models when present (fetch with scripts/fetch-sherpa.sh)
MODEL_SRC="$ROOT/extraResources/diarization-models"
if [[ -f "$MODEL_SRC/segmentation.onnx" ]]; then
  mkdir -p "$RES/diarization-models"
  cp "$MODEL_SRC"/*.onnx "$RES/diarization-models/"
else
  echo "NOTE: diarization models not found at $MODEL_SRC — transcripts will be unlabeled."
  echo "      Run: bash scripts/fetch-sherpa.sh"
fi

codesign --force --deep --sign "$IDENTITY" $TIMESTAMP_FLAG "$APP" 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true

echo "Built: $APP"
echo "Run:   open \"$APP\""
