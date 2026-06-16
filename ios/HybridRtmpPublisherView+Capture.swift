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
    // startPreview selects by `facing:`, so clear any device pinned by a prior
    // switchCameraById — intendedCameraDevice() must resolve the default camera
    // for the requested facing, not a stale pinned id.
    currentDevice = nil
    // attachCameraAndMic now applies mirror + stabilization atomically inside
    // the attach configuration block AND syncs the preview transform up-front.
    // Calling applyMirrorFlags() again here would race the second Task with
    // the attach Task — manifests as a brief unmirror/stutter on first frame.
    // Route through the coalescing guard so the in-flight flag is set/cleared
    // consistently (and so a startPreview that lands on top of an in-flight
    // flip is absorbed rather than piling on a second attach).
    requestCameraAttach()
    cachedIsOnPreview = true
    if autoRotateStream { enableOrientationObserver() }
  }

  func stopPreview() throws {
    lastPreview = nil
    userRotationOverride = nil
    // Clear the camera-attach coalescing guard + freeze overlay ON MAIN (the one
    // thread these are touched on). An in-flight attach Task tail still runs (it
    // captured self) but its reconverge no-ops because pending is false; and a
    // NEXT startPreview/switchCamera won't be wrongly absorbed by a stale
    // in-flight flag. Bumping flipMaskToken invalidates any pending reveal.
    onMain { [weak self] in
      guard let self else { return }
      self.cameraAttachInFlight = false
      self.cameraAttachPending = false
      self.flipMaskToken &+= 1
      self.freezeOverlay.alpha = 0
      self.freezeOverlay.image = nil
    }
    disableOrientationObserver()
    // Stop the Voice Processing pipeline if it was running (NS on).
    denoisePipeline.stop()
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
      // Drop the retained composited frame only AFTER frame flow has stopped —
      // clearing before stopRunning() could be immediately re-populated by an
      // in-flight frame, pinning a capture buffer until the view drops.
      self.previewFrameTap.clear()
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
    // `switchCamera` selects by facing, not by a specific device id, so clear
    // any pinned `currentDevice` from a prior `switchCameraById` — the attach
    // resolves the default wide-angle camera for `currentFacing`, and the
    // reconverge predicate must compare against THAT, not a stale pinned id.
    currentDevice = nil
    if let lp = lastPreview { lastPreview = PreviewConfig(facing: next, width: lp.width, height: lp.height) }
    // attachCameraAndMic atomically applies mirror + stabilization. The
    // redundant applyMirrorFlags() that used to live here raced its Task
    // against attachVideo's Task — produced a brief un-mirror flash on flip.
    //
    // The cheap synchronous intent update above (currentFacing + lastPreview)
    // and the freeze-frame run on EVERY tap so the preview/button stay
    // responsive, but the heavy attach is coalesced: if one is already in
    // flight, this tap is absorbed (the in-flight tail reconverges to the
    // latest currentFacing).
    showFreezeFrame()
    requestCameraAttach()
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
    // Pin the requested device as the intent. attachCameraAndMic resolves the
    // device from `currentDevice` when pinned (else the default for facing), so
    // this id-switch shares the SAME coalescing path as switchCamera — rapid
    // id-switches (or a burst that mixes Flip + selectById) collapse together
    // and reconverge to whichever device is the latest intent.
    currentDevice = device
    if device.position == .front { currentFacing = .front }
    else if device.position == .back { currentFacing = .back }
    cachedZoom = Double(device.videoZoomFactor)
    cachedZoomRange = (
      Double(device.minAvailableVideoZoomFactor),
      Double(device.maxAvailableVideoZoomFactor)
    )
    cachedExposureRange = (device.minExposureTargetBias, device.maxExposureTargetBias)

    showFreezeFrame()
    requestCameraAttach()
  }

  /// Resolve the AVCaptureDevice the NEXT attach should wire up from the
  /// freshest intent: a device pinned via `switchCameraById` (`currentDevice`)
  /// wins; otherwise the default wide-angle camera for `currentFacing`.
  /// `switchCamera` clears `currentDevice` so it always falls through to facing.
  /// Used both to drive an attach and — in the attach tail — to decide whether
  /// the intent moved during the heavy attach and a reconverge is needed.
  func intendedCameraDevice() -> AVCaptureDevice? {
    if let pinned = currentDevice { return pinned }
    let position: AVCaptureDevice.Position = (currentFacing == .front) ? .front : .back
    return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
  }

  /// Coalescing front door for ALL user-driven camera (re)attaches
  /// (switchCamera + switchCameraById + startPreview). If an attach is already
  /// in flight, just flag a pending reconverge and return — the in-flight
  /// attach's tail will pick up the latest intent and fire AT MOST one more
  /// attach. Otherwise start the attach now.
  ///
  /// THREADING: the entry-point Nitro methods (switchCamera / switchCameraById /
  /// startPreview / stopPreview) run on the JS thread, NOT main (the generated
  /// Nitro bridge calls them synchronously with no hop). So this hops to main
  /// before touching cameraAttachInFlight / cameraAttachPending. Together with
  /// the attach tail (also on main) and attachCameraAndMic's prologue (which now
  /// runs on main because it's only ever called from here), EVERY read/write of
  /// the coalescing flags + flipMaskToken + mirrorGeneration happens on the main
  /// thread — so the plain Bool/UInt64 are genuinely race-free. The intent vars
  /// (currentFacing / currentDevice) are still written synchronously on the JS
  /// thread by the entry points before this enqueues; libdispatch's async
  /// barrier makes those writes visible to the main-thread attach, which reads
  /// the FRESHEST intent (and the reconverge double-checks it).
  func requestCameraAttach() {
    onMain { [weak self] in
      guard let self else { return }
      if self.cameraAttachInFlight {
        self.cameraAttachPending = true
        return
      }
      self.cameraAttachInFlight = true
      self.attachCameraAndMic()
    }
  }

  /// Covers a camera device swap with a **freeze-frame** of the last live
  /// preview frame, in BOTH `.passthrough` and `.offscreen` compositing modes.
  ///
  /// The swap itself (`mixer.attachVideo`) takes ~400ms on-device — an
  /// AVFoundation/hardware floor (the other sensor has to power on and deliver
  /// its first frame). We can't make that faster with a single-camera session,
  /// so we make it *feel* instant: the instant the user taps Flip we render the
  /// last composited frame (kept by `previewFrameTap`, which matches the live
  /// preview pixel-for-pixel — orientation, mirror and beauty all baked in) into
  /// `freezeOverlay` and show it immediately. The user sees a held frame with no
  /// black flash; then `finalizeMirror` crossfades the overlay out the moment
  /// the new camera's first frame lands underneath it.
  ///
  /// This also subsumes the old offscreen-only "double render" fix: in
  /// `.offscreen` mode, HaishinKit keeps compositing up to ~3 stale OLD-camera
  /// frames from the `Screen`'s per-track queue after the swap starts (the only
  /// flusher, `Screen.reset()`, is module-internal and never runs on a swap).
  /// The frozen overlay simply sits on top and hides them. The earlier approach
  /// dropped `previewView.alpha` to 0 — a black hole — and only ran offscreen;
  /// a real frozen frame is strictly nicer and works in both modes.
  ///
  /// Token-guarded (`flipMaskToken`) so overlapping flips don't reveal early:
  /// each raise bumps the token, the attach captures it, and only the matching
  /// `finalizeMirror` (the newest flip) crossfades the overlay back out.
  func showFreezeFrame() {
    // ASYMMETRIC MIRROR: the overlay is a subview of previewView and inherits
    // its mirror transform, but the captured frame only has mirrorStream baked
    // in. When mirrorPreview != mirrorStream the transform can change across the
    // swap and the frozen frame would render wrongly-mirrored during the fade.
    // Skip the freeze in that rare, non-default case — the live swap shows
    // through (same as the pre-PR behavior). The shipped example is symmetric.
    guard mirrorPreview == mirrorStream else { return }
    onMain { [weak self] in
      guard let self else { return }
      // Bump the token ON MAIN (every flipMaskToken access is now main-only).
      let token = self.flipMaskToken &+ 1
      self.flipMaskToken = token
      // SAFETY BACKSTOP: the primary reveal is finalizeMirror / the reconverge.
      // This only guarantees a failed / never-completing attach can't strand the
      // frozen frame forever. 0.8s comfortably outlasts a normal attach; in the
      // common case the precise reveal already crossfaded the overlay out before
      // this fires (the `alpha > 0` guard makes it a no-op then). Token-guarded
      // so overlapping flips don't reveal early.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
        guard let self, self.flipMaskToken == token, self.freezeOverlay.alpha > 0 else { return }
        self.fadeOutFreezeOverlay(duration: 0.15)
      }
      // If a freeze overlay is already up (rapid re-flip mid-swap) keep the
      // existing frozen image — the camera is detached so there's no fresher
      // frame to grab — only the backstop above is re-armed under the new token.
      guard self.freezeOverlay.alpha < 1, let ci = self.previewFrameTap.latestImage() else { return }
      let bounds = self.previewView.bounds
      let mode = self.previewView.videoGravity.imageContentMode
      // Rasterize OFF the main thread: createCGImage on a 720x1280 frame is a
      // ~1-5ms GPU readback, and doing it inline would block the run loop on the
      // very flip tap meant to feel instant. Render on a background queue, then
      // hop the UIImage back to main. Token-guarded so a superseded flip's
      // late-arriving render can't show. Still appears within a few ms — far
      // inside the ~400ms swap — so there's no visible gap.
      self.snapshotRenderQueue.async { [weak self] in
        guard let self,
              let cg = self.freezeRenderContext.createCGImage(ci, from: ci.extent) else { return }
        let image = UIImage(cgImage: cg)
        DispatchQueue.main.async { [weak self] in
          // Only raise the overlay if this flip is still current (token), the
          // overlay isn't already up, AND an attach is still in flight. The last
          // check guards the (very rare) case where the attach finished before
          // this background raster returned: the reveal would already have
          // no-op'd, so showing now would strand the frame until the backstop.
          guard let self, self.flipMaskToken == token,
                self.cameraAttachInFlight, self.freezeOverlay.alpha < 1 else { return }
          self.freezeOverlay.frame = bounds
          self.freezeOverlay.contentMode = mode
          self.freezeOverlay.image = image
          self.freezeOverlay.alpha = 1
        }
      }
    }
  }

  /// Crossfade the freeze overlay out (the precise reveal). Waits a beat for the
  /// new camera's first frame to land UNDER the overlay, then fades — so the
  /// reveal is always to a live frame, never a black/stale flash. Re-reads the
  /// token at call time so a flip raised after this is scheduled isn't revealed
  /// by an older request. Must be called on main.
  func crossfadeOutFreezeFrame() {
    guard freezeOverlay.alpha > 0 else { return }
    let revealToken = flipMaskToken
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      guard let self, self.flipMaskToken == revealToken, self.freezeOverlay.alpha > 0 else { return }
      self.fadeOutFreezeOverlay(duration: 0.18)
    }
  }

  /// Fade the overlay to 0 and release its image on completion so a ~3.7MB
  /// frame isn't held idle between flips. Must be called on main.
  private func fadeOutFreezeOverlay(duration: TimeInterval) {
    UIView.animate(withDuration: duration, animations: { [weak self] in
      self?.freezeOverlay.alpha = 0
    }, completion: { [weak self] _ in
      // Only drop the image if a newer flip hasn't re-raised the overlay.
      guard let self, self.freezeOverlay.alpha == 0 else { return }
      self.freezeOverlay.image = nil
    })
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

  /// DEBUG/TEST: inject a deliberate A/V desync (ms) so the self-healing audio
  /// resync loop can be observed recovering it. Only meaningful while
  /// noiseSuppression is on (the VP pipeline is running); no-op otherwise.
  func injectAudioDesyncForTesting(ms: Double) throws {
    denoisePipeline.injectDesync(ms: ms)
  }

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
  // CoreImage skin-smoothing via a HaishinKit VideoEffect. HaishinKit only runs
  // VideoEffects in `.offscreen` compositing mode — the default `.passthrough`
  // sends camera frames straight to the preview + encoder, bypassing the screen
  // (so a registered effect never executes). Enabling beauty therefore:
  //   1. sizes the offscreen `screen` to the current (oriented) encoder
  //      resolution, so the composited output keeps the stream's aspect, and
  //   2. flips the mixer to `.offscreen` so the screen — and our effect — runs.
  // Once offscreen, we STAY offscreen and only register/unregister the effect on
  // toggle — flipping back to `.passthrough` reconfigures the whole pipeline and
  // stalls ~2s per toggle. Affects both preview and encoded stream. See
  // `BeautyVideoEffect`.

  func setBeautyFilterEnabled(enabled: Bool) throws {
    guard enabled != cachedBeautyEnabled else { return }
    cachedBeautyEnabled = enabled
    applyBeautyFilter()
    // Beauty is our biggest GPU add, so keep the thermal observer alive while
    // it's on (independent of any JS `onThermalWarning` subscription) and start
    // already-throttled if the device is hot when beauty is switched on.
    syncThermalObserver()
    applyBeautyThermalScale()
  }

  func isBeautyFilterEnabled() throws -> Bool { return cachedBeautyEnabled }

  /// Map the current thermal state → a beauty headroom scale and push it to the
  /// effect (mirrors Android's SEVERE highp→mediump downgrade). Like Android, the
  /// filter stays ON at every level — just progressively lighter + cheaper —
  /// rather than cutting out. No-op when beauty is off (the effect isn't
  /// registered, so its scale is moot). The set hops to ScreenActor so it's
  /// serialized with the effect's per-frame `execute(_:)`.
  ///   serious  → 0.5 (half intensity + ~half blur radius)
  ///   critical → 0.3 (lightest + cheapest, still visible)
  ///   else     → 1.0 (full)
  func applyBeautyThermalScale() {
    guard cachedBeautyEnabled else { return }
    let scale: Float
    switch ProcessInfo.processInfo.thermalState {
    case .critical: scale = 0.3
    case .serious:  scale = 0.5
    default:        scale = 1.0
    }
    let effect = beautyEffect
    Task { @ScreenActor in effect.setThermalScale(scale) }
  }

  func applyBeautyFilter() {
    let enabled = cachedBeautyEnabled
    let effect = beautyEffect
    let size = orientedEncodedSize()
    let mixer = self.mixer
    Task {
      if enabled {
        await Task { @ScreenActor in
          mixer.screen.size = size
          _ = mixer.screen.registerVideoEffect(effect)
        }.value
        // No-op if already offscreen — so only the FIRST enable in a session
        // pays the passthrough→offscreen pipeline reconfigure (~the DisplayLink
        // render loop spin-up + first-frame kernel pipeline compile).
        await mixer.setVideoMixerSettings(VideoMixerSettings(mode: .offscreen))
      } else {
        // Stay in `.offscreen` and just drop the effect (the screen then
        // composites the raw camera frame). Flipping back to `.passthrough`
        // would reconfigure the whole video pipeline on every toggle and stall
        // ~2s each time; staying offscreen makes subsequent toggles instant.
        await Task { @ScreenActor in
          _ = mixer.screen.unregisterVideoEffect(effect)
        }.value
      }
    }
  }

  /// Encoder resolution oriented for the current rotation — mirrors the W/H
  /// swap in `applyVideoSettings`, so the offscreen screen matches the stream
  /// and preview/stream keep their aspect + orientation.
  private func orientedEncodedSize() -> CGSize {
    guard let cfg = lastVideoCfg else { return CGSize(width: 720, height: 1280) }
    let portrait = (cfg.rotation == 0 || cfg.rotation == 180)
    let w = portrait ? min(cfg.width, cfg.height) : max(cfg.width, cfg.height)
    let h = portrait ? max(cfg.width, cfg.height) : min(cfg.width, cfg.height)
    return CGSize(width: CGFloat(w), height: CGFloat(h))
  }

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
    //
    // This is the prop-didSet path. It is now a SECONDARY corrector: the
    // primary mirror authority is the post-attach re-assert in finalizeMirror.
    // But this path still matters for a plain mirror-prop toggle WITHOUT a flip
    // (no attach happens, so finalizeMirror never runs). We join the same
    // generation scheme so a late prop-didSet Task can't clobber a newer flip's
    // attach — and so a newer flip can't have its tail clobbered by this.
    mirrorGeneration &+= 1
    let gen = mirrorGeneration
    let mirror = mirrorStream
    Task { [weak self] in
      guard let self else { return }
      // Drop if a newer mirror write (flip or another prop change) superseded
      // us. If the device isn't attached yet (mid-flip), configuration throws
      // deviceNotFound — harmless here because that newer flip's finalizeMirror
      // will assert the correct value once its attach completes.
      guard self.mirrorGeneration == gen else { return }
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
    guard let camera = intendedCameraDevice() else {
      log("attachCameraAndMic: no camera for \(currentFacing)")
      // No device to attach — release the coalescing guard (and run any
      // pending reconverge, which will also no-op out) so the guard can't stick.
      cameraAttachInFlight = false
      cameraAttachPending = false
      return
    }
    currentDevice = camera
    // The uniqueID this attach is wiring up. Compared against the freshest
    // intent in the tail to decide whether the user changed cameras DURING the
    // heavy attach and we owe exactly one reconverge.
    let attachedDeviceId = camera.uniqueID
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
    // Bump + capture the mirror generation on the calling (main) thread BEFORE
    // spawning the attach Task. The post-attach re-assert below only commits if
    // this is still the latest generation, so a NEWER flip wins deterministically.
    mirrorGeneration &+= 1
    let gen = mirrorGeneration
    let maskToken = flipMaskToken
    Task { [weak self] in
      guard let self else { return }
      do {
        // Apply mirror + stabilization atomically inside the attach so the
        // first frame from the new AVCaptureInput is already mirrored and
        // stabilized. Without this the camera-control settings get applied
        // after capture is wired and we get a ~1-2s window of unmirrored
        // frames — especially noticeable on the front camera. `mirror` is the
        // call-time prop value (possibly stale on a flip) — the re-assert
        // after attach below corrects it to the freshest value.
        try await self.mixer.attachVideo(camera) { unit in
          unit.isVideoMirrored = mirror
          unit.preferredVideoStabilizationMode = stabilization
        }
        // MediaMixer's async streams that feed outputs only start draining
        // after startRunning() — without it the preview stays black even
        // though capture is "attached." Safe to call repeatedly (guarded
        // by `isRunning` internally).
        await self.mixer.startRunning()
        // Attach audio AFTER startRunning: NS off → mixer mic; NS on → our
        // spectral denoise pipeline feeding mixer.append.
        await self.applyAudioCaptureForCurrentMode()
        self.pinVideoOrientation()
        // Lock frame rate AFTER attach completes. The earlier (pre-fix)
        // sync call fired before attachVideo had a chance to commit the
        // active format, so on first mount iOS would silently pick the
        // closest supported duration to ours and our setting was lost.
        self.applyCameraFpsLock()
        // Live-tier PIP: enable multitasking camera access so the camera keeps
        // running in the PIP window (no-op unless PIP is armed AND the device
        // supports it — iPhone iOS 18+ with `voip`, M1+ iPad).
        self.applyMultitaskingCameraAccess()
        // Finalize mirror as a SINGLE ordered write. `devices[0]` is now
        // populated (attach completed on this same Task), so this can't hit
        // configuration(video:)'s deviceNotFound path. We re-read the prop
        // LIVE so that a mirror prop which arrived on a later render (the
        // example flips mirror on the render AFTER switchCamera) is honored —
        // making the LAST write the freshest value with no second racing Task.
        // Guard on the generation so an OLD flip's late-completing attach can't
        // clobber a NEWER flip. This also covers the encoded stream: on iOS
        // preview + stream share the capture buffer, so isVideoMirrored fixes both.
        await self.finalizeMirror(generation: gen, maskToken: maskToken)
      } catch {
        self.log("attachVideo failed: \(error)")
      }
      // RECONVERGE: clear the in-flight guard and decide on at most one more
      // attach. Runs via `onMain`, the SAME thread requestCameraAttach /
      // showFreezeFrame / finalizeMirror now mutate the coalescing flags +
      // flipMaskToken on, so there is no lost-update race (the entry-point Nitro
      // methods set the INTENT vars on the JS thread, but those are read here via
      // a dispatch barrier and the flags themselves are touched only on main).
      // We fire one more attach iff a tap was absorbed while we were busy
      // (`cameraAttachPending`) AND the freshest intent now resolves to a
      // DIFFERENT device than the one we just attached. An even-count burst lands
      // back on `attachedDeviceId` → no extra attach; an odd-count burst →
      // exactly one reconverge. Either way the final facing/device is correct and
      // at most 2 attaches run per burst. On error we still land here, so the
      // guard is always released (no freeze, no stuck overlay).
      self.onMain { [weak self] in
        guard let self else { return }
        self.cameraAttachInFlight = false
        let pending = self.cameraAttachPending
        self.cameraAttachPending = false
        if pending, self.intendedCameraDevice()?.uniqueID != attachedDeviceId {
          // Intent moved during the attach. Re-raise the freeze frame so the
          // reconverge attach captures a matching flipMaskToken (its
          // finalizeMirror does the precise crossfade reveal), then re-enter the
          // coalescing front door — which sets cameraAttachInFlight = true again,
          // bumps mirrorGeneration, and reads the LATEST intent so it ends on the
          // correct camera.
          self.showFreezeFrame()
          self.requestCameraAttach()
        } else if pending {
          // Taps were absorbed but the freshest intent resolves BACK to the
          // device we just attached (e.g. an even-count back→front→back burst,
          // or a redundant switchCameraById). No reconverge fires — but those
          // absorbed taps bumped flipMaskToken past this attach's maskToken, so
          // finalizeMirror won't have revealed. Crossfade the overlay out here so
          // the freeze frame isn't stranded until the 0.8s backstop.
          self.crossfadeOutFreezeFrame()
        }
        // else (!pending): finalizeMirror already owns the reveal.
      }
    }
  }

  /// Re-asserts the mirror flag from the freshest prop value after an attach
  /// has populated `devices[0]`, then crossfades the freeze frame out. Called
  /// from the tail of every attach Task so the LAST mirror write is
  /// deterministic.
  ///
  /// - `generation`: the mirror generation this attach was born under. If a
  ///   newer flip has bumped `mirrorGeneration` since, this write is dropped —
  ///   the newer flip's own attach (or applyMirrorFlags) owns the final value.
  /// - `maskToken`: the freeze-frame token captured when the overlay was raised;
  ///   the overlay is only crossfaded out if it still matches (no newer flip in
  ///   flight) and only after this mirror write has landed, so the preview is
  ///   never revealed while still showing a stale (non-mirrored) frame.
  func finalizeMirror(generation: UInt64, maskToken: UInt64) async {
    guard self.mirrorGeneration == generation else { return }
    let fresh = self.mirrorStream
    try? await self.mixer.configuration(video: 0) { $0.isVideoMirrored = fresh }
    // The preview transform only matters in the asymmetric (mirrorPreview !=
    // mirrorStream) case; re-evaluate from the freshest props on main.
    let extraFlip = (self.mirrorPreview != self.mirrorStream)
    let transform: CGAffineTransform = extraFlip
      ? CGAffineTransform(scaleX: -1, y: 1)
      : .identity
    onMain { [weak self] in
      guard let self else { return }
      self.previewView.transform = transform
      // Crossfade the freeze frame out now that the correct mirror has landed —
      // only if this is still the latest flip (token match). The crossfade
      // helper gives the new camera's first frame a brief beat to land UNDER the
      // overlay before fading, so the reveal is always to a live new-camera
      // frame, never a black/stale flash. The 0.8s timer in showFreezeFrame is a
      // backstop; this is the precise reveal tied to mirror-settle.
      guard self.flipMaskToken == maskToken else { return }
      self.crossfadeOutFreezeFrame()
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

    // Apply the UIView side of the mirror flag IMMEDIATELY on main, so the
    // preview's CGAffineTransform is right before the first new frame from
    // the rebuilt capture session arrives. Waiting on `attachVideo` to
    // resolve before touching the transform leaves a ~1-2s window where
    // frames render with stale (or no) mirroring.
    let extraFlipPreview = (mirrorPreview != mirrorStream)
    let previewTransform: CGAffineTransform = extraFlipPreview
      ? CGAffineTransform(scaleX: -1, y: 1)
      : .identity
    onMain { [weak self] in
      guard let self else { return }
      self.previewView.transform = previewTransform
      // A background round-trip can land mid-flip while a freeze overlay is
      // still up. defrostCapture does a full re-attach and carries no flip
      // token, so it won't crossfade that overlay out — clear it up-front so the
      // held frame can't outlive the resume. Bump the token to invalidate any
      // pending reveal that would otherwise fight this.
      self.flipMaskToken &+= 1
      self.freezeOverlay.alpha = 0
      self.freezeOverlay.image = nil
    }

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
        await self.mixer.startRunning()
        // Re-attach audio for the current mode (serialized + reactivates the
        // session). When noiseSuppression is on this restarts the denoise
        // pipeline (the AVAudioEngine is dead after a background/interruption);
        // when off it re-attaches the mixer mic.
        self.scheduleAudioRestart()
        self.pinVideoOrientation()
        // Re-lock frame rate. iOS re-commits the device's `activeFormat`
        // during `attachVideo` and resets `activeVideoMin/MaxFrameDuration`
        // to the format default. Without this re-apply, every background/
        // foreground cycle silently drops us back to the format's native
        // frame rate — feels different from what JS asked for.
        self.applyCameraFpsLock()
        self.applyMultitaskingCameraAccess()
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

  /// Attach the right audio source for the current `noiseSuppression` state.
  /// Call AFTER `mixer.startRunning()` so the mixer is live for `append`.
  ///
  /// NS ON → own capture via Apple Voice Processing: detach HaishinKit's mic, then
  /// (re)start the drift-corrected VP pipeline (a fresh engine each time covers
  /// resume/interruption). If VP can't start we fall back to the built-in mic so
  /// audio is never lost. NS OFF → HaishinKit's in-session mic (synced to video
  /// by the shared capture clock), pipeline stopped.
  func applyAudioCaptureForCurrentMode() async {
    let mic = AVCaptureDevice.default(for: .audio)
    if noiseSuppression {
      try? await mixer.attachAudio(nil)
      denoisePipeline.stop()
      // Forward A/V sync telemetry (and the inject self-heal) to the JS callback.
      denoisePipeline.onDriftCorrection = { [weak self] stepMs, totalMs in
        self?.emitAudioDriftCorrection(stepMs, totalMs)
      }
      do {
        try denoisePipeline.start(mixer: mixer)
      } catch {
        log("voice-processing pipeline start failed: \(error) — falling back to built-in mic")
        if let mic { try? await mixer.attachAudio(mic) }
      }
    } else {
      denoisePipeline.stop()
      if let mic { try? await mixer.attachAudio(mic) }
    }
  }

  /// Serialized audio recovery: reactivate the (possibly interruption-deactivated)
  /// `.playAndRecord` session, then rebuild audio capture for the current mode.
  /// Chained on the previous restart so overlapping triggers — a call-end audio
  /// interruption and the capture-session defrost both firing — can't run two
  /// engine / `attachAudio` rebuilds at once.
  func scheduleAudioRestart() {
    let prev = audioRestartTask
    audioRestartTask = Task { [weak self] in
      await prev?.value
      if Task.isCancelled { return }
      guard let self else { return }
      // The session is deactivated after an interruption; reactivate it before
      // (re)starting capture, otherwise the engine / attachAudio silently fails.
      self.configureAudioSession()
      await self.applyAudioCaptureForCurrentMode()
    }
  }

  func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      // `noiseSuppression` no longer forces `.voiceChat` — on iOS it now runs the
      // custom spectral denoiser (parity with Android), so the session mode just
      // follows `audioSource` and we capture raw-ish audio for the denoiser to
      // clean (no double processing / AGC).
      let mode: AVAudioSession.Mode
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

      var options: AVAudioSession.CategoryOptions = []
      if #available(iOS 8.0, *) {
        #if compiler(>=6.0)
        options.insert(.allowBluetoothHFP)
        #else
        options.insert(.allowBluetooth)
        #endif
      }
      try session.setCategory(.playAndRecord, mode: mode, options: options)

      // Leave the built-in mic at iOS's default polar pattern. We used to force
      // `.cardioid` (directional) to reject background, but on selfie/streaming
      // setups the bottom mic's on-axis direction points away from the speaker's
      // mouth, so cardioid audibly LOWERED the captured voice. iOS's default
      // (omnidirectional / system-chosen) gives a fuller, louder voice — and
      // when `noiseSuppression` is on, voiceChat's processing still handles the
      // extra ambience, so we keep clean audio without the level loss.

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
