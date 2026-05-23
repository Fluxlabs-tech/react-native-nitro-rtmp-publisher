//
//  HybridRtmpPublisherView.swift
//  NitroRtmpPublisher
//
//  iOS implementation that mirrors the Android RootEncoder-backed
//  HybridRtmpPublisherView. Uses HaishinKit 1.9.x under the hood.
//
//  All per-frame paths (camera capture, Metal render, H.264/AAC encode,
//  RTMP TX) stay native — the JS bridge is only touched on lifecycle,
//  state changes, and (opt-in) bitrate / record-status updates.
//

import AVFoundation
import Foundation
import HaishinKit
import NitroModules
import UIKit
import VideoToolbox

private let TAG = "RtmpPublisherView"

// AVCaptureSession only really likes one active session per process if you're
// also using the same camera; track active publishers so a second mount fails
// loudly instead of fighting the first.
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

  // ─── HaishinKit ────────────────────────────────────────────────────────────

  private let rtmpConnection = RTMPConnection()
  private lazy var rtmpStream: RTMPStream = RTMPStream(connection: rtmpConnection)

  // ─── Callbacks (set from JS) ───────────────────────────────────────────────

  private var onConnectionEvent: ((RtmpConnectionEvent, String) -> Void)?
  private var onBitrateChange: ((Double) -> Void)?
  private var onRecordStatusChange: ((RecordStatus) -> Void)?
  private var onThermalWarning: ((ThermalStatus) -> Void)?

  // ─── Cached state ──────────────────────────────────────────────────────────

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

  // Recording state.
  private var recordStatus: RecordStatus = .stopped

  // Camera facing & device cache.
  private var currentFacing: CameraFacing = .back
  private var currentDevice: AVCaptureDevice?
  private var audioMuted = false

  // Slot ownership.
  private var holdsActiveSlot = false

  // Thermal monitoring (using ProcessInfo on iOS).
  private var thermalThreshold: ThermalStatus = .severe
  private var lastThermalState: ProcessInfo.ThermalState = .nominal
  private var thermalObserver: NSObjectProtocol?

  // Force FPS limit toggle (cached — applied when camera is attached).
  private var desiredForceFpsLimit = true

  // Stream mode tuning.
  private var lastWriteChunkBuffer: Int64 = 150

  // ─── Props (JSX) ───────────────────────────────────────────────────────────

  // iOS always uses VideoToolbox HW encoders for H.264/HEVC. We accept the
  // prop for API parity but the flag has no equivalent knob on this platform.
  var forceHardwareCodec: Bool = true

  var videoCodec: VideoCodec = .h264 {
    didSet {
      guard videoCodec != oldValue, !rtmpStream.readyState.isStreaming else { return }
      applyVideoCodecSetting()
    }
  }

  var audioCodec: AudioCodec = .aac {
    didSet {
      guard audioCodec != oldValue, !rtmpStream.readyState.isStreaming else { return }
      // HaishinKit 1.x only publishes AAC over RTMP. Warn the JS caller so they
      // know G.711 / Opus requests are silently dropped on iOS (they'll work
      // on the Android side, hence the API parity).
      if audioCodec != .aac {
        log("audioCodec=\(audioCodec.stringValue) is not supported by HaishinKit 1.9 — falling back to AAC")
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

  // iOS uses AVAudioSession categories — we translate the Android-style flag
  // into a category/mode pair when (re)preparing audio.
  var audioSource: AudioSource = .camcorder

  /// When true, forces `AVAudioSession.Mode.voiceChat` (built-in NS + AEC + AGC),
  /// overriding the `audioSource` mapping. Applied on the next `prepareAudio`
  /// call or when the prop changes mid-session.
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
      guard streamMode != oldValue, !rtmpStream.readyState.isStreaming else { return }
      applyStreamMode()
    }
  }

  // iOS doesn't have an equivalent of Android's foreground-service notification.
  // The streaming lifecycle is gated by the host app's UIBackgroundMode entitlements.
  var foregroundServiceTitle: String = ""
  var foregroundServiceText: String = ""

  // ─── Lifecycle: prepare ────────────────────────────────────────────────────

  override init() {
    super.init()
    rtmpConnection.addEventListener(.rtmpStatus, selector: #selector(rtmpStatusEvent(_:)), observer: self)

    // Surface app-lifecycle + AVCaptureSession-interruption events as
    // RtmpConnectionEvents so JS can update UI when iOS yanks the camera
    // (incoming call, Siri, control-center, etc.) or backgrounds the app.
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
    rtmpConnection.removeEventListener(.rtmpStatus, selector: #selector(rtmpStatusEvent(_:)), observer: self)
    NotificationCenter.default.removeObserver(self)
    bitrateTimer?.invalidate()
  }

  // ─── App-lifecycle + AVCaptureSession interruption ─────────────────────────

  @objc private func appDidEnterBackground() {
    // The host has declared `UIBackgroundModes: ["audio"]`, so audio capture
    // can survive. Video capture *cannot* — iOS revokes camera access in the
    // background. We notify JS so it can show a "stream paused" UI.
    onConnectionEvent?(.disconnect, "app entered background")
  }

  @objc private func appWillEnterForeground() {
    // Re-pin orientation + mirror + stabilization so the camera resumes in the
    // correct configuration. The user can manually call `startStream` again
    // if they want auto-resume — we don't second-guess.
    pinVideoOrientation()
    applyMirrorFlags()
    applyVideoStabilizationToCaptureUnit()
  }

  @objc private func sessionWasInterrupted(_ notification: Notification) {
    // Fires on phone call / Siri / control-center / another app grabs camera.
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
    // Camera is back. Reapply our config so the resumed session matches state.
    pinVideoOrientation()
    applyMirrorFlags()
    applyVideoStabilizationToCaptureUnit()
  }

  func prepareVideo(
    width: Double, height: Double, fps: Double, bitrate: Double,
    iFrameInterval: Double, rotation: Double
  ) throws -> Bool {
    if rtmpStream.readyState.isStreaming {
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
    if rtmpStream.readyState.isStreaming {
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
    previewView.attachStream(rtmpStream)
    applyMirrorFlags()
    if autoRotateStream { enableOrientationObserver() }
  }

  func stopPreview() throws {
    lastPreview = nil
    userRotationOverride = nil
    disableOrientationObserver()
    // If recording was active, finalize it before tearing down — otherwise
    // AVAssetWriter keeps trying to write samples it will never receive and
    // the resulting .mp4 is corrupt.
    if let rec = recorder {
      rec.stopRunning()
      rtmpStream.removeObserver(rec)
      recorder = nil
    }
    rtmpStream.attachCamera(nil)
    rtmpStream.attachAudio(nil)
    previewView.attachStream(nil)
    currentDevice = nil
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

    // Re-apply settings in case stop+start cycled the encoder.
    applyVideoSettings()
    applyAudioSettings()
    applyStreamMode()

    // Re-pin orientation: prepareVideo's `applyVideoSettings` may have set it
    // based on the JS-supplied `rotation` arg, but HaishinKit can stomp the
    // orientation again during session reconfiguration. Force the desired pose
    // right before connecting.
    pinVideoOrientation()

    // Keep the screen on for the duration of the stream — iOS equivalent of
    // Android's PARTIAL_WAKE_LOCK. Released in `stopStream` / `onDropView`.
    onMain { UIApplication.shared.isIdleTimerDisabled = true }

    // Connect first. `publish` is fired from rtmpStatusEvent on connectSuccess.
    rtmpConnection.connect(connectUrl)
    onConnectionEvent?(.connectionstarted, connectUrl)
  }

  func stopStream() throws {
    shouldBeStreaming = false
    pendingStreamKey = nil
    currentRtmpConnectUrl = nil
    reconnectWorkItem?.cancel()
    reconnectWorkItem = nil
    if rtmpStream.readyState != .initialized && rtmpStream.readyState != .closed {
      rtmpStream.close()
    }
    if rtmpConnection.connected {
      rtmpConnection.close()
    }
    stopBitrateTimer()
    onMain { UIApplication.shared.isIdleTimerDisabled = false }
  }

  func setAuthorization(user: String, password: String) throws {
    // HaishinKit 1.x doesn't have an explicit setAuthorization API — auth is
    // part of the RTMP `tcUrl`. We splice the credentials into the connect URL
    // on the next `startStream` (see `applyAuthToConnectUrl`).
    pendingAuthUser = user.isEmpty ? nil : user
    pendingAuthPass = password.isEmpty ? nil : password
  }

  private var pendingAuthUser: String?
  private var pendingAuthPass: String?

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
    // HaishinKit 1.9 has no public "force IDR" call. Workaround: write a
    // bitrate value DIFFERENT from the current one, which VideoToolbox treats
    // as a session reconfiguration and emits a fresh IDR. Then snap back to
    // the original value on the next tick. Debounced to once per second.
    guard rtmpStream.readyState.isStreaming else { return }
    let now = Date().timeIntervalSince1970 * 1000
    if now - lastKeyFrameRequestMs < 1000 { return }
    lastKeyFrameRequestMs = now
    var settings = rtmpStream.videoSettings
    let current = settings.bitRate
    settings.bitRate = max(1, current + 1)  // +1 bps so it's a real delta
    rtmpStream.videoSettings = settings
    // Restore the original value on the next runloop turn so adaptive bitrate
    // state stays consistent.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      var s = self.rtmpStream.videoSettings
      s.bitRate = current
      self.rtmpStream.videoSettings = s
    }
  }

  private var lastKeyFrameRequestMs: Double = 0

  /// User-supplied rotation override (degrees → AVCaptureVideoOrientation). When
  /// non-nil this takes priority over the auto-rotate observer in
  /// `pinVideoOrientation`. Cleared by `stopPreview`.
  private var userRotationOverride: AVCaptureVideoOrientation?

  func setStreamRotation(rotation: Double) throws {
    let orientation: AVCaptureVideoOrientation
    switch Int(rotation) {
    case 90:  orientation = .landscapeRight
    case 180: orientation = .portraitUpsideDown
    case 270: orientation = .landscapeLeft
    default:  orientation = .portrait
    }
    userRotationOverride = orientation
    rtmpStream.videoOrientation = orientation
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
    return true
  }

  private func scheduleReconnect(delayMs: Int64, reason: String) {
    reconnectWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, self.shouldBeStreaming else { return }
      if let url = self.currentRtmpConnectUrl {
        self.rtmpConnection.connect(url)
      }
    }
    reconnectWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: work)
  }

  // ─── Status / readouts ─────────────────────────────────────────────────────

  func isStreaming() throws -> Bool {
    return rtmpStream.readyState.isStreaming
  }

  func isOnPreview() throws -> Bool {
    return currentDevice != nil
  }

  func getCameraOrientation() throws -> Double {
    // Returns the rotation degrees that would put the published frame upright
    // for the user's *current* device pose. iOS uses AVCaptureVideoOrientation
    // (not Android-style sensor rotation), but the JS-facing return value
    // matches the Android convention so the same `prepareVideo(...)` call
    // works on both platforms.
    switch currentVideoOrientation() {
    case .portrait:           return 0
    case .landscapeRight:     return 90
    case .portraitUpsideDown: return 180
    case .landscapeLeft:      return 270
    @unknown default:         return 0
    }
  }

  func getStreamWidth() throws -> Double {
    return Double(lastVideoCfg?.width ?? 0)
  }

  func getStreamHeight() throws -> Double {
    return Double(lastVideoCfg?.height ?? 0)
  }

  func getCurrentBitrate() throws -> Double {
    return Double(lastVideoCfg?.bitrate ?? 0)
  }

  // ─── Adaptive bitrate ──────────────────────────────────────────────────────

  func setVideoBitrateOnFly(bitrate: Double) throws {
    let b = Int(bitrate)
    guard b > 0 else { return }
    guard rtmpStream.readyState.isStreaming else {
      log("setVideoBitrateOnFly ignored — not streaming")
      return
    }
    var settings = rtmpStream.videoSettings
    settings.bitRate = b
    rtmpStream.videoSettings = settings
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
    if rtmpStream.readyState.isStreaming {
      startBitrateTimer()
    }
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

  func getCurrentCameraId() throws -> String {
    return currentDevice?.uniqueID ?? ""
  }

  func switchCameraById(id: String) throws {
    if id.isBlank { return }
    guard let device = AVCaptureDevice(uniqueID: id) else {
      log("switchCameraById: no device with id=\(id)")
      return
    }
    currentDevice = device
    if device.position == .front { currentFacing = .front }
    else if device.position == .back { currentFacing = .back }
    rtmpStream.attachCamera(device) { _, error in
      if let error = error { self.log("attachCamera failed: \(String(describing: error))") }
    }
    applyMirrorFlags()
  }

  func isFrontCamera() throws -> Bool {
    return currentFacing == .front
  }

  // ─── Audio control ─────────────────────────────────────────────────────────

  func setAudioMuted(muted: Bool) throws {
    audioMuted = muted
    // HaishinKit 1.9 mutes by toggling `audioMixerSettings.isMuted`. The
    // microphone capture stays attached; muted samples are discarded by the
    // mixer so the audio track is silent but still present in the stream.
    var settings = rtmpStream.audioMixerSettings
    settings.isMuted = muted
    rtmpStream.audioMixerSettings = settings
  }

  func isAudioMuted() throws -> Bool {
    return audioMuted
  }

  // ─── Torch ─────────────────────────────────────────────────────────────────

  func setLanternEnabled(enabled: Bool) throws {
    guard let device = currentDevice, device.hasTorch else { return }
    do {
      try device.lockForConfiguration()
      device.torchMode = enabled ? .on : .off
      device.unlockForConfiguration()
    } catch { log("setLanternEnabled failed: \(error)") }
  }

  func isLanternEnabled() throws -> Bool {
    return currentDevice?.torchMode == .on
  }

  func isLanternSupported() throws -> Bool {
    return currentDevice?.hasTorch ?? false
  }

  // ─── Zoom ──────────────────────────────────────────────────────────────────

  func setZoom(zoom: Double) throws {
    guard let device = currentDevice else { return }
    do {
      try device.lockForConfiguration()
      let clamped = CGFloat(zoom).clamped(device.minAvailableVideoZoomFactor, device.maxAvailableVideoZoomFactor)
      device.videoZoomFactor = clamped
      device.unlockForConfiguration()
    } catch { log("setZoom failed: \(error)") }
  }

  func getZoom() throws -> Double {
    return Double(currentDevice?.videoZoomFactor ?? 1)
  }

  func getMinZoom() throws -> Double {
    return Double(currentDevice?.minAvailableVideoZoomFactor ?? 1)
  }

  func getMaxZoom() throws -> Double {
    return Double(currentDevice?.maxAvailableVideoZoomFactor ?? 1)
  }

  // ─── Exposure ──────────────────────────────────────────────────────────────

  func setExposure(value: Double) throws {
    guard let device = currentDevice else { return }
    do {
      try device.lockForConfiguration()
      let clamped = Float(value).clamped(device.minExposureTargetBias, device.maxExposureTargetBias)
      device.setExposureTargetBias(clamped, completionHandler: nil)
      device.unlockForConfiguration()
    } catch { log("setExposure failed: \(error)") }
  }

  func getExposure() throws -> Double {
    return Double(currentDevice?.exposureTargetBias ?? 0)
  }

  func getMinExposure() throws -> Double {
    return Double(currentDevice?.minExposureTargetBias ?? 0)
  }

  func getMaxExposure() throws -> Double {
    return Double(currentDevice?.maxExposureTargetBias ?? 0)
  }

  // ─── Focus ─────────────────────────────────────────────────────────────────

  func setAutoFocusEnabled(enabled: Bool) throws -> Bool {
    guard let device = currentDevice else { return false }
    let mode: AVCaptureDevice.FocusMode = enabled ? .continuousAutoFocus : .locked
    guard device.isFocusModeSupported(mode) else { return false }
    do {
      try device.lockForConfiguration()
      device.focusMode = mode
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

  // HaishinKit 1.x exposes preferredVideoStabilizationMode via the camera's
  // AVCaptureConnection. We set it on the connection backing the active camera.

  private var videoStabilizationEnabled = false
  private var opticalStabilizationEnabled = false

  func setVideoStabilizationEnabled(enabled: Bool) throws -> Bool {
    videoStabilizationEnabled = enabled
    applyVideoStabilizationToCaptureUnit()
    return true
  }

  func isVideoStabilizationEnabled() throws -> Bool {
    return videoStabilizationEnabled
  }

  func setOpticalVideoStabilizationEnabled(enabled: Bool) throws -> Bool {
    opticalStabilizationEnabled = enabled
    applyVideoStabilizationToCaptureUnit()
    return true
  }

  func isOpticalVideoStabilizationEnabled() throws -> Bool {
    return opticalStabilizationEnabled
  }

  // ─── Local recording ───────────────────────────────────────────────────────

  // Local-file MP4 recording. HaishinKit 1.9 ships an `IOStreamRecorder` that
  // we attach as an observer on the RTMPStream. The recorder writes to
  // `<Documents>/<fileName>.mp4`; we honor the passed-in path by setting the
  // recorder's `fileName` and then moving the produced file into place on
  // `finishWriting`. Pause/resume are best-effort status transitions only —
  // `AVAssetWriter` has no native pause primitive.

  private var recorder: IOStreamRecorder?
  private var pendingRecordOutputUrl: URL?

  func startRecord(path: String) throws -> Bool {
    if path.isBlank { return false }
    if recordStatus != .stopped { return false }
    let destination = URL(fileURLWithPath: path)
    pendingRecordOutputUrl = destination
    let rec = IOStreamRecorder()
    rec.delegate = recorderDelegate
    rec.fileName = destination.deletingPathExtension().lastPathComponent
    let recVideoCodec: AVVideoCodecType
    switch videoCodec {
    case .h265: recVideoCodec = .hevc
    default:    recVideoCodec = .h264
    }
    rec.settings = [
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
    rtmpStream.addObserver(rec)
    rec.startRunning()
    recorder = rec
    transitionRecordStatus(.started)
    transitionRecordStatus(.recording)
    return true
  }

  func stopRecord() throws {
    guard let rec = recorder else {
      transitionRecordStatus(.stopped)
      return
    }
    rec.stopRunning()
    rtmpStream.removeObserver(rec)
    recorder = nil
    // The actual `.stopped` transition fires from the recorderDelegate once
    // AVAssetWriter has finalized the file — that's also where we move it to
    // the user-specified path.
  }

  func pauseRecord() throws {
    // AVAssetWriter doesn't expose pause/resume on iOS — these are best-effort
    // status transitions kept for parity with Android.
    transitionRecordStatus(.paused)
  }

  func resumeRecord() throws {
    transitionRecordStatus(.resumed)
    transitionRecordStatus(.recording)
  }

  func getRecordStatus() throws -> RecordStatus {
    return recordStatus
  }

  private lazy var recorderDelegate: IOStreamRecorderDelegateAdapter =
    IOStreamRecorderDelegateAdapter(owner: self)

  fileprivate func recorderDidFinish(producedFileAt produced: URL?, error: Error?) {
    if let error = error { log("recorder error: \(error)") }
    if let produced = produced, let destination = pendingRecordOutputUrl,
       produced.path != destination.path {
      do {
        if FileManager.default.fileExists(atPath: destination.path) {
          try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: produced, to: destination)
      } catch {
        log("recorder file move failed: \(error)")
      }
    }
    pendingRecordOutputUrl = nil
    transitionRecordStatus(.stopped)
  }

  private func transitionRecordStatus(_ next: RecordStatus) {
    recordStatus = next
    onRecordStatusChange?(next)
  }

  // ─── Event callbacks (JS subscription points) ──────────────────────────────

  func setOnConnectionEvent(callback: @escaping (RtmpConnectionEvent, String) -> Void) throws {
    onConnectionEvent = callback
  }

  func setOnBitrateChange(callback: @escaping (Double) -> Void) throws {
    onBitrateChange = callback
    // Start the per-second TX measurement timer if we're already streaming.
    if rtmpStream.readyState.isStreaming { startBitrateTimer() }
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
    // HaishinKit emits monotonic RTMP timestamps internally — no extra knob
    // needed. Kept for API parity with the Android side.
  }

  func setStreamDelay(delayMs: Double) throws {
    // HaishinKit 1.x doesn't expose a send-side delay knob analogous to Pedro's
    // `streamClient.setDelay`. Cached for future use; no-op today.
    lastWriteChunkBuffer = Int64(delayMs)
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
    if rtmpStream.readyState != .initialized && rtmpStream.readyState != .closed {
      rtmpStream.close()
    }
    if rtmpConnection.connected { rtmpConnection.close() }
    rtmpStream.attachCamera(nil)
    rtmpStream.attachAudio(nil)
    if let rec = recorder {
      rec.stopRunning()
      rtmpStream.removeObserver(rec)
      recorder = nil
    }
    previewView.attachStream(nil)
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

  // ─── Internals ─────────────────────────────────────────────────────────────

  private func applyVideoCodecSetting() {
    // HaishinKit 1.x only emits H.264 by default; HEVC is supported on iOS 12+
    // via `rtmpStream.videoSettings.profileLevel`. Other codecs map to H.264.
    var settings = rtmpStream.videoSettings
    switch videoCodec {
    case .h265:
      settings.profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel as String
    default:
      settings.profileLevel = kVTProfileLevel_H264_Baseline_AutoLevel as String
    }
    rtmpStream.videoSettings = settings
  }

  private func applyVideoSettings() {
    guard let cfg = lastVideoCfg else { return }

    // Decide target orientation first — we need it to size the encoder.
    let r = cfg.rotation
    let orientation: AVCaptureVideoOrientation
    switch r {
    case 90:  orientation = .landscapeRight
    case 180: orientation = .portraitUpsideDown
    case 270: orientation = .landscapeLeft
    default:  orientation = .portrait
    }

    // JS callers pass dimensions in the Android convention: `width`/`height`
    // describe the encoder's *natural landscape* output. On iOS, if we're
    // streaming in portrait we must encode at the swapped resolution — otherwise
    // the encoder produces a 1280x720 frame and HaishinKit scales the 720x1280
    // portrait camera buffer into that landscape canvas, yielding a sideways
    // stream at the viewer end. RootEncoder on Android does this swap inside
    // its `prepareVideo(...rotation)` call; we replicate it here.
    let isPortrait = (orientation == .portrait || orientation == .portraitUpsideDown)
    let encodedWidth  = isPortrait ? min(cfg.width, cfg.height) : max(cfg.width, cfg.height)
    let encodedHeight = isPortrait ? max(cfg.width, cfg.height) : min(cfg.width, cfg.height)

    var settings = rtmpStream.videoSettings
    settings.videoSize = .init(width: encodedWidth, height: encodedHeight)
    settings.bitRate = cfg.bitrate
    settings.maxKeyFrameIntervalDuration = Int32(cfg.iFrameInterval)
    settings.scalingMode = .trim
    if videoCodec == .h265 {
      settings.profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel as String
    } else {
      settings.profileLevel = kVTProfileLevel_H264_Baseline_AutoLevel as String
    }
    rtmpStream.videoSettings = settings

    // FPS lives on the AVCaptureSession; setting `.frameRate` on rtmpStream lets
    // HaishinKit drive the camera frame rate too.
    rtmpStream.frameRate = Float64(cfg.fps)

    rtmpStream.videoOrientation = orientation
  }

  private func applyAudioSettings() {
    guard let cfg = lastAudioCfg else { return }
    var settings = rtmpStream.audioSettings
    settings.bitRate = cfg.bitrate
    rtmpStream.audioSettings = settings
    // Sample rate lives on the mixer settings struct, separate from the codec
    // settings. HaishinKit 1.9 takes it as a `let` at construction time, so
    // re-create the mixer settings with the requested rate.
    let mixer = IOAudioMixerSettings(
      sampleRate: Float64(cfg.sampleRate),
      channels: UInt32(cfg.isStereo ? 2 : 1),
      isMuted: audioMuted
    )
    rtmpStream.audioMixerSettings = mixer
  }

  private func applyMirrorFlags() {
    // On iOS, preview and stream share the same AVCaptureConnection buffer.
    // Setting `isVideoMirrored=true` flips that single buffer → both surfaces
    // see the flipped frames. We use a UIView transform on top only to
    // *differ* the preview from the stream (e.g. mirror the preview but not
    // the stream). When both flags are equal, `isVideoMirrored` does all the
    // work and the UIView transform stays at identity — applying it on top
    // would un-mirror the preview again.
    if let unit = rtmpStream.videoCapture(for: 0) {
      unit.isVideoMirrored = mirrorStream
    }
    let extraFlipPreview = (mirrorPreview != mirrorStream)
    previewView.transform = extraFlipPreview
      ? CGAffineTransform(scaleX: -1, y: 1)
      : .identity
  }

  private func applyVideoStabilizationToCaptureUnit() {
    guard let unit = rtmpStream.videoCapture(for: 0) else { return }
    // iOS exposes only one preferredVideoStabilizationMode per connection.
    // We pick the most aggressive available mode the caller asked for:
    //  - optical (when supported by the lens) takes priority
    //  - software stabilization uses .standard
    //  - if neither flag is set, turn it off (.off matches no-stabilization)
    if opticalStabilizationEnabled {
      unit.preferredVideoStabilizationMode = .cinematic
    } else if videoStabilizationEnabled {
      unit.preferredVideoStabilizationMode = .standard
    } else {
      unit.preferredVideoStabilizationMode = .off
    }
  }

  private func attachCameraAndMic() {
    let position: AVCaptureDevice.Position = (currentFacing == .front) ? .front : .back
    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
      log("attachCameraAndMic: no camera for \(currentFacing)")
      return
    }
    currentDevice = camera
    rtmpStream.attachCamera(camera) { [weak self] _, error in
      if let error = error { self?.log("attachCamera failed: \(String(describing: error))") }
      // HaishinKit's session reconfiguration inside `attachCamera` resets
      // orientation/mirror/stabilization to AVCaptureSession defaults. Reapply
      // everything AFTER the session is rewired so the very first frame is
      // upright + mirrored + stabilized per our state.
      self?.pinVideoOrientation()
      self?.applyMirrorFlags()
      self?.applyVideoStabilizationToCaptureUnit()
    }
    if let mic = AVCaptureDevice.default(for: .audio) {
      rtmpStream.attachAudio(mic) { _, error in
        if let error = error { self.log("attachAudio failed: \(String(describing: error))") }
      }
    }
    applyCameraFpsLock()
  }

  /// Apply the desired stream orientation. Precedence:
  ///  1. Explicit user override via `setStreamRotation`
  ///  2. Device pose, when `autoRotateStream` is on
  ///  3. Portrait, when `autoRotateStream` is off
  private func pinVideoOrientation() {
    let target: AVCaptureVideoOrientation
    if let override = userRotationOverride {
      target = override
    } else if autoRotateStream {
      target = currentVideoOrientation()
    } else {
      target = .portrait
    }
    rtmpStream.videoOrientation = target
  }

  /// Snapshot the current physical device orientation, falling back to the
  /// interface orientation (which is what the user *sees*) when the device is
  /// face-up / face-down / unknown.
  ///
  /// **Must be called on the main thread** — `UIDevice.current.orientation`
  /// and `UIApplication.shared.connectedScenes` are main-thread-only. The
  /// helper hops to main synchronously when called from a worker thread (e.g.
  /// the Nitro JSI thread) so callers don't have to think about it.
  private func currentVideoOrientation() -> AVCaptureVideoOrientation {
    if !Thread.isMainThread {
      return DispatchQueue.main.sync { self.currentVideoOrientation() }
    }
    let device = UIDevice.current.orientation
    switch device {
    case .portrait:           return .portrait
    case .portraitUpsideDown: return .portraitUpsideDown
    case .landscapeLeft:      return .landscapeRight  // device-left → camera-right
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

  /// Fire-and-forget hop to the main thread for UIKit-touching work that
  /// doesn't need to return a value (idle timer, notification observers, etc).
  /// If the caller is already on main, runs synchronously to avoid one extra
  /// runloop turn.
  private func onMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() }
    else { DispatchQueue.main.async(execute: block) }
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
      // AVAudioSession.Mode controls iOS' built-in DSP. The mapping matches
      // Android's MediaRecorder.AudioSource semantics:
      //   - mic                 ⟷ .voiceChat       (AGC + noise gate + AEC, the
      //                                              compressed "phone call" sound)
      //   - camcorder           ⟷ .videoRecording  (gentle AGC, broadband pickup —
      //                                              the recommended default for
      //                                              live streaming)
      //   - voiceCommunication  ⟷ .voiceChat       (same as `mic` here; on iOS
      //                                              there's only one VoIP mode)
      //   - voiceRecognition    ⟷ .measurement     (raw signal, no DSP — useful
      //                                              for offline mixing)
      //   - unprocessed         ⟷ .measurement     (same — iOS has no separate
      //                                              "unprocessed" mode)
      // `noiseSuppression=true` overrides the audioSource mapping and forces
      // `.voiceChat`, which is the only iOS mode that engages Apple's built-in
      // Voice Processing IO unit (NS + AEC + AGC). The user explicitly opts
      // in to compressed but cleaner audio.
      let mode: AVAudioSession.Mode
      if noiseSuppression {
        mode = .voiceChat
      } else {
        switch audioSource {
        case .mic, .voicecommunication: mode = .voiceChat
        case .camcorder:                mode = .videoRecording
        case .voicerecognition,
             .unprocessed:              mode = .measurement
        }
      }

      // `.mixWithOthers` was forcing iOS to duck/level our input so other apps
      // could share the audio session — that boosted background noise relative
      // to voice. Drop it for cleaner capture. Re-add only if you need to mix.
      var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
      if #available(iOS 8.0, *) {
        // `.allowBluetooth` was renamed to `.allowBluetoothHFP` in iOS 18 SDK
        // (Xcode 16+) and the old name is deprecated. Use whichever exists.
        #if compiler(>=6.0)
        options.insert(.allowBluetoothHFP)
        #else
        options.insert(.allowBluetooth)
        #endif
      }
      try session.setCategory(.playAndRecord, mode: mode, options: options)

      // Prefer the front-facing mic when in `camcorder` mode so the lens and
      // mic point in the same direction (matches what a viewer expects).
      if audioSource == .camcorder,
         let inputs = session.availableInputs,
         let mic = inputs.first(where: { $0.portType == .builtInMic }),
         let sources = mic.dataSources {
        let preferred = sources.first { $0.orientation == .front } ?? sources.first
        if let preferred {
          try? mic.setPreferredDataSource(preferred)
        }
      }

      try session.setActive(true)
    } catch {
      log("configureAudioSession failed: \(error)")
    }
  }

  private func applyStreamMode() {
    // Tune the RTMP send pipeline + connection QoS based on the preset. The
    // tradeoffs mirror Android's RootEncoder presets:
    //   - lowLatency: small chunks + utility QoS  → ~1-2s glass-to-glass
    //   - balanced:   default chunks + userInit   → ~3-4s, good for most streams
    //   - quality:    big chunks + userInteract   → ~6-8s, best for long-form
    switch streamMode {
    case .lowlatency:
      rtmpConnection.chunkSize = 4_096
      rtmpConnection.qualityOfService = .utility
    case .balanced:
      rtmpConnection.chunkSize = 4_096
      rtmpConnection.qualityOfService = .userInitiated
    case .quality:
      rtmpConnection.chunkSize = 8_192
      rtmpConnection.qualityOfService = .userInteractive
    }
  }

  // ─── Bitrate measurement timer ─────────────────────────────────────────────

  private var lastSentByteCount: Int64 = 0
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
    let totalBytes = Int64(rtmpConnection.totalBytesOut)
    let deltaBytes = totalBytes - lastSentByteCount
    lastSentByteCount = totalBytes
    let bps = Double(deltaBytes * 8)
    onBitrateChange?(bps)
    if adaptiveEnabled, rtmpStream.readyState.isStreaming {
      adaptBitrate(measuredBps: bps)
    }
  }

  private func adaptBitrate(measuredBps: Double) {
    guard adaptiveMaxBitrate > 0 else { return }
    let target = Double(adaptiveCurrentBitrate)
    // If measured TX is dropping below 80% of current target, congestion likely.
    if measuredBps < target * 0.8 {
      let nextBitrate = Int(target * (1 - adaptiveDecreasePct / 100))
      let floor = adaptiveMaxBitrate / 4 // never below 25% of ceiling
      let clamped = max(nextBitrate, floor)
      if clamped != adaptiveCurrentBitrate {
        adaptiveCurrentBitrate = clamped
        var s = rtmpStream.videoSettings; s.bitRate = clamped; rtmpStream.videoSettings = s
      }
    } else if adaptiveCurrentBitrate < adaptiveMaxBitrate {
      let nextBitrate = Int(target * (1 + adaptiveIncreasePct / 100))
      let clamped = min(nextBitrate, adaptiveMaxBitrate)
      if clamped != adaptiveCurrentBitrate {
        adaptiveCurrentBitrate = clamped
        var s = rtmpStream.videoSettings; s.bitRate = clamped; rtmpStream.videoSettings = s
      }
    }
  }

  // ─── Orientation observer ──────────────────────────────────────────────────

  private var orientationObserver: NSObjectProtocol?
  private func enableOrientationObserver() {
    if orientationObserver != nil { return }
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
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
      self.rtmpStream.videoOrientation = avo
    }
  }

  private func disableOrientationObserver() {
    if let obs = orientationObserver {
      NotificationCenter.default.removeObserver(obs)
      orientationObserver = nil
    }
    UIDevice.current.endGeneratingDeviceOrientationNotifications()
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

  // ─── RTMP event handlers ───────────────────────────────────────────────────

  @objc private func rtmpStatusEvent(_ notification: Notification) {
    let e = Event.from(notification)
    guard let data = e.data as? ASObject,
          let code = data["code"] as? String else { return }
    switch code {
    case RTMPConnection.Code.connectSuccess.rawValue:
      onConnectionEvent?(.connectionsuccess, "")
      // Reset adaptive bitrate state for the new session.
      adaptiveCurrentBitrate = lastVideoCfg?.bitrate ?? adaptiveCurrentBitrate
      // Final orientation pin before `publish` — guarantees the very first
      // RTMP frame is upright.
      pinVideoOrientation()
      // Now actually publish.
      if let key = pendingStreamKey {
        rtmpStream.publish(key)
      }
      startBitrateTimer()
    case RTMPConnection.Code.connectFailed.rawValue,
         RTMPConnection.Code.connectClosed.rawValue:
      let isFailed = (code == RTMPConnection.Code.connectFailed.rawValue)
      stopBitrateTimer()
      if tryAutoReconnect(reason: code) {
        onConnectionEvent?(.reconnecting, code)
        return
      }
      shouldBeStreaming = false
      onConnectionEvent?(isFailed ? .connectionfailed : .disconnect, code)
    case RTMPConnection.Code.connectRejected.rawValue,
         RTMPConnection.Code.connectInvalidApp.rawValue:
      // Treat rejection that mentions auth as authError; otherwise as connectionFailed.
      let desc = (data["description"] as? String) ?? ""
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

  // ─── Helpers ───────────────────────────────────────────────────────────────

  private func splitRtmpUrl(_ url: String) -> (connectUrl: String, streamKey: String) {
    // RTMP convention: rtmp://host[:port]/app/streamKey
    // HaishinKit wants `rtmp://host/app` for connect, `streamKey` for publish.
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
// IOStreamRecorderDelegate adapter
// ────────────────────────────────────────────────────────────────────────────

private final class IOStreamRecorderDelegateAdapter: NSObject, IOStreamRecorderDelegate {
  weak var owner: HybridRtmpPublisherView?
  init(owner: HybridRtmpPublisherView) {
    self.owner = owner
  }
  func recorder(_ recorder: IOStreamRecorder, errorOccured error: IOStreamRecorder.Error) {
    owner?.recorderDidFinish(producedFileAt: nil, error: error)
  }
  func recorder(_ recorder: IOStreamRecorder, finishWriting writer: AVAssetWriter) {
    owner?.recorderDidFinish(producedFileAt: writer.outputURL, error: nil)
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

private extension RTMPStream.ReadyState {
  var isStreaming: Bool {
    // `.publishing(muxer:)` carries an associated value — pattern-match so we
    // don't have to construct a dummy IOMuxer just to compare.
    switch self {
    case .publish, .publishing:
      return true
    default:
      return false
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
