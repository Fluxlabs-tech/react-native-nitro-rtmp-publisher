#!/usr/bin/env bash
#
# Host verification for the iOS beauty pipeline. No device, no Xcode project.
#
# Five checks, each guarding a failure that is INVISIBLE to code review. Three of
# them caught real bugs during the port:
#
#  1. CIBoxBlur FOOTPRINT. Its `radius` is not the box half-width — the effective
#     tap count is 2*floor((radius-1)/2)+1, so radius 1-2 do NOTHING and 3-4 both
#     give 3 taps. The first version of the pipeline passed the half-widths (2 and
#     4), which made the narrow variance exactly zero and the wide window 3x3
#     instead of 9x9. The guided filter silently became a noise AMPLIFIER while
#     still producing a plausible-looking image. Undocumented OS behaviour, so it
#     is asserted rather than trusted.
#
#  2. CIColorCube AXIS ORDER, through the real matchedFromWorkingSpace -> cube ->
#     matchedToWorkingSpace chain. Check 5 cannot catch a transposed axis (both
#     sides share an ordering), so the primaries are probed explicitly: with r/b
#     swapped, pure red returns blue's grade. Also confirms plain CIColorCube
#     applies no colour conversion of its own.
#
#  3. COMPOSITE FIDELITY. The three-band reconstruction diffed against Android's
#     beauty_composite_fragment.glsl, transcribed independently on the CPU, over
#     skin / edge / off-skin / highlight / hair cases. Catches a mistyped constant
#     — every one of them was measured by Herin, not chosen by taste.
#
#  4. END-TO-END BEHAVIOUR on uncorrelated grain at three skin tones, in a
#     CIContext configured like HaishinKit's so fp16 behaves as it will on device.
#     Fails if the pipeline amplifies grain instead of suppressing it, which is
#     what both a broken box footprint and a precision regression look like.
#     (Reconstructing variance as E[u^2] - (E[y]-0.5)^2 fails here: at light-skin
#     luma fp16's step in E[y] exceeds the variance being measured.)
#
#  5. LUT PAYLOAD. All 65,536 cube entries from the embedded base64 diffed against
#     android/src/main/res/raw/lut_looks.png read by a separate Node decoder. This
#     is what proves iOS and Android grade from identical data.
#
# Says nothing about GPU cost or how it LOOKS — both need a device.
#
# Usage: npm run verify:beauty-ios

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

command -v xcrun >/dev/null 2>&1 || {
  echo "✗ xcrun not found — needs macOS + Xcode command-line tools"; exit 1; }

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
PROBE="$BUILD_DIR/check"

xcrun swiftc -O -o "$PROBE" \
  ios/BeautyGuidedPipeline.swift \
  ios/BeautyLookCube.swift \
  ios/BeautyLookAtlas.swift \
  scripts/beauty-ios-check/main.swift

# Checks 1-4 run in-process; 5 needs the Node reference to diff against.
"$PROBE" "$ROOT_DIR"

echo ""
echo "5. LUT payload vs lut_looks.png (65,536 entries, independent decoders)"
"$PROBE" --dump-cube > "$BUILD_DIR/swift.txt"
node scripts/beauty-lut.mjs --emit-cube > "$BUILD_DIR/node.txt"
if diff -q "$BUILD_DIR/swift.txt" "$BUILD_DIR/node.txt" >/dev/null; then
  echo "   every entry matches the atlas Android samples  ok"
else
  echo "   ✗ embedded payload disagrees with lut_looks.png:"
  diff "$BUILD_DIR/swift.txt" "$BUILD_DIR/node.txt" | head -20
  echo "   (regenerate with: node scripts/beauty-lut.mjs --emit-swift)"
  exit 1
fi
