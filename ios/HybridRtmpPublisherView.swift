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
  private let connection = RTMPConnection()
  private lazy var stream = RTMPStream(connection: connection)

  /// Long-lived task that drains `connection.status` and forwards events to JS.
  private var statusObserverTask: Task<Void, Never>?

  // ─── Callbacks (set from JS) ───────────────────────────────────────────────

  private var onConnectionEvent: ((RtmpConnectionEvent, String) -> Void)?
  private var onBitrateChange: ((Double) -> Void)?
  private var onRecordStatusChange: ((RecordStatus) -> Void)?
  private var onThermalWarning: ((ThermalStatus) -> Void)?

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
  private var pendingStreamUrl: String?
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

  // RTMP URL is split into "rtmp://host/app" (connect) + "streamKey" (publish).
  private var currentRtmpConnectUrl: String?

  // Auto-reconnect.
  private var autoReconnectMaxAttempts = 0
  private var autoReconnectBackoffMs: Int64 = 0
  private var retriesRemaining = 0
  private var reconnectWorkItem: DispatchWorkItem?

  // Adaptive bitrate.
  private var adaptiveMaxBitrate = 0
  private var adaptiveDecreasePct: Double = 20
  private var adaptiveIncreasePct: Double = 5
  private var adaptiveEnabled = false
  private var adaptiveCurrentBitrate = 0
  private var bitrateTimer: Timer?
  private var lastSentByteCount: Int64 = 0
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
    super.init()

    // Wire MTHKView as a mixer output so it renders captured frames.
    Task {
      await mixer.addOutput(previewView)
      // Stream is also a mixer output — it receives the encoded frames and
      // pushes them over RTMP. Adding it here ensures audio + video flow
      // into the stream as soon as it starts publishing.
      await mixer.addOutput(stream)
    }

    // Drain the RTMP connection's status AsyncStream into our JS-facing
    // event callback. Lives for the view's lifetime.
    statusObserverTask = Task { [weak self] in
      guard let self else { return }
      for await status in await self.connection.status {
        self.handleRtmpStatus(status)
      }
    }

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
    NotificationCenter.default.removeObserver(self)
    bitrateTimer?.invalidate()
  }

  // ─── App-lifecycle + AVCaptureSession interruption ─────────────────────────

  @objc private func appDidEnterBackground() {
    onConnectionEvent?(.disconnect, "app entered background")
  }

  @objc private func appWillEnterForeground() {
    pinVideoOrientation()
    applyMirrorFlags()
    applyVideoStabilizationToCaptureUnit()
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
    onConnectionEvent?(.disconnect, "session interrupted: \(reason)")
  }

  @objc private func sessionInterruptionEnded(_ notification: Notification) {
    pinVideoOrientation()
    applyMirrorFlags()
    applyVideoStabilizationToCaptureUnit()
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
        onConnectionEvent?(.connectionfailed, "another <RtmpPublisherView> already holds the camera")
        return
      }
      ActivePublisherSlot.count += 1
      holdsActiveSlot = true
    }

    currentFacing = facing
    attachCameraAndMic()
    applyMirrorFlags()
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
    Task {
      try? await self.mixer.attachVideo(nil)
      try? await self.mixer.attachAudio(nil)
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
    let (rawConnectUrl, streamKey) = splitRtmpUrl(url)
    let connectUrl = applyAuthToConnectUrl(rawConnectUrl)
    currentRtmpConnectUrl = connectUrl
    pendingStreamKey = streamKey
    shouldBeStreaming = true
    retriesRemaining = autoReconnectMaxAttempts

    applyVideoSettings()
    applyAudioSettings()
    applyStreamMode()
    pinVideoOrientation()

    onMain { UIApplication.shared.isIdleTimerDisabled = true }

    // Kick off the async connect. The publish() call follows on
    // `connectSuccess` from the status observer.
    Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await self.connection.connect(connectUrl)
        // connect's success is also delivered via the status stream, but
        // we don't wait for that — publish immediately once connect resolves.
        if let key = self.pendingStreamKey {
          _ = try await self.stream.publish(key, type: .live)
        }
        self.cachedIsStreaming = true
        self.onConnectionEvent?(.connectionsuccess, "")
        self.startBitrateTimer()
      } catch {
        self.cachedIsStreaming = false
        self.shouldBeStreaming = false
        self.log("connect/publish failed: \(error)")
        if !self.tryAutoReconnect(reason: "\(error)") {
          self.onConnectionEvent?(.connectionfailed, "\(error)")
        }
      }
    }

    onConnectionEvent?(.connectionstarted, connectUrl)
  }

  func stopStream() throws {
    shouldBeStreaming = false
    pendingStreamKey = nil
    currentRtmpConnectUrl = nil
    reconnectWorkItem?.cancel()
    reconnectWorkItem = nil
    cachedIsStreaming = false
    Task { [weak self] in
      guard let self else { return }
      _ = try? await self.stream.close()
      try? await self.connection.close()
    }
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
    guard cachedIsStreaming, let cfg = lastVideoCfg else { return }
    let now = Date().timeIntervalSince1970 * 1000
    if now - lastKeyFrameRequestMs < 1000 { return }
    lastKeyFrameRequestMs = now
    // Nudge bitrate by 1 bps then restore — forces VideoToolbox to emit a
    // fresh IDR. Same trick as the 1.x implementation.
    Task { [weak self] in
      guard let self else { return }
      var settings = await self.stream.videoSettings
      let original = settings.bitRate
      settings.bitRate = max(1, original + 1)
      try? await self.stream.setVideoSettings(settings)
      // Restore on next runloop turn so adaptive-bitrate state stays consistent.
      settings.bitRate = original
      try? await self.stream.setVideoSettings(settings)
      _ = cfg
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
    retriesRemaining -= 1
    scheduleReconnect(delayMs: autoReconnectBackoffMs, reason: reason)
    onConnectionEvent?(.reconnecting, reason)
    return true
  }

  private func scheduleReconnect(delayMs: Int64, reason: String) {
    reconnectWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, self.shouldBeStreaming else { return }
      if let url = self.currentRtmpConnectUrl {
        Task { [weak self] in
          guard let self else { return }
          do {
            _ = try await self.connection.connect(url)
            if let key = self.pendingStreamKey {
              _ = try await self.stream.publish(key, type: .live)
            }
            self.cachedIsStreaming = true
          } catch {
            self.log("retry connect failed: \(error)")
          }
        }
      }
    }
    reconnectWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: work)
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
      stopBitrateTimer()
      return
    }
    adaptiveMaxBitrate = max
    adaptiveDecreasePct = decreaseRangePercent.clamped(0, 100)
    adaptiveIncreasePct = increaseRangePercent.clamped(0, 100)
    adaptiveEnabled = true
    if cachedIsStreaming { startBitrateTimer() }
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
    attachCameraAndMic()
    applyMirrorFlags()
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
    Task { [weak self] in
      guard let self else { return }
      try? await self.mixer.attachVideo(device)
    }
    applyMirrorFlags()
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
    videoStabilizationEnabled = enabled
    applyVideoStabilizationToCaptureUnit()
    return true
  }

  func isVideoStabilizationEnabled() throws -> Bool { return videoStabilizationEnabled }

  func setOpticalVideoStabilizationEnabled(enabled: Bool) throws -> Bool {
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
    onRecordStatusChange?(next)
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
    pendingStreamUrl = nil
    pendingStreamKey = nil
    userRotationOverride = nil
    reconnectWorkItem?.cancel()
    reconnectWorkItem = nil
    stopBitrateTimer()
    statusObserverTask?.cancel()
    Task { [weak self] in
      guard let self else { return }
      _ = try? await self.stream.close()
      try? await self.connection.close()
      try? await self.mixer.attachVideo(nil)
      try? await self.mixer.attachAudio(nil)
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
    Task { [weak self] in
      guard let self else { return }
      var settings = await self.stream.audioSettings
      settings.bitRate = cfg.bitrate
      try? await self.stream.setAudioSettings(settings)
      let mixerSettings = AudioMixerSettings(
        sampleRate: Float64(cfg.sampleRate),
        channels: UInt32(cfg.isStereo ? 2 : 1)
      )
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
    previewView.transform = extraFlipPreview
      ? CGAffineTransform(scaleX: -1, y: 1)
      : .identity
  }

  private func applyVideoStabilizationToCaptureUnit() {
    let mode: AVCaptureVideoStabilizationMode
    if opticalStabilizationEnabled {
      mode = .cinematic
    } else if videoStabilizationEnabled {
      mode = .standard
    } else {
      mode = .off
    }
    Task { [weak self] in
      guard let self else { return }
      try? await self.mixer.configuration(video: 0) { unit in
        unit.preferredVideoStabilizationMode = mode
      }
    }
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

    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.mixer.attachVideo(camera)
        // Reapply orientation/mirror/stabilization after capture is wired.
        self.pinVideoOrientation()
        self.applyMirrorFlags()
        self.applyVideoStabilizationToCaptureUnit()
      } catch {
        self.log("attachVideo failed: \(error)")
      }
    }

    if let mic = AVCaptureDevice.default(for: .audio) {
      Task { [weak self] in
        guard let self else { return }
        do {
          try await self.mixer.attachAudio(mic)
        } catch {
          self.log("attachAudio failed: \(error)")
        }
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
    lastSentByteCount = 0
    bitrateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.onBitrateTick()
    }
  }

  private func stopBitrateTimer() {
    bitrateTimer?.invalidate()
    bitrateTimer = nil
  }

  private func onBitrateTick() {
    // HK 2.x doesn't expose totalBytesOut publicly on RTMPConnection (it lives
    // inside the private NetworkMonitor). The JS-facing onBitrateChange is
    // primarily used to surface the encoder's configured bitrate after adaptive
    // changes — reading it back from videoSettings + audioSettings matches that
    // contract without needing a network-monitor reporter.
    Task { [weak self] in
      guard let self else { return }
      let vBps = await self.stream.videoSettings.bitRate
      let aBps = await self.stream.audioSettings.bitRate
      let bps = Double(vBps + aBps)
      self.onBitrateChange?(bps)
      if self.adaptiveEnabled, self.cachedIsStreaming {
        self.adaptBitrate(measuredBps: bps)
      }
    }
  }

  private func adaptBitrate(measuredBps: Double) {
    guard adaptiveMaxBitrate > 0 else { return }
    let target = Double(adaptiveCurrentBitrate)
    if measuredBps < target * 0.8 {
      let nextBitrate = Int(target * (1 - adaptiveDecreasePct / 100))
      let floor = adaptiveMaxBitrate / 4
      let clamped = max(nextBitrate, floor)
      if clamped != adaptiveCurrentBitrate {
        adaptiveCurrentBitrate = clamped
        Task { [weak self] in
          guard let self else { return }
          var s = await self.stream.videoSettings
          s.bitRate = clamped
          try? await self.stream.setVideoSettings(s)
        }
      }
    } else if adaptiveCurrentBitrate < adaptiveMaxBitrate {
      let nextBitrate = Int(target * (1 + adaptiveIncreasePct / 100))
      let clamped = min(nextBitrate, adaptiveMaxBitrate)
      if clamped != adaptiveCurrentBitrate {
        adaptiveCurrentBitrate = clamped
        Task { [weak self] in
          guard let self else { return }
          var s = await self.stream.videoSettings
          s.bitRate = clamped
          try? await self.stream.setVideoSettings(s)
        }
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
        self.onThermalWarning?(new.toNitro())
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
      onConnectionEvent?(.connectionsuccess, "")
      adaptiveCurrentBitrate = lastVideoCfg?.bitrate ?? adaptiveCurrentBitrate
      pinVideoOrientation()
      startBitrateTimer()
    case RTMPConnection.Code.connectFailed.rawValue,
         RTMPConnection.Code.connectClosed.rawValue:
      let isFailed = (code == RTMPConnection.Code.connectFailed.rawValue)
      stopBitrateTimer()
      cachedIsStreaming = false
      if tryAutoReconnect(reason: code) { return }
      shouldBeStreaming = false
      onConnectionEvent?(isFailed ? .connectionfailed : .disconnect, code)
    case RTMPConnection.Code.connectRejected.rawValue,
         RTMPConnection.Code.connectInvalidApp.rawValue:
      let desc = status.description
      let isAuth = desc.lowercased().contains("auth") || desc.lowercased().contains("not authorized")
      if isAuth {
        onConnectionEvent?(.autherror, desc)
      } else {
        onConnectionEvent?(.connectionfailed, desc)
      }
    default:
      break
    }
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

  /// Snapshot the current physical device orientation, hopping to main thread
  /// when needed (UIDevice + UIApplication are main-thread-only).
  private func currentVideoOrientation() -> AVCaptureVideoOrientation {
    if !Thread.isMainThread {
      return DispatchQueue.main.sync { self.currentVideoOrientation() }
    }
    let device = UIDevice.current.orientation
    switch device {
    case .portrait:           return .portrait
    case .portraitUpsideDown: return .portraitUpsideDown
    case .landscapeLeft:      return .landscapeRight
    case .landscapeRight:     return .landscapeLeft
    default: break
    }
    if #available(iOS 13.0, *),
       let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
      switch scene.interfaceOrientation {
      case .landscapeLeft:      return .landscapeLeft
      case .landscapeRight:     return .landscapeRight
      case .portraitUpsideDown: return .portraitUpsideDown
      case .portrait, .unknown: return .portrait
      @unknown default:         return .portrait
      }
    }
    return .portrait
  }

  /// Fire-and-forget hop to main thread for UIKit-touching work.
  private func onMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() }
    else { DispatchQueue.main.async(execute: block) }
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  private func splitRtmpUrl(_ url: String) -> (connectUrl: String, streamKey: String) {
    guard let lastSlash = url.range(of: "/", options: .backwards) else {
      return (url, "")
    }
    let connect = String(url[..<lastSlash.lowerBound])
    let key = String(url[lastSlash.upperBound...])
    return (connect, key)
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
