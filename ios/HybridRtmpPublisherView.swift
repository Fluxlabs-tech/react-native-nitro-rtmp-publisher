//
//  HybridRtmpPublisherView.swift
//  NitroRtmpPublisher
//
//  iOS implementation that mirrors the Android RootEncoder-backed
//  HybridRtmpPublisherView. Uses HaishinKit 2.2.5 under the hood — the
//  modern MediaMixer + actor-based async API.
//
//  Architecture note: Nitro view methods are synchronous (or `throws`) but
//  HaishinKit 2.x's API is actor-based and async. We bridge by:
//   - caching state locally for synchronous getters (`isStreaming`, `getZoom`,
//     `getCurrentBitrate`, …) — the cache is updated whenever we mutate the
//     underlying actor state
//   - wrapping all setters in detached `Task { ... }` work — fire-and-forget,
//     errors logged but not surfaced because the JS-facing method doesn't
//     have anywhere to return them
//   - consuming the `connection.status` AsyncStream in a long-lived Task
//     and forwarding events to the JS-side `setOnConnectionEvent` callback
//

import AVFoundation
import Foundation
import HaishinKit
import NitroModules
import RTMPHaishinKit
import UIKit
import VideoToolbox

private let TAG = "RtmpPublisherView"

/// Single-camera-per-process guard. AVCaptureSession only really likes one
/// active capture session; tracking active publishers means a second mount
/// fails loudly instead of silently fighting the first.
private final class ActivePublisherSlot {
  static var count = 0
  private init() {}
}

final class HybridRtmpPublisherView: HybridRtmpPublisherViewSpec {

  // ─── Backing UIView (Metal-based HaishinKit preview) ───────────────────────

  private let previewView: MTHKView = {
    let v = MTHKView(frame: .zero)
    v.videoGravity = .resizeAspect
    v.backgroundColor = .black
    v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    return v
  }()

  var view: UIView { previewView }

  // ─── HaishinKit 2.x ────────────────────────────────────────────────────────

  private let mixer = MediaMixer()

  /// Connection and stream are *both* recreated on every publish cycle.
  /// HaishinKit's `RTMPConnection` keeps every `RTMPStream` we register in
  /// a private `streams` array and has no public `removeStream(_:)` — only
  /// `deinit` clears it. After even one reconnect, calling `connection.connect()`
  /// iterates *all* accumulated dead streams and fires `createStream` on each,
  /// drowning the AMF channel so our real publish's `publishStart` reply
  /// goes unmatched → 15s `requestTimedOut`. We dodge that by throwing both
  /// actors away on every restart so ARC can reclaim them and the next
  /// connection starts with a single-element `streams` array.
  ///
  /// The timeout (15s) is also bumped from HK's 3s default — FB Live /
  /// YouTube Live on rtmps:443 routinely take 5-8s before publishStart.
  private var connection = RTMPConnection(requestTimeout: 15_000)
  private var stream: RTMPStream

  /// Long-lived task that drains `connection.status` and forwards events to JS.
  private var statusObserverTask: Task<Void, Never>?

  /// Per-stream task that drains `stream.status` (NetStream.* events:
  /// publishStart, publishBadName, unpublishSuccess, …). Recreated on every
  /// stream swap so it always points at the active stream.
  private var streamStatusObserverTask: Task<Void, Never>?

  /// Monotonically incremented on every `rebuildPipeline`. Each observer Task
  /// captures the generation at subscription time and bails out if it ever
  /// observes a mismatch — necessary because Swift Task cancellation is
  /// cooperative: when we cancel a stale observer, a status value already
  /// delivered to its iterator can still fire one more `handleRtmpStatus`
  /// call. Without this guard, a stale `connectClosed` from the old
  /// (torn-down) connection lands on `self` AFTER the new session has
  /// successfully published — clobbering `cachedIsStreaming`, stopping the
  /// bitrate timer, and emitting a spurious `.disconnect`.
  private var pipelineGeneration: UInt64 = 0

  /// Last throughput sample reported by `PublisherBitrateStrategy`, in bps.
  /// Updated from a Sendable closure (any actor) — read by the bitrate timer
  /// on the next tick. Race is benign: we never gate logic on this value.
  private var lastMeasuredBps: Double = 0

  // ─── Callbacks (set from JS) ───────────────────────────────────────────────
  //
  // Always invoke via the `emit*` helpers below — never call the closure
  // directly. They hop to the main queue so JS sees events in a single,
  // deterministic order regardless of which Task / actor was the source.
  // Direct invocation from Task continuations resuming on the cooperative
  // executor races with NotificationCenter callbacks dispatched to .main,
  // which manifests as out-of-order delivery to JS state machines.

  private var onConnectionEvent: ((RtmpConnectionEvent, String) -> Void)?
  private var onBitrateChange: ((Double) -> Void)?
  private var onRecordStatusChange: ((RecordStatus) -> Void)?
  private var onThermalWarning: ((ThermalStatus) -> Void)?

  private func emitConnectionEvent(_ event: RtmpConnectionEvent, _ message: String) {
    onMain { [weak self] in self?.onConnectionEvent?(event, message) }
  }
  private func emitBitrateChange(_ bps: Double) {
    onMain { [weak self] in self?.onBitrateChange?(bps) }
  }
  private func emitRecordStatusChange(_ status: RecordStatus) {
    onMain { [weak self] in self?.onRecordStatusChange?(status) }
  }
  private func emitThermalWarning(_ status: ThermalStatus) {
    onMain { [weak self] in self?.onThermalWarning?(status) }
  }

  // ─── Cached state — Nitro JSI getters are synchronous, but HK 2.x is async,
  //     so we mirror the actor state into local properties. Writes go through
  //     `updateCached*` helpers so we never drift. ──────────────────────────

  private struct PreviewConfig {
    var facing: CameraFacing
    var width: Int
    var height: Int
  }
  private struct VideoCfg {
    var width: Int
    var height: Int
    var fps: Int
    var bitrate: Int
    var iFrameInterval: Int
    var rotation: Int
  }
  private struct AudioCfg {
    var bitrate: Int
    var sampleRate: Int
    var isStereo: Bool
  }

  private var lastPreview: PreviewConfig?
  private var lastVideoCfg: VideoCfg?
  private var lastAudioCfg: AudioCfg?
  private var pendingStreamKey: String?

  // Stream state cache. The HK actor's readyState is the source of truth but
  // we cache here so `isStreaming()` is sync.
  private var cachedIsStreaming = false
  private var cachedIsOnPreview = false

  // Camera-control state caches. Read directly from `currentDevice` when
  // available; on JS-thread sync calls we return whatever the last write was.
  private var currentFacing: CameraFacing = .back
  private var currentDevice: AVCaptureDevice?
  private var cachedZoom: Double = 1.0
  private var cachedZoomRange: (min: Double, max: Double) = (1.0, 1.0)
  private var cachedExposure: Float = 0
  private var cachedExposureRange: (min: Float, max: Float) = (-8, 8)
  private var cachedAutoFocusEnabled = true
  private var cachedAudioMuted = false

  // True between an explicit `startStream` and `stopStream` / drop. Gates
  // auto-reconnect so we don't retry against a torn-down camera/surface.
  private var shouldBeStreaming = false

  // Set true the moment we kick off a connect/publish Task and cleared in
  // its tail (success or failure). Gates concurrent startStream calls
  // (double-tap, JS-side races, manual retry while auto-reconnect is in
  // flight) from spawning overlapping stream-rebuild Tasks.
  private var publishInFlight = false

  // True while the app is backgrounded / locked. Suppresses auto-reconnect:
  // iOS kills the RTMP socket on background → `connectClosed` fires → our
  // retry would try to open a new socket against a suspended networking
  // stack → guaranteed `requestTimedOut`. Re-armed on foreground via
  // `defrostCapture`, which also triggers a single fresh reconnect if we
  // were streaming before the app went away.
  private var isInBackground = false

  // RTMP URL is split into "rtmp://host/app" (connect) + "streamKey" (publish).
  private var currentRtmpConnectUrl: String?

  // Auto-reconnect.
  private var autoReconnectMaxAttempts = 0
  private var autoReconnectBackoffMs: Int64 = 0
  private var retriesRemaining = 0
  /// In-flight reconnect Task. Cancelling here interrupts both the delay
  /// (`Task.sleep` throws on cancel) and any await-in-flight inside the
  /// reconnect body — strictly better than `DispatchWorkItem.cancel`, which
  /// is a no-op once the work has started executing.
  private var reconnectTask: Task<Void, Never>?

  // Adaptive bitrate.
  private var adaptiveMaxBitrate = 0
  private var adaptiveDecreasePct: Double = 20
  private var adaptiveIncreasePct: Double = 5
  private var adaptiveEnabled = false
  private var adaptiveCurrentBitrate = 0
  /// `DispatchSourceTimer` (not `Timer`) — the source doesn't require its
  /// creation thread to own a runloop. `Timer.scheduledTimer` schedules on
  /// the current thread's runloop, so a timer created inside a Task
  /// continuation resuming on the cooperative executor silently never fires.
  private var bitrateTimer: DispatchSourceTimer?
  private var lastKeyFrameRequestMs: Double = 0

  // Recording state.
  private var recordStatus: RecordStatus = .stopped
  private var recorder: StreamRecorder?
  private var pendingRecordOutputUrl: URL?

  // Slot ownership.
  private var holdsActiveSlot = false

  // Thermal monitoring (using ProcessInfo on iOS).
  private var thermalThreshold: ThermalStatus = .severe
  private var lastThermalState: ProcessInfo.ThermalState = .nominal
  private var thermalObserver: NSObjectProtocol?

  // Force FPS limit toggle (cached — applied when camera is attached).
  private var desiredForceFpsLimit = true

  // User-supplied rotation override (degrees → AVCaptureVideoOrientation).
  // When non-nil this takes priority over the auto-rotate observer in
  // `pinVideoOrientation`. Cleared by `stopPreview`.
  private var userRotationOverride: AVCaptureVideoOrientation?

  // Snapshot of the latest device orientation, kept current by the orientation
  // observer (and primed on first read from main). Read from any thread —
  // a Bool/enum scalar so we accept the benign tear. Replaces an earlier
  // implementation that hopped to main via `DispatchQueue.main.sync`, which
  // would deadlock if any caller ever ran while main was blocked.
  private var cachedDeviceOrientation: AVCaptureVideoOrientation = .portrait

  // Stabilization (cached for re-apply after attachCamera).
  private var videoStabilizationEnabled = false
  private var opticalStabilizationEnabled = false

  // Pending auth credentials (RTMP URL embed).
  private var pendingAuthUser: String?
  private var pendingAuthPass: String?

  // ─── Props (JSX) ───────────────────────────────────────────────────────────

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
      if thermalWarningThreshold == .none {
        unregisterThermalObserver()
      }
    }
  }

  var audioSource: AudioSource = .camcorder

  var noiseSuppression: Bool = false {
    didSet {
      guard noiseSuppression != oldValue else { return }
      configureAudioSession()
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

  // ─── Init / lifecycle ──────────────────────────────────────────────────────

  override init() {
    self.stream = RTMPStream(connection: connection)
    super.init()

    Task { [stream] in
      await mixer.addOutput(previewView)
      await mixer.addOutput(stream)
    }
    subscribeToConnectionStatus()
    refreshOrientationCacheOnMain()

    // App + AVCaptureSession lifecycle observers.
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(appDidEnterBackground),
                   name: UIApplication.didEnterBackgroundNotification, object: nil)
    nc.addObserver(self, selector: #selector(appWillEnterForeground),
                   name: UIApplication.willEnterForegroundNotification, object: nil)
    nc.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                   name: AVCaptureSession.wasInterruptedNotification, object: nil)
    nc.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                   name: AVCaptureSession.interruptionEndedNotification, object: nil)
  }

  deinit {
    statusObserverTask?.cancel()
    streamStatusObserverTask?.cancel()
    reconnectTask?.cancel()
    NotificationCenter.default.removeObserver(self)
    bitrateTimer?.cancel()
  }

  // ─── App-lifecycle + AVCaptureSession interruption ─────────────────────────

  @objc private func appDidEnterBackground() {
    isInBackground = true
    // Cancel any in-flight reconnect — iOS is about to suspend networking
    // and the next retry would just hit `requestTimedOut`. We'll fire a
    // fresh reconnect on foreground if the user still wants to stream.
    reconnectTask?.cancel()
    reconnectTask = nil
    // The RTMP socket is dead the moment iOS suspends us — flip cached
    // state to match. Two reasons we *must* set this here rather than
    // waiting for the natural `connectClosed` event:
    //  1. iOS doesn't notice the socket is dead until ~10-15s after
    //     foreground (TCP keepalive), so `connectClosed` arrives much
    //     too late to drive the JS UI.
    //  2. `appWillEnterForeground` gates its immediate reconnect on
    //     `!cachedIsStreaming`. Without this clear, the foreground
    //     reconnect never fires and we end up waiting for the late
    //     `connectClosed` → `tryAutoReconnect` path instead.
    cachedIsStreaming = false
    // Stop ticking — the timer is a `DispatchSourceTimer` on `.main`,
    // which means main-queue pause-on-background, then a flurry of
    // catch-up ticks on resume that report stale `lastMeasuredBps` from
    // the dead session.
    stopBitrateTimer()
    emitConnectionEvent(.disconnect, "app entered background")
  }

  @objc private func appWillEnterForeground() {
    isInBackground = false
    defrostCapture()
    // If the user was streaming when we backgrounded, the RTMP socket is
    // dead by now. Kick off one reconnect attempt — `scheduleReconnect`
    // handles the connection.close → reopen → publish dance.
    //
    // The 1500ms delay matters: iOS networking takes a beat to come back
    // online, and server-side most live ingests (FB Live in particular)
    // hold the previous session for a short window before accepting a
    // fresh publish under the same stream key. Reconnecting too aggressively
    // hits `NetStream.Publish.BadName` / `requestTimedOut`.
    if shouldBeStreaming, !publishInFlight, currentRtmpConnectUrl != nil {
      retriesRemaining = max(retriesRemaining, 1)
      scheduleReconnect(delayMs: 1500, reason: "foreground")
    }
  }

  @objc private func sessionWasInterrupted(_ notification: Notification) {
    let reasonRaw = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
    let reason: String
    switch reasonRaw {
    case 1: reason = "video-device-not-available-in-background"
    case 2: reason = "audio-device-in-use-by-another-client"
    case 3: reason = "video-device-in-use-by-another-client"
    case 4: reason = "video-device-not-available-with-multiple-foreground-apps"
    case 5: reason = "video-device-not-available-due-to-system-pressure"
    default: reason = "unknown"
    }
    emitConnectionEvent(.disconnect, "session interrupted: \(reason)")
  }

  @objc private func sessionInterruptionEnded(_ notification: Notification) {
    defrostCapture()
  }

  /// Resurrect the capture pipeline after iOS suspended it (app backgrounded,
  /// or another foreground app took the camera). HaishinKit listens for
  /// `UIApplication.willEnterForegroundNotification` internally and calls
  /// `videoIO.resume()` + `session.startRunningIfNeeded()`, but in practice
  /// the resume path doesn't always fire when our view comes back —
  /// especially on iOS 16 + camera-heavy apps. Re-attaching the same device
  /// is HK's documented "hard reset" for capture: it re-creates the
  /// AVCaptureInput, restarts the session, and replays orientation /
  /// mirror / stabilization. Idempotent — calling it while the session
  /// is already running causes a brief one-frame stutter, not a freeze.
  private func defrostCapture() {
    guard let camera = currentDevice else { return }
    let mic = AVCaptureDevice.default(for: .audio)

    // Apply the UIView side of the mirror flag IMMEDIATELY on main, so the
    // preview's CGAffineTransform is right before the first new frame from
    // the rebuilt capture session arrives. Waiting on `attachVideo` to
    // resolve before touching the transform leaves a ~1-2s window where
    // frames render with stale (or no) mirroring.
    let extraFlipPreview = (mirrorPreview != mirrorStream)
    let previewTransform: CGAffineTransform = extraFlipPreview
      ? CGAffineTransform(scaleX: -1, y: 1)
      : .identity
    onMain { [weak self] in self?.previewView.transform = previewTransform }

    let mirror = mirrorStream
    let stabilization = currentStabilizationMode
    Task { [weak self] in
      guard let self else { return }
      do {
        // Apply mirror + stabilization atomically inside the attach so the
        // very first frame from the new AVCaptureInput is already mirrored
        // and stabilized — no transient un-mirrored frames during resume.
        try await self.mixer.attachVideo(camera) { unit in
          unit.isVideoMirrored = mirror
          unit.preferredVideoStabilizationMode = stabilization
        }
        if let mic { try? await self.mixer.attachAudio(mic) }
        await self.mixer.startRunning()
        self.pinVideoOrientation()
      } catch {
        self.log("defrostCapture failed: \(error)")
      }
    }
  }

  // ─── Lifecycle: prepare ────────────────────────────────────────────────────

  func prepareVideo(
    width: Double, height: Double, fps: Double, bitrate: Double,
    iFrameInterval: Double, rotation: Double
  ) throws -> Bool {
    if cachedIsStreaming {
      log("prepareVideo ignored while streaming")
      return false
    }
    let w = Int(width), h = Int(height)
    let f = Int(fps), b = Int(bitrate)
    let i = Int(iFrameInterval), r = Int(rotation)
    if w <= 0 || h <= 0 || f <= 0 || b <= 0 {
      log("prepareVideo invalid args (w=\(w) h=\(h) fps=\(f) bitrate=\(b))")
      return false
    }
    lastVideoCfg = VideoCfg(width: w, height: h, fps: f, bitrate: b, iFrameInterval: i, rotation: r)
    applyVideoSettings()
    applyStreamMode()
    adaptiveCurrentBitrate = b
    return true
  }

  func prepareAudio(bitrate: Double, sampleRate: Double, isStereo: Bool) throws -> Bool {
    if cachedIsStreaming {
      log("prepareAudio ignored while streaming")
      return false
    }
    let b = Int(bitrate), s = Int(sampleRate)
    if b <= 0 || s <= 0 {
      log("prepareAudio invalid args (bitrate=\(b) sampleRate=\(s))")
      return false
    }
    lastAudioCfg = AudioCfg(bitrate: b, sampleRate: s, isStereo: isStereo)
    applyAudioSettings()
    configureAudioSession()
    return true
  }

  // ─── Lifecycle: preview ────────────────────────────────────────────────────

  func startPreview(facing: CameraFacing, width: Double, height: Double) throws {
    let w = max(1, Int(width))
    let h = max(1, Int(height))
    lastPreview = PreviewConfig(facing: facing, width: w, height: h)

    if !holdsActiveSlot {
      if ActivePublisherSlot.count > 0 {
        log("Refusing to start preview — another <RtmpPublisherView> is active")
        emitConnectionEvent(.connectionfailed, "another <RtmpPublisherView> already holds the camera")
        return
      }
      ActivePublisherSlot.count += 1
      holdsActiveSlot = true
    }

    currentFacing = facing
    // attachCameraAndMic now applies mirror + stabilization atomically inside
    // the attach configuration block AND syncs the preview transform up-front.
    // Calling applyMirrorFlags() again here would race the second Task with
    // the attach Task — manifests as a brief unmirror/stutter on first frame.
    attachCameraAndMic()
    cachedIsOnPreview = true
    if autoRotateStream { enableOrientationObserver() }
  }

  func stopPreview() throws {
    lastPreview = nil
    userRotationOverride = nil
    disableOrientationObserver()
    // If recording was active, finalize it before tearing down.
    if let rec = recorder {
      Task { try? await rec.stopRecording() }
      recorder = nil
    }
    Task { [weak self] in
      guard let self else { return }
      try? await self.mixer.attachVideo(nil)
      try? await self.mixer.attachAudio(nil)
      // Free up the AVCaptureSession. Without this the session keeps the
      // camera unit warm — burns ~2-5% CPU and prevents any other capture
      // consumer (system Camera app, Vision Pro mirroring, etc.) from
      // taking over while our preview is paused.
      await self.mixer.stopRunning()
    }
    currentDevice = nil
    cachedIsOnPreview = false
  }

  // ─── Lifecycle: stream ─────────────────────────────────────────────────────

  func startStream(url: String) throws {
    if url.isBlank {
      log("startStream ignored — empty URL")
      return
    }
    if publishInFlight {
      log("startStream ignored — a connect/publish is already in flight")
      return
    }
    let (rawConnectUrl, streamKey) = splitRtmpUrl(url)
    let connectUrl = applyAuthToConnectUrl(rawConnectUrl)
    currentRtmpConnectUrl = connectUrl
    pendingStreamKey = streamKey
    shouldBeStreaming = true
    publishInFlight = true
    retriesRemaining = autoReconnectMaxAttempts

    applyStreamMode()
    pinVideoOrientation()

    onMain { UIApplication.shared.isIdleTimerDisabled = true }

    Task { [weak self] in
      guard let self else { return }
      defer { self.publishInFlight = false }
      do {
        await self.rebuildPipeline(streamKey: streamKey)
        _ = try await self.connection.connect(connectUrl)
        _ = try await self.stream.publish(streamKey, type: .live)
        self.cachedIsStreaming = true
        self.emitConnectionEvent(.connectionsuccess, "")
        self.startBitrateTimer()
      } catch {
        self.cachedIsStreaming = false
        self.log("connect/publish failed: \(error)")
        self.stopBitrateTimer()
        if !self.tryAutoReconnect(reason: "\(error)") {
          self.shouldBeStreaming = false
          self.emitConnectionEvent(.connectionfailed, "\(error)")
        }
      }
    }

    emitConnectionEvent(.connectionstarted, connectUrl)
  }

  func stopStream() throws {
    shouldBeStreaming = false
    pendingStreamKey = nil
    currentRtmpConnectUrl = nil
    reconnectTask?.cancel()
    reconnectTask = nil
    cachedIsStreaming = false
    // Fire-and-forget — both close() calls block awaiting AMF responses (up
    // to 15s each on a dropped socket). The user wants stopStream to return
    // immediately; we don't care about the polite RTMP goodbye.
    let oldStream = self.stream
    let oldConnection = self.connection
    Task { _ = try? await oldStream.close() }
    Task { try? await oldConnection.close() }
    stopBitrateTimer()
    onMain { UIApplication.shared.isIdleTimerDisabled = false }
  }

  func setAuthorization(user: String, password: String) throws {
    pendingAuthUser = user.isEmpty ? nil : user
    pendingAuthPass = password.isEmpty ? nil : password
  }

  /// Rewrite `rtmp://host/app` → `rtmp://user:pass@host/app` if creds were set.
  private func applyAuthToConnectUrl(_ connectUrl: String) -> String {
    guard let user = pendingAuthUser, !user.isEmpty,
          let pass = pendingAuthPass, !pass.isEmpty,
          let comps = URLComponents(string: connectUrl), comps.user == nil else {
      return connectUrl
    }
    var c = URLComponents(string: connectUrl) ?? URLComponents()
    let enc = { (s: String) in
      s.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? s
    }
    c.user = enc(user)
    c.password = enc(pass)
    return c.string ?? connectUrl
  }

  func requestKeyFrame() throws {
    guard cachedIsStreaming, lastVideoCfg != nil else { return }
    let now = Date().timeIntervalSince1970 * 1000
    if now - lastKeyFrameRequestMs < 1000 { return }
    lastKeyFrameRequestMs = now
    // Nudge bitrate by 1 bps then restore — forces VideoToolbox to emit a
    // fresh IDR. VideoToolbox debounces bitrate changes that arrive within
    // the same encode tick, so a back-to-back set→reset would no-op. The
    // 100 ms gap is enough for the encoder to ack the first change before
    // we revert.
    Task { [weak self] in
      guard let self else { return }
      var settings = await self.stream.videoSettings
      let original = settings.bitRate
      settings.bitRate = max(1, original + 1)
      try? await self.stream.setVideoSettings(settings)
      try? await Task.sleep(nanoseconds: 100_000_000)
      settings.bitRate = original
      try? await self.stream.setVideoSettings(settings)
    }
  }

  func setStreamRotation(rotation: Double) throws {
    let orientation: AVCaptureVideoOrientation
    switch Int(rotation) {
    case 90:  orientation = .landscapeRight
    case 180: orientation = .portraitUpsideDown
    case 270: orientation = .landscapeLeft
    default:  orientation = .portrait
    }
    userRotationOverride = orientation
    Task { await self.mixer.setVideoOrientation(orientation) }
  }

  // ─── Reconnection ──────────────────────────────────────────────────────────

  func setReTries(count: Double) throws {
    retriesRemaining = max(0, Int(count))
  }

  func reTry(delayMs: Double, reason: String) throws -> Bool {
    if retriesRemaining <= 0 { return false }
    retriesRemaining -= 1
    scheduleReconnect(delayMs: Int64(delayMs), reason: reason)
    return true
  }

  func setAutoReconnect(maxAttempts: Double, backoffMs: Double) throws {
    autoReconnectMaxAttempts = max(0, Int(maxAttempts))
    autoReconnectBackoffMs = max(0, Int64(backoffMs))
    retriesRemaining = autoReconnectMaxAttempts
  }

  private func tryAutoReconnect(reason: String) -> Bool {
    guard shouldBeStreaming, autoReconnectMaxAttempts > 0 else { return false }
    if retriesRemaining <= 0 { return false }
    // Don't try to reconnect while the app is suspended — iOS won't let us
    // open a new socket and we'd just waste a retry slot on a guaranteed
    // timeout. `appWillEnterForeground` re-arms `retriesRemaining` and
    // schedules a fresh reconnect when we come back.
    if isInBackground {
      log("auto-reconnect suppressed while backgrounded (reason: \(reason))")
      return true
    }
    retriesRemaining -= 1
    scheduleReconnect(delayMs: autoReconnectBackoffMs, reason: reason)
    emitConnectionEvent(.reconnecting, reason)
    return true
  }

  private func scheduleReconnect(delayMs: Int64, reason: String) {
    reconnectTask?.cancel()
    reconnectTask = Task { [weak self] in
      // Honor cancellation during the backoff delay — `Task.sleep` throws
      // `CancellationError` when cancelled, so we bail without firing the
      // reconnect. DispatchWorkItem.cancel() can't do this once the work
      // has begun executing.
      if delayMs > 0 {
        do { try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
        catch { return }
      }
      if Task.isCancelled { return }
      guard let self = self, self.shouldBeStreaming else { return }
      guard !self.publishInFlight else {
        self.log("reconnect skipped — publish still in flight")
        return
      }
      guard let url = self.currentRtmpConnectUrl, let key = self.pendingStreamKey else { return }

      self.publishInFlight = true
      self.emitConnectionEvent(.connectionstarted, url)
      defer { self.publishInFlight = false }
      do {
        await self.rebuildPipeline(streamKey: key)
        _ = try await self.connection.connect(url)
        _ = try await self.stream.publish(key, type: .live)
        self.cachedIsStreaming = true
        self.emitConnectionEvent(.connectionsuccess, "")
        self.startBitrateTimer()
      } catch {
        self.cachedIsStreaming = false
        self.log("retry connect failed: \(error)")
        self.stopBitrateTimer()
        if !self.tryAutoReconnect(reason: "\(error)") {
          self.shouldBeStreaming = false
          self.emitConnectionEvent(.connectionfailed, "\(error)")
        }
      }
    }
  }

  // ─── Status / readouts ─────────────────────────────────────────────────────

  func isStreaming() throws -> Bool { return cachedIsStreaming }
  func isOnPreview() throws -> Bool { return cachedIsOnPreview }

  func getCameraOrientation() throws -> Double {
    switch currentVideoOrientation() {
    case .portrait:           return 0
    case .landscapeRight:     return 90
    case .portraitUpsideDown: return 180
    case .landscapeLeft:      return 270
    @unknown default:         return 0
    }
  }

  func getStreamWidth() throws -> Double { return Double(lastVideoCfg?.width ?? 0) }
  func getStreamHeight() throws -> Double { return Double(lastVideoCfg?.height ?? 0) }
  func getCurrentBitrate() throws -> Double { return Double(adaptiveCurrentBitrate) }

  // ─── Adaptive bitrate ──────────────────────────────────────────────────────

  func setVideoBitrateOnFly(bitrate: Double) throws {
    let b = Int(bitrate)
    guard b > 0 else { return }
    guard cachedIsStreaming else {
      log("setVideoBitrateOnFly ignored — not streaming")
      return
    }
    Task { [weak self] in
      guard let self else { return }
      var s = await self.stream.videoSettings
      s.bitRate = b
      try? await self.stream.setVideoSettings(s)
    }
    adaptiveCurrentBitrate = b
  }

  func setAdaptiveBitrate(
    maxBitrate: Double, decreaseRangePercent: Double, increaseRangePercent: Double
  ) throws {
    let max = Int(maxBitrate)
    if max <= 0 {
      adaptiveEnabled = false
    } else {
      adaptiveMaxBitrate = max
      adaptiveDecreasePct = decreaseRangePercent.clamped(0, 100)
      adaptiveIncreasePct = increaseRangePercent.clamped(0, 100)
      adaptiveEnabled = true
    }
    // Reinstall the strategy on the active stream — the strategy holds
    // `mamimumVideoBitRate` as a `let`, so changing the cap means creating a
    // new instance. Safe to call mid-stream.
    Task { [weak self] in
      guard let self else { return }
      await self.installBitrateStrategy(on: self.stream)
    }
  }

  /// Build a `PublisherBitrateStrategy` from current adaptive settings and
  /// attach it to the given stream. The strategy:
  ///  - feeds measured throughput into `lastMeasuredBps` (for the timer to
  ///    forward to JS)
  ///  - delegates to HK's `StreamVideoAdaptiveBitRateStrategy` only when
  ///    `adaptiveEnabled` is true
  private func installBitrateStrategy(on stream: RTMPStream) async {
    let cap = adaptiveEnabled ? adaptiveMaxBitrate : (lastVideoCfg?.bitrate ?? 0)
    let strategy = PublisherBitrateStrategy(
      maxVideoBitRate: cap,
      adaptive: adaptiveEnabled
    ) { [weak self] bps in
      self?.lastMeasuredBps = Double(bps)
    }
    await stream.setBitRateStrategy(strategy)
  }

  func resetVideoEncoder() throws -> Bool {
    applyVideoSettings()
    return true
  }

  func resetAudioEncoder() throws -> Bool {
    applyAudioSettings()
    return true
  }

  // ─── Camera selection ──────────────────────────────────────────────────────

  func switchCamera() throws {
    let next: CameraFacing = (currentFacing == .back) ? .front : .back
    currentFacing = next
    if let lp = lastPreview { lastPreview = PreviewConfig(facing: next, width: lp.width, height: lp.height) }
    // attachCameraAndMic atomically applies mirror + stabilization. The
    // redundant applyMirrorFlags() that used to live here raced its Task
    // against attachVideo's Task — produced a brief un-mirror flash on flip.
    attachCameraAndMic()
  }

  func getCamerasAvailable() throws -> [String] {
    var types: [AVCaptureDevice.DeviceType] = [
      .builtInWideAngleCamera,
      .builtInTelephotoCamera,
      .builtInUltraWideCamera,
      .builtInDualCamera,
      .builtInDualWideCamera,
      .builtInTripleCamera,
    ]
    if #available(iOS 15.4, *) {
      types.append(.builtInLiDARDepthCamera)
    }
    return AVCaptureDevice.DiscoverySession(
      deviceTypes: types, mediaType: .video, position: .unspecified
    ).devices.map { $0.uniqueID }
  }

  func getCurrentCameraId() throws -> String { return currentDevice?.uniqueID ?? "" }

  func switchCameraById(id: String) throws {
    if id.isBlank { return }
    guard let device = AVCaptureDevice(uniqueID: id) else {
      log("switchCameraById: no device with id=\(id)")
      return
    }
    currentDevice = device
    if device.position == .front { currentFacing = .front }
    else if device.position == .back { currentFacing = .back }
    cachedZoom = Double(device.videoZoomFactor)
    cachedZoomRange = (
      Double(device.minAvailableVideoZoomFactor),
      Double(device.maxAvailableVideoZoomFactor)
    )
    cachedExposureRange = (device.minExposureTargetBias, device.maxExposureTargetBias)

    // Sync UIView transform up-front so the preview is right before the first
    // frame from the new input arrives. Matches attachCameraAndMic semantics.
    let extraFlipPreview = (mirrorPreview != mirrorStream)
    let previewTransform: CGAffineTransform = extraFlipPreview
      ? CGAffineTransform(scaleX: -1, y: 1)
      : .identity
    onMain { [weak self] in self?.previewView.transform = previewTransform }

    let mirror = mirrorStream
    let stabilization = currentStabilizationMode
    Task { [weak self] in
      guard let self else { return }
      // Apply mirror + stabilization atomically inside the attach so the
      // very first frame from the new AVCaptureInput is already mirrored
      // and stabilized — no transient un-mirrored window.
      try? await self.mixer.attachVideo(device) { unit in
        unit.isVideoMirrored = mirror
        unit.preferredVideoStabilizationMode = stabilization
      }
    }
    applyCameraFpsLock()
  }

  func isFrontCamera() throws -> Bool { return currentFacing == .front }

  // ─── Audio control ─────────────────────────────────────────────────────────

  func setAudioMuted(muted: Bool) throws {
    cachedAudioMuted = muted
    Task { [weak self] in
      guard let self else { return }
      var settings = await self.mixer.audioMixerSettings
      settings.isMuted = muted
      await self.mixer.setAudioMixerSettings(settings)
    }
  }

  func isAudioMuted() throws -> Bool { return cachedAudioMuted }

  // ─── Torch ─────────────────────────────────────────────────────────────────

  func setLanternEnabled(enabled: Bool) throws {
    guard let device = currentDevice, device.hasTorch else { return }
    do {
      try device.lockForConfiguration()
      device.torchMode = enabled ? .on : .off
      device.unlockForConfiguration()
    } catch { log("setLanternEnabled failed: \(error)") }
  }

  func isLanternEnabled() throws -> Bool { return currentDevice?.torchMode == .on }
  func isLanternSupported() throws -> Bool { return currentDevice?.hasTorch ?? false }

  // ─── Zoom ──────────────────────────────────────────────────────────────────

  func setZoom(zoom: Double) throws {
    guard let device = currentDevice else { return }
    do {
      try device.lockForConfiguration()
      let clamped = CGFloat(zoom).clamped(device.minAvailableVideoZoomFactor, device.maxAvailableVideoZoomFactor)
      device.videoZoomFactor = clamped
      cachedZoom = Double(clamped)
      device.unlockForConfiguration()
    } catch { log("setZoom failed: \(error)") }
  }

  func getZoom() throws -> Double { return Double(currentDevice?.videoZoomFactor ?? CGFloat(cachedZoom)) }
  func getMinZoom() throws -> Double { return Double(currentDevice?.minAvailableVideoZoomFactor ?? 1) }
  func getMaxZoom() throws -> Double { return Double(currentDevice?.maxAvailableVideoZoomFactor ?? 1) }

  // ─── Exposure ──────────────────────────────────────────────────────────────

  func setExposure(value: Double) throws {
    guard let device = currentDevice else { return }
    do {
      try device.lockForConfiguration()
      let clamped = Float(value).clamped(device.minExposureTargetBias, device.maxExposureTargetBias)
      device.setExposureTargetBias(clamped, completionHandler: nil)
      cachedExposure = clamped
      device.unlockForConfiguration()
    } catch { log("setExposure failed: \(error)") }
  }

  func getExposure() throws -> Double { return Double(currentDevice?.exposureTargetBias ?? cachedExposure) }
  func getMinExposure() throws -> Double { return Double(currentDevice?.minExposureTargetBias ?? cachedExposureRange.min) }
  func getMaxExposure() throws -> Double { return Double(currentDevice?.maxExposureTargetBias ?? cachedExposureRange.max) }

  // ─── Focus ─────────────────────────────────────────────────────────────────

  func setAutoFocusEnabled(enabled: Bool) throws -> Bool {
    guard let device = currentDevice else { return false }
    let mode: AVCaptureDevice.FocusMode = enabled ? .continuousAutoFocus : .locked
    guard device.isFocusModeSupported(mode) else { return false }
    do {
      try device.lockForConfiguration()
      device.focusMode = mode
      cachedAutoFocusEnabled = enabled
      device.unlockForConfiguration()
      return true
    } catch {
      log("setAutoFocusEnabled failed: \(error)")
      return false
    }
  }

  func isAutoFocusEnabled() throws -> Bool {
    return currentDevice?.focusMode == .continuousAutoFocus
  }

  func setFocusDistance(distance: Double) throws {
    guard let device = currentDevice, device.isLockingFocusWithCustomLensPositionSupported else { return }
    do {
      try device.lockForConfiguration()
      let lensPos = Float(distance).clamped(0, 1)
      device.setFocusModeLocked(lensPosition: lensPos, completionHandler: nil)
      device.unlockForConfiguration()
    } catch { log("setFocusDistance failed: \(error)") }
  }

  // ─── Stabilization ─────────────────────────────────────────────────────────

  func setVideoStabilizationEnabled(enabled: Bool) throws -> Bool {
    if enabled, let device = currentDevice,
       !device.activeFormat.isVideoStabilizationModeSupported(.standard) {
      log("setVideoStabilizationEnabled: .standard not supported by active format")
      videoStabilizationEnabled = false
      return false
    }
    videoStabilizationEnabled = enabled
    applyVideoStabilizationToCaptureUnit()
    return true
  }

  func isVideoStabilizationEnabled() throws -> Bool { return videoStabilizationEnabled }

  func setOpticalVideoStabilizationEnabled(enabled: Bool) throws -> Bool {
    if enabled, let device = currentDevice,
       !device.activeFormat.isVideoStabilizationModeSupported(.cinematic) {
      log("setOpticalVideoStabilizationEnabled: .cinematic not supported by active format")
      opticalStabilizationEnabled = false
      return false
    }
    opticalStabilizationEnabled = enabled
    applyVideoStabilizationToCaptureUnit()
    return true
  }

  func isOpticalVideoStabilizationEnabled() throws -> Bool { return opticalStabilizationEnabled }

  // ─── Local recording ───────────────────────────────────────────────────────

  func startRecord(path: String) throws -> Bool {
    if path.isBlank { return false }
    if recordStatus != .stopped { return false }
    let destination = URL(fileURLWithPath: path)
    pendingRecordOutputUrl = destination
    let rec = StreamRecorder()
    recorder = rec
    let recVideoCodec: AVVideoCodecType = (videoCodec == .h265) ? .hevc : .h264
    let settings: [AVMediaType: [String: any Sendable]] = [
      .audio: [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: lastAudioCfg?.sampleRate ?? 44_100,
        AVNumberOfChannelsKey: (lastAudioCfg?.isStereo ?? true) ? 2 : 1,
      ],
      .video: [
        AVVideoCodecKey: recVideoCodec,
        AVVideoWidthKey: lastVideoCfg?.width ?? 1280,
        AVVideoHeightKey: lastVideoCfg?.height ?? 720,
      ],
    ]
    Task { [weak self] in
      guard let self else { return }
      do {
        await self.mixer.addOutput(rec)
        try await rec.startRecording(destination, settings: settings)
        self.transitionRecordStatus(.started)
        self.transitionRecordStatus(.recording)
      } catch {
        self.log("startRecording failed: \(error)")
        self.recorder = nil
        self.transitionRecordStatus(.stopped)
      }
    }
    return true
  }

  func stopRecord() throws {
    guard let rec = recorder else {
      transitionRecordStatus(.stopped)
      return
    }
    recorder = nil
    Task { [weak self] in
      guard let self else { return }
      do {
        let producedURL = try await rec.stopRecording()
        if let dest = self.pendingRecordOutputUrl, producedURL.path != dest.path {
          try? FileManager.default.removeItem(at: dest)
          try? FileManager.default.moveItem(at: producedURL, to: dest)
        }
        self.pendingRecordOutputUrl = nil
        self.transitionRecordStatus(.stopped)
      } catch {
        self.log("stopRecording failed: \(error)")
        self.transitionRecordStatus(.stopped)
      }
    }
  }

  func pauseRecord() throws { transitionRecordStatus(.paused) }
  func resumeRecord() throws {
    transitionRecordStatus(.resumed)
    transitionRecordStatus(.recording)
  }
  func getRecordStatus() throws -> RecordStatus { return recordStatus }

  private func transitionRecordStatus(_ next: RecordStatus) {
    recordStatus = next
    emitRecordStatusChange(next)
  }

  // ─── Event callbacks ───────────────────────────────────────────────────────

  func setOnConnectionEvent(callback: @escaping (RtmpConnectionEvent, String) -> Void) throws {
    onConnectionEvent = callback
  }

  func setOnBitrateChange(callback: @escaping (Double) -> Void) throws {
    onBitrateChange = callback
    if cachedIsStreaming { startBitrateTimer() }
  }

  func setOnRecordStatusChange(callback: @escaping (RecordStatus) -> Void) throws {
    onRecordStatusChange = callback
  }

  // ─── Thermal monitoring ────────────────────────────────────────────────────

  func getThermalStatus() throws -> ThermalStatus {
    return ProcessInfo.processInfo.thermalState.toNitro()
  }

  func setOnThermalWarning(callback: @escaping (ThermalStatus) -> Void) throws {
    onThermalWarning = callback
    registerThermalObserver()
  }

  // ─── Camera FPS lock / long-stream tuning ─────────────────────────────────

  func setForceFpsLimit(enabled: Bool) throws {
    desiredForceFpsLimit = enabled
    applyCameraFpsLock()
  }

  func forceIncrementalTs(enabled: Bool) throws {
    // HaishinKit emits monotonic RTMP timestamps internally. Kept for API parity.
  }

  func setStreamDelay(delayMs: Double) throws {
    // HaishinKit 2.x doesn't expose a send-side delay knob. Kept for API parity.
  }

  // ─── Drop / cleanup ────────────────────────────────────────────────────────

  func onDropView() {
    shouldBeStreaming = false
    lastPreview = nil
    pendingStreamKey = nil
    userRotationOverride = nil
    reconnectTask?.cancel()
    reconnectTask = nil
    stopBitrateTimer()
    statusObserverTask?.cancel()
    streamStatusObserverTask?.cancel()
    // Same fire-and-forget pattern as rebuildPipeline — RTMPStream/Connection
    // close() each await an AMF roundtrip with a 15s ceiling; on a dropped /
    // backgrounded socket they always time out. Awaiting them serially during
    // teardown can hang the Task for up to 30s, keeping `previewView` +
    // `mixer` alive after the user navigated away. ARC + OS socket reaping
    // handle cleanup either way; the server gets an RST.
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
      Task { try? await rec.stopRecording() }
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
    onRecordStatusChange = nil
    onThermalWarning = nil
  }

  // ─── Internals: settings application ───────────────────────────────────────

  private func applyVideoSettings() {
    guard let cfg = lastVideoCfg else { return }

    let r = cfg.rotation
    let orientation: AVCaptureVideoOrientation
    switch r {
    case 90:  orientation = .landscapeRight
    case 180: orientation = .portraitUpsideDown
    case 270: orientation = .landscapeLeft
    default:  orientation = .portrait
    }

    // Swap encoder dimensions for portrait. See the original 1.x comment —
    // JS passes Android-convention landscape dims and we rotate internally.
    let isPortrait = (orientation == .portrait || orientation == .portraitUpsideDown)
    let encodedWidth  = isPortrait ? min(cfg.width, cfg.height) : max(cfg.width, cfg.height)
    let encodedHeight = isPortrait ? max(cfg.width, cfg.height) : min(cfg.width, cfg.height)

    Task { [weak self] in
      guard let self else { return }
      var settings = await self.stream.videoSettings
      settings.videoSize = .init(width: encodedWidth, height: encodedHeight)
      settings.bitRate = cfg.bitrate
      settings.maxKeyFrameIntervalDuration = Int32(cfg.iFrameInterval)
      settings.scalingMode = .trim
      if self.videoCodec == .h265 {
        settings.profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel as String
      } else {
        settings.profileLevel = kVTProfileLevel_H264_Baseline_AutoLevel as String
      }
      try? await self.stream.setVideoSettings(settings)
      try? await self.mixer.setFrameRate(Float64(cfg.fps))
      await self.mixer.setVideoOrientation(orientation)
    }
  }

  private func applyAudioSettings() {
    guard let cfg = lastAudioCfg else { return }
    let muted = cachedAudioMuted
    Task { [weak self] in
      guard let self else { return }
      var settings = await self.stream.audioSettings
      settings.bitRate = cfg.bitrate
      try? await self.stream.setAudioSettings(settings)
      // Preserve the user's mute state across rebuilds — AudioMixerSettings
      // resets `isMuted` to false on init, so a re-apply (e.g. after
      // prepareAudio) would silently unmute the user.
      var mixerSettings = AudioMixerSettings(
        sampleRate: Float64(cfg.sampleRate),
        channels: UInt32(cfg.isStereo ? 2 : 1)
      )
      mixerSettings.isMuted = muted
      await self.mixer.setAudioMixerSettings(mixerSettings)
    }
  }

  private func applyMirrorFlags() {
    // On iOS preview and stream share the same capture buffer. Toggling
    // `isVideoMirrored` flips both surfaces; the UIView transform only
    // distinguishes them when mirrorPreview != mirrorStream.
    let mirror = mirrorStream
    Task { [weak self] in
      guard let self else { return }
      try? await self.mixer.configuration(video: 0) { unit in
        unit.isVideoMirrored = mirror
      }
    }
    let extraFlipPreview = (mirrorPreview != mirrorStream)
    let transform: CGAffineTransform = extraFlipPreview
      ? CGAffineTransform(scaleX: -1, y: 1)
      : .identity
    // UIView mutation must hop to main — applyMirrorFlags is often called
    // from Task continuations resuming on a background executor (after
    // awaiting MediaMixer). UIKit silently queues background writes to
    // main with non-zero latency, which manifests as the preview lagging
    // 1-2s behind the camera frames on resume.
    onMain { [weak self] in self?.previewView.transform = transform }
  }

  private func applyVideoStabilizationToCaptureUnit() {
    let mode = currentStabilizationMode
    Task { [weak self] in
      guard let self else { return }
      try? await self.mixer.configuration(video: 0) { unit in
        unit.preferredVideoStabilizationMode = mode
      }
    }
  }

  private var currentStabilizationMode: AVCaptureVideoStabilizationMode {
    if opticalStabilizationEnabled { return .cinematic }
    if videoStabilizationEnabled { return .standard }
    return .off
  }

  private func attachCameraAndMic() {
    let position: AVCaptureDevice.Position = (currentFacing == .front) ? .front : .back
    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
      log("attachCameraAndMic: no camera for \(currentFacing)")
      return
    }
    currentDevice = camera
    cachedZoom = Double(camera.videoZoomFactor)
    cachedZoomRange = (
      Double(camera.minAvailableVideoZoomFactor),
      Double(camera.maxAvailableVideoZoomFactor)
    )
    cachedExposureRange = (camera.minExposureTargetBias, camera.maxExposureTargetBias)

    // Sync UIView side of the mirror flag up-front so the preview transform
    // is already correct when the first new frame arrives.
    let extraFlipPreview = (mirrorPreview != mirrorStream)
    let previewTransform: CGAffineTransform = extraFlipPreview
      ? CGAffineTransform(scaleX: -1, y: 1)
      : .identity
    onMain { [weak self] in self?.previewView.transform = previewTransform }

    let mirror = mirrorStream
    let stabilization = currentStabilizationMode
    let mic = AVCaptureDevice.default(for: .audio)
    Task { [weak self] in
      guard let self else { return }
      do {
        // Apply mirror + stabilization atomically inside the attach so the
        // first frame from the new AVCaptureInput is already mirrored and
        // stabilized. Without this the camera-control settings get applied
        // after capture is wired and we get a ~1-2s window of unmirrored
        // frames — especially noticeable on the front camera.
        try await self.mixer.attachVideo(camera) { unit in
          unit.isVideoMirrored = mirror
          unit.preferredVideoStabilizationMode = stabilization
        }
        if let mic {
          try? await self.mixer.attachAudio(mic)
        }
        // MediaMixer's async streams that feed outputs only start draining
        // after startRunning() — without it the preview stays black even
        // though capture is "attached." Safe to call repeatedly (guarded
        // by `isRunning` internally).
        await self.mixer.startRunning()
        self.pinVideoOrientation()
      } catch {
        self.log("attachVideo failed: \(error)")
      }
    }
    applyCameraFpsLock()
  }

  private func applyCameraFpsLock() {
    guard let device = currentDevice, let cfg = lastVideoCfg else { return }
    do {
      try device.lockForConfiguration()
      if desiredForceFpsLimit {
        let duration = CMTime(value: 1, timescale: Int32(cfg.fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
      } else {
        device.activeVideoMinFrameDuration = .invalid
        device.activeVideoMaxFrameDuration = .invalid
      }
      device.unlockForConfiguration()
    } catch {
      log("applyCameraFpsLock failed: \(error)")
    }
  }

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      let mode: AVAudioSession.Mode
      if noiseSuppression {
        mode = .voiceChat
      } else {
        switch audioSource {
        case .mic:
          mode = .default
        case .voicecommunication:
          mode = .voiceChat
        case .camcorder:
          mode = .videoRecording
        case .voicerecognition,
             .unprocessed:
          mode = .measurement
        }
      }

      var options: AVAudioSession.CategoryOptions = []
      if #available(iOS 8.0, *) {
        #if compiler(>=6.0)
        options.insert(.allowBluetoothHFP)
        #else
        options.insert(.allowBluetooth)
        #endif
      }
      try session.setCategory(.playAndRecord, mode: mode, options: options)

      if let inputs = session.availableInputs,
         let mic = inputs.first(where: { $0.portType == .builtInMic }),
         let source = mic.preferredDataSource ?? mic.dataSources?.first,
         let patterns = source.supportedPolarPatterns,
         patterns.contains(.cardioid) {
        try? source.setPreferredPolarPattern(.cardioid)
        try? mic.setPreferredDataSource(source)
      }

      try session.setActive(true)
    } catch {
      log("configureAudioSession failed: \(error)")
    }
  }

  private func applyStreamMode() {
    // HaishinKit 2.x doesn't expose the same chunkSize / qualityOfService
    // knobs on RTMPConnection that 1.x had at the public API surface — most
    // pipeline tuning is hidden inside the actor now. We keep the prop in
    // the spec for API parity; the practical effect is encoder bitrate
    // adjustments via adaptive bitrate.
  }

  // ─── Bitrate timer ─────────────────────────────────────────────────────────

  private func startBitrateTimer() {
    stopBitrateTimer()
    // Reset so stale samples from a previous publish don't bleed into the new
    // session before the first NetworkMonitor tick (~3s).
    lastMeasuredBps = 0
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + 1.0, repeating: 1.0)
    t.setEventHandler { [weak self] in self?.onBitrateTick() }
    t.resume()
    bitrateTimer = t
  }

  private func stopBitrateTimer() {
    bitrateTimer?.cancel()
    bitrateTimer = nil
  }

  private func onBitrateTick() {
    // Prefer the real measured throughput captured by PublisherBitrateStrategy
    // from HK's internal NetworkMonitor. Until the first .status event arrives
    // (the monitor ticks every ~3s), fall back to the encoder's configured
    // bitrate so the UI shows *something* instead of zero.
    if lastMeasuredBps > 0 {
      emitBitrateChange(lastMeasuredBps)
      // Track the configured bitrate too so getCurrentBitrate stays useful.
      Task { [weak self] in
        guard let self else { return }
        let vBps = await self.stream.videoSettings.bitRate
        self.adaptiveCurrentBitrate = vBps
      }
    } else {
      Task { [weak self] in
        guard let self else { return }
        let vBps = await self.stream.videoSettings.bitRate
        let aBps = await self.stream.audioSettings.bitRate
        self.emitBitrateChange(Double(vBps + aBps))
      }
    }
  }

  // ─── Orientation observer ──────────────────────────────────────────────────

  private var orientationObserver: NSObjectProtocol?
  private func enableOrientationObserver() {
    if orientationObserver != nil { return }
    onMain { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
    orientationObserver = NotificationCenter.default.addObserver(
      forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      let avo: AVCaptureVideoOrientation
      switch UIDevice.current.orientation {
      case .landscapeLeft:        avo = .landscapeRight
      case .landscapeRight:       avo = .landscapeLeft
      case .portraitUpsideDown:   avo = .portraitUpsideDown
      case .portrait, .unknown, .faceUp, .faceDown:
        avo = .portrait
      @unknown default:           avo = .portrait
      }
      // Keep the cache in step with what we push to the mixer.
      self.cachedDeviceOrientation = avo
      Task { await self.mixer.setVideoOrientation(avo) }
    }
  }

  private func disableOrientationObserver() {
    if let obs = orientationObserver {
      NotificationCenter.default.removeObserver(obs)
      orientationObserver = nil
    }
    onMain { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
  }

  // ─── Thermal observer ──────────────────────────────────────────────────────

  private func registerThermalObserver() {
    if thermalObserver != nil { return }
    lastThermalState = ProcessInfo.processInfo.thermalState
    thermalObserver = NotificationCenter.default.addObserver(
      forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      let new = ProcessInfo.processInfo.thermalState
      let previous = self.lastThermalState
      self.lastThermalState = new
      let threshold = self.thermalThreshold.toProcessInfoState()
      let enteringOrInZone = new.severityRank >= threshold.severityRank
      let justCleared = previous.severityRank >= threshold.severityRank && new.severityRank < threshold.severityRank
      if enteringOrInZone || justCleared {
        self.emitThermalWarning(new.toNitro())
      }
    }
  }

  private func unregisterThermalObserver() {
    if let obs = thermalObserver {
      NotificationCenter.default.removeObserver(obs)
      thermalObserver = nil
    }
  }

  // ─── RTMP status event handler (from connection.status AsyncStream) ───────

  private func handleRtmpStatus(_ status: RTMPStatus) {
    let code = status.code
    switch code {
    case RTMPConnection.Code.connectSuccess.rawValue:
      // Internal state transition only — pin orientation now that we have a
      // live connection, but DON'T emit `.connectionsuccess` to JS yet.
      // `connectSuccess` is NetConnection.Connect.Success (AMF handshake
      // done); the publish hasn't started yet. The post-publish path in
      // `startStream` / `scheduleReconnect` emits `.connectionsuccess`
      // once we actually have a publishing stream — that's the moment
      // JS should treat us as "live". Without this elision, JS sees two
      // `.connectionsuccess` events ~2s apart (handshake → publish).
      adaptiveCurrentBitrate = lastVideoCfg?.bitrate ?? adaptiveCurrentBitrate
      pinVideoOrientation()
    case RTMPConnection.Code.connectFailed.rawValue,
         RTMPConnection.Code.connectClosed.rawValue:
      let isFailed = (code == RTMPConnection.Code.connectFailed.rawValue)
      stopBitrateTimer()
      cachedIsStreaming = false
      if tryAutoReconnect(reason: code) { return }
      shouldBeStreaming = false
      emitConnectionEvent(isFailed ? .connectionfailed : .disconnect, code)
    case RTMPConnection.Code.connectRejected.rawValue,
         RTMPConnection.Code.connectInvalidApp.rawValue:
      let desc = status.description
      let isAuth = desc.lowercased().contains("auth") || desc.lowercased().contains("not authorized")
      if isAuth {
        emitConnectionEvent(.autherror, desc)
      } else {
        emitConnectionEvent(.connectionfailed, desc)
      }
    default:
      break
    }
  }

  // ─── NetStream.* status events (from RTMPStream.status AsyncStream) ───────
  //
  // `connection.status` carries NetConnection.* events (handshake / connect /
  // auth). The per-stream status carries NetStream.Publish.*, .Unpublish.*,
  // .Failed, .Play.* — these would otherwise only surface as a generic
  // `requestTimedOut` from the publish() continuation, masking the real
  // reason (bad stream name, server-side rejection, …).

  private func handleStreamStatus(_ status: RTMPStatus) {
    let code = status.code
    let desc = status.description
    switch code {
    case RTMPStream.Code.publishStart.rawValue:
      // Server has accepted the publish — best-effort confirmation. We
      // already emitted .connectionsuccess from the connect path; this
      // is just useful diagnostic info.
      log("publishStart: \(desc)")
    case RTMPStream.Code.unpublishSuccess.rawValue:
      log("unpublishSuccess: \(desc)")
    case RTMPStream.Code.publishBadName.rawValue:
      // The stream key was rejected (auth expired, duplicate, malformed).
      // Surface this to JS — the publish() continuation will still time
      // out 15s later, but we can fail fast here.
      cachedIsStreaming = false
      stopBitrateTimer()
      let isAuth = desc.lowercased().contains("auth") || desc.lowercased().contains("not authorized")
      emitConnectionEvent(isAuth ? .autherror : .connectionfailed, "publishBadName: \(desc)")
    case RTMPStream.Code.failed.rawValue,
         RTMPStream.Code.playFailed.rawValue,
         RTMPStream.Code.playStreamNotFound.rawValue:
      cachedIsStreaming = false
      stopBitrateTimer()
      emitConnectionEvent(.connectionfailed, "\(code): \(desc)")
    default:
      break
    }
  }

  private func subscribeToStreamStatus(_ stream: RTMPStream) {
    streamStatusObserverTask?.cancel()
    let generation = pipelineGeneration
    streamStatusObserverTask = Task { [weak self] in
      guard let self else { return }
      for await status in await stream.status {
        // Drop stale events from a torn-down stream actor. Swift Task
        // cancellation is cooperative — one event in flight at cancel time
        // can still reach this point. Without the guard, it stomps on the
        // new session's state.
        if self.pipelineGeneration != generation { return }
        self.handleStreamStatus(status)
      }
    }
  }

  /// (Re)subscribe to `self.connection.status`. The closure captures a
  /// snapshot of the current connection AND pipeline generation so a later
  /// rebuild (which swaps `self.connection` for a fresh actor and bumps the
  /// generation) doesn't leave us reacting to the dead AsyncStream — and,
  /// crucially, doesn't let a late `connectClosed` from the old connection
  /// emit a spurious `.disconnect` while the new session is healthy.
  private func subscribeToConnectionStatus() {
    statusObserverTask?.cancel()
    let conn = self.connection
    let generation = pipelineGeneration
    statusObserverTask = Task { [weak self] in
      guard let self else { return }
      for await status in await conn.status {
        if self.pipelineGeneration != generation { return }
        self.handleRtmpStatus(status)
      }
    }
  }

  /// Throw out the current `connection` + `stream` and build fresh ones.
  /// Required for every restart (initial publish, JS-side `startStream`
  /// retry, native auto-reconnect, foreground re-publish) because HK's
  /// `RTMPConnection.streams` array only clears on `deinit` — anything
  /// short of recreating the connection leaves dead `RTMPStream` actors
  /// in there, and the next `connect()` calls `createStream` on every
  /// one of them, drowning the AMF channel so our real publish's
  /// `publishStart` reply goes unmatched.
  private func rebuildPipeline(streamKey: String) async {
    // Bump the generation BEFORE cancelling — once incremented, any in-flight
    // status event from the old observers will fail the generation check and
    // bail out before reaching `handleRtmpStatus` / `handleStreamStatus`.
    // Cancelling alone isn't enough: Swift cancellation is cooperative and
    // a status value already pulled from the AsyncStream iterator still
    // fires one final handler call.
    pipelineGeneration &+= 1
    statusObserverTask?.cancel()
    streamStatusObserverTask?.cancel()

    let oldStream = self.stream
    let oldConnection = self.connection
    await self.mixer.removeOutput(oldStream)

    // Fire-and-forget the polite RTMP goodbye. RTMPStream.close() sends an
    // unpublish AMF command and awaits `unpublishSuccess` for up to
    // `requestTimeout` (15s); RTMPConnection.close() then walks every stream,
    // calling `FCUnpublish` + `deleteStream` and awaiting responses with the
    // same 15s ceiling. On a dead socket (the common case after a background
    // suspension) those calls always time out — awaiting them serially adds
    // up to ~30s of unrecoverable latency before we can even start the new
    // publish. ARC reclaims both actors once these tasks complete, and the
    // OS closes the abandoned TCP socket when references drop. The server
    // gets a clean RST either way.
    Task { _ = try? await oldStream.close() }
    Task { try? await oldConnection.close() }

    let newConnection = RTMPConnection(requestTimeout: 15_000)
    let newStream = RTMPStream(connection: newConnection, fcPublishName: streamKey)
    self.connection = newConnection
    self.stream = newStream

    subscribeToConnectionStatus()
    subscribeToStreamStatus(newStream)
    await self.mixer.addOutput(newStream)
    await installBitrateStrategy(on: newStream)
    applyVideoSettings()
    applyAudioSettings()
  }

  // ─── Orientation pin ──────────────────────────────────────────────────────

  private func pinVideoOrientation() {
    let target: AVCaptureVideoOrientation
    if let override = userRotationOverride {
      target = override
    } else if autoRotateStream {
      target = currentVideoOrientation()
    } else {
      target = .portrait
    }
    Task { [weak self] in
      guard let self else { return }
      await self.mixer.setVideoOrientation(target)
    }
  }

  /// Read the latest cached orientation (refreshed by the orientation
  /// observer and `refreshOrientationCacheOnMain`). Safe from any thread.
  private func currentVideoOrientation() -> AVCaptureVideoOrientation {
    return cachedDeviceOrientation
  }

  /// Prime / refresh `cachedDeviceOrientation` by reading UIKit on main.
  /// UIDevice + UIApplication require main thread; this is the only place
  /// we touch them. Fire from any context; updates the cache asynchronously.
  private func refreshOrientationCacheOnMain() {
    onMain { [weak self] in
      guard let self else { return }
      let device = UIDevice.current.orientation
      switch device {
      case .portrait:           self.cachedDeviceOrientation = .portrait; return
      case .portraitUpsideDown: self.cachedDeviceOrientation = .portraitUpsideDown; return
      case .landscapeLeft:      self.cachedDeviceOrientation = .landscapeRight; return
      case .landscapeRight:     self.cachedDeviceOrientation = .landscapeLeft; return
      default: break
      }
      if #available(iOS 13.0, *),
         let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
        switch scene.interfaceOrientation {
        case .landscapeLeft:      self.cachedDeviceOrientation = .landscapeLeft
        case .landscapeRight:     self.cachedDeviceOrientation = .landscapeRight
        case .portraitUpsideDown: self.cachedDeviceOrientation = .portraitUpsideDown
        case .portrait, .unknown: self.cachedDeviceOrientation = .portrait
        @unknown default:         self.cachedDeviceOrientation = .portrait
        }
      }
    }
  }

  /// Fire-and-forget hop to main thread for UIKit-touching work.
  private func onMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() }
    else { DispatchQueue.main.async(execute: block) }
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  /// Split an RTMP URL into `(connectUrl, streamKey)`.
  ///
  /// Naive last-slash split fails on URLs where the query string is part of
  /// the publish name (`rtmp://host/app/streamName?auth=…`) — using
  /// `String.range(of:"/", options:.backwards)` on the raw URL would split at
  /// the `/` inside `auth=path/whatever` when servers embed slashes in
  /// signed params. We split on the last `/` BEFORE any `?`, then re-attach
  /// the query string to the stream key so HK passes it verbatim in the
  /// publish AMF command (FB Live / Instagram / Wowza signed auth all rely
  /// on this).
  private func splitRtmpUrl(_ url: String) -> (connectUrl: String, streamKey: String) {
    let pathPart: String
    let queryPart: String
    if let q = url.range(of: "?") {
      pathPart = String(url[..<q.lowerBound])
      queryPart = String(url[q.lowerBound...])  // includes the "?"
    } else {
      pathPart = url
      queryPart = ""
    }
    guard let lastSlash = pathPart.range(of: "/", options: .backwards) else {
      return (url, "")
    }
    let connect = String(pathPart[..<lastSlash.lowerBound])
    let name = String(pathPart[lastSlash.upperBound...])
    return (connect, name + queryPart)
  }

  private func log(_ message: String) {
    #if DEBUG
    NSLog("\(TAG): \(message)")
    #endif
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Mapping helpers
// ────────────────────────────────────────────────────────────────────────────

private extension AspectRatioMode {
  var avLayerGravity: AVLayerVideoGravity {
    switch self {
    case .fill:   return .resizeAspectFill
    case .adjust: return .resizeAspect
    case .none:   return .resize
    }
  }
}

private extension ProcessInfo.ThermalState {
  var severityRank: Int {
    switch self {
    case .nominal:  return 0
    case .fair:     return 1
    case .serious:  return 3
    case .critical: return 4
    @unknown default: return 0
    }
  }
  func toNitro() -> ThermalStatus {
    switch self {
    case .nominal:  return .none
    case .fair:     return .light
    case .serious:  return .severe
    case .critical: return .critical
    @unknown default: return .none
    }
  }
}

private extension ThermalStatus {
  func toProcessInfoState() -> ProcessInfo.ThermalState {
    switch self {
    case .none, .light:                      return .fair
    case .moderate, .severe:                 return .serious
    case .critical, .emergency, .shutdown:   return .critical
    }
  }
}

private extension String {
  var isBlank: Bool { trimmingCharacters(in: .whitespaces).isEmpty }
}

private extension Double {
  func clamped(_ lower: Double, _ upper: Double) -> Double {
    return Swift.min(Swift.max(self, lower), upper)
  }
}

private extension CGFloat {
  func clamped(_ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    return Swift.min(Swift.max(self, lower), upper)
  }
}

private extension Float {
  func clamped(_ lower: Float, _ upper: Float) -> Float {
    return Swift.min(Swift.max(self, lower), upper)
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Bit-rate strategy
// ────────────────────────────────────────────────────────────────────────────
//
// HaishinKit's NetworkMonitor is private on RTMPConnection, so we can't read
// `totalBytesOut` or `currentBytesOutPerSecond` directly. But HK *does* call
// `stream.bitRateStrategy?.adjustBitrate(event, stream:)` on every monitor
// tick — meaning the throughput data is plumbed through the strategy hook
// we set via `setBitRateStrategy`. We install a custom strategy on every
// active RTMPStream that:
//   1. Forwards `currentBytesOutPerSecond × 8` to a Sendable sink → JS-side
//      `onBitrateChange` reports the actual measured send rate.
//   2. When JS-side adaptive bitrate is enabled, also delegates to HK's
//      built-in `StreamVideoAdaptiveBitRateStrategy` which adjusts the
//      encoder bitrate in response to `publishInsufficientBWOccured`.
//
final class PublisherBitrateStrategy: StreamBitRateStrategy, @unchecked Sendable {
  let mamimumVideoBitRate: Int
  let mamimumAudioBitRate: Int = 0

  private let inner: StreamVideoAdaptiveBitRateStrategy?
  private let onThroughputBps: @Sendable (Int) -> Void

  init(maxVideoBitRate: Int, adaptive: Bool, onThroughputBps: @escaping @Sendable (Int) -> Void) {
    self.mamimumVideoBitRate = maxVideoBitRate
    self.inner = adaptive ? StreamVideoAdaptiveBitRateStrategy(mamimumVideoBitrate: maxVideoBitRate) : nil
    self.onThroughputBps = onThroughputBps
  }

  func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
    switch event {
    case .status(let report):
      onThroughputBps(report.currentBytesOutPerSecond * 8)
    case .publishInsufficientBWOccured(let report):
      onThroughputBps(report.currentBytesOutPerSecond * 8)
    case .reset:
      break
    }
    await inner?.adjustBitrate(event, stream: stream)
  }
}
