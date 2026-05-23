<h1 align="center">react-native-nitro-rtmp-publisher</h1>

<p align="center">
  <a href="https://www.npmjs.com/package/react-native-nitro-rtmp-publisher"><img alt="npm" src="https://img.shields.io/npm/v/react-native-nitro-rtmp-publisher.svg"></a>
  <a href="https://www.npmjs.com/package/react-native-nitro-rtmp-publisher"><img alt="downloads" src="https://img.shields.io/npm/dm/react-native-nitro-rtmp-publisher.svg"></a>
  <a href="./LICENSE"><img alt="license" src="https://img.shields.io/npm/l/react-native-nitro-rtmp-publisher.svg"></a>
  <img alt="iOS" src="https://img.shields.io/badge/iOS-13.0%2B-000000.svg?logo=apple">
  <img alt="Android" src="https://img.shields.io/badge/Android-21%2B-3DDC84.svg?logo=android">
  <img alt="Nitro" src="https://img.shields.io/badge/Nitro-Modules-FF6B35.svg">
</p>

<p align="center">
  <strong>High-performance RTMP camera publisher for React Native.</strong><br>
  Native preview, hardware encoding, adaptive bitrate, auto-reconnect, and a tiny JS surface — on both iOS and Android.
</p>

<p align="center">
  Built on <a href="https://nitro.margelo.com">Nitro Modules</a> ·
  Android backed by <a href="https://github.com/pedroSG94/RootEncoder">RootEncoder</a> ·
  iOS backed by <a href="https://github.com/HaishinKit/HaishinKit.swift">HaishinKit</a>
</p>

---

## Why this library

Live streaming from a phone is two hard problems entangled — owning the camera capture pipeline without choking the React Native UI thread, and pushing encoded H.264 over a flaky mobile network. We solve both natively and only touch the JS bridge on real state transitions.

- **Native preview view** — Camera2/Metal + GPU compositor on the C++ thread. Zero React Native UI thread cost per frame.
- **Hardware H.264/HEVC encoding** — `MediaCodec` on Android, `VideoToolbox` on iOS.
- **Adaptive bitrate built in** — measures TX throughput, drops on congestion, recovers on headroom. Or take manual control with `setVideoBitrateOnFly`.
- **Auto-reconnect** — opt-in retry budget that survives the mobile network's mood swings.
- **Type-safe API** — generated end-to-end by Nitrogen. No JSON serialization on the hot path.
- **Opt-in callbacks** — per-second bitrate callback is **off** by default. Subscribe only if you need it.
- **Cross-platform parity** — same JS API on iOS and Android. Platform differences live inside the library, never in your app code.

---

## Table of contents

- [Install](#install)
  - [iOS](#ios)
  - [Android](#android)
- [Quickstart](#quickstart)
- [Permissions](#permissions)
- [Props](#props)
- [Methods](#methods)
  - [Lifecycle](#lifecycle)
  - [Status](#status)
  - [Adaptive bitrate](#adaptive-bitrate)
  - [Auto-reconnect](#auto-reconnect)
  - [Camera selection](#camera-selection)
  - [Audio](#audio)
  - [Torch](#torch)
  - [Zoom](#zoom)
  - [Exposure](#exposure)
  - [Focus](#focus)
  - [Stabilization](#stabilization)
  - [Local recording](#local-recording)
  - [Long-form streams](#long-form-streams)
  - [FPS lock in low light](#fps-lock-in-low-light)
  - [Audio source](#audio-source)
  - [Noise suppression](#noise-suppression)
  - [Thermals](#thermals)
  - [Events](#events)
- [Platform parity](#platform-parity)
- [Performance notes](#performance-notes)
- [Architecture](#architecture)
- [Common pitfalls](#common-pitfalls)
- [Contributing](#contributing)
- [Acknowledgements](#acknowledgements)
- [License](#license)

---

## Install

```sh
npm install react-native-nitro-rtmp-publisher react-native-nitro-modules
# or
yarn add  react-native-nitro-rtmp-publisher react-native-nitro-modules
```

### iOS

Run `pod install` in your `ios/` directory. The library declares HaishinKit as a CocoaPods dependency, so no additional setup is needed.

Add the privacy descriptions to your `Info.plist` so iOS can prompt the user the first time the publisher accesses the camera / microphone:

```xml
<key>NSCameraUsageDescription</key>
<string>Allow $(PRODUCT_NAME) to use the camera for live streaming.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Allow $(PRODUCT_NAME) to use the microphone for live streaming.</string>
```

If you want streaming to continue while the user briefly backgrounds the app, also add:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

**Minimum**: iOS 13. **Xcode**: 15+ recommended.

### Android

The library declares `CAMERA`, `RECORD_AUDIO`, `INTERNET`, `ACCESS_NETWORK_STATE`, `WAKE_LOCK`, and the foreground-service permissions in its own manifest — manifest merging picks these up automatically, so you don't have to repeat them.

You still need to request runtime permissions before mounting the view (see [Permissions](#permissions)).

**Minimum**: `minSdkVersion` 21. **Kotlin**: 1.9+.

---

## Quickstart

```tsx
import { useEffect, useMemo, useRef, useState } from 'react'
import { Alert, StyleSheet, Button, View } from 'react-native'
import { callback } from 'react-native-nitro-modules'
import {
  RtmpPublisherView,
  requestRtmpPermissions,
  type RtmpPublisherViewMethods,
} from 'react-native-nitro-rtmp-publisher'

export default function App() {
  const publisher = useRef<RtmpPublisherViewMethods | null>(null)
  const [ready, setReady] = useState(false)

  // One platform-agnostic permission call — works on iOS and Android.
  useEffect(() => {
    requestRtmpPermissions().then(({ granted }) => {
      if (!granted) Alert.alert('Camera + microphone permissions required')
      setReady(granted)
    })
  }, [])

  const hybridRef = useMemo(
    () => callback((ref: RtmpPublisherViewMethods) => {
      publisher.current = ref

      // Configure encoder BEFORE startPreview (avoids preview/stream race).
      const rotation = ref.getCameraOrientation()
      ref.prepareVideo(1280, 720, 30, 2_500_000, 2, rotation)
      ref.prepareAudio(128_000, 44_100, true)
      ref.startPreview('back', 1280, 720)

      // 5 retries, 3s backoff — survives momentary network drops.
      ref.setAutoReconnect(5, 3000)

      // Adaptive bitrate: cap at 2.5 Mbps, drop 20% on congestion, recover 5%.
      ref.setAdaptiveBitrate(2_500_000, 20, 5)

      ref.setOnConnectionEvent((event, msg) => {
        console.log('rtmp:', event, msg)
      })
    }),
    []
  )

  if (!ready) return <View />

  return (
    <View style={{ flex: 1 }}>
      <RtmpPublisherView
        style={StyleSheet.absoluteFill}
        videoCodec="h264"
        audioCodec="aac"
        aspectRatioMode="adjust"
        audioSource="camcorder"
        streamMode="balanced"
        hybridRef={hybridRef}
      />
      <Button title="Go live" onPress={() =>
        publisher.current?.startStream('rtmp://your-ingest/app/streamKey')
      } />
    </View>
  )
}
```

> **Important** — wrap the `hybridRef` callback in `useMemo([], …)`. If the callback identity changes between renders, the view re-initializes on every render and the camera will thrash open/close.

A fuller example (pinch-to-zoom, event sheet, thermal chip, auto-reconnect) lives in [`example/`](./example).

---

## Permissions

The library ships a single `requestRtmpPermissions()` helper that works on both platforms:

```ts
import { requestRtmpPermissions } from 'react-native-nitro-rtmp-publisher'

const { granted, camera, microphone } = await requestRtmpPermissions()
if (!granted) {
  // surface a UI prompting the user to enable in Settings
}
```

- **Android**: shows the standard `PermissionsAndroid` runtime dialog for `CAMERA` + `RECORD_AUDIO`.
- **iOS**: resolves to `granted: true` immediately. iOS shows the system permission sheet automatically the first time `AVCaptureDevice` opens the camera or microphone — the publisher view stays idle until the user accepts, so it's safe to mount before the user has decided.

If you want to roll your own permission flow (e.g. using `expo-camera`), you can — just make sure both permissions are granted before mounting `<RtmpPublisherView>` on Android. On iOS you can mount anytime.

---

## Props

All props are required (set them once in JSX; runtime mutations are honored where the underlying platform supports it).

| Prop                  | Type                                  | Default     | Description |
|-----------------------|---------------------------------------|-------------|-------------|
| `forceHardwareCodec`  | `boolean`                             | `true`      | **Android-meaningful** — pin both `MediaCodec` encoders to HARDWARE. Silent no-op on iOS (always uses VideoToolbox HW). |
| `videoCodec`          | `'h264' \| 'h265' \| 'av1'`           | `'h264'`    | RTMP servers almost always require H.264. iOS supports `h264`/`h265`; Android adds `av1`. |
| `audioCodec`          | `'aac' \| 'g711' \| 'opus'`           | `'aac'`     | RTMP standard is AAC. Other values are accepted for API parity but only AAC actually publishes over RTMP on iOS. |
| `aspectRatioMode`     | `'fill' \| 'adjust' \| 'none'`        | `'adjust'`  | How the preview maps onto the view bounds. |
| `mirrorPreview`       | `boolean`                             | `false`     | Flip on-screen preview horizontally. |
| `mirrorStream`        | `boolean`                             | `false`     | Flip encoded stream horizontally. |
| `thermalWarningThreshold` | `ThermalStatus`                   | `'severe'`  | Minimum OS thermal level that fires `setOnThermalWarning`. `'none'` disables monitoring entirely. |
| `audioSource`         | `'mic' \| 'camcorder' \| 'voiceRecognition' \| 'voiceCommunication' \| 'unprocessed'` | `'camcorder'` | Capture mode. `'camcorder'` is the right default for live streaming on both platforms. |
| `noiseSuppression`    | `boolean`                             | `false`     | Engage on-device noise suppression + echo cancellation + AGC. See [Noise suppression](#noise-suppression). Best used for talk streams in noisy environments; leave off for vlogs/music. |
| `autoRotateStream`    | `boolean`                             | `true`      | Internal orientation observer auto-updates `setStreamRotation` as the device rotates. Disable for manual control. |
| `streamMode`          | `'lowLatency' \| 'balanced' \| 'quality'` | `'balanced'` | Pipeline preset. See [Long-form streams](#long-form-streams). |
| `foregroundServiceTitle` | `string`                           | `''`        | **Android-only.** If non-empty, a foreground service auto-starts on `startStream` and auto-stops on `stopStream`. Silently ignored on iOS (uses `UIBackgroundModes` from `Info.plist` instead). |
| `foregroundServiceText`  | `string`                           | `''`        | Notification text shown alongside `foregroundServiceTitle`. |

> **Combining `mirrorPreview` and `mirrorStream`** — on the front camera, set both to `true` so the streamer and viewer see the same orientation (selfie convention). On iOS we go through `AVCaptureConnection.isVideoMirrored` for the shared buffer plus a UIView transform for asymmetric cases — see [example/App.tsx](./example/App.tsx) for the canonical setup.

---

## Methods

Call methods imperatively via `hybridRef`. The full ref type is `RtmpPublisherViewMethods`.

### Lifecycle

| Method | Notes |
|---|---|
| `prepareVideo(width, height, fps, bitrate, iFrameInterval, rotation): boolean` | Configure video encoder. Call **before** `startPreview`. Dimensions follow the natural-landscape convention (e.g. `1280, 720`) — the library rotates internally based on `rotation`. |
| `prepareAudio(bitrate, sampleRate, isStereo): boolean` | Configure audio encoder. Call **before** `startPreview`. |
| `startPreview(facing, width, height): void` | Open camera, render frames into the view. |
| `stopPreview(): void` | Release camera. |
| `startStream(url): void` | Begin RTMP publish. Queues until the GL surface is ready, so calling it immediately after `prepareVideo`/`prepareAudio` is safe. |
| `stopStream(): void` | End RTMP publish. |
| `setAuthorization(user, password): void` | Set AMF credentials. Some Wowza / Nimble setups require this. On iOS, the credentials are spliced into the connect URL as `rtmp://user:pass@host/...` at the next `startStream`. |
| `setStreamRotation(rotation): void` | Update encoder rotation mid-session (0/90/180/270). |
| `requestKeyFrame(): void` | Force the next encoded frame to be an IDR. Debounced to ~1Hz. |

### Status

| Method | Returns |
|---|---|
| `isStreaming()` | `boolean` |
| `isOnPreview()` | `boolean` |
| `getCameraOrientation()` | Recommended rotation (degrees) to pass to `prepareVideo`. |
| `getStreamWidth()` / `getStreamHeight()` | Currently configured encoder resolution. |
| `getCurrentBitrate()` | Configured **target** bitrate (bps). For measured TX rate, subscribe to `setOnBitrateChange`. |

### Adaptive bitrate

The library samples the measured TX bitrate every second and adjusts the encoder via `setVideoBitrateOnFly`:
- decreases when congestion is detected (RTMP send-buffer fills up on Android; TX throughput drops on iOS),
- slowly recovers toward `maxBitrate` when the network has headroom.

```ts
// Cap at 2.5 Mbps. On congestion drop 20% of current bitrate; on recovery
// raise 5% per second.
ref.setAdaptiveBitrate(2_500_000, 20, 5)

// Disable
ref.setAdaptiveBitrate(0, 0, 0)
```

`maxBitrate` should match (or be slightly above) the `bitrate` you passed to `prepareVideo`. The adapter resets to the ceiling at every fresh `startStream`.

For full manual control, subscribe to `setOnBitrateChange` and call `setVideoBitrateOnFly(...)` yourself.

### Auto-reconnect

Mobile networks drop. By default the library does NOT retry on its own — opt in:

```ts
// On every `connectionFailed`/`disconnect`, retry up to 5 times with a 3-second
// backoff. Fires a `reconnecting` event right before each retry; if the budget
// runs out you'll get a final `disconnect`.
ref.setAutoReconnect(5, 3000)
```

The retry budget is re-seeded on every fresh `startStream(url)`. Calling `stopStream()` aborts any in-flight retry.

For manual retry control:

```ts
ref.setReTries(5)                      // budget for the session
const ok = ref.reTry(3000, 'manual')   // returns false if budget exhausted
```

### Camera selection

| Method | Notes |
|---|---|
| `switchCamera()` | Toggle front ⇄ back. |
| `getCamerasAvailable(): string[]` | Camera2 IDs on Android, AVCaptureDevice unique IDs on iOS. |
| `getCurrentCameraId(): string` | |
| `switchCameraById(id): void` | Select a specific lens (ultra-wide / tele / LiDAR-depth). |
| `isFrontCamera(): boolean` | |

### Audio

| Method | Notes |
|---|---|
| `setAudioMuted(muted): void` | Keeps the audio track in the stream but emits silence. |
| `isAudioMuted(): boolean` | |

### Torch

| Method | Notes |
|---|---|
| `setLanternEnabled(on): void` | No-op when unsupported (e.g. front camera). |
| `isLanternEnabled(): boolean` | |
| `isLanternSupported(): boolean` | |

### Zoom

```ts
const min = ref.getMinZoom()      // usually 1.0
const max = ref.getMaxZoom()      // device-dependent
ref.setZoom(2.0)
```

For pinch-to-zoom, hook RN's `PanResponder` to multi-touch and call `setZoom(currentZoom * scale)`. See [example/src/hooks/usePinchZoom.ts](./example/src/hooks/usePinchZoom.ts) for a reference implementation.

### Exposure

```ts
const min = ref.getMinExposure()
const max = ref.getMaxExposure()
ref.setExposure(0)                // EV-compensation step
```

### Focus

| Method | Notes |
|---|---|
| `setAutoFocusEnabled(on): boolean` | Returns whether it was applied. |
| `isAutoFocusEnabled(): boolean` | |
| `setFocusDistance(d): void` | Manual focus. Android: device units. iOS: lens position 0..1. |

### Stabilization

| Method | Notes |
|---|---|
| `setVideoStabilizationEnabled(on): boolean` | Software stabilization. iOS: `AVCaptureVideoStabilizationMode.standard`. |
| `setOpticalVideoStabilizationEnabled(on): boolean` | Optical / cinematic stabilization, hardware-gated. iOS: `.cinematic` mode. |
| `isVideoStabilizationEnabled() / isOpticalVideoStabilizationEnabled()` | Current state. |

### Local recording

Independent of streaming — can record while live, or without ever streaming.

```ts
const started = ref.startRecord('/path/to/clip.mp4')
// returns false if the path is invalid or the recorder is already running
ref.stopRecord()
// also: pauseRecord(), resumeRecord(), getRecordStatus()

ref.setOnRecordStatusChange((status) => console.log('record:', status))
```

- **Android**: full lifecycle including pause/resume.
- **iOS**: `pauseRecord` / `resumeRecord` are best-effort status transitions; `AVAssetWriter` has no native pause primitive. The output file may have a small gap at the pause point.

### Long-form streams

For broadcasts that run for hours, A/V can drift if the encoder's clock and the audio capture clock disagree. Use the `quality` preset:

```tsx
<RtmpPublisherView streamMode="quality" ... />
```

That preset:
- **Android**: forces monotonic incremental timestamps + `TimestampMode.CLOCK`, enlarges the RTMP cache to ~4s, writes larger chunks, softens the ABR exponential factor.
- **iOS**: enlarges the chunk size to 8192 bytes and elevates the connection QoS to `userInteractive`. iOS encoders emit monotonic timestamps internally so no extra knob is needed.

If you need finer control, call the primitives directly:

```ts
ref.forceIncrementalTs(true)   // Android only — iOS is intrinsic
ref.setStreamDelay(50)         // Android only — +50ms audio delay
```

### FPS lock in low light

By default Camera2's auto-exposure can extend frame duration to brighten dark frames — your "30fps" stream becomes 15fps once the sun goes down. Lock the AE FPS range:

```ts
ref.setForceFpsLimit(true)
```

Trade-off: darker night frames, but smooth motion. Recommended on for any sports / motion-heavy stream. iOS uses `activeVideoMin/MaxFrameDuration` for the same effect.

### Audio source

The default Android `MIC` source is tuned for phone calls — AGC crushes dynamic range and the noise gate kills ambient sound. Pick a better source via the `audioSource` prop:

| Source | iOS mapping¹ | Android mapping | Use for |
|---|---|---|---|
| `'camcorder'` | `.videoRecording` (light NR built in) | `CAMCORDER` | **Default.** Streaming, vlogs, anywhere voice + room mix |
| `'mic'` | `.default` (natural, no DSP) | `MIC` (AGC + NS) | Talking heads — Android applies phone-call tuning, iOS gives natural mic input |
| `'voiceRecognition'` | `.measurement` (raw) | `VOICE_RECOGNITION` (raw) | Clean signal, you handle mixing |
| `'voiceCommunication'` | `.voiceChat` | `VOICE_COMMUNICATION` | Two-way streams with echo cancellation |
| `'unprocessed'` | `.measurement` | `UNPROCESSED` (API 24+) | Music capture, pro-audio scenarios |

¹ iOS mappings shown here assume `noiseSuppression={false}`. Setting it `true` forces `.voiceChat` regardless of source — see [Noise suppression](#noise-suppression).

Single biggest perceived audio-quality win available. Test with `'camcorder'` first.

### Noise suppression

The `noiseSuppression` prop is the on/off switch for aggressive voice processing — Apple's Voice Processing IO unit on iOS, Android's `NoiseSuppressor` + `AcousticEchoCanceler` + AGC on Android. Decoupled from `audioSource` so you can mix and match.

```tsx
<RtmpPublisherView noiseSuppression={true}  ... />
```

- **iOS**: forces `AVAudioSession.Mode.voiceChat` regardless of `audioSource`. This is the only iOS mode that enables NS — Apple bundles NS + AEC + AGC into a single audio unit, so you can't independently get NS without AGC. AGC will compress your voice in exchange.
- **Android**: passes `echoCanceler` + `noiseSuppressor` flags to RootEncoder's `prepareAudio`, layered on top of your `audioSource`. The DSP is finer-grained — voice stays more natural than on iOS.

**Tradeoff:** noise suppression kills background, but AGC also damps your own voice when speaking softly or near silence — the classic "phone-call" sound. For most talk streams indoors, leaving it `false` and using `audioSource="camcorder"` gives a cleaner result (the `.videoRecording` mode has light noise reduction built in without the AGC clamp). Flip it on only when you're streaming from cafés, streets, or events where ambient is overwhelming.

| | `noiseSuppression={false}` | `noiseSuppression={true}` |
|---|---|---|
| Voice | Natural, full dynamic range | Compressed, leveled |
| Background | Light NR via `.videoRecording` on iOS (camcorder source) | Aggressively gated |
| Music in background | Preserved | Squashed |
| Phone-call feel | No | Yes |

Toggleable live mid-session via the prop. On iOS the change applies immediately; on Android call `ref.resetAudioEncoder()` after to rebuild the `AudioRecord` pipeline with the new DSP state.

### Thermals

Sustained streaming can throttle the SoC. The library hooks the OS thermal API on both platforms so you can react without polling.

```ts
// Set the trip level via the `thermalWarningThreshold` prop (default 'severe').
// The OS listener is only registered when you actually subscribe — zero work
// otherwise.
ref.setOnThermalWarning((status) => {
  // 'none' | 'light' | 'moderate' | 'severe' | 'critical' | 'emergency' | 'shutdown'
  if (status === 'severe') ref.setVideoBitrateOnFly(1_000_000)
  if (status === 'critical') ref.stopStream()
})

// One-shot read
const now = ref.getThermalStatus()
```

The callback fires twice for a typical heat event:
1. When the state first crosses the threshold (entering the warning zone)
2. Once when it falls back below the threshold (clearing — useful for "all good, dial back up" logic)

- **Android**: requires API 29 (Android 10). Older devices always report `'none'`.
- **iOS**: maps `ProcessInfo.thermalState` (`nominal` / `fair` / `serious` / `critical`) onto our 7-level scale.

#### Testing thermal handling without overheating the device

Android:
```bash
adb shell cmd thermalservice override-status 3   # SEVERE
adb shell cmd thermalservice override-status 0   # back to normal
adb shell cmd thermalservice reset               # release override
```

iOS: thermal state can't be triggered from the CLI; use Instruments' Thermal State template, or wrap the device in a thermal cover and run an encoder benchmark.

### Events

```ts
// Connection state changes (low frequency, important).
ref.setOnConnectionEvent((event, message) => {
  // event ∈ 'connectionStarted' | 'connectionSuccess' | 'connectionFailed'
  //       | 'disconnect' | 'reconnecting' | 'authError' | 'authSuccess'
})

// Per-second bitrate updates (OPT-IN). If you never call this,
// nothing crosses the JSI bridge for bitrate.
ref.setOnBitrateChange((bitrateBps) => { ... })

// Local recorder state (OPT-IN).
ref.setOnRecordStatusChange((status) => { ... })
```

> **iOS extras** — backgrounding the app or having another app grab the camera (incoming call, Siri, Control Center) emits a synthetic `disconnect` event with a descriptive reason like `"session interrupted: video-device-in-use-by-another-client"`. When the camera comes back, you receive a `connectionSuccess`-equivalent fresh state. The UI never has to poll.

---

## Platform parity

Same JS API, same behavior — but worth knowing exactly where the platforms differ under the hood:

| Feature | iOS | Android |
|---|---|---|
| Capture | AVFoundation | Camera2 |
| Encoder | VideoToolbox | MediaCodec |
| Preview | HaishinKit MTHKView (Metal) | OpenGlView (OpenGL ES) |
| RTMP transport | HaishinKit | RootEncoder |
| Video codecs | H.264, HEVC | H.264, HEVC, AV1 |
| Audio codec | AAC only (RTMP) | AAC (G.711, Opus accepted but RTMP-incompatible) |
| Adaptive bitrate signal | TX throughput delta | RTMP send-buffer depth |
| `forceIncrementalTs` | Intrinsic (no-op flag) | Active knob |
| `setStreamDelay` | No-op | Active knob |
| Background streaming | `UIBackgroundModes: ['audio']` | Foreground service via `foregroundServiceTitle` |
| Wake lock | `UIApplication.isIdleTimerDisabled` | `PARTIAL_WAKE_LOCK` |
| Mirror | Single `AVCaptureConnection` buffer; UIView transform for asymmetric cases | Separate preview / stream flip flags, re-applied on `switchCamera()` |
| `noiseSuppression` | Forces `AVAudioSession.Mode.voiceChat` (NS+AEC+AGC bundled, can't separate) | Independent `NoiseSuppressor` + `AcousticEchoCanceler` AudioEffects |

When in doubt, **the JS API is the contract**. Where a knob doesn't map to one platform, we either translate (audioSource modes) or silently no-op (forceHardwareCodec on iOS).

---

## Performance notes

Everything in the hot path stays native:

- **Capture → GPU compose → encoder input surface** — never crosses into JS, no per-frame allocation.
- **HW encode** — VideoToolbox / MediaCodec on a dedicated thread. Effectively zero CPU.
- **FLV muxing + RTMP TX** — HaishinKit's `RTMPClient` / RootEncoder's `RtmpClient` on background threads.
- **JS bridge** — touched only on:
  - `setOnConnectionEvent` transitions (rare),
  - `setOnBitrateChange` (opt-in, ~1 Hz when subscribed),
  - any imperative method you call.

Knobs that move CPU/GPU usage:

| Lever | Effect |
|---|---|
| Resolution (1080p → 720p) | ~2× less work end-to-end |
| FPS (30 → 24) | -20% |
| `forceHardwareCodec={true}` | Required for "free" encode on Android |
| Don't subscribe to bitrate | Saves one bridge round-trip per second |
| Don't record while streaming | Avoids a second encoder |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                            JavaScript                            │
│   <RtmpPublisherView                                             │
│     videoCodec mirrorPreview … hybridRef={...}/>                 │
│                       ▲                                          │
│                       │ generated by Nitrogen                   │
│                       ▼                                          │
│   ref.prepareVideo() / startStream() / setZoom() / …             │
└─────────────────────────────────────────────────────────────────┘
                          │ JSI (one call, no JSON)
                          ▼
┌──────────────────────────────┐    ┌──────────────────────────────┐
│  HybridRtmpPublisherView.kt  │    │ HybridRtmpPublisherView.swift│
│        (Android)             │    │           (iOS)              │
│                              │    │                              │
│  OpenGlView ── RtmpCamera2   │    │  MTHKView ── RTMPStream      │
│       │            │         │    │      │           │           │
│       ▼            ▼         │    │      ▼           ▼           │
│  GL preview   MediaCodec     │    │ Metal preview  VideoToolbox  │
│              ↓ RTMP/TCP      │    │              ↓ RTMP/TCP      │
└──────────────────────────────┘    └──────────────────────────────┘
            │                                    │
            ▼                                    ▼
      RootEncoder                             HaishinKit
```

- **JS surface** — typed spec at [`src/specs/RtmpPublisher.nitro.ts`](./src/specs/RtmpPublisher.nitro.ts). Nitrogen generates the C++ shim, the platform-native base class, and the Fabric view component config.
- **Native implementations** — `HybridRtmpPublisherView` in Kotlin (Android) and Swift (iOS); each extends the generated spec.
- **Lifecycle** — both platforms emit a synthetic `disconnect` event when the camera is yanked out from under us (rotation, backgrounding, phone call, another app grabbing the camera), so the JS state never silently diverges from reality.

---

## Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| Camera opens/closes in a loop | `hybridRef` callback recreated per render | Wrap in `useMemo([], …)` |
| Output stream lands in landscape after a few seconds | `prepareVideo` called after `startPreview`; encoder rotation latched late | Call `prepareVideo` + `prepareAudio` **before** `startPreview` |
| Output is upside down | Rotation applied twice | Pick one source of truth: either pass `rotation` to `prepareVideo` OR drive `setStreamRotation` from an orientation observer, not both |
| Audio missing from stream (Android) | `prepareAudio` ran without `RECORD_AUDIO` permission granted | Call `requestRtmpPermissions()` and only mount the view after `granted === true` |
| White screen on real iOS device with embedded JS bundle | Hermes inspector tries to open devtools WebSocket in `__DEV__` mode | Build with `--dev false` for the embedded bundle, or use Metro over Wi-Fi |
| `Unable to resolve module ./index` from Metro | The package symlink resolves recursively into `example/` | Use `metro.config.js` with a `blockList` regex for the example path |
| iOS: stream is sideways with the camera vertical | iOS encoder sized for landscape but receiving portrait frames | The library swaps dimensions automatically when `rotation: 0` is passed — make sure you're using the JS API surface, not patching the Swift side |

---

## Contributing

PRs welcome. The library structure:

```
src/specs/         # Nitro spec (single source of truth — drives codegen)
src/permissions.ts # Cross-platform permission helper
ios/               # Swift implementation
android/src/       # Kotlin implementation
nitrogen/generated # COMMITTED — regenerated via `npm run specs`
example/           # Reference app (Expo SDK 56 / RN 0.85)
```

To work on the library locally:

```sh
npm install
cd example
npm install
# Android
npm run android
# iOS
npm run ios:device -- <UDID>
```

After changing the spec, run `npm run specs` from the repo root to regenerate the Nitrogen bindings, then `cd example/ios && pod install` to pick up new sources on iOS.

---

## Acknowledgements

- [Nitro Modules](https://github.com/mrousavy/nitro) by Marc Rousavy — the JSI codegen that makes the typed bridge possible
- [RootEncoder](https://github.com/pedroSG94/RootEncoder) by Pedro Sánchez — Android RTMP runtime
- [HaishinKit.swift](https://github.com/HaishinKit/HaishinKit.swift) by Shogo Endo — iOS RTMP runtime

---

## License

MIT (this package). RootEncoder is Apache-2.0. HaishinKit.swift is BSD-3-Clause.
