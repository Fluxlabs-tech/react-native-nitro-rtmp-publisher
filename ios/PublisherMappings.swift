//
//  PublisherMappings.swift
//  NitroRtmpPublisher
//
//  Pure type-mapping extensions. These bridge between the Nitro-generated
//  JS-facing enums (`AspectRatioMode`, `ThermalStatus`, …) and the
//  AVFoundation / Foundation types we use under the hood. No I/O, no state
//  — safe to keep `private`-scoped so they don't leak into other Swift
//  files outside this pod.
//

import AVFoundation
import Foundation
import NitroModules
import UIKit

// MARK: - Aspect ratio

extension AspectRatioMode {
  var avLayerGravity: AVLayerVideoGravity {
    switch self {
    case .fill:   return .resizeAspectFill
    case .adjust: return .resizeAspect
    case .none:   return .resize
    }
  }
}

extension AVLayerVideoGravity {
  /// `UIImageView` content mode that letterboxes/fills identically to how the
  /// Metal preview renders this gravity — so the flip freeze-frame overlay
  /// lines up with the live feed underneath it.
  var imageContentMode: UIView.ContentMode {
    switch self {
    case .resizeAspectFill: return .scaleAspectFill
    case .resize:           return .scaleToFill
    default:                return .scaleAspectFit  // .resizeAspect
    }
  }
}

// MARK: - Thermal state

extension ProcessInfo.ThermalState {
  /// Numeric rank for "crossed a threshold?" comparisons.
  var severityRank: Int {
    switch self {
    case .nominal:    return 0
    case .fair:       return 1
    case .serious:    return 3
    case .critical:   return 4
    @unknown default: return 0
    }
  }

  /// iOS only exposes 4 thermal states (`nominal`/`fair`/`serious`/`critical`).
  /// We map them onto our 7-level JS-facing scale by collapsing the lower
  /// end (no `.moderate` / `.emergency` / `.shutdown` equivalents on iOS).
  func toNitro() -> ThermalStatus {
    switch self {
    case .nominal:    return .none
    case .fair:       return .light
    case .serious:    return .severe
    case .critical:   return .critical
    @unknown default: return .none
    }
  }
}

extension ThermalStatus {
  /// Inverse of `toNitro()` for threshold comparison via `severityRank`.
  func toProcessInfoState() -> ProcessInfo.ThermalState {
    switch self {
    case .none, .light:                    return .fair
    case .moderate, .severe:               return .serious
    case .critical, .emergency, .shutdown: return .critical
    }
  }
}

// MARK: - Scalar utilities

extension String {
  var isBlank: Bool { trimmingCharacters(in: .whitespaces).isEmpty }
}

extension Double {
  func clamped(_ lower: Double, _ upper: Double) -> Double {
    return Swift.min(Swift.max(self, lower), upper)
  }
}

extension CGFloat {
  func clamped(_ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    return Swift.min(Swift.max(self, lower), upper)
  }
}

extension Float {
  func clamped(_ lower: Float, _ upper: Float) -> Float {
    return Swift.min(Swift.max(self, lower), upper)
  }
}
