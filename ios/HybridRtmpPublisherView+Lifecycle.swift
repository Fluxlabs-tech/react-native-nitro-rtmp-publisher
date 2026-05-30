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
    // Cancel any in-flight reconnect — iOS is about to suspend networking
    // and the next retry would just hit `requestTimedOut`. We'll fire a
    // fresh reconnect on foreground if the user still wants to stream.
    reconnectTask?.cancel()
    reconnectTask = nil
    reconnectScheduled = false
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

  @objc func appWillEnterForeground() {
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
