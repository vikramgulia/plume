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
# Silero voice activity detector, bundled in the app: cuts recordings into speech chunks for Whisper.
VAD_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
VAD_SHA256="9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"
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

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}
fetch "$VAD_URL" "$MODELS/silero_vad.onnx"
if [[ "$(sha256_of "$MODELS/silero_vad.onnx")" != "$VAD_SHA256" ]]; then
  echo "ERROR: silero_vad.onnx does not match its expected checksum" >&2
  rm -f "$MODELS/silero_vad.onnx"
  exit 1
fi

echo ""
echo "Sizes:"
ls -lh "$MODELS" | tail -n +2
echo "Libs: $(ls "$TP/lib" 2>/dev/null | wc -l | tr -d ' ') files, $(du -sh "$TP/lib" 2>/dev/null | cut -f1)"