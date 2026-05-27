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
// Or with options. Options are grouped by platform — `ios` and `android`
// sub-objects hold platform-specific options; any key at the top level is
// treated as "common" and applied to both platforms (a platform sub-object
// key wins over a top-level key of the same name on that platform):
//
//   "plugins": [
//     ["react-native-nitro-rtmp-publisher", {
//       "ios": {
//         "cameraUsage": "Stream live video from your camera.",
//         "microphoneUsage": "Capture audio for live streams.",
//         "legacyRtmpCompatibility": true   // legacy-FMS RTMP connect fix
//       },
//       "android": {
//         "disableForegroundService": true  // opt out of the FG service
//       }
//     }]
//   ]
//
// Setting `disableForegroundService: true` writes
// `nitroRtmpPublisherFgs=false` into android/gradle.properties at prebuild
// time. The library then builds with a stripped Android manifest (no FGS
// permissions, no <service> declaration) so Play Console doesn't require
// the "Foreground services" form. The trade-off is that streams cannot
// survive backgrounding on Android 14+. See README.md.
//
// Setting `legacyRtmpCompatibility: true` (iOS only, default false) injects
// a post_install hook into ios/Podfile that patches HaishinKit's
// RTMPStream.createStream() to fire the FMLE releaseStream/FCPublish
// commands fire-and-forget. Without it, publishing to legacy Flash-Media-
// Server-style ingests (e.g. Agora RTLS, fmsVer FMS/3,0,1,123) stalls ~15s
// because those servers never reply to those commands and HaishinKit awaits
// them before sending createStream. Most ingests (YouTube, Twitch,
// Facebook/Instagram, OBS-relay, Wowza) don't need it, so it's off by
// default. Harmless when enabled against modern servers. See README.md.
//

const {
  withDangerousMod,
  withGradleProperties,
  withInfoPlist,
} = require('@expo/config-plugins');
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

// Toggles the Android FGS opt-out. Writes `nitroRtmpPublisherFgs=false` into
// android/gradle.properties when `disableForegroundService: true`. The
// library's android/build.gradle reads this property at build time and swaps
// to the stripped manifest (no FOREGROUND_SERVICE_* perms, no <service>).
//
// Idempotent: replaces an existing entry with the new value rather than
// duplicating. When the flag is omitted or false we don't touch the file —
// gradle.properties stays clean for users who never need this.
const FGS_GRADLE_KEY = 'nitroRtmpPublisherFgs';

const withFgsOptOut = (config, { disableForegroundService } = {}) => {
  if (!disableForegroundService) {
    return config;
  }
  return withGradleProperties(config, (config) => {
    const existing = config.modResults.findIndex(
      (item) => item.type === 'property' && item.key === FGS_GRADLE_KEY
    );
    const entry = { type: 'property', key: FGS_GRADLE_KEY, value: 'false' };
    if (existing >= 0) {
      config.modResults[existing] = entry;
    } else {
      config.modResults.push(entry);
    }
    return config;
  });
};

// Opt-in iOS fix for legacy Flash-Media-Server-style RTMP ingests (e.g.
// Agora RTLS). Injects a post_install hook into ios/Podfile that rewrites
// HaishinKit RTMPStream.createStream() so the FMLE releaseStream/FCPublish
// calls are fire-and-forget detached Tasks instead of `async let _` bindings
// (which Swift implicitly awaits at the end of the enclosing `if`, blocking
// createStream ~15s on servers that never reply to those commands).
//
// Why a post_install hook and not the podspec's prepare_command: a
// prepare_command always runs and its output is baked into the CocoaPods
// download cache (keyed by git tag, not by our flag), so it can't be toggled
// per-app and would leak across projects sharing the cache. post_install
// runs on every `pod install` against the freshly-laid-down Pods/ tree, so
// it's both opt-in and cache-immune. The patch is idempotent (skips if
// already applied) and a no-op if upstream renames the lines on a bump.
const PODFILE_LEGACY_RTMP_PATCH = `  rtmp_hk_stream = File.join(__dir__, 'Pods', 'RTMPHaishinKit', 'RTMPHaishinKit', 'Sources', 'RTMP', 'RTMPStream.swift')
  if File.exist?(rtmp_hk_stream)
    rtmp_src = File.read(rtmp_hk_stream)
    rtmp_orig = rtmp_src.dup
    {
      'async let _ = connection?.call("releaseStream", arguments: fcPublishName)' =>
        'Task { _ = try? await connection?.call("releaseStream", arguments: fcPublishName) }',
      'async let _ = connection?.call("FCPublish", arguments: fcPublishName)' =>
        'Task { _ = try? await connection?.call("FCPublish", arguments: fcPublishName) }',
    }.each do |rtmp_from, rtmp_to|
      next if rtmp_src.include?(rtmp_to)
      rtmp_src = rtmp_src.sub(rtmp_from, rtmp_to) if rtmp_src.include?(rtmp_from)
    end
    # Only write when something actually changed — and make the file writable
    # first. CocoaPods lays pod sources down read-only on CI (e.g. EAS Build),
    # so an unconditional File.write fails with EACCES. Skipping the write when
    # already patched also keeps idempotent re-runs from touching a RO file.
    if rtmp_src != rtmp_orig
      File.chmod(0644, rtmp_hk_stream) rescue nil
      File.write(rtmp_hk_stream, rtmp_src)
    end
  end`;

const withLegacyRtmpCompatibility = (
  config,
  { legacyRtmpCompatibility } = {}
) => {
  if (!legacyRtmpCompatibility) {
    return config;
  }
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
        tag: `${PKG_NAME}-legacy-rtmp`,
        src: before,
        newSrc: PODFILE_LEGACY_RTMP_PATCH,
        // Insert as the first statements inside the existing post_install
        // block — by then every pod is downloaded into Pods/.
        anchor: /post_install do \|[^|]*\|/,
        offset: 1,
        comment: '#',
      });

      if (!result.contents.includes(`@generated begin ${PKG_NAME}-legacy-rtmp`)) {
        throw new Error(
          `[${PKG_NAME}] couldn't find a \`post_install do |installer|\` block in ios/Podfile to inject the legacy-RTMP compatibility patch. Add it manually — see the README.`
        );
      }

      if (result.contents !== before) {
        fs.writeFileSync(podfilePath, result.contents);
      }
      return config;
    },
  ]);
};

// Props are grouped by platform: `ios` / `android` sub-objects carry
// platform-specific options, and any remaining top-level key is "common" and
// applied to both platforms. A platform key overrides a common key of the
// same name. Each modifier below is inherently single-platform, so we hand it
// the merged set for its platform and it picks out the keys it cares about.
const withRtmpPublisher = (config, props = {}) => {
  const { ios = {}, android = {}, ...common } = props;
  const iosProps = { ...common, ...ios };
  const androidProps = { ...common, ...android };

  config = withPodfilePatch(config);
  config = withPermissions(config, iosProps);
  config = withFgsOptOut(config, androidProps);
  config = withLegacyRtmpCompatibility(config, iosProps);
  return config;
};

module.exports = withRtmpPublisher;
