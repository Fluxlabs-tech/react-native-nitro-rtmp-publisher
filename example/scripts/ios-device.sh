#!/usr/bin/env bash
#
# Build + install + launch on a real iOS device.
#
# Why this exists:
#  - `expo run:ios` hits "TypeError: Cannot convert object to primitive value"
#    on iOS 16 devices (Expo CLI's LockdowndClient bug).
#  - `react-native-xcode.sh` unconditionally sets `DEV=true` for Debug builds,
#    which embeds a dev-mode bundle that fails with "Cannot create devtools
#    websocket connections in embedded environments" when no Metro is reachable.
#
# What this does:
#  1. xcodebuild Debug-iphoneos for the given UDID
#  2. Rebuild the JS bundle as production (`--dev false`)
#  3. Compile to Hermes bytecode and overwrite the .app's main.jsbundle
#  4. Install + launch via ios-deploy (works for iOS 13+ devices)
#
# Usage:
#   npm run ios:device -- <UDID>
#   UDID=d3657ae676d9b2ae98f67fb1f28dad1369e53cc7 npm run ios:device
#
# Optional env vars:
#   DEVELOPMENT_TEAM   default: 54ZWJ39Z23
#   SCHEME             default: example
#   WORKSPACE          default: ios/example.xcworkspace
#   BUNDLE_ID          default: com.fluxlabs.rtmppublisherexample

set -euo pipefail

UDID="${1:-${UDID:-}}"
if [[ -z "$UDID" ]]; then
  echo "Usage: npm run ios:device -- <UDID>"
  echo "List devices with: xcrun xctrace list devices"
  exit 1
fi

DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-54ZWJ39Z23}"
SCHEME="${SCHEME:-example}"
WORKSPACE="${WORKSPACE:-ios/example.xcworkspace}"
BUNDLE_ID="${BUNDLE_ID:-com.fluxlabs.rtmppublisherexample}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "▸ 1/4  xcodebuild Debug for device $UDID"
xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "platform=iOS,id=$UDID" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  build \
  | xcpretty --simple --color 2>/dev/null \
  || xcodebuild \
      -workspace "$WORKSPACE" \
      -scheme "$SCHEME" \
      -configuration Debug \
      -destination "platform=iOS,id=$UDID" \
      -allowProvisioningUpdates \
      DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
      CODE_SIGN_STYLE=Automatic \
      build \
      -quiet

# Locate the produced .app in DerivedData.
DD_DIR="$HOME/Library/Developer/Xcode/DerivedData"
APP_PATH="$(find "$DD_DIR" -name "$SCHEME.app" -path "*Debug-iphoneos*" -type d -print0 \
            | xargs -0 ls -dt 2>/dev/null | head -1)"
if [[ -z "$APP_PATH" ]]; then
  echo "✗ Couldn't find $SCHEME.app under DerivedData"
  exit 1
fi
echo "▸ 1/4  done. App at: $APP_PATH"

echo "▸ 2/4  Re-bundle JS as production (__DEV__=false, minified)"
PROD_JS="/tmp/${SCHEME}-prod-bundle.js"
ASSETS_DIR="/tmp/${SCHEME}-prod-assets"
rm -f "$PROD_JS"
rm -rf "$ASSETS_DIR"
npx expo export:embed \
  --platform ios \
  --dev false \
  --minify true \
  --bundle-output "$PROD_JS" \
  --assets-dest "$ASSETS_DIR" \
  --entry-file ./node_modules/expo/AppEntry.js

echo "▸ 3/4  Compile to Hermes bytecode and overwrite the .app's main.jsbundle"
HERMESC="$ROOT_DIR/node_modules/hermes-compiler/hermesc/osx-bin/hermesc"
if [[ ! -x "$HERMESC" ]]; then
  echo "✗ hermesc not found at $HERMESC"
  exit 1
fi
"$HERMESC" -emit-binary -out "$APP_PATH/main.jsbundle" "$PROD_JS"

# Copy bundled assets into the .app so any required PNGs/fonts resolve.
if [[ -d "$ASSETS_DIR" ]]; then
  rsync -a "$ASSETS_DIR/" "$APP_PATH/assets/"
fi

echo "▸ 4/4  Install + launch via ios-deploy"
if ! command -v ios-deploy >/dev/null 2>&1; then
  echo "✗ ios-deploy not installed. Run: npm i -g ios-deploy"
  exit 1
fi
set +e
ios-deploy --id "$UDID" --bundle "$APP_PATH" --justlaunch --debug 2>&1 \
  | grep -vE "^\(lldb\) +command|^\(lldb\) +script|^\(lldb\) +target|^\(lldb\) +process|^\(lldb\) +connect$|^\(lldb\) +run$" \
  | tail -20 \
  || true
IOS_DEPLOY_EXIT=${PIPESTATUS[0]}
set -e

if [[ "$IOS_DEPLOY_EXIT" -ne 0 ]]; then
  echo "✗ ios-deploy exited with code $IOS_DEPLOY_EXIT"
  exit "$IOS_DEPLOY_EXIT"
fi

echo "✓ Done. App launched on $UDID."
