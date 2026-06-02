//
//  PictureInPictureController.swift
//  NitroRtmpPublisher
//
//  iOS system Picture-in-Picture for the camera publisher.
//
//  Unlike Android (where a foreground service keeps the camera + encoder live
//  in the PIP window on every device), iOS suspends AVCaptureSession the moment
//  the app backgrounds — and entering system PIP IS backgrounding. So:
//   • The PIP *window* works on any iPhone/iPad (iOS 15+): it shows the last
//     composited frame; while backgrounded the stream stalls and resumes on
//     return (the existing background handler already does that).
//   • The camera stays *live* in PIP (and the RTMP stream keeps publishing)
//     only where iOS allows multitasking camera access — iPhone iOS 18+ (with
//     the host app declaring the `voip` UIBackgroundMode) and M1+ iPads — via
//     `AVCaptureSession.isMultitaskingCameraAccessEnabled`. That tier is set up
//     in `HybridRtmpPublisherView+PictureInPicture.swift`.
//
//  The display surface is HaishinKit's `PiPHKView` — a UIView whose layer IS an
//  `AVSampleBufferDisplayLayer` and which is itself a `MediaMixerOutput` that
//  enqueues the composited preview frames (orientation + mirror + beauty baked
//  in). We hand that layer to `AVPictureInPictureControllerContentSource`, which
//  is the only sanctioned path for live / non-`AVPlayer` PIP content (iOS 15+);
//  `MTHKView` is `CAMetalLayer`-backed and cannot drive PIP.
//
//  All methods here must be called on the main thread (AVKit requirement). The
//  owning view routes through `onMain`.
//

import AVFoundation
import AVKit
import Foundation
import HaishinKit
import UIKit

final class PictureInPictureController: NSObject {

  /// The AVSampleBufferDisplayLayer-backed view fed by the mixer. The owner
  /// adds this as a (visually redundant — it shows the same composited frames
  /// as the live preview) subview behind the preview's flip overlay and
  /// registers it as a `MediaMixerOutput`, but only while PIP is armed, so the
  /// extra per-frame enqueue costs nothing when the feature is off.
  ///
  /// COST NOTE (audit #6): while armed, HaishinKit's `PiPHKView` enqueues each
  /// composited frame inside a `Task { @MainActor in … }` — i.e. ~30 main-actor
  /// hops/sec. That hop is inherent to AVKit's sample-buffer PIP path
  /// (`enqueue` / `setNeedsDisplay` are main-thread-only, and only `PiPHKView`
  /// can drive the content source — `MTHKView` is CAMetalLayer-backed and
  /// cannot), it lives in vendored HaishinKit (not here), it's bounded to the
  /// live tier while armed, and it's trivial next to the H.264 encode already on
  /// every frame. If Instruments ever shows queue-depth growth, the only in-tree
  /// lever is a `PiPHKView` subclass swapping the per-frame `Task` for a
  /// precomputed MainActor closure / `DispatchQueue.main.async`.
  let displayView = PiPHKView(frame: .zero)

  /// Fired on PIP enter (`true`) / exit (`false`). Always delivered on main
  /// (AVKit calls the delegate on main); the owner re-marshals to the JS thread.
  var onChange: ((Bool) -> Void)?

  // Lock-guarded (audit #4): written on main by AVKit's delegate callbacks (via
  // the weak proxy) but read from the JS thread by `isInPictureInPicture()`. A
  // plain stored Bool would be a (benign, but undisciplined) cross-thread race;
  // the lock matches the `PipSupportBox` / `publishLock` pattern used elsewhere.
  private let isActiveLock = NSLock()
  private var _isActive = false
  private(set) var isActive: Bool {
    get { isActiveLock.lock(); defer { isActiveLock.unlock() }; return _isActive }
    set { isActiveLock.lock(); _isActive = newValue; isActiveLock.unlock() }
  }

  private var controller: AVPictureInPictureController?
  private var possibleObservation: NSKeyValueObservation?
  private var pendingStart = false
  // Weak-forwarding delegate proxies (defined at the bottom of this file).
  // Routing AVKit's strong `delegate` / `playbackDelegate` references through
  // these — instead of `self` — keeps the controller⇄self retain cycle from
  // forming, so the whole PIP graph self-collects when the owning view releases
  // its `let pip`, even if `teardown()` never runs (Fabric onDropView edge
  // cases). See audit #1.
  private let controllerDelegateProxy = PIPControllerDelegateProxy()
  private let playbackDelegateProxy = PIPPlaybackDelegateProxy()

  override init() {
    super.init()
    controllerDelegateProxy.owner = self
    playbackDelegateProxy.owner = self
    displayView.videoGravity = .resizeAspect
    // A running host-clock timebase gives PIP a live wall-clock reference; the
    // playback delegate then reports an infinite time range to mark the source
    // as live (hides the scrubber). Without a timebase PIP can refuse to start.
    var timebase: CMTimebase?
    CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(),
      timebaseOut: &timebase
    )
    if let timebase {
      // Seed to the host clock's CURRENT time (NOT .zero): the composited
      // CMSampleBuffers carry capture-clock (host-time) PTS, so a timebase
      // starting at 0 would treat every frame as far in the future and the
      // layer would display nothing (black). Matching host time displays them.
      CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
      CMTimebaseSetRate(timebase, rate: 1.0)
      displayView.layer.controlTimebase = timebase
    }
  }

  var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

  /// Build (idempotently) the controller around the display layer and set the
  /// auto-enter toggle. Auto-enter (`canStartPictureInPictureAutomaticallyFromInline`)
  /// is the iOS analog of Android's `setAutoEnterEnabled`.
  func setup(autoStart: Bool) {
    guard isSupported else { return }
    if controller == nil {
      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: displayView.layer,
        playbackDelegate: playbackDelegateProxy
      )
      let c = AVPictureInPictureController(contentSource: source)
      c.delegate = controllerDelegateProxy
      controller = c
    }
    controller?.canStartPictureInPictureAutomaticallyFromInline = autoStart
  }

  func setAutoStart(_ enabled: Bool) {
    controller?.canStartPictureInPictureAutomaticallyFromInline = enabled
  }

  /// Manual entry. Returns whether a start was initiated. If PIP isn't possible
  /// yet (no frame enqueued / layer not yet on screen — common right after
  /// arming) the start is DEFERRED via KVO and fires once it becomes possible;
  /// we still return `true` because the request was accepted. Never call
  /// `startPictureInPicture()` synchronously right after building the controller.
  @discardableResult
  func start() -> Bool {
    guard let c = controller else { return false }
    if c.isPictureInPictureActive { return false }
    if c.isPictureInPicturePossible {
      c.startPictureInPicture()
      return true
    }
    pendingStart = true
    possibleObservation?.invalidate()
    possibleObservation = c.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] controller, _ in
      guard let self else { return }
      DispatchQueue.main.async {
        guard self.pendingStart, controller.isPictureInPicturePossible else { return }
        self.pendingStart = false
        self.possibleObservation?.invalidate()
        self.possibleObservation = nil
        controller.startPictureInPicture()
      }
    }
    return true
  }

  /// Flush the display layer so it resumes decoding after a background /
  /// interruption (otherwise enqueued frames are ignored and the window stays
  /// frozen on return). Call on foreground / interruption-end.
  func flushForResume() {
    let layer = displayView.layer
    if #available(iOS 17.0, *) {
      if layer.sampleBufferRenderer.requiresFlushToResumeDecoding {
        layer.sampleBufferRenderer.flush()
      }
    } else {
      if layer.requiresFlushToResumeDecoding {
        layer.flush()
      }
    }
  }

  func teardown() {
    pendingStart = false
    possibleObservation?.invalidate()
    possibleObservation = nil
    if controller?.isPictureInPictureActive == true {
      controller?.stopPictureInPicture()
    }
    controller?.delegate = nil
    controller = nil
    isActive = false
  }
}

// MARK: - Delegate handlers (invoked by the weak proxies below)

extension PictureInPictureController {
  fileprivate func handleDidStart() {
    isActive = true
    onChange?(true)
  }

  fileprivate func handleDidStop() {
    isActive = false
    onChange?(false)
  }

  fileprivate func handleFailedToStart() {
    isActive = false
    pendingStart = false
  }
}

// MARK: - Weak-forwarding delegate proxies (audit #1)
//
// `AVPictureInPictureController` strongly retains both its `delegate` and (via
// the `ContentSource`) its `playbackDelegate`. Pointing those at the
// `PictureInPictureController` directly forms a controller⇄owner retain cycle
// that ONLY `teardown()` breaks — so a view dropped through a path that skips
// `disarmPictureInPicture()` (documented Fabric edge cases) would leak the whole
// PIP graph (controller + ContentSource + display layer + timebase). These
// proxies hold the owner WEAKLY and forward, so the graph self-collects the
// moment the owning view releases its `let pip`, independent of teardown.

private final class PIPControllerDelegateProxy: NSObject, AVPictureInPictureControllerDelegate {
  weak var owner: PictureInPictureController?

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    owner?.handleDidStart()
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    owner?.handleDidStop()
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    owner?.handleFailedToStart()
  }

  /// Called when the user taps "return to app" on the PIP window. We have
  /// nothing special to restore (the inline preview is still mounted), so just
  /// signal completion so iOS finishes the un-PIP transition.
  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}

private final class PIPPlaybackDelegateProxy: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
  weak var owner: PictureInPictureController?

  func pictureInPictureController(
    _ controller: AVPictureInPictureController, setPlaying playing: Bool
  ) {
    // Live camera — no play/pause semantics.
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ controller: AVPictureInPictureController
  ) -> CMTimeRange {
    // Infinite range marks the source as live and hides the PIP scrubber.
    return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ controller: AVPictureInPictureController
  ) -> Bool {
    return false
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
    // No-op — do not tear down or resize the layer on render-size transitions.
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    // Live source can't skip — complete immediately so the controls don't hang.
    completionHandler()
  }
}
