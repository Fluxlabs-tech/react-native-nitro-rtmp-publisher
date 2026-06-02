//
//  HybridRtmpPublisherView+Events.swift
//  NitroRtmpPublisher
//
//  JS-facing callback setters and `emit*` helpers. All emissions hop to
//  main via `onMain` so JS-side state machines see events in a single,
//  deterministic order regardless of which Task / actor was the source.
//

import Foundation
import NitroModules
import UIKit

extension HybridRtmpPublisherView {

  // MARK: - Callback setters

  func setOnConnectionEvent(callback: @escaping (RtmpConnectionEvent, String) -> Void) throws {
    onConnectionEvent = callback
  }

  func setOnBitrateChange(callback: @escaping (Double) -> Void) throws {
    onBitrateChange = callback
    if cachedIsStreaming { startBitrateTimer() }
  }

  func setOnRecordStatusChange(callback: @escaping (RecordStatus) -> Void) throws {
    onRecordStatusChange = callback
  }

  // `setOnThermalWarning` lives in `+Lifecycle.swift` since it also
  // wires up the thermal observer as a side effect.
  //
  // The Picture-in-Picture API (enterPictureInPicture / isInPictureInPicture /
  // setOnPictureInPictureChange) is implemented in +PictureInPicture.swift.

  // MARK: - Main-thread hop helpers

  /// Fire-and-forget hop to main thread. UIKit + NotificationCenter
  /// observation blocks require main; callbacks coming from Task
  /// continuations resume on the cooperative executor, so every emit goes
  /// through this trampoline to keep JS event ordering deterministic.
  func onMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() }
    else { DispatchQueue.main.async(execute: block) }
  }

  func emitConnectionEvent(_ event: RtmpConnectionEvent, _ message: String) {
    onMain { [weak self] in self?.onConnectionEvent?(event, message) }
  }
  func emitBitrateChange(_ bps: Double) {
    onMain { [weak self] in self?.onBitrateChange?(bps) }
  }
  func emitRecordStatusChange(_ status: RecordStatus) {
    onMain { [weak self] in self?.onRecordStatusChange?(status) }
  }
  func emitThermalWarning(_ status: ThermalStatus) {
    onMain { [weak self] in self?.onThermalWarning?(status) }
  }
}
