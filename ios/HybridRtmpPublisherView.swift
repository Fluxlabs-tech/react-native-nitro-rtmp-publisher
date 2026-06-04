//
//  HybridRtmpPublisherView.swift
//  NitroRtmpPublisher
//
//  iOS implementation of the Nitro view. Mirrors the Android
//  RootEncoder-backed publisher; uses HaishinKit 2.2.x under the hood
//  (MediaMixer + RTMPConnection/Stream actors).
//
//  This file holds the class declaration, all stored state, the Nitro
//  prop setters (`didSet` handlers), and the lifecycle entry points
//  (`init`, `deinit`, `onDropView`). All behavior is split across topical
//  extensions to keep this file readable:
//
//    HybridRtmpPublisherView+Streaming.swift   — RTMP transport, reconnect
//                                                machinery, encoder
//                                                settings, bitrate timer,
//                                                NetStream status events.
//    HybridRtmpPublisherView+Capture.swift     — camera & mic attach,
//                                                preview, mirror /
//                                                stabilization, all
//                                                per-device controls
//                                                (zoom / exposure / focus
//                                                / torch), audio session.
//    HybridRtmpPublisherView+Recording.swift   — local MP4 recording.
//    HybridRtmpPublisherView+Lifecycle.swift   — app background/foreground,
//                                                AVCaptureSession
//                                                interruption, orientation
//                                                and thermal observers.
//    HybridRtmpPublisherView+Events.swift      — JS callback setters and
//                                                the `emit*` helpers that
//                                                hop them to main.
//    HybridRtmpPublisherView+UrlHelpers.swift  — RTMP URL parsing +
//                                                credential sanitization.
//
//  Standalone:
//    PublisherBitrateStrategy.swift            — custom HK
//                                                `StreamBitRateStrategy`.
//    PublisherMappings.swift                   — type-bridging extensions
//                                                (Nitro enums → AVFoundation
//                                                / ProcessInfo).
//
//  Architecture note: Nitro view methods are synchronous (or `throws`) but
//  HaishinKit 2.x's API is actor-based and async. We bridge by:
//   - caching state locally for synchronous getters (`isStreaming`,
//     `getZoom`, `getCurrentBitrate`, …) — the cache is updated whenever
//     we mutate the underlying actor state
//   - wrapping all setters in detached `Task { ... }` work — fire-and-
//     forget, errors logged but not surfaced because the JS-facing method
//     doesn't have anywhere to return them
//   - consuming `connection.status` + `stream.status` AsyncStreams in
//     long-lived Tasks (with `pipelineGeneration` guards to drop stale
//     events from torn-down actors).
//

import AVFoundation
import Foundation
import HaishinKit
import NitroModules
import RTMPHaishinKit
import UIKit
import VideoToolbox

let TAG = "RtmpPublisherView"

/// Single-camera-per-process guard. AVCaptureSession only really likes one
/// active capture session; tracking active publishers means a second mount
/// fails loudly instead of silently fighting the first.
final class ActivePublisherSlot {
  static var count = 0
  private init() {}
}

final class HybridRtmpPublisherView: HybridRtmpPublisherViewSpec {

  // ─── Backing UIView (Metal-based HaishinKit preview) ─────────────────────

  let previewView: MTHKView = {
    let v = MTHKView(frame: .zero)
    v.videoGravity = .resizeAspect
    v.backgroundColor = .black
    v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    return v
  }()

  // Freeze-frame overlay used to cover the ~400ms AVCaptureSession reconfigure
  // during a camera flip. On flip we render the last composited preview frame
  // (captured by `previewFrameTap`) into this image view, show it instantly so
  // the user sees a held frame (never a black flash or the offscreen
  // "double-render"), then crossfade it out the moment the new camera's first
  // frame lands (see `showFreezeFrame` / `finalizeMirror`). Added as a SUBVIEW
  // of the Metal preview so it inherits the same mirror transform; the captured
  // frame already has orientation + mirror + beauty baked in, so the freeze
  // matches the live preview pixel-for-pixel.
  let freezeOverlay: UIImageView = {
    let iv = UIImageView(frame: .zero)
    iv.contentMode = .scaleAspectFit
    iv.backgroundColor = .clear
    iv.isUserInteractionEnabled = false
    iv.clipsToBounds = true
    iv.alpha = 0
    iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    return iv
  }()

  // Renders the captured `CIImage` freeze frame to a `CGImage` on flip. Eager
  // `let` (not `lazy var`) so first-access is thread-safe — the render runs on
  // `snapshotRenderQueue`, off the main thread. GPU-backed; a single 720×1280
  // render is a few ms. `CIContext` is safe to use concurrently for rendering.
  let freezeRenderContext = CIContext(options: [.cacheIntermediates: false])

  // Serial background queue for the per-flip freeze-frame raster (createCGImage
  // + GPU→CPU readback), so the flip tap never blocks the main run loop. The
  // resulting UIImage is hopped back to main to show. `.userInteractive` because
  // it's on the user's flip-tap path and the overlay should appear promptly.
  let snapshotRenderQueue = DispatchQueue(label: "rtmp.freeze.snapshot", qos: .userInteractive)

  var view: UIView { previewView }

  // ─── HaishinKit 2.x ──────────────────────────────────────────────────────

  let mixer = MediaMixer()

  /// iOS `noiseSuppression` path. When NS is ON we own audio capture through this
  /// pipeline (AVAudioEngine with Apple's Voice Processing — NS/AEC, AGC disabled
  /// — feeding `mixer.append`) instead of `mixer.attachAudio(mic)`. When OFF it's
  /// never started and the mixer captures the mic directly. See
  /// `applyAudioCaptureForCurrentMode()`.
  let denoisePipeline = AudioDenoisePipeline()

  /// Serializes audio (re)starts so the AVAudioSession-interruption recovery
  /// (`handleAudioSessionInterruption`) and the AVCaptureSession defrost path
  /// (`defrostCapture`) can't fire two concurrent denoise-engine / `attachAudio`
  /// rebuilds against the same mixer. Each restart chains on the previous one.
  var audioRestartTask: Task<Void, Never>?

  /// Connection and stream are *both* recreated on every publish cycle.
  /// HaishinKit's `RTMPConnection` keeps every `RTMPStream` we register in
  /// a private `streams` array and has no public `removeStream(_:)` — only
  /// `deinit` clears it. After even one reconnect, calling `connect()`
  /// iterates *all* accumulated dead streams and fires `createStream` on
  /// each, drowning the AMF channel so our real publish's `publishStart`
  /// reply goes unmatched → 15s `requestTimedOut`. We dodge that by
  /// throwing both actors away on every restart so ARC can reclaim them
  /// and the next connection starts with a single-element `streams` array.
  ///
  /// The timeout (15s) is also bumped from HK's 3s default — FB Live /
  /// YouTube Live on rtmps:443 routinely take 5-8s before publishStart.
  var connection = RTMPConnection(requestTimeout: 15_000)
  var stream: RTMPStream

  /// Long-lived task that drains `connection.status` and forwards events
  /// to JS. Re-subscribed on every `rebuildPipeline`.
  var statusObserverTask: Task<Void, Never>?

  /// Per-stream task that drains `stream.status` (NetStream.* events:
  /// publishStart, publishBadName, unpublishSuccess, …). Recreated on
  /// every stream swap so it always points at the active stream.
  var streamStatusObserverTask: Task<Void, Never>?

  /// Monotonically incremented on every `rebuildPipeline`. Each observer
  /// Task captures the generation at subscription time and bails out if
  /// it ever observes a mismatch — necessary because Swift Task
  /// cancellation is cooperative: when we cancel a stale observer, a
  /// status value already delivered to its iterator can still fire one
  /// more handler call. Without this guard, a stale `connectClosed` from
  /// the old (torn-down) connection lands on `self` AFTER the new session
  /// has successfully published — clobbering `cachedIsStreaming`,
  /// stopping the bitrate timer, and emitting a spurious `.disconnect`.
  var pipelineGeneration: UInt64 = 0

  /// Last throughput sample reported by `PublisherBitrateStrategy`, in bps.
  /// Updated from a Sendable closure (any actor) — read by the bitrate
  /// timer on the next tick. Race is benign: we never gate logic on this
  /// value.
  var lastMeasuredBps: Double = 0

  // ─── Callbacks (set from JS) — invoke via emit* helpers in +Events.swift

  var onConnectionEvent: ((RtmpConnectionEvent, String) -> Void)?
  var onBitrateChange: ((Double) -> Void)?
  /// Combined per-second stats (bitrate bps + video fps). See setOnStreamStats.
  var onStreamStats: ((Double, Double) -> Void)?
  var onRecordStatusChange: ((RecordStatus) -> Void)?
  var onThermalWarning: ((ThermalStatus) -> Void)?
  var onPictureInPictureChange: ((Bool) -> Void)?

  // ─── Picture-in-Picture (see +PictureInPicture.swift) ────────────────────
  // System PIP via an AVSampleBufferDisplayLayer (HaishinKit's PiPHKView) fed
  // by the mixer + AVPictureInPictureController. `pip` is created on main (the
  // view is constructed on main by Fabric).
  let pip = PictureInPictureController()
  // True once the PIP controller + display view are set up (the feature is
  // armed). Touched only on main.
  var pipArmed = false
  // True iff this device SUPPORTS multitasking camera access — the LIVE PIP tier
  // (iPhone iOS 18+ with the `voip` background mode, M1+ iPad). PIP is armed ONLY
  // when this is true; on the frozen-frame tier we disable PIP entirely (a frozen
  // window + a paused stream is a worse experience than no PIP). Resolved from the
  // capture session after the camera attaches.
  //
  // Lock-guarded (audit #5): the resolver + prop setter write it on main, but
  // `enterPictureInPicture()` reads it on the JS thread. Mirroring the file's
  // lock discipline (publishLock / PipSupportBox) makes the cross-thread read
  // safe while keeping the synchronous "return false on the frozen tier"
  // semantics of `enterPictureInPicture()`.
  private let multitaskingSupportLock = NSLock()
  private var _multitaskingCameraAccessSupported = false
  var multitaskingCameraAccessSupported: Bool {
    get { multitaskingSupportLock.lock(); defer { multitaskingSupportLock.unlock() }; return _multitaskingCameraAccessSupported }
    set { multitaskingSupportLock.lock(); _multitaskingCameraAccessSupported = newValue; multitaskingSupportLock.unlock() }
  }
  // True iff multitasking camera access is currently ENABLED on the session.
  // Gates the background handler so a still-live PIP stream isn't torn down.
  // Read/written only on main, so a plain Bool is race-free here.
  var multitaskingCameraAccessActive = false
  // Serializes the PIP display-view's mixer add/remove (both async actor hops)
  // so a rapid arm→disarm toggle can't let the unordered removeOutput land
  // before the addOutput and leave the view registered as a mixer output forever
  // (decoding every frame off-screen). Each op awaits the previous Task's value,
  // so the last-issued op always wins. Assigned/read only on main. See audit #2.
  var pipOutputTask: Task<Void, Never>?
  // Cancellable handle for the 0.6s deferred live-tier background teardown.
  // `pip.onChange(true)` cancels it, so a PIP that starts later than 0.6s can't
  // be torn down as if it were a real background. Touched only on main. Audit #3.
  var pendingBackgroundTeardown: DispatchWorkItem?

  // ─── Cached state — Nitro JSI getters are synchronous, but HK 2.x is
  //     async, so we mirror the actor state into local properties. ──────

  struct PreviewConfig {
    var facing: CameraFacing
    var width: Int
    var height: Int
  }
  struct VideoCfg {
    var width: Int
    var height: Int
    var fps: Int
    var bitrate: Int
    var iFrameInterval: Int
    var rotation: Int
  }
  struct AudioCfg {
    var bitrate: Int
    var sampleRate: Int
    var isStereo: Bool
  }

  var lastPreview: PreviewConfig?
  var lastVideoCfg: VideoCfg?
  var lastAudioCfg: AudioCfg?
  var pendingStreamKey: String?

  // Stream state cache. The HK actor's readyState is the source of truth
  // but we cache here so `isStreaming()` is sync.
  var cachedIsStreaming = false
  var cachedIsOnPreview = false

  // Camera-control state caches. Read directly from `currentDevice` when
  // available; on JS-thread sync calls we return whatever the last write
  // was.
  var currentFacing: CameraFacing = .back
  var currentDevice: AVCaptureDevice?
  var cachedZoom: Double = 1.0
  var cachedZoomRange: (min: Double, max: Double) = (1.0, 1.0)
  var cachedExposure: Float = 0
  var cachedExposureRange: (min: Float, max: Float) = (-8, 8)
  var cachedAutoFocusEnabled = true
  var cachedAudioMuted = false
  // Beauty filter (iOS): a CoreImage VideoEffect registered on the mixer's
  // ScreenActor. The mixer (and its screen) persist across publish cycles, so
  // once registered the effect stays until toggled off — no re-apply needed
  // (unlike the Android GL path, which re-attaches on every startPreview).
  let beautyEffect = BeautyVideoEffect()
  var cachedBeautyEnabled = false
  // Passive mixer output that keeps the latest composited preview frame so a
  // camera flip can render a freeze-frame over the seam. See `PreviewFrameTap`
  // and `showFreezeFrame`.
  let previewFrameTap = PreviewFrameTap()
  // Bumped on every camera flip; ties a specific freeze-frame raise to the
  // attach that should crossfade it out, so overlapping flips (rapid
  // double-tap) don't reveal the preview while a later flip is still mid-swap
  // and only the newest flip owns the reveal. Touched ONLY on main — every
  // mutator (showFreezeFrame / stopPreview / defrostCapture, and the capture in
  // attachCameraAndMic) runs on the main thread (the JS-thread entry points hop
  // via onMain / requestCameraAttach first), so the plain UInt64 is race-free.
  var flipMaskToken: UInt64 = 0

  // ─── Camera-attach coalescing (rapid Flip-button mashing) ────────────────
  //
  // `mixer.attachVideo` is a HEAVY actor call: HaishinKit wraps it in an
  // AVCaptureSession beginConfiguration/commitConfiguration that tears down the
  // old AVCaptureDeviceInput and constructs a fresh one (spins up the new
  // camera hardware) — ~0.4-1.0s on-device. MediaMixer is a serial actor, so N
  // rapid Flip taps would otherwise enqueue N of these back-to-back and freeze
  // the UI for several seconds before draining.
  //
  // We coalesce: only ONE attach runs at a time. While one is in flight, a tap
  // just updates the intent (`currentFacing` / `currentDevice`) and sets
  // `cameraAttachPending`. When the in-flight attach finishes, its tail does AT
  // MOST ONE reconverge attach to the latest intent.
  //
  // Result: any burst of N taps collapses into 1 attach (intent unchanged, e.g.
  // even taps back→…→back) or 2 attaches (1 initial + 1 reconverge, e.g. odd
  // taps), and always lands on the correct final facing.
  //
  // THREADING — these flags are mutated ONLY on the main thread. The entry-point
  // Nitro methods (switchCamera / switchCameraById / startPreview / stopPreview)
  // run on the JS thread (the generated bridge calls them with no hop), so they
  // do NOT touch these flags directly: they route through requestCameraAttach(),
  // which hops to main via `onMain` before reading/writing them; the attach tail
  // and finalizeMirror also run on main. So `flipMaskToken` / `mirrorGeneration`
  // and these two Bools are all single-threaded → a plain Bool/UInt64 is genuinely
  // race-free. (The INTENT vars currentFacing/currentDevice are still set on the
  // JS thread, but the attach reads them on main after a dispatch barrier and the
  // reconverge re-checks them, so reading the freshest intent is correct.) Reset
  // in stopPreview / onDropView (both via onMain) so a view that drops mid-attach
  // can't leave the guard stuck.
  var cameraAttachInFlight = false
  var cameraAttachPending = false

  // Monotonic generation for mirror writes. Bumped (on main) at the entry of
  // EVERY path that asserts mirror — attachCameraAndMic / switchCameraById /
  // defrostCapture (which seed mirror inside the attach block) and
  // applyMirrorFlags (the prop-didSet path). Each spawned Task captures the
  // generation it was born under and only commits its mirror write if it's
  // still the latest. This makes mirror last-writer-wins DETERMINISTIC:
  // whichever flip is newest owns the final value, so a heavy in-flight
  // attach from an OLD flip can't clobber a NEWER flip's mirror when its tail
  // finally lands. The winning writer re-reads `mirrorStream` live at commit
  // time, so the committed value is always the freshest prop — regardless of
  // whether the JS prop arrived before or after the attach completed.
  var mirrorGeneration: UInt64 = 0

  // True between an explicit `startStream` and `stopStream` / drop. Gates
  // auto-reconnect so we don't retry against a torn-down camera/surface.
  var shouldBeStreaming = false

  // Set true the moment we kick off a connect/publish Task and cleared in
  // its tail (success or failure). Gates concurrent startStream calls
  // (double-tap, JS-side races, manual retry while auto-reconnect is in
  // flight) from spawning overlapping stream-rebuild Tasks.
  //
  // Reads and writes go through `tryClaimPublishSlot` / `releasePublishSlot`
  // / `isPublishingInFlight`, all backed by `publishLock`. A plain `var`
  // here would read fine on 64-bit ARM but the check-and-set pattern
  // (`if !inFlight { inFlight = true }`) used by `startStream` and the
  // reconnect Task body isn't atomic, so two near-simultaneous callers
  // could both pass the check and race into `rebuildPipeline`.
  let publishLock = NSLock()
  var _publishInFlight = false

  /// In-flight publish (initial `startStream` or auto-reconnect) Task.
  /// Stored so `onDropView` / `stopStream` can cancel it — Tasks spawned
  /// without a stored reference can't be torn down externally and
  /// hold `self` strongly via `guard let self = self`, delaying view
  /// deallocation by up to 15 s (the RTMP timeout) on unmount.
  var publishTask: Task<Void, Never>?

  // True while the app is backgrounded / locked. Suppresses auto-reconnect:
  // iOS kills the RTMP socket on background → `connectClosed` fires → our
  // retry would try to open a new socket against a suspended networking
  // stack → guaranteed `requestTimedOut`. Re-armed on foreground via
  // `defrostCapture`, which also triggers a single fresh reconnect if we
  // were streaming before the app went away.
  var isInBackground = false

  // True iff backgrounding actually tore down capture/stream (frozen tier or a
  // real background). On a LIVE PIP return the camera + stream stayed alive and
  // this stays false, so `appWillEnterForeground` skips the (jittery) camera
  // re-attach + reconnect. Set in `performBackgroundStreamTeardown`, cleared on
  // the next foreground.
  var didBackgroundTeardown = false

  // RTMP URL is split into "rtmp://host/app" (connect) + "streamKey" (publish).
  var currentRtmpConnectUrl: String?

  // Auto-reconnect.
  var autoReconnectMaxAttempts = 0
  var autoReconnectBackoffMs: Int64 = 0
  var retriesRemaining = 0
  /// In-flight reconnect Task. Cancelling here interrupts both the delay
  /// (`Task.sleep` throws on cancel) and any await-in-flight inside the
  /// reconnect body — strictly better than `DispatchWorkItem.cancel`,
  /// which is a no-op once the work has started executing.
  var reconnectTask: Task<Void, Never>?
  /// True between `scheduleReconnect` and its Task body completing.
  /// Lets `tryAutoReconnect` short-circuit when called from two paths for
  /// the same underlying failure (e.g. socket dies → both
  /// `handleRtmpStatus(connectClosed)` and `publishTask.catch` fire),
  /// which would otherwise decrement `retriesRemaining` twice and emit
  /// `.reconnecting` twice per real disconnect.
  var reconnectScheduled = false

  // Adaptive bitrate.
  var adaptiveMaxBitrate = 0
  var adaptiveDecreasePct: Double = 20
  var adaptiveIncreasePct: Double = 5
  var adaptiveEnabled = false
  var adaptiveCurrentBitrate = 0
  /// `DispatchSourceTimer` (not `Timer`) — the source doesn't require its
  /// creation thread to own a runloop. `Timer.scheduledTimer` schedules
  /// on the current thread's runloop, so a timer created inside a Task
  /// continuation resuming on the cooperative executor silently never
  /// fires.
  var bitrateTimer: DispatchSourceTimer?
  var lastKeyFrameRequestMs: Double = 0

  // Recording state.
  var recordStatus: RecordStatus = .stopped
  var recorder: StreamRecorder?
  var pendingRecordOutputUrl: URL?

  // Slot ownership.
  var holdsActiveSlot = false

  // Thermal monitoring (using ProcessInfo on iOS).
  var thermalThreshold: ThermalStatus = .severe
  var lastThermalState: ProcessInfo.ThermalState = .nominal
  var thermalObserver: NSObjectProtocol?

  // Force FPS limit toggle (cached — applied when camera is attached).
  var desiredForceFpsLimit = true

  // User-supplied rotation override (degrees → AVCaptureVideoOrientation).
  // When non-nil this takes priority over the auto-rotate observer in
  // `pinVideoOrientation`. Cleared by `stopPreview`.
  var userRotationOverride: AVCaptureVideoOrientation?

  // Snapshot of the latest device orientation, kept current by the
  // orientation observer (and primed on first read from main). Read from
  // any thread — a Bool/enum scalar so we accept the benign tear.
  // Replaces an earlier implementation that hopped to main via
  // `DispatchQueue.main.sync`, which would deadlock if any caller ever
  // ran while main was blocked.
  var cachedDeviceOrientation: AVCaptureVideoOrientation = .portrait

  // Stabilization (cached for re-apply after attachCamera).
  var videoStabilizationEnabled = false
  var opticalStabilizationEnabled = false

  // Orientation observer handle. Set by `enableOrientationObserver`
  // (defined in +Lifecycle.swift), torn down by `disableOrientationObserver`.
  var orientationObserver: NSObjectProtocol?

  // Pending auth credentials (RTMP URL embed). Read by
  // `applyAuthToConnectUrl` in `+UrlHelpers.swift`.
  var pendingAuthUser: String?
  var pendingAuthPass: String?

  // ─── Props (JSX) ─────────────────────────────────────────────────────────

  var forceHardwareCodec: Bool = true

  var videoCodec: VideoCodec = .h264 {
    didSet {
      guard videoCodec != oldValue, !cachedIsStreaming else { return }
      applyVideoSettings()
    }
  }

  var audioCodec: AudioCodec = .aac {
    didSet {
      guard audioCodec != oldValue, !cachedIsStreaming else { return }
      if audioCodec != .aac {
        log("audioCodec=\(audioCodec.stringValue) is not supported by HaishinKit — falling back to AAC")
      }
    }
  }

  var aspectRatioMode: AspectRatioMode = .adjust {
    didSet {
      guard aspectRatioMode != oldValue else { return }
      previewView.videoGravity = aspectRatioMode.avLayerGravity
      // Keep the PIP window's gravity in step too (otherwise it's set once at
      // arm time), so changing aspect mode after PIP is armed doesn't leave the
      // floating window letterboxed/cropped differently from the inline preview.
      // didSet runs on main; `pipArmed` / `pip` are main-only. See audit #8.
      if pipArmed { pip.displayView.videoGravity = aspectRatioMode.avLayerGravity }
      // If a freeze overlay is currently shown (gravity changed mid-flip), keep
      // its fit in sync with the live preview so they letterbox identically.
      if freezeOverlay.alpha > 0 {
        freezeOverlay.contentMode = aspectRatioMode.avLayerGravity.imageContentMode
      }
    }
  }

  var mirrorPreview: Bool = false {
    didSet {
      guard mirrorPreview != oldValue else { return }
      applyMirrorFlags()
    }
  }

  var mirrorStream: Bool = false {
    didSet {
      guard mirrorStream != oldValue else { return }
      applyMirrorFlags()
    }
  }

  var thermalWarningThreshold: ThermalStatus = .severe {
    didSet {
      guard thermalWarningThreshold != oldValue else { return }
      thermalThreshold = thermalWarningThreshold
      // Register/unregister based on BOTH the warning subscription AND beauty:
      // even at threshold `.none` (warnings off) we keep the observer alive
      // while beauty is on so its thermal auto-throttle still works. Idempotent.
      syncThermalObserver()
    }
  }

  var audioSource: AudioSource = .camcorder

  var noiseSuppression: Bool = false {
    didSet {
      guard noiseSuppression != oldValue else { return }
      configureAudioSession()
      // Swap the audio capture path live if we're already previewing (NS on →
      // spectral denoise pipeline, NS off → mixer mic). If not previewing, the
      // next attachCameraAndMic picks the right path.
      guard cachedIsOnPreview else { return }
      Task { [weak self] in await self?.applyAudioCaptureForCurrentMode() }
    }
  }

  var autoRotateStream: Bool = true {
    didSet {
      guard autoRotateStream != oldValue else { return }
      if autoRotateStream {
        enableOrientationObserver()
      } else {
        disableOrientationObserver()
      }
    }
  }

  var streamMode: StreamMode = .balanced {
    didSet {
      guard streamMode != oldValue, !cachedIsStreaming else { return }
      applyStreamMode()
    }
  }

  // iOS doesn't have a foreground-service equivalent. UIBackgroundModes in
  // Info.plist handles backgrounding.
  var foregroundServiceTitle: String = ""
  var foregroundServiceText: String = ""
  var foregroundServiceIcon: String = ""

  // System Picture-in-Picture toggle (parity with Android's auto-enter). On iOS
  // this arms the AVPictureInPictureController and sets
  // `canStartPictureInPictureAutomaticallyFromInline` so the OS auto-enters PIP
  // on background. See +PictureInPicture.swift for the per-device behavior.
  var pictureInPictureEnabled: Bool = false {
    didSet {
      guard pictureInPictureEnabled != oldValue else { return }
      onMain { [weak self] in
        guard let self else { return }
        if self.pictureInPictureEnabled {
          // Don't arm directly — check live-tier support against the session
          // first; `applyMultitaskingCameraAccess` then syncs (arms iff
          // supported). On the frozen-frame tier PIP stays disabled. Re-checked
          // from each camera attach, so this resolves once preview is running.
          self.applyMultitaskingCameraAccess()
        } else {
          self.multitaskingCameraAccessSupported = false
          self.disarmPictureInPicture()
        }
      }
    }
  }

  // ─── Init / lifecycle ────────────────────────────────────────────────────

  override init() {
    self.stream = RTMPStream(connection: connection)
    super.init()

    // Freeze-frame overlay sits on top of the Metal preview. As a subview it
    // inherits previewView's mirror transform, matching the live feed.
    previewView.addSubview(freezeOverlay)

    // Forward PIP enter/exit to JS (AVKit fires the delegate on main; the emit
    // helper re-marshals deterministically).
    pip.onChange = { [weak self] inPip in
      guard let self else { return }
      // A real PIP start defuses any pending background teardown (the 0.6s
      // live-tier defer) so a late start can't tear down a still-live stream.
      // AVKit fires this on main — the same thread the work item is scheduled
      // and cancelled on. See audit #3.
      if inPip {
        self.pendingBackgroundTeardown?.cancel()
        self.pendingBackgroundTeardown = nil
      }
      self.emitPictureInPictureChange(inPip)
    }

    Task { [stream] in
      await mixer.addOutput(previewView)
      await mixer.addOutput(stream)
      // Passive tap that keeps the latest composited frame for flip freezing.
      await mixer.addOutput(previewFrameTap)
    }
    subscribeToConnectionStatus()
    refreshOrientationCacheOnMain()

    // App + AVCaptureSession lifecycle observers. Selectors point at
    // @objc handlers in `+Lifecycle.swift`.
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(appDidEnterBackground),
                   name: UIApplication.didEnterBackgroundNotification, object: nil)
    nc.addObserver(self, selector: #selector(appWillEnterForeground),
                   name: UIApplication.willEnterForegroundNotification, object: nil)
    nc.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                   name: AVCaptureSession.wasInterruptedNotification, object: nil)
    nc.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                   name: AVCaptureSession.interruptionEndedNotification, object: nil)
    // A phone call / Siri / alarm / another app interrupts the AUDIO session —
    // separate from the AVCaptureSession video interruptions above. Without
    // handling its `.ended`, the stream resumes with video but permanently MUTED
    // audio. See `handleAudioSessionInterruption`.
    nc.addObserver(self, selector: #selector(handleAudioSessionInterruption(_:)),
                   name: AVAudioSession.interruptionNotification, object: nil)
  }

  deinit {
    statusObserverTask?.cancel()
    streamStatusObserverTask?.cancel()
    reconnectTask?.cancel()
    publishTask?.cancel()
    NotificationCenter.default.removeObserver(self)
    // `removeObserver(self)` only matches observers registered via the
    // selector variant. The orientation + thermal observers use the
    // closure variant (returns a token, kept in `orientationObserver` /
    // `thermalObserver`), which `removeObserver(self)` does NOT clean up.
    // Without these two lines, a view drop that doesn't go through
    // `onDropView` leaks the closure in NotificationCenter — small per
    // unmount but adds up over many mount/unmount cycles. Idempotent
    // with `onDropView` (which nils both tokens).
    if let obs = orientationObserver {
      NotificationCenter.default.removeObserver(obs)
      orientationObserver = nil
    }
    if let obs = thermalObserver {
      NotificationCenter.default.removeObserver(obs)
      thermalObserver = nil
    }
    bitrateTimer?.cancel()
    // Defensive — `onDropView` is supposed to release the slot on unmount
    // but Fabric has edge cases (force-quit during native init, view
    // recycling races) where it may not fire. `holdsActiveSlot` makes this
    // idempotent with the `onDropView` path: if it already released, this
    // is a no-op.
    if holdsActiveSlot {
      holdsActiveSlot = false
      ActivePublisherSlot.count = max(0, ActivePublisherSlot.count - 1)
    }
  }

  // ─── Drop / cleanup ──────────────────────────────────────────────────────

  func onDropView() {
    shouldBeStreaming = false
    lastPreview = nil
    pendingStreamKey = nil
    userRotationOverride = nil
    // Cancel any in-flight audio restart so it can't re-attach audio after the
    // teardown below, then tear down the spectral denoise pipeline.
    audioRestartTask?.cancel()
    audioRestartTask = nil
    denoisePipeline.stop()
    // Release the camera-attach coalescing guard so a drop mid-attach can't
    // leave it stuck (a remounted view starting from a fresh instance anyway,
    // but defensive and idempotent).
    // Release the coalescing guard + freeze overlay on main (the thread they're
    // touched on), mirroring stopPreview, so a drop mid-attach can't leave the
    // guard stuck or strand a frozen frame.
    onMain { [weak self] in
      guard let self else { return }
      self.cameraAttachInFlight = false
      self.cameraAttachPending = false
      self.flipMaskToken &+= 1
      self.freezeOverlay.alpha = 0
      self.freezeOverlay.image = nil
      // Tear down PIP (controller + display-view mixer output + subview).
      self.disarmPictureInPicture()
    }
    previewFrameTap.clear()
    reconnectTask?.cancel()
    reconnectTask = nil
    reconnectScheduled = false
    publishTask?.cancel()
    publishTask = nil
    // Sync release — see stopStream for rationale. The cancelled publish
    // Task's deferred release is skipped via its `Task.isCancelled` check,
    // preventing a double-release.
    releasePublishSlot()
    stopBitrateTimer()
    statusObserverTask?.cancel()
    streamStatusObserverTask?.cancel()
    // Same fire-and-forget pattern as rebuildPipeline — RTMPStream /
    // RTMPConnection close() each await an AMF roundtrip with a 15s
    // ceiling; on a dropped / backgrounded socket they always time out.
    // Awaiting them serially during teardown can hang the Task for up to
    // 30s, keeping `previewView` + `mixer` alive after the user navigated
    // away. ARC + OS socket reaping handle cleanup either way; the server
    // gets an RST.
    let oldStream = self.stream
    let oldConnection = self.connection
    Task { _ = try? await oldStream.close() }
    Task { try? await oldConnection.close() }
    Task { [weak self] in
      guard let self else { return }
      try? await self.mixer.attachVideo(nil)
      try? await self.mixer.attachAudio(nil)
      // Release the AVCaptureSession so another publisher view (or any
      // other AVCapture consumer) can take over without contention.
      await self.mixer.stopRunning()
    }
    if let rec = recorder {
      // Detach from mixer BEFORE stopping so no more sample buffers get
      // pushed into a stopping recorder. Without this the recorder stays
      // in `mixer.outputs[]` until the whole publisher view drops (i.e.
      // until self deinits) and keeps consuming frames after
      // stopRecording returns.
      let m = mixer
      Task {
        await m.removeOutput(rec)
        try? await rec.stopRecording()
      }
      recorder = nil
    }
    unregisterThermalObserver()
    disableOrientationObserver()
    NotificationCenter.default.removeObserver(self)
    onMain { UIApplication.shared.isIdleTimerDisabled = false }
    if holdsActiveSlot {
      holdsActiveSlot = false
      ActivePublisherSlot.count = max(0, ActivePublisherSlot.count - 1)
    }
    onConnectionEvent = nil
    onBitrateChange = nil
    onStreamStats = nil
    onRecordStatusChange = nil
    onThermalWarning = nil
    onPictureInPictureChange = nil
  }

  // ─── publishInFlight locking ─────────────────────────────────────────────

  /// Atomically check-and-set the publish slot. Returns true exactly once
  /// until the caller pairs with `releasePublishSlot()`. Use this instead
  /// of `if !inFlight { inFlight = true }` — the unguarded check-and-set
  /// is racy across the JS thread + reconnect Task continuation.
  func tryClaimPublishSlot() -> Bool {
    publishLock.lock()
    defer { publishLock.unlock() }
    if _publishInFlight { return false }
    _publishInFlight = true
    return true
  }

  func releasePublishSlot() {
    publishLock.lock()
    defer { publishLock.unlock() }
    _publishInFlight = false
  }

  /// Locked read for code paths that only need to peek (e.g. the
  /// foreground-reconnect gate). Use `tryClaimPublishSlot()` when you
  /// intend to also reserve the slot.
  func isPublishingInFlight() -> Bool {
    publishLock.lock()
    defer { publishLock.unlock() }
    return _publishInFlight
  }

  // ─── Diagnostic logging ──────────────────────────────────────────────────

  func log(_ message: String) {
    #if DEBUG
    NSLog("\(TAG): \(message)")
    #endif
  }
}
