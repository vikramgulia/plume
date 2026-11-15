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

# PLUME_RELEASE_SIGNING=1 (set by CI when the Developer ID secrets exist) signs once at the
# end with the hardened runtime, the entitlements and Apple's secure timestamp, so the app
# can be notarized. Otherwise the local/ad-hoc flow below is used.
RELEASE_SIGNING=0
if [[ "${PLUME_RELEASE_SIGNING:-0}" == "1" ]]; then
  RELEASE_SIGNING=1
  if [[ "$IDENTITY" == "-" ]]; then
    echo "ERROR: PLUME_RELEASE_SIGNING=1 needs PLUME_CODE_SIGN_IDENTITY."
    exit 1
  fi
fi

# Self-signed certs can't reach Apple's timestamp servers.
TIMESTAMP_FLAG=""
if [[ "$IDENTITY" != "-" && $RELEASE_SIGNING -eq 0 ]]; then
  TIMESTAMP_FLAG="--timestamp=none"
fi

# Optional version stamping (CI passes these for release builds).
BUILD_SETTINGS=()
[[ -n "${PLUME_MARKETING_VERSION:-}" ]] && BUILD_SETTINGS+=("MARKETING_VERSION=$PLUME_MARKETING_VERSION")
[[ -n "${PLUME_BUILD_NUMBER:-}" ]] && BUILD_SETTINGS+=("CURRENT_PROJECT_VERSION=$PLUME_BUILD_NUMBER")

if [[ $RELEASE_SIGNING -eq 1 ]]; then
  # Signed manually at the end, after the models are copied into the bundle.
  SIGN_SETTINGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="")
else
  SIGN_SETTINGS=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$IDENTITY"
    DEVELOPMENT_TEAM=""
    CODE_SIGNING_ALLOWED=YES
    OTHER_CODE_SIGN_FLAGS="$TIMESTAMP_FLAG"
  )
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
  "${SIGN_SETTINGS[@]}" \
  ${BUILD_SETTINGS[@]+"${BUILD_SETTINGS[@]}"} \
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

xattr -cr "$APP" 2>/dev/null || true
if [[ $RELEASE_SIGNING -eq 1 ]]; then
  codesign --force --options runtime --timestamp \
    --entitlements "$PLUME/Plume/Resources/plume.entitlements" \
    --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  codesign --force --deep --sign "$IDENTITY" $TIMESTAMP_FLAG "$APP" 2>/dev/null || true
fi

echo "Built: $APP"
echo "Run:   open \"$APP\""
