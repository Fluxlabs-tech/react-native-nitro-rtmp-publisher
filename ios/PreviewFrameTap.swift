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
  // Composited video frames since the last `takeFrameCount()`. Used to derive
  // the live video fps for `onStreamStats` (the bitrate timer reads + resets it
  // each second). This is the rate frames are fed to the encoder.
  private var frameCount: Int = 0
  // Only count while a stats consumer is active (toggled via `setCounting`), so
  // the per-frame path stays a no-op when `onStreamStats` isn't subscribed.
  private var counting = false
  // A one-shot wait for a live picture after a camera swap; see `whenPictureIsLive`.
  private struct LiveWait {
    // Frames that arrive before this (system uptime) only set `previous`.
    let notBefore: TimeInterval
    // The previous frame's samples, to tell a new frame from a repeated one.
    var previous: [UInt8]?
    // Frames so far that showed a picture and differed from the one before.
    var fresh = 0
    let handler: () -> Void
  }
  private var liveWait: LiveWait?

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
    if counting { frameCount += 1 }
    let waiting = liveWait != nil
    lock.unlock()
    // Only while a flip is waiting to reveal the new camera: a few frames per flip.
    guard waiting else { return }
    let samples = Self.samples(of: pixelBuffer)
    lock.lock()
    var handler: (() -> Void)?
    if var wait = liveWait {
      // A frame this can't read counts as fresh, so a wait can't hang on it.
      let differs = samples.map { $0 != wait.previous } ?? true
      let hasPicture = samples.map { ($0.max() ?? 0) - ($0.min() ?? 0) > 2 } ?? true
      wait.previous = samples
      if differs, hasPicture, ProcessInfo.processInfo.systemUptime >= wait.notBefore {
        wait.fresh += 1
      }
      if wait.fresh >= 2 {
        handler = wait.handler
        liveWait = nil
      } else {
        liveWait = wait
      }
    }
    lock.unlock()
    handler?()
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

  /// Calls `handler` once, from the mixer's executor, when the preview is showing
  /// the new camera live after a swap: the second composited frame, arriving at
  /// least `settle` seconds from now, that has a picture in it and differs from
  /// the frame before it.
  ///
  /// The attach returning is not that moment. What reaches the preview after it:
  ///  - first, in one burst, whatever the pipeline buffered while the mixer was
  ///    busy with the attach, which can still be the old camera. `settle` lets
  ///    that pass;
  ///  - frames of one flat colour: a camera's first frame or two, or the
  ///    offscreen screen's bare background. They don't count;
  ///  - in `.offscreen` compositing (beauty filter), an early frame of the new
  ///    camera, taken before its exposure settled, that HaishinKit's screen
  ///    holds for 250-600 ms (iPhone 15) before live frames flow. Frames keep
  ///    arriving all through it, so neither counting frames nor a fixed wait
  ///    finds its end; a frame that differs from the one before it does.
  ///
  /// A second call replaces a wait that has not fired. A scene that gives no
  /// such frames (a covered lens) never fires: the caller needs a timeout.
  func whenPictureIsLive(settle: TimeInterval, _ handler: @escaping () -> Void) {
    lock.lock()
    liveWait = LiveWait(notBefore: ProcessInfo.processInfo.systemUptime + settle, handler: handler)
    lock.unlock()
  }

  /// Drops a wait started with `whenPictureIsLive` that has not fired.
  func cancelLiveWait() {
    lock.lock()
    liveWait = nil
    lock.unlock()
  }

  /// 144 luma samples spread over the frame: enough to tell a new camera frame
  /// from a repeated one (sensor noise alone changes some of them) and a picture
  /// from a flat colour, at no cost next to the frame's own processing. Nil for
  /// a buffer this can't read.
  private static func samples(of buffer: CVPixelBuffer) -> [UInt8]? {
    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    // HaishinKit hands out bi-planar 4:2:0 frames in both compositing modes:
    // plane 0 is luma, one or two bytes a sample. A packed BGRA frame has four.
    let planar = CVPixelBufferIsPlanar(buffer)
    let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
    let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
    let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
    let address = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
    guard let address, width >= 16, height >= 16, rowBytes >= width else { return nil }
    let sampleBytes = rowBytes / width
    // The most significant byte of a sample: the green byte of BGRA, the high
    // byte of a little-endian 10-bit sample, the only byte of an 8-bit one.
    let offset = sampleBytes >= 4 ? 1 : sampleBytes - 1
    let bytes = address.assumingMemoryBound(to: UInt8.self)
    var values = [UInt8]()
    values.reserveCapacity(144)
    for row in 1...12 {
      for column in 1...12 {
        values.append(bytes[(height * row / 13) * rowBytes + (width * column / 13) * sampleBytes + offset])
      }
    }
    return values
  }

  /// Enable/disable frame counting and reset the counter. The bitrate timer
  /// turns this on only while streaming AND `onStreamStats` is subscribed, so
  /// the per-frame increment never runs when no one is listening.
  func setCounting(_ enabled: Bool) {
    lock.lock()
    counting = enabled
    frameCount = 0
    lock.unlock()
  }

  /// Number of composited video frames since the last call, resetting the
  /// counter. The bitrate timer calls this once a second → frames ≈ fps.
  func takeFrameCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    let c = frameCount
    frameCount = 0
    return c
  }

  /// Drop the retained frame so we don't pin a capture buffer after the
  /// preview stops.
  func clear() {
    lock.lock()
    latest = nil
    frameCount = 0
    liveWait = nil
    lock.unlock()
  }
}
