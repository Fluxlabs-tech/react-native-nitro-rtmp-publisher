//
// Expo config plugin for react-native-nitro-rtmp-publisher.
//
// Runs at `expo prebuild` time. Does two things so Expo users don't have to
// touch native projects:
//
//   1. iOS — removes the Podfile blocks that 1.x versions injected (the
//      vendored HaishinKit podspecs and the legacy-RTMP source patch).
//      HaishinKit now comes in as a Swift package through the podspec's
//      `spm_dependency`, so the Podfile needs nothing from this plugin.
//
//   2. iOS — writes NSCameraUsageDescription / NSMicrophoneUsageDescription
//      ONLY if the user explicitly supplies a string via plugin props.
//      We don't backfill a default — silent string injection is surprising,
//      App Store reviewers reject vague auto-generated copy, and most apps
//      already set these via `expo.ios.infoPlist` in app.json. If neither
//      prop is set we leave Info.plist alone.
//
//   3. iOS — optional live-tier Picture-in-Picture. Set `enablePictureInPicture:
//      true` (ios prop) and the plugin merges the `voip` (and `audio`)
//      UIBackgroundModes into Info.plist so the camera + RTMP stream stay LIVE
//      in the PIP floating window (iPhone iOS 18+ / M1+ iPad). Opt-in by design:
//      `voip` carries App Store Guideline 2.5.4 scrutiny for a one-way
//      broadcaster, and without it iOS PIP simply stays disabled (the frozen
//      tier is disabled by design). Mirrors the Android `enablePictureInPicture`
//      option below — set it on both (or as a common top-level key) for parity.
//
// Android — autolinking + the library's own AndroidManifest entries handle
// permissions and the foreground service automatically. The one optional
// piece is system Picture-in-Picture: set `enablePictureInPicture: true`
// (android prop) and the plugin adds `android:supportsPictureInPicture="true"`
// plus the required `android:configChanges` to the host launcher activity at
// prebuild time (Expo has no first-class app.json field for these).
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
//         "enablePictureInPicture": true    // add voip+audio bg modes (live PIP)
//       },
//       "android": {
//         "disableForegroundService": true, // opt out of the FG service
//         "enablePictureInPicture": true    // add system PIP to the activity
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
// `legacyRtmpCompatibility` is no longer a plugin option: since 2.0 it is a
// prop on RtmpPublisherView, and passing it here only prints a warning. With
// the prop on, the publisher sends the FMLE releaseStream/FCPublish commands
// itself, without waiting for replies. Without it, publishing to legacy Flash-Media-
// Server-style ingests (e.g. Agora RTLS, fmsVer FMS/3,0,1,123) stalls ~15s
// because those servers never reply to those commands and HaishinKit awaits
// them before sending createStream. Most ingests (YouTube, Twitch,
// Facebook/Instagram, OBS-relay, Wowza) don't need it, so it's off by
// default. Harmless when enabled against modern servers. See README.md.
//

const {
  AndroidConfig,
  WarningAggregator,
  withAndroidManifest,
  withDangerousMod,
  withGradleProperties,
  withInfoPlist,
} = require('@expo/config-plugins');
const { removeContents } = require('@expo/config-plugins/build/utils/generateCode');
const fs = require('fs');
const path = require('path');

const PKG_NAME = 'react-native-nitro-rtmp-publisher';

// HaishinKit comes in as a Swift package (`spm_dependency` in the podspec), so
// the Podfile needs nothing from this plugin. Earlier versions injected two
// tagged blocks (the vendored HaishinKit podspecs and the legacy-RTMP source
// patch); remove them, so a prebuild without --clean doesn't point CocoaPods at
// podspecs that no longer exist.
const withPodfileCleanup = (config) => {
  return withDangerousMod(config, [
    'ios',
    async (config) => {
      const podfilePath = path.join(
        config.modRequest.platformProjectRoot,
        'Podfile'
      );
      if (!fs.existsSync(podfilePath)) {
        return config;
      }
      const before = fs.readFileSync(podfilePath, 'utf8');
      let contents = before;
      for (const tag of [PKG_NAME, `${PKG_NAME}-legacy-rtmp`]) {
        contents = removeContents({ src: contents, tag }).contents;
      }
      if (contents !== before) {
        fs.writeFileSync(podfilePath, contents);
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

// Opt-in (iOS): enable the live-tier Picture-in-Picture background modes. iOS
// keeps the camera + RTMP stream live in the PIP floating window only when the
// app declares the `voip` UIBackgroundMode (iPhone iOS 18+ / M1+ iPad); `audio`
// is the base mode background streaming already needs, so we ensure both. The
// library then flips `AVCaptureSession.isMultitaskingCameraAccessEnabled` at
// runtime where supported. Mirrors the Android `enablePictureInPicture` option.
//
// Merges into whatever UIBackgroundModes the app already declares (e.g. via
// `expo.ios.infoPlist`) — never replaces — and is idempotent across prebuilds.
//
// ⚠️ Strictly opt-in: `voip` is intended for VoIP / video-conferencing apps and
// carries App Store Guideline 2.5.4 scrutiny for a one-way broadcaster. Omit the
// flag and iOS PIP stays disabled (no review risk); Android PIP is unaffected.
const IOS_PIP_BACKGROUND_MODES = ['audio', 'voip'];

const withIosPictureInPicture = (config, { enablePictureInPicture } = {}) => {
  if (!enablePictureInPicture) {
    return config;
  }
  return withInfoPlist(config, (config) => {
    const existing = Array.isArray(config.modResults.UIBackgroundModes)
      ? config.modResults.UIBackgroundModes
      : [];
    config.modResults.UIBackgroundModes = Array.from(
      new Set([...existing, ...IOS_PIP_BACKGROUND_MODES])
    );
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

// configChanges the system fires when entering/leaving PIP. The host activity
// must declare it absorbs these, otherwise Android RECREATES the activity on
// the transition (camera restarts, RN remounts). Merged into — never replacing
// — whatever Expo already put on the activity.
const PIP_CONFIG_CHANGES = [
  'keyboard',
  'keyboardHidden',
  'orientation',
  'screenLayout',
  'screenSize',
  'smallestScreenSize',
  'uiMode',
];

// Opt-in (Android): add system Picture-in-Picture support to the host launcher
// activity. Sets `android:supportsPictureInPicture="true"` and merges the PIP
// configChanges. Without this, the `pictureInPictureEnabled` prop / methods
// can't take effect (the OS rejects PIP for an activity that doesn't declare
// support) and the activity gets recreated on the transition. Idempotent.
const withAndroidPictureInPicture = (config, { enablePictureInPicture } = {}) => {
  if (!enablePictureInPicture) {
    return config;
  }
  return withAndroidManifest(config, (config) => {
    const activity = AndroidConfig.Manifest.getMainActivityOrThrow(
      config.modResults
    );
    activity.$ = activity.$ || {};
    activity.$['android:supportsPictureInPicture'] = 'true';
    const existing = (activity.$['android:configChanges'] || '')
      .split('|')
      .map((s) => s.trim())
      .filter(Boolean);
    activity.$['android:configChanges'] = Array.from(
      new Set([...existing, ...PIP_CONFIG_CHANGES])
    ).join('|');
    return config;
  });
};

// `legacyRtmpCompatibility` was a plugin option in 1.x, where it patched
// HaishinKit's source at pod install. Since 2.0 it is a prop on
// RtmpPublisherView, read when a stream starts. An app that still passes the
// option would silently lose the behaviour, so say so at prebuild.
const withLegacyRtmpCompatibility = (
  config,
  { legacyRtmpCompatibility } = {}
) => {
  if (legacyRtmpCompatibility !== undefined) {
    WarningAggregator.addWarningIOS(
      PKG_NAME,
      'The "legacyRtmpCompatibility" plugin option does nothing since 2.0. Pass the legacyRtmpCompatibility prop to RtmpPublisherView instead.'
    );
  }
  return config;
};

const withRtmpPublisher = (config, props = {}) => {
  const { ios = {}, android = {}, ...common } = props;
  const iosProps = { ...common, ...ios };
  const androidProps = { ...common, ...android };

  config = withPodfileCleanup(config);
  config = withPermissions(config, iosProps);
  config = withIosPictureInPicture(config, iosProps);
  config = withFgsOptOut(config, androidProps);
  config = withAndroidPictureInPicture(config, androidProps);
  config = withLegacyRtmpCompatibility(config, iosProps);
  return config;
};

module.exports = withRtmpPublisher;
