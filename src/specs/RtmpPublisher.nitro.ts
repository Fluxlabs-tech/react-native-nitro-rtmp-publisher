import type {
  HybridView,
  HybridViewMethods,
  HybridViewProps,
} from 'react-native-nitro-modules'

// ────────────────────────────────────────────────────────────────────────────
// Enums
// ────────────────────────────────────────────────────────────────────────────

/** Connection state events emitted by the RTMP client. */
export type RtmpConnectionEvent =
  | 'connectionStarted'
  | 'connectionSuccess'
  | 'connectionFailed'
  | 'disconnect'
  /** Auto-reconnect just fired — expect `connectionStarted` next. */
  | 'reconnecting'
  | 'authError'
  | 'authSuccess'

export type CameraFacing = 'front' | 'back'

/** Video codecs supported by RootEncoder. RTMP servers usually require H264. */
export type VideoCodec = 'h264' | 'h265' | 'av1'

/** Audio codecs supported by RootEncoder. RTMP requires AAC. */
export type AudioCodec = 'aac' | 'g711' | 'opus'

/**
 * How the preview surface scales relative to the rendered frame.
 * - `fill`   — crop to fill the view (no letterbox)
 * - `adjust` — fit inside the view (may letterbox)
 * - `none`   — stretch (use only when aspect matches)
 */
export type AspectRatioMode = 'fill' | 'adjust' | 'none'

/** State of the local file recorder (independent of streaming). */
export type RecordStatus =
  | 'started'
  | 'stopped'
  | 'recording'
  | 'paused'
  | 'resumed'

/**
 * Android `PowerManager` thermal status. Higher = hotter, more aggressive
 * throttling. `severe` and above usually translate to MediaCodec / camera
 * frame drops. Reported as `'none'` on Android < 10 (API 29).
 */
export type ThermalStatus =
  | 'none'        // 0
  | 'light'       // 1
  | 'moderate'    // 2
  | 'severe'      // 3 — frame drops likely
  | 'critical'    // 4 — encoder may fail
  | 'emergency'   // 5
  | 'shutdown'    // 6

/**
 * `MediaRecorder.AudioSource` selection. Big perceived-quality knob for streaming.
 *
 * - `mic` — Default. Phone-call tuning: aggressive AGC, noise gate, AEC.
 *   Voices sound "compressed". Background sounds get squashed.
 * - `camcorder` — Tuned for video recording. Softer AGC, picks up music/bass.
 *   **Best default for live streaming.**
 * - `voiceRecognition` — Raw, no post-processing. Cleanest signal but no AGC.
 *   Use with manual mixing.
 * - `voiceCommunication` — VoIP-tuned: AEC + AGC + noise suppression.
 * - `unprocessed` — Bypasses all DSP (API 24+). Pro-audio scenarios only.
 */
export type AudioSource =
  | 'mic'
  | 'camcorder'
  | 'voiceRecognition'
  | 'voiceCommunication'
  | 'unprocessed'

/**
 * Stream-pipeline mode. Trades latency for stability/quality.
 *
 * - `lowLatency` — ~1-2s glass-to-glass. Small RTMP cache, small chunks,
 *   aggressive ABR. Use for interactive streams (video calls).
 * - `balanced` — ~3-4s glass-to-glass. Default. Good for most live streams.
 * - `quality` — ~6-8s glass-to-glass. Large cache, larger chunks, monotonic
 *   timestamps (`forceIncrementalTs`), gentler ABR. **Best for long-form
 *   broadcasts (sermons, concerts, multi-hour streams)** — survives 3+ hours
 *   without A/V drift.
 */
export type StreamMode = 'lowLatency' | 'balanced' | 'quality'

// ────────────────────────────────────────────────────────────────────────────
// View props (declarative — set via JSX, change rarely)
// ────────────────────────────────────────────────────────────────────────────

export interface RtmpPublisherViewProps extends HybridViewProps {
  /**
   * Pin both encoders to hardware MediaCodec. Strongly recommended.
   * Set to `false` to let RootEncoder pick `FIRST_COMPATIBLE_FOUND` (may
   * silently fall back to software on devices lacking a usable HW codec).
   * @default true
   */
  forceHardwareCodec: boolean

  /**
   * Video codec used by the encoder. Most RTMP ingest only supports H264.
   * @default 'h264'
   */
  videoCodec: VideoCodec

  /**
   * Audio codec used by the encoder. RTMP requires AAC.
   * @default 'aac'
   */
  audioCodec: AudioCodec

  /**
   * How the preview maps onto the view bounds.
   * @default 'adjust'
   */
  aspectRatioMode: AspectRatioMode

  /**
   * Mirror the on-screen preview horizontally (selfie-mode).
   * Does NOT affect the published stream.
   * @default false
   */
  mirrorPreview: boolean

  /**
   * Mirror the encoded stream horizontally.
   * Does NOT affect the on-screen preview.
   * @default false
   */
  mirrorStream: boolean

  /**
   * Fire `onThermalWarning` when the OS thermal status reaches or exceeds
   * this level. The callback also fires once when the state transitions
   * back *below* the threshold so JS can clear any warning UI.
   *
   * Set to `'none'` to disable thermal monitoring entirely.
   *
   * Requires Android 10 (API 29) — no-op on older devices.
   * @default 'severe'
   */
  thermalWarningThreshold: ThermalStatus

  /**
   * `MediaRecorder.AudioSource` used by `prepareAudio`. `camcorder` is the
   * recommended default for streaming — less aggressive AGC than `mic`,
   * captures music/ambient sounds better.
   * @default 'camcorder'
   */
  audioSource: AudioSource

  /**
   * Suppress steady background noise — fans, air-conditioners, appliance hum,
   * traffic rumble, broadband hiss — without the "phone-call" voice compression.
   * Useful for talk streams in noisy environments (offices, cafes, rooms with
   * a fan or AC droning in the background).
   *
   * - **Android**: a custom **spectral denoiser** (decision-directed Wiener
   *   filter with adaptive noise-floor tracking) on the captured PCM, installed
   *   via RootEncoder's `setCustomAudioEffect`. Targets the *stationary* noise
   *   floor, so steady fan / AC hum is removed while voice **and music** stay
   *   largely intact. Applies live (no re-prepare).
   * - **iOS**: Apple's **Voice Processing** (the FaceTime/Siri-grade NS + echo
   *   canceller) on an owned `AVAudioEngine` capture, with **AGC disabled** so
   *   the voice keeps its natural level (no leveling/compression). HaishinKit
   *   exposes no audio-effect hook, so the library owns capture while this is
   *   `true` and feeds the mixer via `append`; reverts to HaishinKit's own mic
   *   capture when `false`. Note Apple's processor is *voice-isolation*, so it
   *   also suppresses non-voice background (incl. music), unlike Android.
   *
   * Neither platform applies the AGC/compression of a phone-call processor, so
   * it's safe to leave on for talk streams. Leave `false` for music / wide-mic
   * streams where you want the raw, unprocessed room tone.
   * @default false
   */
  noiseSuppression: boolean

  /**
   * Automatically call `setStreamRotation()` on device-orientation changes
   * via `OrientationEventListener`. Prevents streams going landscape after
   * the user rotates. Disable if you want manual control.
   * @default true
   */
  autoRotateStream: boolean

  /**
   * Stream-pipeline tuning preset. `quality` is recommended for long-form
   * broadcasts (~3hr+) since it forces monotonic timestamps which prevents
   * A/V drift over time.
   * @default 'balanced'
   */
  streamMode: StreamMode

  /**
   * If non-empty, a foreground service is **auto-started** on `startStream`
   * and **auto-stopped** on `stopStream` / view drop. The notification uses
   * this title and `foregroundServiceText`.
   *
   * Set this for broadcaster-style apps where the user may briefly switch
   * apps / lock screen mid-stream. The FG service prevents Android from
   * killing the process under memory pressure.
   *
   * Leave empty (`''`) — the default — for camera apps where the user
   * always has the preview visible. No notification, no FG service.
   *
   * @default ''
   */
  foregroundServiceTitle: string

  /**
   * Notification text shown alongside `foregroundServiceTitle`. Ignored
   * when the title is empty.
   * @default ''
   */
  foregroundServiceText: string

  /**
   * **Android only.** Drawable resource name to use as the foreground-service
   * notification's small icon. Pass the bare resource name *without* package
   * prefix or extension, e.g. `'ic_notification'` for `res/drawable/ic_notification.png`.
   *
   * The drawable must live in the host app's `res/drawable*` directory (this
   * library is a runtime resolver — no compile-time link). When empty or
   * unresolvable, a generic system icon is used.
   *
   * No-op on iOS (iOS has no foreground-service notification).
   *
   * @default ''
   */
  foregroundServiceIcon: string

  /**
   * Arm system Picture-in-Picture — the OS floating window with the camera
   * preview inside. When `true`, the app auto-enters PIP on background; the
   * preview keeps rendering in the window and, where the platform keeps the
   * camera live, the in-progress RTMP stream keeps publishing across the
   * enter/exit transition. The window aspect ratio is kept portrait (matching
   * the configured stream).
   *
   * **Android** (every device): registers a PIP lifecycle observer on the host
   * Activity and — on Android 12+ (API 31) — calls `setAutoEnterEnabled(true)`
   * so the OS shrinks the app into PIP on Home / Recents with **no host
   * `MainActivity` changes required**. On Android 8–11 (API 26–30) auto-enter on
   * Home isn't available — call {@link RtmpPublisherViewMethods.enterPictureInPicture}
   * from a button (or the host's `onUserLeaveHint`) instead. Requires
   * `android:supportsPictureInPicture="true"` + the appropriate
   * `android:configChanges` on the activity (the Expo config plugin's
   * `enablePictureInPicture` option writes these for you).
   *
   * **iOS** — live PIP only on the tier where iOS keeps the camera running
   * during multitasking: **iPhone iOS 18+** (the host declares the `voip`
   * `UIBackgroundMode`) and **M1+ iPads**, where the camera stays live and the
   * stream keeps publishing. Everywhere else (older iOS, pre-M1 iPad, or no
   * `voip` mode) it is a **no-op** by design — iOS suspends the camera on
   * background, so a non-live device could only show a frozen frame with a
   * paused stream. Auto-enter uses `canStartPictureInPictureAutomaticallyFromInline`;
   * the Expo plugin's `enablePictureInPicture` option adds the `voip` mode.
   *
   * @default false
   */
  pictureInPictureEnabled: boolean
}

// ────────────────────────────────────────────────────────────────────────────
// View methods (imperative — call via `hybridRef`)
// ────────────────────────────────────────────────────────────────────────────

export interface RtmpPublisherViewMethods extends HybridViewMethods {
  // ─── Lifecycle ────────────────────────────────────────────────────────────

  /**
   * Configure the video encoder. Call once at view-ready, before `startPreview`.
   * Width/height/bitrate are in pixels and bits-per-second.
   * `rotation` should typically be `getCameraOrientation()`.
   */
  prepareVideo(
    width: number,
    height: number,
    fps: number,
    bitrate: number,
    iFrameInterval: number,
    rotation: number
  ): boolean

  /** Configure the audio encoder. Call once at view-ready, before `startPreview`. */
  prepareAudio(bitrate: number, sampleRate: number, isStereo: boolean): boolean

  /** Open the camera and render frames into the view. */
  startPreview(facing: CameraFacing, width: number, height: number): void
  stopPreview(): void

  /** Begin publishing to the given RTMP URL. */
  startStream(url: string): void
  stopStream(): void

  /**
   * Set RTMP server credentials. Call before `startStream` for servers that
   * require AMF auth (e.g. some Wowza / Nimble setups). For ingests that
   * accept `rtmp://user:pass@host/...` URLs you don't need this.
   */
  setAuthorization(user: string, password: string): void

  /**
   * Force the next encoded frame to be a key-frame (IDR). Useful after a
   * large bitrate drop or scene cut. No-op when not streaming.
   */
  requestKeyFrame(): void

  /**
   * Update the encoder rotation mid-session (degrees, 0/90/180/270).
   * Typically wired up to an `OrientationEventListener` on the JS side.
   */
  setStreamRotation(rotation: number): void

  // ─── Reconnection ────────────────────────────────────────────────────────

  /**
   * Set the maximum number of retry attempts available to `reTry()` and to
   * the built-in auto-reconnect. Default `0` (no retries).
   */
  setReTries(count: number): void

  /**
   * Manually attempt a reconnect (typically from a `connectionFailed` /
   * `disconnect` handler). Consumes one entry from the retry budget set via
   * `setReTries()`. Returns `false` if the budget is exhausted.
   */
  reTry(delayMs: number, reason: string): boolean

  /**
   * Configure the built-in auto-reconnect. When `maxAttempts > 0`, the library
   * automatically calls `reTry(...)` on `connectionFailed` and `disconnect`
   * while the user-requested stream is still considered active (i.e. `stopStream`
   * has not been called and the surface is still alive).
   *
   * Each retry consumes one attempt from the budget and uses an escalating
   * backoff (`backoffMs · 2^attempt`, clamped) so a dead/rate-limiting server
   * isn't hammered. Emits a `reconnecting` event right before the underlying
   * retry fires.
   *
   * @default Auto-reconnect defaults to **5 attempts / 2000ms** on both
   * platforms even if you never call this — a transient mid-stream network blip
   * recovers out of the box. Pass `maxAttempts = 0` to opt out explicitly.
   */
  setAutoReconnect(maxAttempts: number, backoffMs: number): void

  // ─── Status ───────────────────────────────────────────────────────────────

  isStreaming(): boolean
  isOnPreview(): boolean

  /** Recommended encoder rotation for the current device (degrees). */
  getCameraOrientation(): number

  /** Resolution of the currently configured encoder. */
  getStreamWidth(): number
  getStreamHeight(): number

  /**
   * Currently *configured* encoder target bitrate (bits-per-second).
   * NOT the measured TX throughput — subscribe to `setOnBitrateChange` for
   * the per-second measured value.
   */
  getCurrentBitrate(): number

  // ─── Adaptive bitrate ────────────────────────────────────────────────────

  /**
   * Change video bitrate WITHOUT resetting the encoder. Use this for adaptive
   * bitrate based on network conditions — cheap, no rotation flash.
   */
  setVideoBitrateOnFly(bitrate: number): void

  /**
   * Enable built-in adaptive bitrate. The library samples the measured TX
   * bitrate every second and adjusts the encoder via `setVideoBitrateOnFly`:
   *  - decreases when the network is congested (RTMP send-buffer fills up)
   *  - slowly recovers toward `maxBitrate` when the network has headroom
   *
   * `maxBitrate` is the ceiling — usually equal to the `bitrate` you passed
   * to `prepareVideo`. Pass `0` to disable.
   *
   * The optional `decreaseRangePercent` (0..100, default 20) controls how
   * aggressively bitrate drops on congestion; `increaseRangePercent` (0..100,
   * default 5) controls how quickly it recovers.
   */
  setAdaptiveBitrate(
    maxBitrate: number,
    decreaseRangePercent: number,
    increaseRangePercent: number
  ): void

  // ─── Encoder reset (rare) ────────────────────────────────────────────────

  resetVideoEncoder(): boolean
  resetAudioEncoder(): boolean

  // ─── Camera selection ────────────────────────────────────────────────────

  /** Cycle through cameras (front ⇄ back). */
  switchCamera(): void

  /** All available camera IDs from CameraManager. */
  getCamerasAvailable(): string[]

  /** Current camera ID (matches one of `getCamerasAvailable()`). */
  getCurrentCameraId(): string

  /** Switch to a specific camera by its CameraManager id. */
  switchCameraById(id: string): void

  isFrontCamera(): boolean

  // ─── Audio control ───────────────────────────────────────────────────────

  /** Mute/unmute the captured audio (keeps the audio track in the stream). */
  setAudioMuted(muted: boolean): void
  isAudioMuted(): boolean

  // ─── Torch (lantern) ─────────────────────────────────────────────────────

  setLanternEnabled(enabled: boolean): void
  isLanternEnabled(): boolean
  isLanternSupported(): boolean

  // ─── Zoom ────────────────────────────────────────────────────────────────

  setZoom(zoom: number): void
  getZoom(): number
  getMinZoom(): number
  getMaxZoom(): number

  // ─── Exposure ────────────────────────────────────────────────────────────

  setExposure(value: number): void
  getExposure(): number
  getMinExposure(): number
  getMaxExposure(): number

  // ─── Focus ───────────────────────────────────────────────────────────────

  /** Enable or disable continuous auto-focus. Returns true if applied. */
  setAutoFocusEnabled(enabled: boolean): boolean
  isAutoFocusEnabled(): boolean

  /** Manual focus distance (camera units, device-specific). */
  setFocusDistance(distance: number): void

  // ─── Video stabilization ─────────────────────────────────────────────────

  /** Software stabilization. Returns true if applied. */
  setVideoStabilizationEnabled(enabled: boolean): boolean
  isVideoStabilizationEnabled(): boolean

  /** Optical (lens) stabilization, if hardware supports it. Returns true. */
  setOpticalVideoStabilizationEnabled(enabled: boolean): boolean
  isOpticalVideoStabilizationEnabled(): boolean

  // ─── Beauty filter ───────────────────────────────────────────────────────

  /**
   * Toggle a skin-smoothing "beauty" filter on the camera feed. It affects
   * BOTH the local preview and the encoded stream. Fixed strength (no
   * intensity parameter).
   *
   * Supported on both platforms — Android uses a RootEncoder GL shader,
   * iOS a HaishinKit CoreImage `VideoEffect`.
   */
  setBeautyFilterEnabled(enabled: boolean): void
  isBeautyFilterEnabled(): boolean

  // ─── Local recording ─────────────────────────────────────────────────────

  /**
   * Save an MP4 to disk while streaming (or independently of streaming).
   * Returns `true` if the recorder accepted the path. Failures (bad path,
   * already recording, storage permission missing) return `false`.
   */
  startRecord(path: string): boolean
  stopRecord(): void
  pauseRecord(): void
  resumeRecord(): void
  getRecordStatus(): RecordStatus

  // ─── Event callbacks (split for bridge efficiency) ───────────────────────

  /** State changes (connect/disconnect/auth). Fires only on transitions. */
  setOnConnectionEvent(
    callback: (event: RtmpConnectionEvent, message: string) => void
  ): void

  /**
   * Opt-in: per-second bitrate updates. If never called, RootEncoder still
   * computes the value internally but nothing crosses the JNI/JSI bridge.
   */
  setOnBitrateChange(callback: (bitrate: number) => void): void

  /**
   * Opt-in: combined per-second stream stats while publishing — delivered in a
   * single callback (fires roughly once a second on the JS thread, only while
   * streaming). Superset of {@link setOnBitrateChange}; use this if you also
   * want the live frame rate.
   *
   * @param bitrateBps Total **measured** RTMP send throughput in bits/sec — the
   *   muxed audio + video stream plus container overhead (not the configured
   *   target). Same value as {@link setOnBitrateChange}.
   * @param videoFps Live video frames per second. **Android:** the actual frames
   *   sent to the network (post-encoder — drops under congestion show here).
   *   **iOS:** frames fed to the encoder (capture/composite rate). `0` until the
   *   first measurement after streaming starts. (Per-track *bitrate* can't be
   *   split — both engines only measure the muxed total.)
   */
  setOnStreamStats(
    callback: (bitrateBps: number, videoFps: number) => void
  ): void

  /**
   * Opt-in: fired on every transition of the local recorder state
   * (`started` → `recording` → `paused` → `resumed` → `stopped`).
   */
  setOnRecordStatusChange(callback: (status: RecordStatus) => void): void

  /**
   * Read the current OS thermal status synchronously. Returns `'none'` on
   * Android < 10 (API 29).
   */
  getThermalStatus(): ThermalStatus

  /**
   * Subscribe to thermal-status transitions filtered by the
   * `thermalWarningThreshold` prop. Fires when:
   *   1. New state >= threshold (entering warning zone), OR
   *   2. Previous state >= threshold AND new state < threshold (clearing).
   *
   * Registering this callback also enables the underlying OS listener; if
   * you never subscribe, the library never touches `PowerManager`.
   */
  setOnThermalWarning(callback: (status: ThermalStatus) => void): void

  // ─── Camera FPS lock ────────────────────────────────────────────────────

  /**
   * When `true`, locks `CONTROL_AE_TARGET_FPS_RANGE = [fps, fps]` (using the
   * fps from `prepareVideo`) so the camera does NOT drop below 30fps in low
   * light to brighten the image. The trade-off is darker frames at night.
   *
   * Default behaviour (without calling this) varies by RootEncoder version —
   * usually `[1, fps]` which yields stuttery 15-20fps in dim lighting.
   * @default true after this method is called
   */
  setForceFpsLimit(enabled: boolean): void

  // ─── Long-stream / sync tuning ──────────────────────────────────────────

  /**
   * Force monotonically-increasing RTMP timestamps even if the source clock
   * jitters. **Required for streams longer than ~30 minutes** to prevent
   * A/V drift and timestamp-wrap issues at the server.
   *
   * Automatically enabled by `streamMode: 'quality'`.
   */
  forceIncrementalTs(enabled: boolean): void

  /**
   * Manually shift audio relative to video (milliseconds). Use for compensating
   * A/V sync drift on devices known to drift. Positive = delay audio.
   * Most streams don't need this; check before adjusting.
   */
  setStreamDelay(delayMs: number): void

  // ─── Picture-in-Picture ──────────────────────────────────────────────────

  /**
   * Ask the system to enter Picture-in-Picture mode now — use this for a manual
   * "PIP" button. The floating window uses a portrait aspect ratio matching the
   * configured stream.
   *
   * **Android:** works on API 26+ regardless of the
   * {@link RtmpPublisherViewProps.pictureInPictureEnabled} prop (also the path
   * for Android 8–11, where auto-enter isn't available). Returns `false` if PIP
   * couldn't be requested — no host Activity, API < 26, PIP disabled for the app
   * in system settings, or already in PIP.
   *
   * **iOS:** starts live PIP on the supported tier (iPhone iOS 18+ with the
   * `voip` background mode / M1+ iPad). The start may be deferred until the
   * window is ready and still return `true`. Returns `false` on devices where
   * PIP isn't offered (older iOS, pre-M1 iPad, or no `voip` mode).
   */
  enterPictureInPicture(): boolean

  /**
   * `true` while in the Picture-in-Picture window. Works on **both platforms**
   * (on iOS, only the live tier ever enters PIP). Subscribe to
   * {@link setOnPictureInPictureChange} for enter/exit transitions.
   */
  isInPictureInPicture(): boolean

  /**
   * Subscribe to PIP enter/exit transitions — fires `true` when the app enters
   * the floating window and `false` when it returns to full screen. Use it to
   * hide overlays/controls while in PIP. The callback is delivered on the JS
   * thread. Works on **both platforms** (on iOS it fires for the live tier).
   */
  setOnPictureInPictureChange(callback: (isInPip: boolean) => void): void

}

export type RtmpPublisherView = HybridView<
  RtmpPublisherViewProps,
  RtmpPublisherViewMethods,
  { ios: 'swift'; android: 'kotlin' }
>
