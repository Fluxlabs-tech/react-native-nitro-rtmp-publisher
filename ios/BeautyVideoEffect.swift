//
//  BeautyVideoEffect.swift
//  NitroRtmpPublisher
//
//  Skin-smoothing "beauty" effect for iOS. The smoothing itself is a fast guided
//  filter with three-band reconstruction — see `BeautyGuidedPipeline`, the port of
//  Android's five-pass GLES pipeline. This file owns the effect's STATE (intensity,
//  colour look), the LUT grade, and the final composition.
//
//  Registered as a HaishinKit `VideoEffect` on the mixer's `screen` in
//  `.offscreen` compositing mode. `execute(_:)` runs SYNCHRONOUSLY on
//  HaishinKit's `ScreenActor` for EVERY composited frame, at the stream
//  resolution (typ. 720x1280 portrait) @ 30fps, and affects BOTH the preview
//  and the encoded stream. The returned CIImage becomes a lazy node in
//  HaishinKit's canvas graph that HaishinKit's own CIContext renders.
//
//  ── Why this design (and why earlier attempts failed) ───────────────────────
//   • A plain CIGaussianBlur blended 50/50 softens EVERYTHING (eyes, brows,
//     edges) → reads as "blurry", not "beauty". (Failed attempt #1.)
//   • A single GENERAL `CIKernel(source:)` doing 25 dependent
//     `sample()`/`samplerTransform()` reads per output pixel CRASHED the device
//     live at 720x1280@30fps (~700M dependent reads/sec through the runtime
//     CIKL path → GPU/watchdog instability). (Failed attempt #2.)
//   • Frequency separation (a Gaussian high-pass plus screen/lighten/soft-light
//     blends) was stable and shipped, but MEASURED at full strength it kept 65%
//     of pore detail on light skin, 85% on mid and 105% on deep — i.e. it
//     AMPLIFIED detail on deep skin — while pushing red +31/255. Its smoothing
//     and its brightening were coupled by construction: strength entered through
//     `smoothColor`, which fed the blend stack, so there was no way to smooth
//     harder without reddening. That is the same pair of failures Herin's Android
//     RCA identified, and why the guided filter replaced this shape there rather
//     than being tuned into it. (Retired attempt #3.)
//
//   The guided filter keeps the property that made #3 stable — no neighbour
//   sampling in OUR code, every custom kernel a `CIColorKernel` and every box
//   filter Apple's `CIBoxBlur` — while decoupling smoothing from colour, which it
//   carries as a luma ratio. See `BeautyGuidedPipeline` for the graph, its
//   fp16 precision constraints, and the CIBoxBlur radius trap.
//
//  ── Color-space correctness (the subtle, load-bearing part) ─────────────────
//   HaishinKit's SDR CIContext uses workingFormat = RGBAh (half-float). The
//   working COLOR SPACE is not one fixed thing: CI_PRINT_TREE on a live device
//   shows this effect running in TWO contexts with different ones — the preview
//   MTHKView at ExtendedLinearSRGB and the encode bitmap path at ITUR_709. An
//   earlier version of this comment asserted a single linear ITU-R 709 working
//   space; that was wrong, and the difference matters because the two have
//   different transfer functions.
//
//   The code never depended on the answer: `matchedFromWorkingSpace` /
//   `matchedToWorkingSpace` resolve whatever the RENDERING context declares, so
//   both paths land on the same sRGB-encoded values. Do not replace them with a
//   hardcoded conversion.
//
//   The Android GLSL math, by contrast, runs on GAMMA-ENCODED display values.
//   Running the guided filter's
//   relative-contrast thresholds, the skin-locus chromaticity test and the
//   saturation step on linear-light values would put every one of Herin's
//   measured constants in the wrong domain.
//
//   Fix: pin the kernel to operate on sRGB-gamma-encoded values. We convert the
//   inputs FROM the renderer's working space TO sRGB just before the kernel
//   (`matchedFromWorkingSpace`/colorSpace conversion), run the gamma-domain math,
//   then convert the result BACK to the working space (`matchedToWorkingSpace`)
//   so HaishinKit composites it correctly. These conversions are cheap, stable
//   CIImage color-management nodes (no deprecation, iOS 16+).
//
//  ── Safety / crash-avoidance ────────────────────────────────────────────────
//   • Every failure path (kernel compile, blur, apply, conversion) returns the
//     ORIGINAL frame — beauty degrades to a graceful no-op, never a fatal.
//   • Division guards: the composite's luma ratio divides by max(y, 0.03) and the
//     saturation headroom by max(|dev|, 1e-4), so neither can produce a NaN on a
//     black pixel; the result is clamped to [0,1] for the encoder.
//   • Origin is NOT assumed (0,0): HaishinKit hands us a pre-scaled, transformed
//     CIImage, so everything is driven off `image.extent`, with finite/>=2px
//     guards, clamp-then-crop on every box blur, and a final crop back.
//   • No per-frame heap allocation: every kernel and blur filter is built once
//     and only their inputs are reset per call.
//   • Origin normalisation: the pipeline spans two resolutions, so `execute`
//     translates the frame to the origin before rendering and back afterwards.
//     Tracking a non-zero origin through every scale change is how off-by-one
//     misalignment between the quarter-res and full-res passes creeps in.
//
//  ── Colour looks ────────────────────────────────────────────────────────────
//   Warm / Bright / Cool, matching Android. Warm is the ungraded filter above;
//   Bright and Cool are 32³ colour LUTs applied with `CIColorCube`, built from
//   the SAME atlas Android samples (embedded via `BeautyLookAtlas`, decoded by
//   `BeautyLookCube`), so the two platforms cannot drift apart.
//
//   Order matters and mirrors Android's composite tail exactly: base beauty →
//   LUT (blended by the look mix) → lerp toward the source by intensity. That is
//   why the guided pipeline always renders at FULL strength and the intensity lerp
//   is deferred to `finalize`; applying intensity first would stop the dial from
//   diluting the grade, which it does on Android.
//
//   Cost when no look is selected: nothing beyond the intensity lerp, which the
//   same `finalize` kernel performs either way. With a look: the cube, whose
//   trilinear interpolation is a hardware 3D lookup here rather than the manual
//   blue-axis blend GLES2 forces on Android. The 512KB-per-look cube data is
//   decoded lazily, off the render path, on first use of a non-Warm look.
//
//  ── API stability note ──────────────────────────────────────────────────────
//   `CIColorKernel(source:)` (runtime Core Image Kernel Language) is formally
//   deprecated in favor of Metal CIKernels, but a COLOR kernel (no sampling) is
//   the simple, stable, self-contained path and avoids the `-fcikernel` /
//   `-cikernel` pod build-flag + .metal + resource-bundle plumbing a Metal
//   CIKernel would require. It still works on current iOS; it is the one piece
//   exposed to future-OS behavior change. To port later: write the same math as
//   a Metal CIColorKernel, add `-fcikernel` to MTLCOMPILERFLAGS and `-cikernel`
//   to MTLLINKERFLAGS on the pod target, ship a default.metallib, and load via
//   `CIKernel(functionName:fromMetalLibraryData:)`. Not required now.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import HaishinKit

/// `@unchecked Sendable`: only ever touched on HaishinKit's `ScreenActor`
/// (registration + the per-frame `execute(_:)`), which serializes all access.
/// All mutated state (the look cubes, and the filter inputs inside
/// `BeautyGuidedPipeline`) is therefore confined to that actor; there is no
/// cross-thread mutation.
final class BeautyVideoEffect: VideoEffect, @unchecked Sendable {

  // MARK: - Tuning knobs

  /// Overall strength, 0…1. 1.0 == the full Android look; lower values lerp the
  /// beauty result back toward the original (applied inside the kernel, so it's
  /// free). Use this as the primary "intensity" dial.
  private var intensity: Float = 1.0 {
    didSet { intensity = max(0.0, min(1.0, intensity)) }
  }

  // ── No thermal lever, deliberately ──────────────────────────────────────
  // This used to hold a `thermalScale` that multiplied `intensity` (0.5 at
  // `serious`, 0.3 at `critical`). It was removed: Android does NOT dim the look
  // under heat — it swaps highp for mediump, a cost change nobody can see —
  // whereas scaling intensity silently capped a user-facing slider. On a small
  // chassis that is the normal state, so a slider at 100% delivered half the
  // effect while Android delivered all of it. A thermostat must not overrule the
  // seller's control.
  //
  // That leaves iOS with no thermal cost lever, which is a real gap: unlike the
  // frequency-separation kernel this replaced, `BeautyGuidedPipeline`'s cost is
  // fixed, so there is nothing cheap to give up. The lever to build when a device
  // measurement justifies it is skipping the NARROW BAND — it drops the two
  // full-resolution box blurs, the bulk of the per-frame GPU work, and reads as
  // slightly softer rather than dimmer. Add that; do not reinstate a dimmer.

  func setIntensity(_ value: Float) {
    intensity = value
  }

  // MARK: - Colour look

  /// Which LUT to grade with: -1 Warm (no LUT at all), 0 Bright, 1 Cool.
  /// Mirrors Android's `lookSlot`, including Warm being an absence rather than
  /// a third table. ScreenActor-confined like every other mutable field here.
  private var lookSlot: Int = -1

  /// Look strength, 0…1. Ignored while the look is Warm, exactly as Android
  /// forces `lookMix` to 0 for a negative slot.
  ///
  /// Defaults to 1, matching Android's `desiredLookMix = 1.0f`: selecting a look
  /// without also setting a strength applies it in full. Defaulting to 0 here
  /// would make `setBeautyLook` alone appear to do nothing on iOS while working
  /// on Android — the example app only calls `setBeautyLook`.
  private var lookMix: Float = 1.0

  /// Built on first use of a non-Warm look and kept for the session. Two 512KB
  /// float cubes, so a session that never opens the look picker never allocates
  /// them. nil while the decode is in flight or after it has failed.
  private var lookCubes: [CIFilter]?

  /// Latches the one-shot decode. Set for both "in flight" and "failed" so a
  /// malformed payload can't respawn a decode on every frame.
  private var lookCubesRequested = false

  /// MUST be called on ScreenActor. Kicks the decode off here rather than on the
  /// first graded frame so the work overlaps the user's tap instead of stalling
  /// the render loop.
  func setLookSlot(_ slot: Int) {
    lookSlot = slot
    if slot >= 0 { loadLookCubes() }
  }

  /// MUST be called on ScreenActor.
  func setLookMix(_ value: Float) {
    lookMix = max(0.0, min(1.0, value))
  }

  /// Android forces the mix to 0 for Warm rather than blending toward an
  /// identity table, so Warm costs nothing. Same here.
  private var effectiveLookMix: Float {
    lookSlot < 0 ? 0 : lookMix
  }

  /// The cube for the current slot, or nil while the decode is pending/failed —
  /// in which case `execute` renders the ungraded base filter for those frames.
  private func currentLookCube() -> CIFilter? {
    guard lookSlot >= 0 else { return nil }
    guard let lookCubes else {
      loadLookCubes()
      return nil
    }
    return lookSlot < lookCubes.count ? lookCubes[lookSlot] : nil
  }

  /// Decodes the atlas off the render path, then hands the finished payloads to
  /// ScreenActor to build the filters. Only `Data` crosses the boundary (CIFilter
  /// is not Sendable), and the assignment lands on the same actor that reads it.
  private func loadLookCubes() {
    guard !lookCubesRequested else { return }
    lookCubesRequested = true
    DispatchQueue.global(qos: .userInitiated).async {
      guard let payloads = BeautyLookCube.decodeAll() else { return }
      Task { @ScreenActor in
        let filters = payloads.compactMap { BeautyLookCube.makeFilter($0) }
        guard filters.count == payloads.count else { return }
        self.lookCubes = filters
        // Mirrors Android's `beauty LUT 256x256` line. Logged on SUCCESS as well
        // as failure so a device session can tell "the cubes loaded" apart from
        // "nothing happened", which silence alone cannot.
        NSLog(
          "[BeautyVideoEffect] beauty LUT ready: \(filters.count) looks,"
            + " \(BeautyLookCube.dimension)³ cube each"
        )
      }
    }
  }

  // MARK: - Fixed objects (built once; reused every frame)

  /// Guided filter + three-band reconstruction — the smoothing itself. nil on
  /// kernel compile failure → execute() passes frames through unchanged (beauty
  /// becomes a safe no-op).
  private let guided = BeautyGuidedPipeline()

  /// Applies the look mix and the intensity lerp in one O(1) pass.
  private let finalizeKernel: CIColorKernel?

  /// sRGB color space we pin the kernel math to (gamma-encoded, to match the
  /// domain Android's GLSL runs in). Created once.
  private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

  init() {
    finalizeKernel = CIColorKernel(source: BeautyVideoEffect.finalizeSource)
    if guided == nil {
      NSLog("[BeautyVideoEffect] guided pipeline unavailable — beauty is a no-op")
    }
    if finalizeKernel == nil {
      NSLog("[BeautyVideoEffect] finalize kernel failed to compile — beauty is a no-op")
    }
    if sRGB == nil {
      NSLog("[BeautyVideoEffect] sRGB color space unavailable — beauty is a no-op")
    }
    prewarm()
  }

  // MARK: - Pre-warm

  /// Compiles the CIColorKernel + Gaussian Metal pipelines ahead of the first
  /// real frame, on a background queue, so the first time beauty is enabled the
  /// offscreen render loop doesn't stall ~seconds while Core Image JIT-compiles
  /// them. Core Image caches the compiled kernel program globally, so
  /// HaishinKit's own CIContext benefits. Runs once at init — before the effect
  /// is ever registered — so it can't race `execute(_:)`. It DOES drive the shared
  /// `guided` pipeline's filters, which is safe only because nothing else can be
  /// running yet.
  private func prewarm() {
    guard let guided, let finalizeKernel, let sRGB else { return }
    DispatchQueue.global(qos: .utility).async {
      // 64x64 is enough to exercise every stage: the quarter-res chain still has
      // a 16x16 working size, above the 2px floor `render` guards on.
      let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
      let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
      let src = (base.matchedFromWorkingSpace(to: sRGB) ?? base).cropped(to: extent)
      guard let beauty = guided.render(source: src, extent: extent) else { return }
      // Warm the look path's kernel too, so the first tap on Bright/Cool doesn't
      // stall the render loop compiling it. The cube itself is a built-in whose
      // pipeline Core Image already has; only its 512KB payload is lazy, and that
      // is decoded off the render path by `loadLookCubes()`.
      guard let mixed = finalizeKernel.apply(
        extent: extent,
        arguments: [src, beauty, beauty, Float(0.5), Float(1.0)]
      ) else { return }
      let working = mixed.matchedToWorkingSpace(from: sRGB) ?? mixed
      _ = CIContext().createCGImage(working, from: extent)
    }
  }

  // MARK: - VideoEffect

  func execute(_ image: CIImage) -> CIImage {
    guard let guided, let finalizeKernel, let sRGB else { return image }

    // HaishinKit hands us `CIImage(cvPixelBuffer:, options:).transformed(by:)`,
    // so the origin is NOT guaranteed to be (0,0). Guard against the degenerate /
    // infinite extents Core Image can produce.
    let extent = image.extent
    guard !extent.isInfinite, !extent.isNull,
          extent.width.isFinite, extent.height.isFinite,
          extent.width >= 2, extent.height >= 2 else { return image }

    // Android's drawFilter() blits the frame straight through when intensity
    // reaches 0 rather than paying the pipeline to reproduce its own input.
    let effectiveIntensity = intensity
    guard effectiveIntensity > 0.001 else { return image }

    // Normalise to the origin. The pipeline spans two resolutions, and carrying a
    // non-zero origin through every scale change is how the quarter-res and
    // full-res passes end up misaligned by a pixel.
    let originExtent = CGRect(origin: .zero, size: extent.size)
    let centred = image.transformed(
      by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
    )

    // Pin the math to sRGB-gamma-encoded values. HaishinKit's working space is
    // linear-light ITU-R 709; the Android math expects gamma-encoded display
    // values, so convert in here and back out at the end.
    let src = (centred.matchedFromWorkingSpace(to: sRGB) ?? centred)
      .cropped(to: originExtent)

    // Always full strength: the look grades this result, and only then does
    // `finalize` lerp toward the source. See the ordering note in the header.
    guard let beautyFull = guided.render(source: src, extent: originExtent) else {
      return image
    }

    // A look grades the beauty result before the intensity lerp. With no look (or
    // a cube still decoding) `graded` IS `beautyFull` and the mix is forced to 0,
    // so the same kernel handles both paths.
    var graded = beautyFull
    var mix: Float = 0
    if effectiveLookMix > 0, let lookCube = currentLookCube() {
      lookCube.setValue(beautyFull, forKey: kCIInputImageKey)
      if let out = lookCube.outputImage?.cropped(to: originExtent) {
        graded = out
        mix = effectiveLookMix
      }
    }

    guard let kernelOut = finalizeKernel.apply(
      extent: originExtent,
      arguments: [src, beautyFull, graded, mix, effectiveIntensity]
    ) else { return image }

    return finish(
      kernelOut, originExtent: originExtent, targetExtent: extent,
      sRGB: sRGB, fallback: image
    )
  }

  /// Converts the gamma-domain result BACK to the renderer's working space so
  /// HaishinKit composites/encodes it correctly, undoes the origin normalisation,
  /// then re-asserts the original extent — HaishinKit renders via
  /// `createCGImage(image, from: videoGravity.region(bounds, image: image.extent))`,
  /// and a stray infinite or shifted extent here would mis-crop the output.
  private func finish(
    _ image: CIImage, originExtent: CGRect, targetExtent: CGRect,
    sRGB: CGColorSpace, fallback: CIImage
  ) -> CIImage {
    let working = image.matchedToWorkingSpace(from: sRGB) ?? image
    let moved = working.transformed(
      by: CGAffineTransform(translationX: targetExtent.minX, y: targetExtent.minY)
    )
    let result = moved.cropped(to: targetExtent)
    // `fallback` is the UNTOUCHED input frame, not `image` (which is the kernel
    // output we just failed to make sense of).
    return result.extent.isInfinite ? fallback : result
  }

  // MARK: - Look mix kernel (CIColorKernel — NO sample()/dependent reads)
  //
  // Mirrors the tail of Android's beauty_composite_fragment.glsl:
  //
  //     if (uLookMix > 0.0) color = mix(color, lutLookup(color), uLookMix);
  //     color = mix(src, color, uBeautyIntensity);
  //
  // `graded` is the cube's output — the CIColorCube filter stands in for
  // lutLookup(), and being a built-in it does the trilinear interpolation in
  // hardware instead of the manual blue-axis blend GLES2 forces on Android.
  //
  // Both mixes live in one kernel so a look costs exactly one extra O(1) pass,
  // and `strength` is applied HERE rather than in `beauty` so the intensity dial
  // dilutes the grade the same way it does on Android.
  private static let finalizeSource = """
  kernel vec4 finalize(__sample src, __sample beauty, __sample graded,
                       float lookMix, float strength) {
      vec3 c = mix(beauty.rgb, graded.rgb, clamp(lookMix, 0.0, 1.0));
      c = mix(src.rgb, c, clamp(strength, 0.0, 1.0));
      return vec4(clamp(c, 0.0, 1.0), src.a);
  }
  """
}
