# Android: opting out of the foreground service

By default the library declares these in its AndroidManifest, which auto-merge into your app's APK:

- `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CAMERA`, `FOREGROUND_SERVICE_MICROPHONE`
- `POST_NOTIFICATIONS`
- A `<service>` declaration for `RtmpForegroundService`

These let `<RtmpPublisherView>` keep camera/mic active while the app is in the background — required on Android 14+, otherwise the OS revokes both within ~5 seconds of backgrounding.

The trade-off: any app whose merged manifest carries `FOREGROUND_SERVICE_CAMERA` or `_MICROPHONE` has to fill the **Play Console "Foreground services" declaration form** (with a demo video) before it can publish, *whether or not the service is actually used at runtime*.

**If your app is foreground-only** — kiosk mode, in-app demos, internal tools, anything where the user is always looking at the streaming UI — you can opt out at build time and skip the Play Console form entirely. The library publishes a stripped manifest variant for exactly this case.

## Bare React Native

Add this to your app's `android/gradle.properties`:

```properties
nitroRtmpPublisherFgs=false
```

That's it. The next build uses the stripped manifest — no FGS permissions, no `<service>` declaration. The `foregroundServiceTitle` / `foregroundServiceText` / `foregroundServiceIcon` props become no-ops; the library logs one warning the first time `startStream` is called with a non-empty title so you know it's being ignored.

## Expo (managed)

Pass the option to the config plugin:

```jsonc
{
  "plugins": [
    ["react-native-nitro-rtmp-publisher", {
      "android": {
        "disableForegroundService": true
      }
    }]
  ]
}
```

`expo prebuild` writes the gradle property for you. Re-run prebuild after toggling.

## Trade-off you're accepting

- ✅ No Play Console FGS form required.
- ✅ Smaller permission set in the user's install prompt + system Settings → Apps view.
- ❌ Streams **die when the app backgrounds** on Android 14+ (camera/mic revoked by the OS). Lock screen, app switcher, push-notification tap — all kill the stream.
- ❌ The library's compiled `RtmpForegroundService` class is still in the AAR as dead code (~3 KB). Not worth shipping two AAR variants to remove.

The flag is **build-time only.** If you later need background streaming, you have to publish a new build (manifest entries are baked into the binary). There's no JS-runtime "enable FGS" path.
