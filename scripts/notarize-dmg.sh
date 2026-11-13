#!/usr/bin/env bash
# Submit a signed DMG to Apple's notary service, wait for the result, and staple the ticket.
#
# Usage: APPLE_API_KEY_P8=<base64 .p8> APPLE_API_KEY_ID=<id> APPLE_API_ISSUER_ID=<uuid> \
#          bash scripts/notarize-dmg.sh dist/Plume-1.0.0-arm64.dmg
set -euo pipefail

DMG="${1:?usage: notarize-dmg.sh path/to/Plume.dmg}"
: "${APPLE_API_KEY_P8:?APPLE_API_KEY_P8 (base64 of the App Store Connect API key .p8) is required}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required}"
: "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID is required}"

KEY_DIR="$(mktemp -d)"
trap 'rm -rf "$KEY_DIR"' EXIT
KEY="$KEY_DIR/AuthKey_${APPLE_API_KEY_ID}.p8"
printf '%s' "$APPLE_API_KEY_P8" | base64 --decode > "$KEY"

xcrun notarytool submit "$DMG" \
  --key "$KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" \
  --wait --timeout 30m

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "Notarized and stapled: $DMG"
