//
//  HybridRtmpPublisherView+PictureInPicture.swift
//  NitroRtmpPublisher
//
//  Wires the shared Nitro PIP API (the prop + 3 methods, identical to Android)
//  to `PictureInPictureController`. See that file + the `ios-pip` research notes
//  for the platform constraints. Two tiers:
//   • Frozen-frame PIP — every iPhone/iPad on iOS 15+. The window shows the last
//     composited frame; the stream pauses while backgrounded and resumes on
//     return (the existing background handler).
//   • Live PIP — iPhone iOS 18+ (host app declares the `voip` UIBackgroundMode)
//     and M1+ iPads. The camera stays live and the RTMP stream keeps publishing.
//     Gated at runtime by `AVCaptureSession.isMultitaskingCameraAccessSupported`,
//     so it auto-activates only when the host opts in — the library default and
//     example stay App-Store-safe.
//

import AVFoundation
import Foundation
import HaishinKit
import NitroModules
import UIKit

/// Lock-guarded result so the `mixer.configuration` lambda (runs on the mixer
/// actor) can report back without a cross-actor data race.
private final class PipSupportBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _supported = false
  private var _enabled = false
  var supported: Bool {
    get { lock.lock(); defer { lock.unlock() }; return _supported }
    set { lock.lock(); _supported = newValue; lock.unlock() }
  }
  var enabled: Bool {
    get { lock.lock(); defer { lock.unlock() }; return _enabled }
    set { lock.lock(); _enabled = newValue; lock.unlock() }
  }
}

extension HybridRtmpPublisherView {

  // ─── Nitro API (identical signatures to Android) ─────────────────────────

  func enterPictureInPicture() throws -> Bool {
    // PIP is offered ONLY on the live tier — frozen-frame devices return false
    // (a frozen window + paused stream is a worse experience than no PIP).
    guard pip.isSupported, multitaskingCameraAccessSupported else { return false }
    // Nitro view methods run on the JS thread; AVKit must be touched on main.
    onMain { [weak self] in
      guard let self else { return }
      self.armPictureInPicture(autoStart: self.pictureInPictureEnabled)
      self.pip.start()
    }
    return true
  }

  func isInPictureInPicture() throws -> Bool { return pip.isActive }

  func setOnPictureInPictureChange(callback: @escaping (Bool) -> Void) throws {
    onPictureInPictureChange = callback
  }

  // ─── Arm / disarm (main thread) ──────────────────────────────────────────

  /// Build the PIP controller, attach the AVSampleBufferDisplayLayer-backed
  /// view to the window, and feed it composited frames. Idempotent.
  func armPictureInPicture(autoStart: Bool) {
    guard pip.isSupported else { return }
    if !pipArmed {
      pipArmed = true
      // PIP requires a playback-capable, active audio session before the
      // controller is created. `.playAndRecord` (set here) satisfies it without
      // breaking mic capture. Idempotent.
      configureAudioSession()
      // The PIP source layer must (a) be in the window + rendering for PIP to
      // become possible, and (b) carry the right ASPECT RATIO: AVKit derives the
      // floating-window shape from THIS layer's bounds (not the buffer size), so a
      // tiny/square layer produced a square window with the portrait video
      // pillarboxed (black bar). So size it to the full preview bounds
      // (device-portrait aspect, matching Android's PIP window). To avoid the
      // black-cover bug — a full-opacity subview sits ON TOP of the MTHKView Metal
      // preview — we keep it nearly transparent: the MTHKView underneath stays the
      // visible inline preview, while this layer still composites + renders
      // (alpha > 0) so PIP stays possible, and PIP draws its window at full
      // opacity from the enqueued buffers.
      pip.displayView.frame = previewView.bounds
      pip.displayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      pip.displayView.alpha = 0.02
      pip.displayView.videoGravity = aspectRatioMode.avLayerGravity
      previewView.insertSubview(pip.displayView, at: 0)
      // COST NOTE (audit #7): while armed, this AVSampleBufferDisplayLayer and
      // the MTHKView underneath BOTH present every composited buffer. The
      // composite itself runs once in the mixer, so the extra cost is one more
      // window-server layer presenting — NOT 2× GPU — and only on the live tier
      // while armed. Do NOT gate the mixer output on `isPictureInPictureActive`:
      // the layer must already be rendering for auto-enter-on-background to work,
      // and AVKit derives the portrait PIP-window aspect from these full bounds.
      let view = pip.displayView
      // Serialize the add against any in-flight remove so order is deterministic
      // (the mixer actor gives no FIFO ordering between separately-spawned
      // Tasks). The last-issued op wins, matching `pipArmed`. See audit #2.
      let prev = pipOutputTask
      pipOutputTask = Task { [weak self] in
        await prev?.value
        await self?.mixer.addOutput(view)
      }
    }
    pip.setup(autoStart: autoStart)
  }

  func disarmPictureInPicture() {
    guard pipArmed else { return }
    pipArmed = false
    pip.teardown()
    let view = pip.displayView
    // Serialize the remove against any in-flight add (see `armPictureInPicture`):
    // chaining on the previous Task guarantees the last-issued op wins, so the
    // view can't be left registered as a mixer output after disarm. See audit #2.
    let prev = pipOutputTask
    pipOutputTask = Task { [weak self] in
      await prev?.value
      await self?.mixer.removeOutput(view)
    }
    view.removeFromSuperview()
  }

  // ─── Live tier: multitasking camera access ───────────────────────────────

  /// Enable `AVCaptureSession.isMultitaskingCameraAccessEnabled` when the device
  /// supports it (iPhone iOS 18+ with the host's `voip` background mode, M1+
  /// iPad) so the camera keeps delivering frames in PIP and the RTMP stream
  /// stays live. No-op (and `multitaskingCameraAccessActive` stays false)
  /// everywhere else — those devices get the frozen-frame tier. Reaches the
  /// session HaishinKit owns via `MediaMixer.configuration`. Only meaningful
  /// while PIP is armed.
  /// Resolve live-tier support against the capture session, enable multitasking
  /// camera access where supported, and (re)sync PIP arming. Called from the
  /// `pictureInPictureEnabled` setter and each camera attach, so support is known
  /// once preview is running.
  func applyMultitaskingCameraAccess() {
    guard pictureInPictureEnabled else { return }
    guard #available(iOS 16.0, *) else {
      onMain { [weak self] in
        self?.multitaskingCameraAccessSupported = false
        self?.syncPictureInPicture()
      }
      return
    }
    let box = PipSupportBox()
    Task { [weak self] in
      guard let self else { return }
      await self.mixer.configuration { session in
        box.supported = session.isMultitaskingCameraAccessSupported
        if box.supported {
          session.isMultitaskingCameraAccessEnabled = true
          box.enabled = session.isMultitaskingCameraAccessEnabled
        }
      }
      self.onMain { [weak self] in
        guard let self else { return }
        self.multitaskingCameraAccessSupported = box.supported
        self.multitaskingCameraAccessActive = box.enabled
        self.syncPictureInPicture()
      }
    }
  }

  /// Arm PIP only on the LIVE tier (multitasking camera access supported);
  /// otherwise keep it disabled. Idempotent — safe to call repeatedly.
  func syncPictureInPicture() {
    if pictureInPictureEnabled && multitaskingCameraAccessSupported {
      armPictureInPicture(autoStart: true)
    } else {
      disarmPictureInPicture()
    }
  }

  // ─── Emit ────────────────────────────────────────────────────────────────

  func emitPictureInPictureChange(_ inPip: Bool) {
    onMain { [weak self] in self?.onPictureInPictureChange?(inPip) }
  }
}
