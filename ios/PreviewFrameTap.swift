//
//  PreviewFrameTap.swift
//  NitroRtmpPublisher
//
//  A passive `MediaMixerOutput` that keeps the most-recent *composited*
//  preview frame so the view layer can grab a freeze-frame on demand
//  (used to cover the ~400ms AVCaptureSession reconfigure during a camera
//  flip — see `HybridRtmpPublisherView.showFreezeFrame`).
//
//  Why a separate output instead of snapshotting the preview view?
//  `MTHKView` is Metal-backed; UIKit's `snapshotView` / `drawViewHierarchyInRect`
//  return BLACK for `CAMetalLayer` content, so a UIView snapshot would freeze to
//  a black rectangle. Instead we register as a second mixer output with
//  `videoTrackId == .max`, which receives the SAME composited `CMSampleBuffer`s
//  `MTHKView` renders (orientation + mirror + beauty effect all already baked
//  in). The captured frame therefore matches the live preview pixel-for-pixel.
//
//  This mirrors HaishinKit's own `MTHKView`, which likewise keeps the latest
//  frame as a `CIImage` — so holding one composited buffer at a time is a
//  proven-safe pattern here.
//

import AVFoundation
import CoreImage
import Foundation
import HaishinKit

final class PreviewFrameTap: MediaMixerOutput, @unchecked Sendable {

  // `.max` → receive the composited video output (the same stream MTHKView
  // consumes), in both `.passthrough` and `.offscreen` compositing modes.
  let videoTrackId: UInt8? = UInt8.max
  // We don't care about audio.
  let audioTrackId: UInt8? = nil

  // Guards `latest`. The `didOutput` callback is `nonisolated` and fires from
  // the mixer's executor; `latestImage()` / `clear()` are read on main. An
  // NSLock keeps this race-free without a per-frame hop to MainActor (which is
  // what MTHKView does — we avoid that extra ~30 Tasks/sec).
  private let lock = NSLock()
  private var latest: CIImage?

  // MARK: MediaMixerOutput

  nonisolated func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
    guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
    // `CIImage(cvPixelBuffer:)` is lazy + retains the buffer; we replace the
    // stored image every frame so at most one composited buffer is held at a
    // time. The view renders it to a CGImage almost immediately on flip (the
    // stored frame is ≤1 frame old in steady state), so the buffer is still
    // valid when we read it.
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    lock.lock()
    latest = image
    lock.unlock()
  }

  nonisolated func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {}

  func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {}

  // MARK: App-facing

  /// The latest composited preview frame, or nil if none has arrived yet
  /// (e.g. before the first attach, or after `clear()`).
  func latestImage() -> CIImage? {
    lock.lock()
    defer { lock.unlock() }
    return latest
  }

  /// Drop the retained frame so we don't pin a capture buffer after the
  /// preview stops.
  func clear() {
    lock.lock()
    latest = nil
    lock.unlock()
  }
}
