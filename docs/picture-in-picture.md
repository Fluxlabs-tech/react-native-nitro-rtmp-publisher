# Picture-in-Picture

System Picture-in-Picture — the OS floating window with the camera preview inside. The **JS API is identical on both platforms**, but the runtime behavior differs because iOS restricts camera capture in the background:

| Capability | Android | iOS |
|---|---|---|
| PIP available | every device | **iPhone iOS 18+ (host declares `voip`) / M1+ iPad only** — disabled on older iOS / pre-M1 iPad |
| Camera **live** in PIP + stream keeps publishing | **yes, every device** (via the foreground service) | **yes** — it's the only tier offered (camera stays live, stream keeps publishing) |

**API** (same on both platforms):

| Method | Notes |
|---|---|
| `enterPictureInPicture(): boolean` | Request PIP now. Use for a manual button (and the Android 8–11 path). Returns `false` if PIP is unsupported, disabled for the app in system settings, there's no host Activity, or it's already active. (iOS may defer the actual start until the window is ready and still return `true`.) |
| `isInPictureInPicture(): boolean` | `true` while in the PIP window. |
| `setOnPictureInPictureChange(cb: (isInPip: boolean) => void): void` | Fires `true` on enter, `false` on exit (delivered on the JS thread). Use it to hide overlays/controls while in PIP. |

Set **`pictureInPictureEnabled`** to arm **auto-enter on background** (Android API 31+ via `setAutoEnterEnabled`; iOS via `canStartPictureInPictureAutomaticallyFromInline`). The floating window uses the **device's screen aspect ratio**.

## Android setup

**Manifest** — the host activity must declare PIP support and absorb the configuration changes PIP fires (otherwise Android recreates the Activity and the camera restarts):

```xml
<activity
  android:name=".MainActivity"
  android:supportsPictureInPicture="true"
  android:configChanges="keyboard|keyboardHidden|orientation|screenSize|screenLayout|smallestScreenSize|uiMode" />
```

> **Expo:** there's no first-class `app.json` field for `supportsPictureInPicture` / `configChanges`, and a plain `expo prebuild` would drop a hand-edited manifest — so the library's config plugin does it for you. Enable it once:
>
> ```json
> {
>   "expo": {
>     "plugins": [
>       ["react-native-nitro-rtmp-publisher", { "enablePictureInPicture": true }]
>     ]
>   }
> }
> ```
>
> The next `expo prebuild` adds `supportsPictureInPicture="true"` and merges the required `configChanges` into your launcher activity (existing entries are preserved). Bare RN apps edit the manifest directly as shown above.
>
> `enablePictureInPicture` is a **common** key — the same flag also arms iOS PIP (see [iOS setup](#ios-setup)). For Android only, scope it: `{ "android": { "enablePictureInPicture": true } }`.

## iOS setup

iOS PIP is built on `AVPictureInPictureController` + an `AVSampleBufferDisplayLayer` (HaishinKit's `PiPHKView`) fed the composited preview frames — the only sanctioned path for live, non-`AVPlayer` content. It works on **iOS 15+** with no extra setup beyond the `audio` background mode you already need for background streaming.

PIP is offered **only on the live tier** — devices where iOS keeps the camera running during multitasking. By design it is **disabled** elsewhere: iOS suspends the camera the moment the app backgrounds (entering PIP *is* backgrounding), so a non-live device could only show a **frozen frame with a paused stream** — a worse experience than no PIP. The library detects this at runtime (`AVCaptureSession.isMultitaskingCameraAccessSupported`) and arms PIP only where it's live.

- **Disabled (no-op):** iPhone **< iOS 18**, any iPhone that doesn't declare the `voip` background mode, and **pre-M1 iPads**. `pictureInPictureEnabled` does nothing and `enterPictureInPicture()` returns `false`. (Android PIP is unaffected.)
- **Enabled (live):** **iPhone iOS 18+** with `voip` in `UIBackgroundModes`, and **M1+ iPads** — the camera stays live and the RTMP stream keeps publishing in the floating window. Opt in by adding the `voip` background mode:

  ```json
  // app.json → expo.ios.infoPlist
  "UIBackgroundModes": ["audio", "voip"]
  ```

  > **Expo:** rather than editing `infoPlist` by hand, enable the plugin option — it merges `voip` + `audio` into `UIBackgroundModes` at prebuild time (parity with the Android option, and any modes you already declare are preserved):
  >
  > ```json
  > {
  >   "expo": {
  >     "plugins": [
  >       ["react-native-nitro-rtmp-publisher", { "enablePictureInPicture": true }]
  >     ]
  >   }
  > }
  > ```
  >
  > This is the same **common** `enablePictureInPicture` key shown in [Android setup](#android-setup) — one flag arms PIP on **both** platforms. For iOS only, scope it: `{ "ios": { "enablePictureInPicture": true } }`.

  The library then enables `AVCaptureSession.isMultitaskingCameraAccessEnabled` automatically where supported — no entitlement needed on iOS 18+.

  > ⚠️ **App Store note:** `voip` is intended for VoIP / video-conferencing apps; declaring it on a one-way broadcaster carries some **Guideline 2.5.4** review scrutiny. If you don't add `voip` (manually or via the plugin option), iOS PIP simply stays disabled — no review risk, and Android PIP still works everywhere.

> **Keep the keyboard off the streaming screen.** A focused `TextInput` under a `KeyboardAvoidingView` (`behavior="height"`) can mis-size the preview while in PIP (it sizes from screen metrics, not the small PIP window). Edit text such as the RTMP URL in a separate modal or bottom sheet so its keyboard lives in its own window — see the URL sheet in [`example/src/ui/StreamOverlay.android.tsx`](../example/src/ui/StreamOverlay.android.tsx) and [example/App.tsx](../example/App.tsx).

```ts
<RtmpPublisherView ... pictureInPictureEnabled={true} hybridRef={hybridRef} />

// hide your overlays while the floating window is showing
ref.setOnPictureInPictureChange((inPip) => setControlsVisible(!inPip))

// optional manual trigger (also the Android 8–11 path)
ref.enterPictureInPicture()
```
