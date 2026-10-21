#!/usr/bin/env bash
# Generate Xcode project and run Plume unit tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Plume"
xcodegen generate
xcodebuild -project Plume.xcodeproj -scheme Plume \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:PlumeTests test \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES
