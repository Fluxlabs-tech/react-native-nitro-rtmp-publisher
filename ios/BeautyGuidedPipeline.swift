//
//  BeautyGuidedPipeline.swift
//  NitroRtmpPublisher
//
//  Fast guided filter with three-band reconstruction — the iOS port of Android's
//  five-pass GLES pipeline (`BeautyFilterRender` + beauty_*.glsl). Produces the
//  FULL-STRENGTH beauty image; `BeautyVideoEffect` owns the look grade and the
//  intensity lerp that sit after it.
//
//  ── Why a guided filter at all ──────────────────────────────────────────────
//   Fit q = a*y + b to each local window. Flat region -> variance small -> a→0 ->
//   output is the local mean (heavy smoothing). Edge -> variance large -> a→1 ->
//   output is the input (no smoothing). So eyelashes and brow hairs survive
//   untouched while the pores beside them flatten. `eps` scales with the local
//   mean, making the threshold a RELATIVE contrast — without that, one setting
//   means a different perceived strength on deep and light skin.
//
//   It replaces a frequency-separation kernel whose smoothing and its brightening
//   were coupled by construction: measured on synthetic skin at full strength,
//   that kernel kept 65% of pore detail on light skin, 85% on mid, and 105% on
//   deep (i.e. AMPLIFIED it), while pushing red +31/255. Android's composite keeps
//   ~30% on skin, tone-independently, and carries colour as a luma ratio so hue
//   never shifts. This file is that behaviour.
//
//  ── Shape of the graph, and why it is this shape ────────────────────────────
//   The header of `BeautyVideoEffect` records that a general `CIKernel` doing 25
//   dependent sample() reads at 720x1280@30 destabilised the device. So NONE of
//   our kernels sample a neighbour: every one is a `CIColorKernel` reading only
//   its destination pixel, and every box filter is Apple's separable, GPU-optimised
//   `CIBoxBlur`. The guided filter is what makes that possible — its coefficients
//   only need to be SMOOTH, so they are computed at 1/16 the pixel count.
//
//   COST, honestly: Android's shader comments claim the guided pipeline is cheaper
//   than the single-pass kernel it replaced there. Do NOT inherit that claim here
//   — it has not been established on iOS. CI_PRINT_TREE on a 720x1280 device frame
//   shows the quarter-res chain costing about half of one full-resolution pass
//   (as designed, negligible), but the FULL-resolution pass count went UP versus
//   frequency separation: two separable 5-tap box blurs plus the deviation,
//   composite, cube and finalize kernels, against one Gaussian plus one kernel
//   before. Roughly 2x the full-res passes. Whether that matters is a
//   Metal-System-Trace question, not an arithmetic one; measure before quoting a
//   number either way.
//
//     quarter res:  scale ↓4 ─ boxBlur(4) ─ mean RGB ─┬───────────────────────┐
//                        └─ deviation(↓4, mean) ─ boxBlur(4) ─ var ─ coeff ─ boxBlur(4) ─ (a,b)
//     full res:     boxBlur(2) ─ mean RGB ─┬─ deviation(src, mean) ─ boxBlur(2) ─ var
//                   composite(src, narrowMean, narrowVar, (a,b)↑, wideMean↑)
//
//   `insertingIntermediate` at every scale boundary is LOAD-BEARING, not an
//   optimisation: without it Core Image fuses the graph and can evaluate the
//   quarter-res chain once per full-resolution output pixel, or propagate the ROI
//   so those passes run at full size. That is the difference between this being
//   cheaper than what it replaces and being ~16x more expensive.
//
//  ── Precision (the part that silently breaks) ───────────────────────────────
//   HaishinKit's SDR CIContext uses workingFormat RGBAh — HALF float. Android hit
//   the same class of problem at 8 bits: mean(y) and mean(y^2) are both ~0.44 on
//   skin and the variance is their ~6e-5 difference, an order of magnitude below
//   the quantisation step, so `var` comes out random and often negative.
//
//   Android solves it by never forming that difference: its narrow band sums
//   (tap - centre) and (tap - centre)^2 directly, so every quantity stays small.
//   A box blur cannot reference the centre sample, so the first version here
//   computed E[u^2] - (E[y]-0.5)^2 with u = y - 0.5, on the theory that centring
//   kept the terms small enough. MEASURED: it does not. At light-skin luma 0.625
//   fp16's step in E[y] is ~3e-4, which propagates to 2*0.125*3e-4 = 7.5e-5 of
//   error in the squared term — LARGER than the 4.8e-5 variance being measured.
//   The pipeline amplified pore noise to ~120% instead of cutting it to ~30%.
//
//   So the variance is computed in TWO passes instead, at both scales:
//     1. box blur the source            -> local mean
//     2. an O(1) kernel reads the pixel AND that mean -> (y - mean)^2
//     3. box blur that                  -> variance
//   Nothing is ever subtracted from anything of comparable size: (y-mean)^2 is
//   ~1.4e-4 for 3/255 grain, where fp16 resolves ~7e-8. It costs one extra box
//   blur per scale and is strictly more accurate than the form it replaces.
//
//   Do not "simplify" this back into E[y^2] - E[y]^2 or the centred variant. It
//   looks like one pass fewer and it silently stops working.
//
//  ── Constants ───────────────────────────────────────────────────────────────
//   Every constant below is copied from the Android shaders and must stay in sync
//   with them. They are load-bearing and were derived from measurement, not taste
//   — see the comments in beauty_coeff_fragment.glsl and
//   beauty_composite_fragment.glsl for what each one was measured against.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Not Sendable and not thread-safe: the filters it owns are mutated per frame.
/// Only ever touched from HaishinKit's ScreenActor, via `BeautyVideoEffect`.
final class BeautyGuidedPipeline {

  // MARK: - Geometry

  /// Reduced-resolution factor for the statistics passes. Android's DOWNSCALE.
  private let downscale: CGFloat = 4

  // ── CIBoxBlur radius is NOT the box half-width ──────────────────────────
  // MEASURED against a hard step: CIBoxBlur's effective tap count is
  // 2*floor((radius-1)/2)+1. So radius 1 and 2 are literal NO-OPS, radius 3 and
  // 4 both give a 3-tap box, and radius 8 gives 7 taps. Passing the half-width
  // you want produces a filter that silently does nothing or a quarter of the
  // intended work — the first version of this file used 2 and 4, which made the
  // narrow variance exactly zero and the wide window 3x3 instead of 9x9. The
  // whole guided filter then degenerated into a noise amplifier.
  //
  // To get half-width h, pass radius = 2h+1. `scripts/verify-beauty-blur.sh`
  // asserts these footprints so an OS change surfaces as a failing check rather
  // than a filter that quietly stops filtering.

  /// Wide window: half-width 4 at quarter resolution, i.e. Android's WIDE_RADIUS
  /// of 4 reduced-resolution pixels — a 33x33 footprint at full resolution.
  private let wideRadius: Float = 9

  /// Narrow window: half-width 2 at full resolution. Android takes 3x3 taps at
  /// stride 2, which spans the same 5x5 extent.
  private let narrowRadius: Float = 5

  // MARK: - Kernels (built once)

  private let deviation: CIColorKernel
  private let coeff: CIColorKernel
  private let composite: CIColorKernel

  // MARK: - Reusable filters

  private let narrowMeanBlur = CIFilter.boxBlur()
  private let narrowVarBlur = CIFilter.boxBlur()
  private let wideMeanBlur = CIFilter.boxBlur()
  private let wideVarBlur = CIFilter.boxBlur()
  private let coeffBlur = CIFilter.boxBlur()

  /// nil if any kernel fails to compile, so the caller can fall back rather than
  /// render garbage.
  init?() {
    guard let a = CIColorKernel(source: BeautyGuidedPipeline.deviationSource),
          let b = CIColorKernel(source: BeautyGuidedPipeline.coeffSource),
          let c = CIColorKernel(source: BeautyGuidedPipeline.compositeSource)
    else {
      NSLog("[BeautyGuidedPipeline] kernel compile failed — guided beauty unavailable")
      return nil
    }
    deviation = a
    coeff = b
    composite = c
  }

  // MARK: - Render

  /// `source` must already carry sRGB-gamma-encoded values (the domain the Android
  /// GLSL runs in) and sit at the origin; `extent` is its extent. Returns the
  /// full-strength beauty image in the same space, or nil on any failure.
  func render(source: CIImage, extent: CGRect) -> CIImage? {
    // ── Quarter-resolution analysis ─────────────────────────────────────────
    // A plain affine downscale samples rather than area-averages, so it aliases;
    // the radius-4 box that follows averages that away, and Android's GL_LINEAR
    // taps alias in exactly the same manner. Materialised immediately so the
    // whole quarter-res chain below is computed ONCE at quarter size.
    let inverse = 1.0 / downscale
    let small = source
      .transformed(by: CGAffineTransform(scaleX: inverse, y: inverse))
      .insertingIntermediate(cache: true)
    let smallExtent = CGRect(
      x: 0, y: 0,
      width: (extent.width * inverse).rounded(.down),
      height: (extent.height * inverse).rounded(.down)
    )
    guard smallExtent.width >= 2, smallExtent.height >= 2 else { return nil }
    let smallCropped = small.cropped(to: smallExtent)

    // Window-mean colour. Feeds BOTH the guided model (mean luma is
    // dot(mean, W) — exact, because luma is linear in RGB) and the skin test,
    // which Android deliberately runs on the window AVERAGE: brows, lashes and
    // lips are dark and achromatic per pixel, so a per-pixel test calls them
    // background, hands them the background's clarity gain and rings their
    // inner edge.
    guard let wideMean = boxed(
      wideMeanBlur, smallCropped, radius: wideRadius, extent: smallExtent
    ) else { return nil }

    // Two-pass variance — see the precision note in the header. Not one pass.
    guard let wideDev = deviation.apply(
      extent: smallExtent, arguments: [smallCropped, wideMean]
    ),
      let wideVar = boxed(wideVarBlur, wideDev, radius: wideRadius, extent: smallExtent)
    else { return nil }

    guard let rawCoeff = coeff.apply(
      extent: smallExtent, arguments: [wideMean, wideVar]
    ),
      // Android box-filters the coefficients over a second wide window; a guided
      // filter's a and b are only valid as smooth fields.
      let smoothCoeff = boxed(
        coeffBlur, rawCoeff, radius: wideRadius, extent: smallExtent
      )
    else { return nil }

    // ── Back up to full resolution ──────────────────────────────────────────
    // Bilinear upsample of deliberately smooth fields — this is the "fast" in
    // fast guided filter. Materialised before the upscale so the quarter-res
    // work cannot be pulled into the full-resolution pass.
    let upscale = CGAffineTransform(scaleX: downscale, y: downscale)
    let coeffUp = smoothCoeff
      .insertingIntermediate(cache: true)
      .transformed(by: upscale)
      .cropped(to: extent)
    let wideMeanUp = wideMean
      .insertingIntermediate(cache: true)
      .transformed(by: upscale)
      .cropped(to: extent)

    // ── Full-resolution narrow band ─────────────────────────────────────────
    // Mean luma comes from the mean-RGB blur by dot(), so no packing kernel is
    // needed; the variance then takes the same two-pass route as the wide band.
    let sourceCropped = source.cropped(to: extent)
    guard let narrowMean = boxed(
      narrowMeanBlur, sourceCropped, radius: narrowRadius, extent: extent
    ),
      let narrowDev = deviation.apply(
        extent: extent, arguments: [sourceCropped, narrowMean]
      ),
      let narrowVar = boxed(
        narrowVarBlur, narrowDev, radius: narrowRadius, extent: extent
      )
    else { return nil }

    return composite.apply(
      extent: extent,
      arguments: [sourceCropped, narrowMean, narrowVar, coeffUp, wideMeanUp]
    )
  }

  /// Clamp-then-crop around a box blur: without the clamp the box reads
  /// transparent pixels past the frame edge and darkens the border, and the blur
  /// returns an image LARGER than `extent`, which has to be cropped back so every
  /// image in the graph shares one coordinate space — that is what lets the
  /// colour kernels align their `__sample` inputs with no manual sampling.
  private func boxed(
    _ filter: CIFilter & CIBoxBlur, _ image: CIImage, radius: Float, extent: CGRect
  ) -> CIImage? {
    filter.inputImage = image.clampedToExtent()
    filter.radius = radius
    return filter.outputImage?.cropped(to: extent)
  }
}

// MARK: - Kernels

extension BeautyGuidedPipeline {

  /// Squared deviation of this pixel's luma from the window mean, used at BOTH
  /// scales. Step 2 of the two-pass variance: it reads the pixel and the
  /// already-blurred mean at the SAME coordinate, so it stays O(1) — no
  /// neighbour sampling — while giving the numerically safe form. See the
  /// precision note in the file header for why the one-pass moment form does not
  /// work in fp16.
  fileprivate static let deviationSource = """
  kernel vec4 deviation(__sample s, __sample mean) {
      vec3 W = vec3(0.299, 0.587, 0.114);
      float d = dot(s.rgb, W) - dot(mean.rgb, W);
      return vec4(d * d, 0.0, 0.0, 1.0);
  }
  """

  /// Guided coefficients from the wide window. Android's beauty_coeff_fragment.
  fileprivate static let coeffSource = """
  kernel vec4 coeff(__sample meanRGB, __sample varianceIn) {
      float m1 = dot(meanRGB.rgb, vec3(0.299, 0.587, 0.114));
      float var = max(varianceIn.r, 0.0);
      // EPS_WIDE 0.060, EPS_FLOOR 0.04. eps scales with the local mean so the
      // threshold is a RELATIVE contrast — an absolute one means a different
      // perceived strength on deep and light skin.
      float a = var / (var + 0.060 * (m1 * m1 + 0.04));
      float b = (1.0 - a) * m1;
      return vec4(a, b, 0.0, 1.0);
  }
  """

  /// Full-resolution three-band reconstruction. Android's
  /// beauty_composite_fragment, minus the LUT and the intensity lerp — those live
  /// in `BeautyVideoEffect` so the cube can be a built-in CIColorCube.
  fileprivate static let compositeSource = """
  // Skin locus in NORMALISED chromaticity r = R/(R+G+B), g = G/(R+G+B).
  //
  // Not YCbCr. Cb and Cr are absolute chroma differences, so they shrink as luma
  // falls: across a 2.8x exposure range they move 2-3x, while these coordinates
  // are identical to three decimals. With a Cb/Cr skin box a deep skin tone
  // scored 0.63 mask coverage against 1.00 for a light tone — the filter quietly
  // did less for darker-skinned sellers, and less again in a dim room.
  //
  // Skin across tones is a LINE here, not a point: deeper skin sits at higher r
  // and lower g. So the test is distance from that segment.
  float skinRegion(vec3 c) {
      float s = max(c.r + c.g + c.b, 1e-4);
      vec2 p = vec2(c.r / s, c.g / s) - vec2(0.405, 0.323);      // LOCUS_O
      float perp = abs(dot(p, vec2(0.361, 0.933)));              // LOCUS_N
      float along = dot(p, vec2(0.933, -0.361)) / 0.0804;        // LOCUS_U, LEN
      float lum = dot(c, vec3(0.299, 0.587, 0.114));

      float m = 1.0 - smoothstep(0.008, 0.016, perp);            // MASK_LO/HI
      m = m * (1.0 - smoothstep(1.6, 2.4, abs(along - 0.5)));    // tone range
      // Only for crushed blacks, where chromaticity is noise. Hair and brows are
      // achromatic and the locus test already rejects them, so this stays low —
      // any higher and deep skin, at luma ~0.22, falls out of the mask.
      m = m * smoothstep(0.03, 0.09, lum);
      m = m * (1.0 - smoothstep(0.94, 0.995, lum));              // blown highlights
      return m;
  }

  kernel vec4 composite(__sample src, __sample narrowMean, __sample narrowVar,
                        __sample co, __sample wide) {
      vec3 rgb = src.rgb;
      float y = dot(rgb, vec3(0.299, 0.587, 0.114));

      // Narrow band. Mean luma is dot(meanRGB, W) — exact, luma is linear — and
      // the variance arrives already computed by the two-pass route, so nothing
      // here subtracts two similar numbers. See the header precision note.
      float mean = dot(narrowMean.rgb, vec3(0.299, 0.587, 0.114));
      float varN = max(narrowVar.r, 0.0);
      float scale = mean * mean + 0.04;                          // EPS_FLOOR

      // Two thresholds on the same variance. `keep` marks anything with real
      // structure, so smoothing rides (1 - keep) and lashes come through at full
      // strength. `hard` opens only on genuinely high-contrast edges — print, a
      // product outline, a garment fold — so off-skin clarity cannot turn fabric
      // weave or sensor grain into an artificial pattern. Weave sits near var
      // 2e-4 and print near 6e-2, two orders apart.
      float keep = varN / (varN + 0.006 * scale);                // EPS_NARROW
      float hard = varN / (varN + 0.020 * scale);                // EPS_HARD
      float baseN = keep * y + (1.0 - keep) * mean;

      float baseW = co.r * y + co.g;
      float region = skinRegion(wide.rgb);

      float med = baseN - baseW;   // 5-33px: contour, folds, product outlines
      float fine = y - baseN;      // under 5px: pores, blemishes, grain, lashes

      // The fine band means opposite things on and off skin, so it gets opposite
      // treatment: on skin it is blemish (cut it), off skin it is product detail
      // (leave it). Perceived sharpness on skin comes from `med` instead, because
      // that band holds contour rather than blemish — measured, a hard edge puts
      // 1.5% in fine and 4.5% in med, so boosting fine cannot sharpen an edge.
      //
      // Sensor noise raises `keep`, so using it here would disable smoothing on
      // the frames that need it most; `hard` opens later and keeps only real edges.
      float skinFine = mix(0.30, 1.0, hard);                     // SKIN_FINE
      float kf = mix(1.0, skinFine, region);
      float kmBg = 1.0 + (1.50 - 1.0) * hard;                    // BG_MED
      float km = kmBg + (1.20 - kmBg) * region;                  // SKIN_MED
      // In low light a band boost boosts sensor noise and nothing else.
      km = 1.0 + (km - 1.0) * smoothstep(0.06, 0.25, baseW);

      float outY = baseW + med * km + fine * kf;

      // Midtone lift, zero at both ends so it cannot push anything into clipping.
      float t = clamp(outY, 0.0, 1.0);
      outY = outY + 0.05 * region * 4.0 * t * (1.0 - t);         // SKIN_LIFT

      // Soft shoulder rather than a hard clamp, so highlights roll off instead of
      // flattening to a single value.
      outY = max(outY, 0.0);
      float hi = 1.0 - 0.88;                                     // SHOULDER
      if (outY > 0.88) {
          outY = 0.88 + hi * (1.0 - exp(-(outY - 0.88) / hi));
      }

      // Colour is carried as a LUMA RATIO, so hue and saturation survive the
      // smoothing untouched. The kernel this replaces ran screen / lighten /
      // soft-light blends per channel, which shifted colour toward red and then
      // needed a saturation boost to partly undo itself.
      vec3 color = rgb * clamp(outY / max(y, 0.03), 0.0, 3.0);

      // Boost toward SATURATION 1.70, but never past the pixel's headroom. A flat
      // mix above 1.0 shoves channels out of range and the final clamp then
      // flattens every vivid tone to the same value; this backs off per pixel.
      float lum = dot(color, vec3(0.299, 0.587, 0.114));
      vec3 dev = color - vec3(lum);
      vec3 room = mix(vec3(lum), vec3(1.0 - lum), step(0.0, dev));
      vec3 lim = room / max(abs(dev), 1e-4);
      float headroom = max(1.0, min(min(lim.r, lim.g), lim.b));
      color = vec3(lum) + dev * min(1.70, headroom);

      return vec4(clamp(color, 0.0, 1.0), src.a);
  }
  """
}
