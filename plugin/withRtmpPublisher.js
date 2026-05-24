//
// Expo config plugin for react-native-nitro-rtmp-publisher.
//
// Runs at `expo prebuild` time. Does two things so Expo users don't have to
// touch native projects:
//
//   1. iOS — injects the two vendored HaishinKit podspec lines into the
//      generated `ios/Podfile`. Upstream HaishinKit stopped publishing
//      podspecs to CocoaPods trunk after 2.0.9, so we ship our own and
//      tell CocoaPods to use them. The plugin is idempotent: subsequent
//      prebuilds replace the injected block in-place via @expo's
//      `mergeContents` helper (delimited by tagged `# @generated` markers).
//
//   2. iOS — writes NSCameraUsageDescription / NSMicrophoneUsageDescription
//      ONLY if the user explicitly supplies a string via plugin props.
//      We don't backfill a default — silent string injection is surprising,
//      App Store reviewers reject vague auto-generated copy, and most apps
//      already set these via `expo.ios.infoPlist` in app.json. If neither
//      prop is set we leave Info.plist alone.
//
// Android needs no plugin work — autolinking + the AndroidManifest entries
// in the library handle everything.
//
// Usage in app.json / app.config.js:
//
//   {
//     "expo": {
//       "plugins": [
//         "react-native-nitro-rtmp-publisher"
//       ]
//     }
//   }
//
// Or with per-app permission strings:
//
//   "plugins": [
//     ["react-native-nitro-rtmp-publisher", {
//       "cameraUsage": "Stream live video from your camera.",
//       "microphoneUsage": "Capture audio for live streams."
//     }]
//   ]
//

const { withDangerousMod, withInfoPlist } = require('@expo/config-plugins');
const { mergeContents } = require('@expo/config-plugins/build/utils/generateCode');
const fs = require('fs');
const path = require('path');

const PKG_NAME = 'react-native-nitro-rtmp-publisher';

const PODFILE_INJECTION = `
  # Vendored HaishinKit 2.x podspecs. Upstream stopped publishing to
  # CocoaPods trunk after 2.0.9 — these point at the current 2.2.x tag.
  pod 'HaishinKit',     :podspec => '../node_modules/${PKG_NAME}/podspecs/HaishinKit.podspec'
  pod 'RTMPHaishinKit', :podspec => '../node_modules/${PKG_NAME}/podspecs/RTMPHaishinKit.podspec'
`.trim();

const withPodfilePatch = (config) => {
  return withDangerousMod(config, [
    'ios',
    async (config) => {
      const podfilePath = path.join(
        config.modRequest.platformProjectRoot,
        'Podfile'
      );
      if (!fs.existsSync(podfilePath)) {
        throw new Error(
          `[${PKG_NAME}] ios/Podfile not found at ${podfilePath} — has prebuild run?`
        );
      }
      const before = fs.readFileSync(podfilePath, 'utf8');

      const result = mergeContents({
        tag: PKG_NAME,
        src: before,
        newSrc: PODFILE_INJECTION,
        // Anchor at the first `target '<app>' do` line — the line where
        // RN/Expo Podfiles open the application target block.
        anchor: /target\s+['"][^'"]+['"]\s+do\b/,
        offset: 1, // insert AFTER the matching line, inside the target block
        comment: '#',
      });

      // mergeContents returns didMerge=false / didClear=false in two cases:
      //   (a) the tagged block is already present and matches — idempotent
      //   (b) neither the block nor the anchor was found — failure
      // We distinguish by checking the output for our tag.
      if (!result.contents.includes(`@generated begin ${PKG_NAME}`)) {
        throw new Error(
          `[${PKG_NAME}] couldn't locate a \`target '...' do\` block in ios/Podfile to inject HaishinKit pods. Add them manually — see the README.`
        );
      }

      if (result.contents !== before) {
        fs.writeFileSync(podfilePath, result.contents);
      }
      return config;
    },
  ]);
};

const withPermissions = (config, { cameraUsage, microphoneUsage } = {}) => {
  // Only touch Info.plist when the consumer opts in by passing strings.
  // No-op otherwise: anything the user set via `expo.ios.infoPlist` in
  // app.json stays untouched.
  if (!cameraUsage && !microphoneUsage) {
    return config;
  }
  return withInfoPlist(config, (config) => {
    if (cameraUsage) {
      config.modResults.NSCameraUsageDescription = cameraUsage;
    }
    if (microphoneUsage) {
      config.modResults.NSMicrophoneUsageDescription = microphoneUsage;
    }
    return config;
  });
};

const withRtmpPublisher = (config, props = {}) => {
  config = withPodfilePatch(config);
  config = withPermissions(config, props);
  return config;
};

module.exports = withRtmpPublisher;
