#!/bin/bash
# Downloads the bundled CLIP model files (~290MB) that are gitignored
# because they exceed GitHub's 100MB per-file limit. Run this once after
# cloning, before `swift build`/`swift run` — the app won't launch without
# these (Search tab's TextEmbedder/ImageEmbedder require them).
#
# Source: InspiratioNULL/CLIP-VIT-B-32-DataComp.XL-CoreML on Hugging Face
# (MIT-licensed Core ML conversion of OpenAI's CLIP ViT-B/32).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Sources/PhotoOrganizer/Resources/CLIPModels"
BASE="https://huggingface.co/InspiratioNULL/CLIP-VIT-B-32-DataComp.XL-CoreML/resolve/main"

mkdir -p "$DEST/ImageEncoder.mlmodelc/weights" "$DEST/ImageEncoder.mlmodelc/analytics"
mkdir -p "$DEST/TextEncoder.mlmodelc/weights" "$DEST/TextEncoder.mlmodelc/analytics"

echo "Downloading ImageEncoder.mlmodelc (~176MB)..."
curl -sL "$BASE/CLIP_ImageEncoder.mlmodelc/coremldata.bin" -o "$DEST/ImageEncoder.mlmodelc/coremldata.bin"
curl -sL "$BASE/CLIP_ImageEncoder.mlmodelc/metadata.json" -o "$DEST/ImageEncoder.mlmodelc/metadata.json"
curl -sL "$BASE/CLIP_ImageEncoder.mlmodelc/model.mil" -o "$DEST/ImageEncoder.mlmodelc/model.mil"
curl -sL "$BASE/CLIP_ImageEncoder.mlmodelc/weights/weight.bin" -o "$DEST/ImageEncoder.mlmodelc/weights/weight.bin"
curl -sL "$BASE/CLIP_ImageEncoder.mlmodelc/analytics/coremldata.bin" -o "$DEST/ImageEncoder.mlmodelc/analytics/coremldata.bin"

echo "Downloading TextEncoder.mlmodelc (~127MB)..."
curl -sL "$BASE/CLIP_TextEncoder.mlmodelc/coremldata.bin" -o "$DEST/TextEncoder.mlmodelc/coremldata.bin"
curl -sL "$BASE/CLIP_TextEncoder.mlmodelc/metadata.json" -o "$DEST/TextEncoder.mlmodelc/metadata.json"
curl -sL "$BASE/CLIP_TextEncoder.mlmodelc/model.mil" -o "$DEST/TextEncoder.mlmodelc/model.mil"
curl -sL "$BASE/CLIP_TextEncoder.mlmodelc/weights/weight.bin" -o "$DEST/TextEncoder.mlmodelc/weights/weight.bin"
curl -sL "$BASE/CLIP_TextEncoder.mlmodelc/analytics/coremldata.bin" -o "$DEST/TextEncoder.mlmodelc/analytics/coremldata.bin"

echo "Done. Verifying sizes..."
find "$DEST/ImageEncoder.mlmodelc" "$DEST/TextEncoder.mlmodelc" -type f -exec ls -la {} \;
