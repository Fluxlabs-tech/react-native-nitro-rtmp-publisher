//
//  HybridRtmpPublisherView+Capture.swift
//  NitroRtmpPublisher
//
//  Camera & microphone capture pipeline + per-device controls.
//
//  Owns the conversation with `MediaMixer` for everything *upstream* of
//  the encoder: attaching / detaching devices, mirror + stabilization
//  flags on the capture unit, frame-rate locking, audio session config,
//  zoom / exposure / focus / torch, and the preview / startPreview /
//  stopPreview public surface.
//

import AVFoundation
import Foundation
import HaishinKit
import NitroModules
import UIKit
import VideoToolbox

extension HybridRtmpPublisherView {

  // ─── Lifecycle: prepare ──────────────────────────────────────────────────

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

  // ─── Lifecycle: preview ──────────────────────────────────────────────────

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

  // ─── Sync getters (cached) ───────────────────────────────────────────────

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

  // ─── Camera selection ────────────────────────────────────────────────────

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
      // FPS lock AFTER attach so iOS doesn't silently coerce the duration
      // to the closest supported value of the not-yet-committed format.
      self.applyCameraFpsLock()
    }
  }

  /// Returns the *intended* camera facing — i.e. what the most recent
  /// `switchCamera` / `switchCameraById` / `startPreview(facing:)` call
  /// asked for. Because the underlying `mixer.attachVideo` is async, there
  /// can be a brief window (a few hundred ms) where the actual hardware
  /// hasn't switched yet. For UI purposes (mirror prop toggles, button
  /// state) the intent is what matters; if you need the post-attach truth,
  /// listen for the first bitrate-change tick after `switchCamera`.
  func isFrontCamera() throws -> Bool { return currentFacing == .front }

  // ─── Audio control ───────────────────────────────────────────────────────

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

  // ─── Torch ───────────────────────────────────────────────────────────────

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

  // ─── Zoom ────────────────────────────────────────────────────────────────

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

  // ─── Beauty filter ─────────────────────────────────────────────────────────
  // Android-only (RootEncoder's BeautyFilterRender). HaishinKit has no built-in
  // beauty filter, so these are no-ops on iOS — gate UI with isBeautyFilterSupported().

  func setBeautyFilterEnabled(enabled: Bool) throws {
    log("setBeautyFilterEnabled(\(enabled)) ignored — not supported on iOS")
  }

  func isBeautyFilterEnabled() throws -> Bool { return false }
  func isBeautyFilterSupported() throws -> Bool { return false }

  // ─── Exposure ────────────────────────────────────────────────────────────

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

  // ─── Focus ───────────────────────────────────────────────────────────────

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

  // ─── Stabilization ───────────────────────────────────────────────────────

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

  // ─── FPS lock ────────────────────────────────────────────────────────────

  func setForceFpsLimit(enabled: Bool) throws {
    desiredForceFpsLimit = enabled
    applyCameraFpsLock()
  }

  // ─── Internals: capture-pipeline helpers ─────────────────────────────────

  func applyMirrorFlags() {
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

  func applyVideoStabilizationToCaptureUnit() {
    let mode = currentStabilizationMode
    Task { [weak self] in
      guard let self else { return }
      try? await self.mixer.configuration(video: 0) { unit in
        unit.preferredVideoStabilizationMode = mode
      }
    }
  }

  var currentStabilizationMode: AVCaptureVideoStabilizationMode {
    if opticalStabilizationEnabled { return .cinematic }
    if videoStabilizationEnabled { return .standard }
    return .off
  }

  func attachCameraAndMic() {
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
        // Lock frame rate AFTER attach completes. The earlier (pre-fix)
        // sync call fired before attachVideo had a chance to commit the
        // active format, so on first mount iOS would silently pick the
        // closest supported duration to ours and our setting was lost.
        self.applyCameraFpsLock()
      } catch {
        self.log("attachVideo failed: \(error)")
      }
    }
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
  func defrostCapture() {
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
        // Re-lock frame rate. iOS re-commits the device's `activeFormat`
        // during `attachVideo` and resets `activeVideoMin/MaxFrameDuration`
        // to the format default. Without this re-apply, every background/
        // foreground cycle silently drops us back to the format's native
        // frame rate — feels different from what JS asked for.
        self.applyCameraFpsLock()
      } catch {
        self.log("defrostCapture failed: \(error)")
      }
    }
  }

  func applyCameraFpsLock() {
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

  func configureAudioSession() {
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

  // ─── Orientation pin ─────────────────────────────────────────────────────

  func pinVideoOrientation() {
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
  func currentVideoOrientation() -> AVCaptureVideoOrientation {
    return cachedDeviceOrientation
  }

  /// Prime / refresh `cachedDeviceOrientation` by reading UIKit on main.
  /// UIDevice + UIApplication require main thread; this is the only place
  /// we touch them. Fire from any context; updates the cache asynchronously.
  func refreshOrientationCacheOnMain() {
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
}
