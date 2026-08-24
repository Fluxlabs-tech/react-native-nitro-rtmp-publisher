//
//  BeautyLookCube.swift
//  NitroRtmpPublisher
//
//  Turns the embedded LUT atlas (`BeautyLookAtlas`) into `CIColorCube` payloads
//  for the Bright and Cool beauty looks. Warm needs nothing from here — on both
//  platforms it IS the ungraded base filter.
//
//  ── Why decode by hand instead of using CoreGraphics ────────────────────────
//   The atlas is DATA that happens to be shaped like an image. Handing it to
//   CGImageSource/UIImage invites exactly the two things that destroy it:
//   colour management (the atlas is deliberately untagged — the generator
//   rejects iCCP/sRGB/gAMA/cHRM chunks) and resampling (any interpolation
//   smears colour across the 32x32 tile boundaries and corrupts every lookup —
//   the same corruption Android's `inScaled = false` guards against). So the
//   payload ships pre-unfiltered and this file touches it with arithmetic only:
//   inflate, undo one subtraction per byte, repack. The bytes that reach the GPU
//   are the same bytes Android's `GLUtils.texImage2D` uploads.
//
//  ── Cost ───────────────────────────────────────────────────────────────────
//   ~200KB inflate plus 65k float conversions per look, and each finished cube
//   is 32³ × RGBA float32 = 512KB. That is why `decodeAll()` is pure and
//   explicitly OFF the render path — `BeautyVideoEffect` runs it on a background
//   queue the first time a non-Warm look is selected, so a session that never
//   opens the look picker never pays for it.
//

import CoreImage
import Foundation

#if canImport(Compression)
import Compression
#endif

enum BeautyLookCube {

  /// Cube edge. `CIColorCube`'s `inputCubeDimension`.
  static let dimension = BeautyLookAtlas.cubeSide

  /// Slot order in the atlas — MUST match the stacking the generator wrote and
  /// the `uLookSlot` values Android's composite shader uses.
  static let brightSlot = 0
  static let coolSlot = 1

  /// Decodes both looks. Returns `nil` on any malformed payload, which leaves
  /// the looks unavailable and the base beauty filter working — never a fatal.
  ///
  /// Pure and slow enough to keep off the render path; see the cost note above.
  static func decodeAll() -> [Data]? {
    guard let atlas = decodeAtlas() else { return nil }
    return [cube(from: atlas, slot: brightSlot), cube(from: atlas, slot: coolSlot)]
  }

  /// base64 → raw DEFLATE → undo the sub filter → 256×256 RGB8, row-major from
  /// the top.
  private static func decodeAtlas() -> [UInt8]? {
    guard let payload = Data(
      base64Encoded: BeautyLookAtlas.payloadBase64, options: .ignoreUnknownCharacters
    ) else {
      NSLog("[BeautyLookCube] atlas base64 malformed — beauty looks unavailable")
      return nil
    }

    let expected = BeautyLookAtlas.decodedByteCount
    var bytes = [UInt8](repeating: 0, count: expected)

    // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what the generator's
    // `deflateRawSync` produces. A short read means a truncated or mismatched
    // payload, so treat anything but the exact expected length as a failure
    // rather than rendering from a partially-filled buffer.
    let written = bytes.withUnsafeMutableBufferPointer { destination -> Int in
      guard let destinationBase = destination.baseAddress else { return 0 }
      return payload.withUnsafeBytes { source -> Int in
        guard let sourceBase = source.baseAddress else { return 0 }
        return compression_decode_buffer(
          destinationBase, expected,
          sourceBase.assumingMemoryBound(to: UInt8.self), payload.count,
          nil, COMPRESSION_ZLIB
        )
      }
    }
    guard written == expected else {
      NSLog(
        "[BeautyLookCube] atlas inflate wrote \(written) of \(expected) bytes"
          + " — beauty looks unavailable"
      )
      return nil
    }

    // Each byte was stored as its difference from the byte three positions to
    // the left (PNG's "sub" filter), wrapping at 256. Deflate alone leaves this
    // data almost incompressible — 186KB of 196KB — because a smooth LUT
    // repeats gradients, not exact byte runs; the subtraction is what takes it
    // to 37KB. `&+` restores the wrap.
    let rowBytes = BeautyLookAtlas.side * 3
    for row in 0..<BeautyLookAtlas.side {
      let base = row * rowBytes
      for offset in 3..<rowBytes {
        bytes[base + offset] = bytes[base + offset] &+ bytes[base + offset - 3]
      }
    }
    return bytes
  }

  /// Repacks one look into `CIColorCube`'s layout: RGBA float32 with red varying
  /// fastest, then green, then blue (Apple's documented cube ordering).
  ///
  /// Atlas addressing is the GLES shader's, unchanged: blue slice `b` sits at
  /// tile column `b % 8`, tile row `b / 8` within the look's 4 rows; inside a
  /// tile x is red and y is green, with green 0 at the tile's TOP row —
  /// `GLUtils.texImage2D` uploads bitmap row 0 to t = 0, and PNG row 0 is the
  /// top, so the texture row index and the PNG row index are the same number.
  ///
  /// Alpha is 1, which also satisfies `inputCubeData`'s premultiplied-alpha
  /// requirement without any extra work.
  private static func cube(from atlas: [UInt8], slot: Int) -> Data {
    let n = dimension
    var values = [Float](repeating: 0, count: n * n * n * 4)
    var out = 0
    for blue in 0..<n {
      let tileX = (blue % BeautyLookAtlas.cols) * n
      let tileY = (slot * BeautyLookAtlas.rowsPerLook + blue / BeautyLookAtlas.cols) * n
      for green in 0..<n {
        var source = ((tileY + green) * BeautyLookAtlas.side + tileX) * 3
        for _ in 0..<n {
          values[out] = Float(atlas[source]) / 255.0
          values[out + 1] = Float(atlas[source + 1]) / 255.0
          values[out + 2] = Float(atlas[source + 2]) / 255.0
          values[out + 3] = 1.0
          out += 4
          source += 3
        }
      }
    }
    return values.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  /// Builds the reusable filter for one decoded payload. Cheap — the expensive
  /// part was `decodeAll()`.
  ///
  /// Plain `CIColorCube`, NOT `CIColorCubeWithColorSpace`: the caller has already
  /// converted the frame into sRGB-gamma-encoded values to match the domain
  /// Android's GLSL runs in, so the lookup must index those values as-is. A
  /// colour-space variant would convert on the way in and out and land the grade
  /// somewhere else entirely.
  static func makeFilter(_ cubeData: Data) -> CIFilter? {
    guard let filter = CIFilter(name: "CIColorCube") else {
      NSLog("[BeautyLookCube] CIColorCube unavailable — beauty looks unavailable")
      return nil
    }
    filter.setValue(Float(dimension), forKey: "inputCubeDimension")
    filter.setValue(cubeData, forKey: "inputCubeData")
    return filter
  }
}
