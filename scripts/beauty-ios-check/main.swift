// Host verification for the iOS beauty pipeline. Compiled against the REAL
// sources (`BeautyGuidedPipeline`, `BeautyLookCube`, `BeautyLookAtlas`) so it
// cannot drift from what ships. Driven by scripts/verify-beauty-ios.sh, which
// documents why each check exists.
//
// `--dump-cube` prints every cube entry for diffing against
// `node scripts/beauty-lut.mjs --emit-cube`; everything else runs the checks.
import CoreImage
import Foundation

let repo = CommandLine.arguments.count > 1 && !CommandLine.arguments[1].hasPrefix("--")
  ? CommandLine.arguments[1] : "."
var failures = 0

let n = BeautyLookCube.dimension
guard let payloads = BeautyLookCube.decodeAll(), payloads.count == 2 else {
  print("FAIL: BeautyLookCube.decodeAll()"); exit(1)
}

// ── --dump-cube ─────────────────────────────────────────────────────────────
// Proves the embedded base64 payload round-trips to the same bytes Android
// samples. It CANNOT catch a transposed axis — the dump and the reference share
// an ordering — which is why check 2 exists separately.
if CommandLine.arguments.contains("--dump-cube") {
  var out = ""
  for (slot, payload) in payloads.enumerated() {
    let floats = payload.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    for i in 0..<(n * n * n) {
      guard floats[i * 4 + 3] == 1.0 else {
        FileHandle.standardError.write(
          "slot \(slot) entry \(i) alpha \(floats[i * 4 + 3])\n".data(using: .utf8)!)
        exit(1)
      }
      out += "\(slot) \(i)"
        + " \(Int((floats[i * 4] * 255).rounded()))"
        + " \(Int((floats[i * 4 + 1] * 255).rounded()))"
        + " \(Int((floats[i * 4 + 2] * 255).rounded()))\n"
    }
  }
  print(out, terminator: "")
  exit(0)
}

guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
      let linear = CGColorSpace(name: CGColorSpace.linearSRGB) else { exit(1) }

// Half-float working format, matching HaishinKit's SDR context, so fp16
// behaviour here is the device's. The working COLOUR SPACE varies on device
// (ExtendedLinearSRGB for the preview MTHKView, ITUR_709 for the encode path);
// linearSRGB stands in for a linear one, and the effect's
// matchedFrom/ToWorkingSpace calls make the pipeline independent of which it is.
let ctx = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAh])
// Raw value passthrough, for reading data-carrying intermediates exactly.
let raw = CIContext(options: [.workingColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])

// ── 1. CIBoxBlur footprint ─────────────────────────────────────────────────
print("1. CIBoxBlur footprint (radius -> effective tap count)")
func tapCount(radius: Float) -> Int {
  let side = 64
  let e = CGRect(x: 0, y: 0, width: side, height: side)
  var px = [UInt8](repeating: 255, count: side * side * 4)
  for y in 0..<side {
    for x in 0..<side {
      let v: UInt8 = x < side / 2 ? 0 : 255
      for k in 0..<3 { px[(y * side + x) * 4 + k] = v }
    }
  }
  let img = CIImage(bitmapData: Data(px), bytesPerRow: side * 4,
                    size: CGSize(width: side, height: side),
                    format: .RGBA8, colorSpace: sRGB)
  let f = CIFilter(name: "CIBoxBlur")!
  f.setValue(img.clampedToExtent(), forKey: kCIInputImageKey)
  f.setValue(radius, forKey: "inputRadius")
  var out = [Float](repeating: 0, count: side * 4)
  raw.render((f.outputImage ?? img).cropped(to: e), toBitmap: &out, rowBytes: side * 16,
             bounds: CGRect(x: 0, y: side / 2, width: side, height: 1),
             format: .RGBAf, colorSpace: nil)
  var transition = 0
  for i in 0..<side where out[i * 4] > 0.001 && out[i * 4] < 0.999 { transition += 1 }
  return transition + 1
}
for (radius, want) in [(Float(5), 5), (Float(9), 9)] {
  let got = tapCount(radius: radius)
  if got != want { failures += 1 }
  print("   radius \(Int(radius)) -> \(got) taps (want \(want)) "
    + (got == want ? "ok" : "<-- CHANGED: update BeautyGuidedPipeline's radii"))
}

// ── 2. CIColorCube axis order, through the real execute() chain ────────────
print("\n2. CIColorCube axis order (primaries are decisive)")
func cubeEntry(_ payload: Data, _ r: Int, _ g: Int, _ b: Int) -> (Int, Int, Int) {
  let f = payload.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  let i = ((b * n + g) * n + r) * 4
  return (Int((f[i] * 255).rounded()), Int((f[i + 1] * 255).rounded()),
          Int((f[i + 2] * 255).rounded()))
}
func graded(_ filter: CIFilter, _ r: Int, _ g: Int, _ b: Int) -> (Int, Int, Int)? {
  let v = { (k: Int) in CGFloat(k) / CGFloat(n - 1) }
  guard let color = CIColor(red: v(r), green: v(g), blue: v(b), alpha: 1,
                            colorSpace: sRGB) else { return nil }
  let e = CGRect(x: 0, y: 0, width: 8, height: 8)
  let base = CIImage(color: color).cropped(to: e)
  // Exactly BeautyVideoEffect.execute's graded tail.
  let src = base.matchedFromWorkingSpace(to: sRGB) ?? base
  filter.setValue(src, forKey: kCIInputImageKey)
  guard let out = filter.outputImage?.cropped(to: e) else { return nil }
  let back = out.matchedToWorkingSpace(from: sRGB) ?? out
  var px = [UInt8](repeating: 0, count: 4 * 64)
  ctx.render(back, toBitmap: &px, rowBytes: 8 * 4, bounds: e,
             format: .RGBA8, colorSpace: sRGB)
  return (Int(px[0]), Int(px[1]), Int(px[2]))
}
let probes: [(String, Int, Int, Int)] = [
  ("pure red", n - 1, 0, 0), ("pure green", 0, n - 1, 0), ("pure blue", 0, 0, n - 1),
  ("black", 0, 0, 0), ("white", n - 1, n - 1, n - 1), ("neutral mid", 16, 16, 16),
  ("warm skin", 24, 18, 15), ("deep skin", 14, 10, 8), ("asymmetric", 28, 4, 20),
]
for (slot, look) in [(0, "bright"), (1, "cool")] {
  guard let filter = BeautyLookCube.makeFilter(payloads[slot]) else {
    print("   FAIL: makeFilter slot \(slot)"); failures += 1; continue
  }
  var worstProbe = 0
  for (_, r, g, b) in probes {
    let want = cubeEntry(payloads[slot], r, g, b)
    guard let got = graded(filter, r, g, b) else { failures += 1; continue }
    worstProbe = max(worstProbe,
                     max(abs(want.0 - got.0), max(abs(want.1 - got.1), abs(want.2 - got.2))))
  }
  // 1 LSB of slack for the fp16 working format and the 8-bit readback.
  if worstProbe > 1 { failures += 1 }
  print("   \(look): \(probes.count) probes, worst delta \(worstProbe)/255 "
    + (worstProbe <= 1 ? "ok" : "<-- MISMATCH (axis order or colour management)"))
}

// ── 3. Composite fidelity vs Android's shader, transcribed on the CPU ──────
print("\n3. Composite kernel vs CPU transcription of beauty_composite_fragment.glsl")
let file = try String(contentsOfFile: "\(repo)/ios/BeautyGuidedPipeline.swift",
                      encoding: .utf8)
guard let s0 = file.range(of: "  // Skin locus in NORMALISED"),
      let s1 = file.range(of: "\n  \"\"\"", range: s0.upperBound..<file.endIndex),
      let composite = CIColorKernel(source: String(file[s0.lowerBound..<s1.lowerBound]))
else { print("   FAIL: could not parse/compile the composite kernel"); exit(1) }

let E = CGRect(x: 0, y: 0, width: 4, height: 4)
func solid(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
  CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: sRGB)!)
    .cropped(to: E)
}
func W(_ c: (Double, Double, Double)) -> Double { 0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2 }
func ss(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
  let t = max(0, min(1, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
}
func cpu(_ src: (Double, Double, Double), _ nMean: (Double, Double, Double),
         _ varN: Double, _ co: (Double, Double), _ wide: (Double, Double, Double))
  -> (Double, Double, Double) {
  let y = W(src), mean = W(nMean)
  let scale = mean * mean + 0.04
  let keep = varN / (varN + 0.006 * scale)
  let hard = varN / (varN + 0.020 * scale)
  let baseN = keep * y + (1 - keep) * mean
  let baseW = co.0 * y + co.1
  let s = max(wide.0 + wide.1 + wide.2, 1e-4)
  let p = (wide.0 / s - 0.405, wide.1 / s - 0.323)
  var region = 1 - ss(0.008, 0.016, abs(p.0 * 0.361 + p.1 * 0.933))
  region *= 1 - ss(1.6, 2.4, abs((p.0 * 0.933 + p.1 * -0.361) / 0.0804 - 0.5))
  region *= ss(0.03, 0.09, W(wide))
  region *= 1 - ss(0.94, 0.995, W(wide))
  let med = baseN - baseW, fine = y - baseN
  let kf = 1.0 + ((0.30 + 0.70 * hard) - 1.0) * region
  let kmBg = 1.0 + 0.50 * hard
  var km = kmBg + (1.20 - kmBg) * region
  km = 1.0 + (km - 1.0) * ss(0.06, 0.25, baseW)
  var outY = baseW + med * km + fine * kf
  let t = max(0, min(1, outY))
  outY += 0.05 * region * 4.0 * t * (1 - t)
  outY = max(outY, 0)
  if outY > 0.88 { outY = 0.88 + 0.12 * (1 - exp(-(outY - 0.88) / 0.12)) }
  let ratio = max(0, min(3, outY / max(y, 0.03)))
  var c = (src.0 * ratio, src.1 * ratio, src.2 * ratio)
  let lum = W(c)
  let dev = (c.0 - lum, c.1 - lum, c.2 - lum)
  func room(_ d: Double) -> Double { d >= 0 ? 1 - lum : lum }
  let head = max(1.0, min(room(dev.0) / max(abs(dev.0), 1e-4),
                          min(room(dev.1) / max(abs(dev.1), 1e-4),
                              room(dev.2) / max(abs(dev.2), 1e-4))))
  let sat = min(1.70, head)
  c = (lum + dev.0 * sat, lum + dev.1 * sat, lum + dev.2 * sat)
  return (max(0, min(1, c.0)), max(0, min(1, c.1)), max(0, min(1, c.2)))
}
// (src, narrowMeanRGB, narrowVar, coeff=(a,b), wideMeanRGB)
let cases: [(String, (Double, Double, Double), (Double, Double, Double), Double,
             (Double, Double), (Double, Double, Double))] = [
  ("light skin, flat", (0.77, 0.58, 0.48), (0.770, 0.580, 0.480), 4.8e-5, (0.05, 0.594), (0.77, 0.58, 0.48)),
  ("light skin, edge", (0.77, 0.58, 0.48), (0.600, 0.450, 0.370), 6.0e-2, (0.90, 0.050), (0.77, 0.58, 0.48)),
  ("mid skin, flat", (0.60, 0.44, 0.36), (0.600, 0.440, 0.360), 1.2e-5, (0.04, 0.451), (0.60, 0.44, 0.36)),
  ("deep skin, flat", (0.35, 0.25, 0.20), (0.350, 0.250, 0.200), 5.0e-5, (0.03, 0.264), (0.35, 0.25, 0.20)),
  ("off-skin (blue)", (0.20, 0.35, 0.75), (0.200, 0.350, 0.750), 1.5e-3, (0.30, 0.266), (0.20, 0.35, 0.75)),
  ("blown highlight", (0.98, 0.97, 0.96), (0.980, 0.970, 0.960), 2.0e-4, (0.10, 0.873), (0.98, 0.97, 0.96)),
  ("dark hair", (0.08, 0.07, 0.07), (0.080, 0.070, 0.070), 8.0e-3, (0.60, 0.029), (0.08, 0.07, 0.07)),
]
var worst = 0.0
for (name, src, nMean, varN, co, wide) in cases {
  guard let out = composite.apply(extent: E, arguments: [
    solid(src.0, src.1, src.2), solid(nMean.0, nMean.1, nMean.2),
    solid(varN, 0, 0), solid(co.0, co.1, 0), solid(wide.0, wide.1, wide.2),
  ]) else { print("   \(name): apply failed"); failures += 1; continue }
  var px = [Float](repeating: 0, count: 4)
  raw.render(out, toBitmap: &px, rowBytes: 16,
             bounds: CGRect(x: 1, y: 1, width: 1, height: 1),
             format: .RGBAf, colorSpace: nil)
  let c = cpu(src, nMean, varN, co, wide)
  let d = max(abs(Double(px[0]) - c.0),
              max(abs(Double(px[1]) - c.1), abs(Double(px[2]) - c.2)))
  worst = max(worst, d)
  if d >= 2e-3 { failures += 1; print("   \(name): MISMATCH \(d)") }
}
print(String(format: "   %d cases, worst deviation %.6f  %@", cases.count, worst,
             worst < 2e-3 ? "ok" : "<-- FAIL"))

// ── 4. End-to-end behaviour on realistic grain ────────────────────────────
print("\n4. Pipeline on uncorrelated grain (~3/255): suppression + hue")
guard let pipeline = BeautyGuidedPipeline() else {
  print("   FAIL: pipeline kernels did not compile"); exit(1)
}
let N = 256, NE = CGRect(x: 0, y: 0, width: 256, height: 256)
var seed: UInt64 = 0x2545F4914F6CDD1D
func rnd() -> Double {
  seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
  return Double(seed % 10_000) / 10_000.0 - 0.5
}
func hf(_ px: [UInt8]) -> Double {
  var acc = 0.0, count = 0.0
  for y in 8..<(N - 8) {
    for x in 8..<(N - 8) {
      var m = 0.0
      for j in -1...1 { for i in -1...1 { m += Double(px[((y + j) * N + x + i) * 4 + 1]) } }
      let d = Double(px[(y * N + x) * 4 + 1]) - m / 9.0
      acc += d * d; count += 1
    }
  }
  return (acc / count).squareRoot()
}
func avg(_ px: [UInt8]) -> (Double, Double, Double) {
  var r = 0.0, g = 0.0, b = 0.0, count = 0.0
  for y in 8..<(N - 8) {
    for x in 8..<(N - 8) {
      r += Double(px[(y * N + x) * 4]); g += Double(px[(y * N + x) * 4 + 1])
      b += Double(px[(y * N + x) * 4 + 2]); count += 1
    }
  }
  return (r / count, g / count, b / count)
}
print("   tone         grain kept    dR    dG    dB")
for (name, base) in [("light skin", (0.77, 0.58, 0.48)),
                     ("mid skin  ", (0.60, 0.44, 0.36)),
                     ("deep skin ", (0.35, 0.25, 0.20))] {
  seed = 0x2545F4914F6CDD1D
  var px = [UInt8](repeating: 255, count: N * N * 4)
  for i in 0..<(N * N) {
    let d = rnd() * 0.024
    let c = [base.0 + d, base.1 + d, base.2 + d]
    for k in 0..<3 { px[i * 4 + k] = UInt8(max(0, min(255, (c[k] * 255).rounded()))) }
  }
  let img = CIImage(bitmapData: Data(px), bytesPerRow: N * 4,
                    size: CGSize(width: 256, height: 256),
                    format: .RGBA8, colorSpace: sRGB)
  let s = (img.matchedFromWorkingSpace(to: sRGB) ?? img).cropped(to: NE)
  guard let out = pipeline.render(source: s, extent: NE) else {
    print("   \(name): render failed"); failures += 1; continue
  }
  var outPx = [UInt8](repeating: 0, count: N * N * 4)
  ctx.render((out.matchedToWorkingSpace(from: sRGB) ?? out).cropped(to: NE),
             toBitmap: &outPx, rowBytes: N * 4, bounds: NE,
             format: .RGBA8, colorSpace: sRGB)
  let kept = hf(outPx) / hf(px)
  let mi = avg(px), mo = avg(outPx)
  // Above 1.0 means the filter is AMPLIFYING grain — the signature of a broken
  // box footprint or a precision regression.
  if !kept.isFinite || kept > 1.0 { failures += 1 }
  print(String(format: "   %@   %6.1f%%   %+5.1f %+5.1f %+5.1f%@", name, kept * 100,
               mo.0 - mi.0, mo.1 - mi.1, mo.2 - mi.2,
               kept > 1.0 ? "   <-- AMPLIFYING" : ""))
}

print(failures == 0 ? "\nPASS" : "\nFAIL: \(failures) check(s)")
exit(failures == 0 ? 0 : 1)
