#!/usr/bin/env bash
# Create a local self-signed code-signing certificate with a stable fake Team ID.
# This lets macOS treat rebuilt Plume.app as the same app for privacy prompts
# (microphone, etc.) instead of a brand-new app on every build.
#
# Usage:
#   bash scripts/create-local-signing-cert.sh
#   # Then trust the cert in Keychain Access and build:
#   PLUME_CODE_SIGN_IDENTITY="Plume Local Signing" bash scripts/build-plume.sh
set -euo pipefail

CERT_NAME="${PLUME_LOCAL_CERT_NAME:-Plume Local Signing}"
TEAM_ID="${PLUME_LOCAL_TEAM_ID:-LOCALTEAM1}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
CERT_PASS="${PLUME_LOCAL_CERT_PASSWORD:-plume}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ${#TEAM_ID} -ne 10 ]]; then
  echo "ERROR: PLUME_LOCAL_TEAM_ID must be exactly 10 characters (macOS Team ID length)."
  exit 1
fi

echo "Creating self-signed certificate '${CERT_NAME}' with Team ID '${TEAM_ID}'..."

openssl req -x509 -newkey rsa:2048 \
  -keyout "$TMP/plume.key" \
  -out "$TMP/plume.cer" \
  -days 3650 \
  -nodes \
  -subj "/CN=${CERT_NAME}/O=Plume/OU=${TEAM_ID}/C=US" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -config <(cat /etc/ssl/openssl.cnf <(printf "\n[req]\ndistinguished_name=req_distinguished_name\nprompt=no\n[req_distinguished_name]\n"))

# macOS Security.framework needs the older PBE algorithms for PKCS#12 import.
openssl pkcs12 -export \
  -out "$TMP/plume.p12" \
  -inkey "$TMP/plume.key" \
  -in "$TMP/plume.cer" \
  -name "$CERT_NAME" \
  -passout pass:"$CERT_PASS" \
  -keypbe PBE-SHA1-3DES \
  -certpbe PBE-SHA1-3DES \
  -macalg SHA1

echo "Importing into login keychain..."
if security import "$TMP/plume.p12" -k "$KEYCHAIN" -P "$CERT_PASS" -T /usr/bin/codesign -T /usr/bin/security 2>/dev/null; then
  echo "Imported successfully."
else
  echo "Import may have failed (certificate may already exist or keychain is locked)."
fi

echo ""
echo "NEXT STEPS:"
echo "1. Open Keychain Access."
echo "2. Choose 'Login' > 'My Certificates'."
echo "3. Find '${CERT_NAME}'."
echo "4. Double-click it, expand Trust, and set 'Code Signing' to 'Always Trust'."
echo "5. Close the cert dialog (you may be asked for your password)."
echo ""
echo "Then build with:"
echo "  PLUME_CODE_SIGN_IDENTITY=\"${CERT_NAME}\" bash scripts/build-plume.sh"
echo ""
echo "Verify with:"
echo "  codesign -dv --verbose=4 build/DerivedData/Build/Products/Release/Plume.app | grep TeamIdentifier"
