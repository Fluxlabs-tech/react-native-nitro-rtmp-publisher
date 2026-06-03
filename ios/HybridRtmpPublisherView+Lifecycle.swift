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
    // Defuse any still-pending live-tier background teardown (e.g. a quick
    // background→foreground bounce shorter than the 0.6s defer). The work item's
    // own guard would also no-op it, but cancelling drops the dangling ref. #3.
    pendingBackgroundTeardown?.cancel()
    pendingBackgroundTeardown = nil
    // Resume the PIP display layer's decoder (cheap + harmless on every tier).
    onMain { [weak self] in self?.pip.flushForResume() }
    // Only resurrect capture/stream if backgrounding actually tore them down.
    // On a LIVE PIP return the camera + RTMP stream stayed alive (no teardown
    // ran), so re-attaching the camera here would force a needless ~400ms
    // reconfigure — the visible jitter when coming back from PIP.
    let needsResume = didBackgroundTeardown
    didBackgroundTeardown = false
    guard needsResume else { return }
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
    if shouldBeStreaming, !isPublishingInFlight(), currentRtmpConnectUrl != nil {
      retriesRemaining = max(retriesRemaining, 1)
      scheduleReconnect(delayMs: 1500, reason: "foreground")
    }
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
    emitConnectionEvent(.disconnect, "session interrupted: \(reason)")
  }

  @objc func sessionInterruptionEnded(_ notification: Notification) {
    defrostCapture()
    onMain { [weak self] in self?.pip.flushForResume() }
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
      // rebuild on `.ended`, so there's nothing to do here.
      break
    case .ended:
      // Only restore if we're actually capturing (preview / stream active).
      guard cachedIsOnPreview else { return }
      scheduleAudioRestart()
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
