#!/usr/bin/env bash
# Download sherpa-onnx static libs (with onnxruntime) and the diarization models.
# Idempotent: skips anything already present.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TP="$ROOT/third_party/sherpa-onnx"
MODELS="$ROOT/extraResources/diarization-models"

LIBS_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.3/sherpa-onnx-v1.13.3-osx-arm64-static-lib.tar.bz2"
SEG_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
# The static-lib archive ships no headers; the C API header comes from the same tag.
HEADER_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.3/sherpa-onnx/c-api/c-api.h"
EMB_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx"

fetch() {
  local url="$1" dest="$2"
  if [[ -e "$dest" ]]; then
    echo "SKIP $(basename "$dest") (exists)"
    return
  fi
  echo "GET  $url"
  mkdir -p "$(dirname "$dest")"
  code=$(curl -sL -o "$dest.part" -w '%{http_code}' "$url")
  if [[ "$code" != "200" ]]; then
    rm -f "$dest.part"
    echo "ERROR: HTTP $code for $url" >&2
    exit 1
  fi
  mv "$dest.part" "$dest"
}

if [[ ! -f "$TP/lib/libsherpa-onnx-c-api.a" ]]; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  fetch "$LIBS_URL" "$TMP/sherpa-libs.tar.bz2"
  mkdir -p "$TP"
  tar -xjf "$TMP/sherpa-libs.tar.bz2" -C "$TP" --strip-components=1
  echo "Extracted static libs to $TP"
else
  echo "SKIP sherpa-onnx static libs (exists)"
fi

fetch "$HEADER_URL" "$TP/include/c-api.h"

mkdir -p "$MODELS"
if [[ ! -f "$MODELS/segmentation.onnx" ]]; then
  TMP=$(mktemp -d)
  fetch "$SEG_URL" "$TMP/segmentation.tar.bz2"
  tar -xjf "$TMP/segmentation.tar.bz2" -C "$TMP"
  cp "$TMP"/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx "$MODELS/segmentation.onnx"
  rm -rf "$TMP"
else
  echo "SKIP segmentation model (exists)"
fi

fetch "$EMB_URL" "$MODELS/embedding.onnx"

echo ""
echo "Sizes:"
ls -lh "$MODELS" | tail -n +2
echo "Libs: $(ls "$TP/lib" 2>/dev/null | wc -l | tr -d ' ') files, $(du -sh "$TP/lib" 2>/dev/null | cut -f1)"