//
//  BeautyVideoEffect.swift
//  NitroRtmpPublisher
//
//  Skin-smoothing "beauty" effect for iOS — a frequency-separation port of
//  Android's RootEncoder `beauty_fragment.glsl` (HIGH-PASS skin smoothing).
//  It smooths only low-frequency skin tone while PRESERVING high-frequency
//  detail (eyes, brows, hair, pores, lip/nostril edges), so it reads as
//  "beauty" and NOT "blur".
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
//
//   Frequency separation removes ALL neighbor sampling from our custom code:
//     1. The low-pass is Apple's separable, GPU-optimized `CIGaussianBlur`.
//     2. Our custom kernel is a `CIColorKernel` — two `__sample` inputs (the
//        original frame + the blurred frame), reading ONLY the destination
//        pixel of each. No `sample()`, no `samplerTransform()`, no neighbor
//        reads → strictly O(1) per pixel. This is the cheap, stable shape
//        Core Image is built for.
//   Core Image aligns `destCoord()` across both `__sample` inputs automatically
//   because both images share the same extent/coordinate space, so the per-pixel
//   high-pass (central.g − blurred.g) lines up with zero manual sampling.
//
//  ── Color-space correctness (the subtle, load-bearing part) ─────────────────
//   HaishinKit's SDR CIContext uses workingFormat = RGBAh (half-float) and
//   workingColorSpace = ITU-R 709 — i.e. a LINEAR-light working space — and it
//   color-manages the camera input into that space (see DynamicRangeMode +
//   VideoTrackScreenObject in HaishinKit 2.2.5). The Android GLSL math, by
//   contrast, runs on GAMMA-ENCODED display values. Running the pow()/hardLight/
//   screen/softLight math directly on linear-light values drifts the look
//   (darker, contrastier) vs Android.
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
//   • NaN guard: CIKL `pow()` of a negative base is undefined and renders as
//     black/garbage; both pow bases are floored with max(...,0), and a final
//     clamp keeps output in [0,1] for the encoder.
//   • Origin is NOT assumed (0,0): HaishinKit hands us a pre-scaled, transformed
//     CIImage, so everything is driven off `image.extent`, with finite/>=2px
//     guards, clamp-then-crop on the blur, and a final crop back to `extent`.
//   • No per-frame heap allocation: the kernel and the blur filter are built
//     once and only their inputs are reset per call.
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
/// All mutated state (`blur.inputImage` / `blur.radius`) is therefore confined
/// to that actor; there is no cross-thread mutation.
final class BeautyVideoEffect: VideoEffect, @unchecked Sendable {

  // MARK: - Tuning knobs

  /// Blur radius (in pixels) at the reference short side. Android's 25-tap green
  /// kernel reached ~20px on a ~720-wide working texture; a Gaussian of this
  /// radius gives a comparable low-pass footprint. Scaled by resolution below
  /// so the smoothing footprint (in face-relative terms) is constant across
  /// stream sizes. LOWER for a subtler effect or for low-end devices.
  ///
  /// Tune side-by-side against an Android device: 6.0 is a gentle start, 8.0
  /// matches the Android reach more closely, 10–12 is stronger smoothing.
  var baseBlurRadius: CGFloat = 7.0

  /// Overall strength, 0…1. 1.0 == the full Android look; lower values lerp the
  /// beauty result back toward the original (applied inside the kernel, so it's
  /// free). Use this as the primary "intensity" dial.
  var intensity: Float = 1.0 {
    didSet { intensity = max(0.0, min(1.0, intensity)) }
  }

  /// Thermal headroom scale (0…1), applied on top of `intensity` AND
  /// `baseBlurRadius`. This is the iOS analog of Android's highp→mediump beauty
  /// downgrade: Core Image has no shader-precision knob, so under sustained heat
  /// the publisher makes the effect LIGHTER and CHEAPER instead (a smaller
  /// Gaussian is real GPU savings — fewer separable taps). Like Android, the
  /// filter stays ON at every thermal level — the publisher drives this to ~0.5
  /// at `serious` and ~0.3 at `critical`, restoring 1.0 when the device cools
  /// (see `applyBeautyThermalScale`). A value at/below ~0 makes `execute()` skip
  /// the blur + kernel + color-space conversions entirely (full bypass) — kept
  /// as a defensive floor, not used as a normal thermal tier. Confined to
  /// ScreenActor like all other mutable state here — set only via
  /// `setThermalScale`.
  private var thermalScale: Float = 1.0

  /// Set the thermal headroom scale (0…1). MUST be called on HaishinKit's
  /// ScreenActor (the publisher hops via `Task { @ScreenActor in … }`) so it is
  /// serialized with `execute(_:)`, which is the only other accessor.
  func setThermalScale(_ scale: Float) {
    thermalScale = max(0.0, min(1.0, scale))
  }

  /// Reference short side the blur radius is calibrated for (Android's ~720).
  private let referenceMinDimension: CGFloat = 720

  /// Hard floor/ceiling on the resolved per-frame radius so tiny or huge streams
  /// stay sane and cheap.
  private let minBlurRadius: CGFloat = 2.0
  private let maxBlurRadius: CGFloat = 24.0

  // MARK: - Fixed objects (built once; reused every frame)

  /// Per-pixel color math. nil on compile failure → execute() passes frames
  /// through unchanged (beauty becomes a safe no-op).
  private let colorKernel: CIColorKernel?

  /// Apple's separable Gaussian. Reused across frames (cheaper than rebuilding a
  /// CIFilter every frame); only its inputs are reset per call.
  private let blur = CIFilter.gaussianBlur()

  /// sRGB color space we pin the kernel math to (gamma-encoded, to match the
  /// domain Android's GLSL runs in). Created once.
  private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

  init() {
    colorKernel = CIColorKernel(source: BeautyVideoEffect.source)
    if colorKernel == nil {
      NSLog("[BeautyVideoEffect] CIColorKernel failed to compile — beauty is a no-op")
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
  /// is ever registered — so it can't race `execute(_:)`, and uses its OWN
  /// throwaway blur/context (never touches `self.blur`).
  private func prewarm() {
    guard let colorKernel, let sRGB else { return }
    DispatchQueue.global(qos: .utility).async {
      let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
      let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
      let src = base.matchedFromWorkingSpace(to: sRGB) ?? base
      let warmBlur = CIFilter.gaussianBlur()
      warmBlur.inputImage = src.clampedToExtent()
      warmBlur.radius = 4
      guard let blurred = warmBlur.outputImage?.cropped(to: extent),
            let out = colorKernel.apply(
              extent: extent,
              arguments: [src.cropped(to: extent), blurred, Float(1.0)]
            ) else { return }
      let working = out.matchedToWorkingSpace(from: sRGB) ?? out
      _ = CIContext().createCGImage(working, from: extent)
    }
  }

  // MARK: - VideoEffect

  func execute(_ image: CIImage) -> CIImage {
    guard let colorKernel, let sRGB else { return image }

    // HaishinKit hands us `CIImage(cvPixelBuffer:, options:).transformed(by:)`,
    // so the origin is NOT guaranteed to be (0,0). Drive everything off
    // image.extent and never assume zero origin. Guard against the degenerate /
    // infinite extents Core Image can produce.
    let extent = image.extent
    guard !extent.isInfinite, !extent.isNull,
          extent.width.isFinite, extent.height.isFinite,
          extent.width >= 2, extent.height >= 2 else { return image }

    // Thermal throttle (set by the publisher's thermal observer). Near zero
    // (critical) → BYPASS: skip the blur + kernel + the two color-space
    // conversions — the bulk of our GPU cost — and pass the frame through
    // untouched for maximum thermal relief. Otherwise fold the scale into both
    // the intensity (look) and the blur radius (cost).
    let scale = thermalScale
    guard scale > 0.01 else { return image }
    let effectiveIntensity = intensity * scale

    // Pin the math to sRGB-gamma-encoded values. HaishinKit's working space is
    // linear-light ITU-R 709; the Android math expects gamma-encoded display
    // values. Convert the source into sRGB so the pow()/hardLight/blend math
    // lands on the same encoding Android uses. (No-op cost if already sRGB.)
    let srcSRGB = image.matchedFromWorkingSpace(to: sRGB) ?? image

    // Resolution-independent smoothing footprint: scale the Gaussian radius with
    // the frame's short side so 1080p doesn't smooth ~½ as hard as 720p. The
    // thermal scale shrinks the radius too — a smaller Gaussian is fewer
    // separable taps, i.e. real GPU savings under heat.
    let minDim = min(extent.width, extent.height)
    let radius = max(minBlurRadius,
                     min(maxBlurRadius, baseBlurRadius * CGFloat(scale) * (minDim / referenceMinDimension)))

    // Clamp so the Gaussian can read past the frame edge without pulling in
    // transparent pixels (which would darken the border). The Gaussian returns
    // an image larger than `extent`; crop it back so the blurred image shares
    // the ORIGINAL extent/coordinate space — this is what lets the color kernel
    // align the two __sample inputs pixel-for-pixel.
    blur.inputImage = srcSRGB.clampedToExtent()
    blur.radius = Float(radius)
    guard let blurredInfinite = blur.outputImage else { return image }
    let blurred = blurredInfinite.cropped(to: extent)

    // O(1) per pixel: reads only the destination pixel of `srcSRGB` and
    // `blurred`. Both share `extent`, so destCoord() aligns automatically.
    guard let kernelOut = colorKernel.apply(
      extent: extent,
      arguments: [srcSRGB.cropped(to: extent), blurred, effectiveIntensity]
    ) else {
      return image
    }

    // Convert the gamma-domain result BACK to the renderer's working space so
    // HaishinKit composites/encodes it correctly.
    let working = kernelOut.matchedToWorkingSpace(from: sRGB) ?? kernelOut

    // Re-assert the original extent. HaishinKit then renders via
    // `createCGImage(image, from: videoGravity.region(bounds, image: image.extent))`;
    // a stray infinite or shifted extent here would mis-crop the output.
    let result = working.cropped(to: extent)
    return result.extent.isInfinite ? image : result
  }

  // MARK: - Per-pixel kernel (CIColorKernel — NO sample()/dependent reads)
  //
  // Port of beauty_fragment.glsl's per-pixel tail, retuned for the BRIGHT / FAIR
  // look (matches Android's beauty_whitening_fragment.glsl 1:1). The 25-tap green
  // blur is now `blurred.g` (Apple's Gaussian); the color tail desaturates (kills
  // the red), drops the darkening lift, and adds a luma-gated lift toward white.
  // `strength` lerps the final result back toward the original (intensity dial),
  // applied here so it costs nothing.
  //
  // Look knobs (keep in sync with the Android .glsl): SMOOTH_GAMMA 0.85,
  // SOFTLIGHT 0.18, SATURATION 0.85, WHITEN 0.16 (gated 0.30..0.88), FINAL_LIFT 0.
  //
  // Safety baked in:
  //  • `pow()` of a negative base is undefined in CIKL (→ NaN → black/garbage):
  //    both bases are floored with max(...,0).
  //  • final clamp keeps output in [0,1] so the lift / saturation steps can't
  //    push channels out of range into the encoder.
  //  • alpha is passed through from the source rather than hard-coded to 1.0, so
  //    the effect is correct if ever fed RGBA.
  private static let source = """
  float hardLight(float color) {
      if (color <= 0.5) { return color * color * 2.0; }
      return 1.0 - ((1.0 - color) * (1.0 - color) * 2.0);
  }

  kernel vec4 beauty(__sample central, __sample blurred, float strength) {
      vec3 c = central.rgb;

      // High-pass on the green channel: central minus low-pass, biased to 0.5.
      float highPass = c.g - blurred.g + 0.5;
      highPass = hardLight(highPass);
      highPass = hardLight(highPass);
      highPass = hardLight(highPass);
      highPass = hardLight(highPass);
      highPass = hardLight(highPass);

      // Luminance-weighted strength: smooth/brighten brighter (skin) regions more.
      float luminance = dot(c, vec3(0.299, 0.587, 0.114));
      float alpha = pow(max(luminance, 0.0), 0.748);   // LUMA_EXP

      vec3 smoothColor = c + (c - vec3(highPass)) * alpha * 0.1;
      // max(0) before pow: negative base → NaN in CIKL.
      // SMOOTH_GAMMA (stock 0.874; lower = brighter).
      smoothColor = clamp(pow(max(smoothColor, 0.0), vec3(0.85)), 0.0, 1.0);

      vec3 screen   = vec3(1.0) - (vec3(1.0) - smoothColor) * (vec3(1.0) - c);
      vec3 lighten  = max(smoothColor, c);
      vec3 softLight = 2.0 * c * smoothColor + c * c - 2.0 * c * c * smoothColor;

      vec3 result = mix(c, screen, alpha);
      result = mix(result, lighten, alpha);
      result = mix(result, softLight, 0.18);   // SOFTLIGHT (stock 0.241)

      // De-redden: blend TOWARD luminance (<1 desaturates). The stock shader did
      // the OPPOSITE here — a saturateMatrix that AMPLIFIED skin's orange/red.
      float lum2 = dot(result, vec3(0.299, 0.587, 0.114));
      result = mix(vec3(lum2), result, 0.85);   // SATURATION

      // Fair glow: a luminance-gated lift toward white — brightens AND further
      // de-reds the lit face, while the smoothstep gate leaves dark hair / brows
      // / background untouched.
      float whiteMask = smoothstep(0.30, 0.88, lum2);   // WHITEN_LO, WHITEN_HI
      result = mix(result, vec3(1.0), 0.16 * whiteMask);   // WHITEN

      // Overall brightness. The stock shader SUBTRACTED 0.096 here (a DARKEN that
      // also crushed the blue channel → more red); FINAL_LIFT defaults to 0.0.

      // Overall intensity: lerp the full-beauty result back toward the original.
      result = mix(c, result, clamp(strength, 0.0, 1.0));

      // Keep output in gamut for the encoder.
      result = clamp(result, 0.0, 1.0);

      return vec4(result, central.a);
  }
  """
}
