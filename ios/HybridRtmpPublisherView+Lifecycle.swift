//
//  HybridRtmpPublisherView+Lifecycle.swift
//  NitroRtmpPublisher
//
//  App lifecycle (background/foreground), AVCaptureSession interruption,
//  device-orientation observer, and ProcessInfo thermal observer.
//
//  The handlers here exist to keep the capture pipeline alive across iOS's
//  forced suspends and to defer / coordinate auto-reconnect with the JS
//  layer's expectations of "you were streaming when I left, I expect to
//  still be streaming when I come back."
//

import AVFoundation
import Foundation
import HaishinKit
import NitroModules
import UIKit

extension HybridRtmpPublisherView {

  // ─── App-lifecycle + AVCaptureSession interruption ───────────────────────

  @objc func appDidEnterBackground() {
    isInBackground = true
    // LIVE PIP tier (iPhone iOS 18+ with the `voip` background mode, M1+ iPad):
    // the camera keeps capturing in the PIP window and the RTMP stream stays up,
    // so the proactive teardown below would wrongly kill a still-live stream.
    // PIP can start a beat AFTER backgrounding, so when this device granted
    // multitasking camera access we DEFER: if PIP is active shortly after, keep
    // the stream alive; otherwise (a real background — camera IS suspended) run
    // the teardown so foreground-reconnect works.
    if pictureInPictureEnabled, multitaskingCameraAccessActive {
      // Cancellable so `pip.onChange(true)` can defuse it the instant PIP
      // actually starts — otherwise a PIP that begins LATER than 0.6s would be
      // torn down here as if it were a real background (killing a still-live
      // stream). The `isInBackground` + `!pip.isActive` guard stays as a
      // belt-and-suspenders fallback. See audit #3.
      pendingBackgroundTeardown?.cancel()
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.pendingBackgroundTeardown = nil
        guard self.isInBackground, !self.pip.isActive else { return }
        self.performBackgroundStreamTeardown(reason: "app entered background")
      }
      pendingBackgroundTeardown = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
      return
    }
    performBackgroundStreamTeardown(reason: "app entered background")
  }

  /// The proactive RTMP teardown done when iOS suspends us in the background.
  ///
  /// We *must* flip `cachedIsStreaming` here rather than waiting for the natural
  /// `connectClosed`: (1) iOS doesn't notice the dead socket for ~10-15s (TCP
  /// keepalive), too late to drive the JS UI; (2) `appWillEnterForeground` gates
  /// its immediate reconnect on `!cachedIsStreaming`, so without this the
  /// foreground reconnect never fires. Split out so the live-PIP path can decide
  /// whether/when to run it.
  func performBackgroundStreamTeardown(reason: String) {
    // Record that we actually tore down, so `appWillEnterForeground` knows to
    // resurrect capture/stream (vs. a live-PIP return where nothing was torn down).
    didBackgroundTeardown = true
    // Cancel any in-flight reconnect — iOS is about to suspend networking and
    // the next retry would just hit `requestTimedOut`.
    reconnectTask?.cancel()
    reconnectTask = nil
    reconnectScheduled = false
    cachedIsStreaming = false
    // Stop ticking — the `DispatchSourceTimer` on `.main` pauses on background
    // then fires a flurry of catch-up ticks on resume with stale `lastMeasuredBps`.
    stopBitrateTimer()
    emitConnectionEvent(.disconnect, reason)
  }

  @objc func appWillEnterForeground() {
    isInBackground = false
    // Belt-and-suspenders: a foreground transition means any interruption is
    // over. Guarantees the stall watchdog can't stay gated off if a rare device
    // skipped both interruption-ended callbacks.
    captureInterrupted = false
    // Defuse any still-pending live-tier background teardown (e.g. a quick
    // background→foreground bounce shorter than the 0.6s defer). The work item's
    // own guard would also no-op it, but cancelling drops the dangling ref. #3.
    pendingBackgroundTeardown?.cancel()
    pendingBackgroundTeardown = nil
    // Resume the PIP display layer's decoder (cheap + harmless on every tier).
    onMain { [weak self] in self?.pip.flushForResume() }
    // Only re-attach CAPTURE if backgrounding actually tore it down. On a LIVE
    // PIP return the camera stayed alive (no teardown ran), so re-attaching here
    // would force a needless ~400ms reconfigure — the visible jitter from PIP.
    let needsResume = didBackgroundTeardown
    didBackgroundTeardown = false
    if needsResume {
      defrostCapture()
    }
    // Reconnect the RTMP socket if it's down — for BOTH paths, NOT just the
    // torn-down one. The live-PIP path (needsResume == false) can still have
    // lost its socket while backgrounded: handleRtmpStatus(connectClosed) would
    // have hit `tryAutoReconnect`'s `isInBackground` suppression (no schedule,
    // no event), and without this it would never recover on return — stranded at
    // shouldBeStreaming=true / cachedIsStreaming=false forever. The
    // `!cachedIsStreaming` guard means a still-live PIP stream is left untouched
    // (no needless blip); only an actually-dead socket reconnects.
    //
    // The 1500ms delay matters: iOS networking takes a beat to come back online,
    // and most live ingests (FB Live especially) hold the previous session for a
    // short window before accepting a fresh publish under the same stream key.
    // Reconnecting too aggressively hits `NetStream.Publish.BadName` /
    // `requestTimedOut`.
    if shouldBeStreaming, !cachedIsStreaming, !isPublishingInFlight(),
       !reconnectScheduled, currentRtmpConnectUrl != nil {
      retriesRemaining = max(retriesRemaining, 1)
      scheduleReconnect(delayMs: 1500, reason: "foreground")
    }
    // If a call/interruption emitted a .disconnect and the socket survived (no
    // reconnect scheduled above), balance it now that we're foregrounded.
    recoverFromInterruptionIfNeeded()
  }

  @objc func sessionWasInterrupted(_ notification: Notification) {
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
    // Capture is paused — gate the silent-stall watchdog off (0 bytes is now
    // expected, not a dead socket).
    captureInterrupted = true
    // We're about to tell JS the stream "disconnected"; record that we owe it a
    // matching recovery event when the interruption ends (only if we were live).
    if shouldBeStreaming { interruptionNeedsRecovery = true }
    emitConnectionEvent(.disconnect, "session interrupted: \(reason)")
  }

  @objc func sessionInterruptionEnded(_ notification: Notification) {
    captureInterrupted = false
    defrostCapture()
    onMain { [weak self] in self?.pip.flushForResume() }
    recoverFromInterruptionIfNeeded()
  }

  /// Balance the `.disconnect` emitted on a recoverable interruption with a
  /// recovery arc. If the RTMP socket actually dropped, a real reconnect
  /// (foreground-resume / `.ended` paths) emits RECONNECTING→CONNECTIONSUCCESS
  /// and we just consume the flag here. If the socket SURVIVED (a foreground
  /// call/Siri only paused capture), no reconnect runs — so we emit the arc
  /// ourselves so JS leaves the "disconnected" state. Idempotent: both
  /// interruption-end callbacks (and appWillEnterForeground) may call it.
  func recoverFromInterruptionIfNeeded() {
    guard interruptionNeedsRecovery else { return }
    // Still mid-interruption / suspended / a reconnect is already in flight, or
    // the socket dropped (a real reconnect will own the arc) → just consume.
    guard shouldBeStreaming, cachedIsStreaming, !isInBackground,
          !reconnectScheduled, !isPublishingInFlight() else {
      // Only consume once we're foregrounded and settled; while still
      // backgrounded leave it for the foreground pass.
      if !isInBackground { interruptionNeedsRecovery = false }
      return
    }
    interruptionNeedsRecovery = false
    emitConnectionEvent(.reconnecting, "interruption ended")
    emitConnectionEvent(.connectionsuccess, "")
  }

  /// Audio-session interruption (phone call, Siri, alarm, another app grabbing
  /// the audio device) — SEPARATE from the AVCaptureSession interruptions above.
  /// iOS deactivates the audio session and stops our capture: the AVAudioEngine
  /// (noiseSuppression path) is stopped and the mic detached, while video keeps
  /// flowing on the capture session. So without restoring here, the stream comes
  /// back with video but permanently silent audio (the reported "audio muted
  /// after a call"). On `.ended` we reactivate the session and rebuild audio for
  /// the current mode (serialized via `scheduleAudioRestart`).
  @objc func handleAudioSessionInterruption(_ notification: Notification) {
    guard
      let info = notification.userInfo,
      let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    switch type {
    case .began:
      // iOS has already deactivated the session + stopped our engine; we fully
      // rebuild on `.ended`, so there's nothing to do here. Gate the stall
      // watchdog off for the interruption (0 bytes is expected during the call).
      captureInterrupted = true
    case .ended:
      // Interruption over — re-enable the stall watchdog (cleared before the
      // preview guard so it always resets, even when not on preview).
      captureInterrupted = false
      // Only restore if we're actually capturing (preview / stream active).
      guard cachedIsOnPreview else { return }
      scheduleAudioRestart()
      // Resume VIDEO too. A few devices don't fire
      // `AVCaptureSession.interruptionEnded` for a phone call, so the capture
      // session — paused when the call grabbed the audio device — never resumes
      // via `sessionInterruptionEnded`, leaving video frozen for the rest of the
      // stream (audio recovers via `scheduleAudioRestart` above, which is why the
      // symptom is "audio fine, video stuck"). The audio-session `.ended` IS
      // reliable; a foreground call doesn't release the camera device, so a
      // re-`startRunning()` resumes it — idempotent (no-op if the session is
      // already running, e.g. the capture-session notification did fire), and
      // retried once in case the capture interruption clears a beat after the
      // audio one.
      Task { [weak self] in
        await self?.mixer.startRunning()
        try? await Task.sleep(nanoseconds: 700_000_000)
        await self?.mixer.startRunning()
      }
      // Revalidate the RTMP socket. Capture is back, but a call that cleanly
      // closed the socket leaves the publish dead with audio+video flowing only
      // locally. Reconnect when the socket is confirmed down. (A half-open
      // socket — cachedIsStreaming still stale-true — is handled by the
      // silent-stall watchdog once frames resume into the dead pipe.) Guarded so
      // a still-live stream isn't blipped and we don't race an already-scheduled
      // reconnect (e.g. one kicked by appWillEnterForeground for a call that
      // backgrounded the app).
      if shouldBeStreaming, !cachedIsStreaming, !isPublishingInFlight(),
         !reconnectScheduled, currentRtmpConnectUrl != nil {
        retriesRemaining = max(retriesRemaining, 1)
        scheduleReconnect(delayMs: 1000, reason: "audio-interruption-ended")
      }
      // Socket survived (no reconnect scheduled above) → emit the recovery arc
      // so the interruption's .disconnect is balanced.
      recoverFromInterruptionIfNeeded()
    @unknown default:
      break
    }
  }

  // ─── Orientation observer ────────────────────────────────────────────────

  func enableOrientationObserver() {
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

  func disableOrientationObserver() {
    if let obs = orientationObserver {
      NotificationCenter.default.removeObserver(obs)
      orientationObserver = nil
    }
    onMain { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
  }

  // ─── Thermal observer ────────────────────────────────────────────────────

  func registerThermalObserver() {
    if thermalObserver != nil { return }
    lastThermalState = ProcessInfo.processInfo.thermalState
    thermalObserver = NotificationCenter.default.addObserver(
      forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      let new = ProcessInfo.processInfo.thermalState
      let previous = self.lastThermalState
      self.lastThermalState = new
      // Auto-throttle the beauty filter under thermal pressure (iOS analog of
      // Android's SEVERE highp→mediump downgrade): serious → lighter + cheaper,
      // critical → bypass, restored when it cools. No-op when beauty is off.
      self.applyBeautyThermalScale()
      let threshold = self.thermalThreshold.toProcessInfoState()
      let enteringOrInZone = new.severityRank >= threshold.severityRank
      let justCleared = previous.severityRank >= threshold.severityRank && new.severityRank < threshold.severityRank
      if enteringOrInZone || justCleared {
        self.emitThermalWarning(new.toNitro())
      }
    }
  }

  func unregisterThermalObserver() {
    if let obs = thermalObserver {
      NotificationCenter.default.removeObserver(obs)
      thermalObserver = nil
    }
  }

  /// Register or unregister the thermal observer based on who needs it: a JS
  /// `onThermalWarning` subscription (with a non-`.none` threshold) OR the beauty
  /// filter being enabled (so the auto-throttle works even without any JS
  /// subscription, matching Android where the listener is live while previewing).
  /// Idempotent — safe to call from either trigger.
  func syncThermalObserver() {
    let warningWanted = onThermalWarning != nil && thermalThreshold != .none
    if cachedBeautyEnabled || warningWanted {
      registerThermalObserver()
    } else {
      unregisterThermalObserver()
    }
  }

  func getThermalStatus() throws -> ThermalStatus {
    return ProcessInfo.processInfo.thermalState.toNitro()
  }

  func setOnThermalWarning(callback: @escaping (ThermalStatus) -> Void) throws {
    onThermalWarning = callback
    syncThermalObserver()
  }

  // ─── No-op API parity stubs ──────────────────────────────────────────────

  func forceIncrementalTs(enabled: Bool) throws {
    // HaishinKit emits monotonic RTMP timestamps internally. Kept for API parity.
  }

  func setStreamDelay(delayMs: Double) throws {
    // HaishinKit 2.x doesn't expose a send-side delay knob. Kept for API parity.
  }
}
