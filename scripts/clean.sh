#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rm -rf \
  "$ROOT/build/DerivedData" \
  "$ROOT/dist" \
  "$ROOT/Plume/Plume.xcodeproj/xcuserdata"
echo "Cleaned build artifacts."
