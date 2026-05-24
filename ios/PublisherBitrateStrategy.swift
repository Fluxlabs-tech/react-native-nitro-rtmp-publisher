//
//  PublisherBitrateStrategy.swift
//  NitroRtmpPublisher
//
//  Custom HaishinKit bit-rate strategy installed on every active RTMPStream.
//
//  HK's `NetworkMonitor` is private on `RTMPConnection`, so we can't read
//  `totalBytesOut` / `currentBytesOutPerSecond` directly. But HK *does*
//  call `stream.bitRateStrategy?.adjustBitrate(event, stream:)` on every
//  monitor tick — that's our hook into the otherwise-internal throughput
//  data. This strategy:
//
//   1. Forwards `currentBytesOutPerSecond × 8` to a Sendable sink so the
//      JS-side `onBitrateChange` reports actual measured send rate.
//   2. When JS-side adaptive bitrate is enabled, delegates to HK's built-in
//      `StreamVideoAdaptiveBitRateStrategy` which adjusts the encoder
//      bitrate in response to `publishInsufficientBWOccured`.
//

import Foundation
import HaishinKit

final class PublisherBitrateStrategy: StreamBitRateStrategy, @unchecked Sendable {
  let mamimumVideoBitRate: Int
  let mamimumAudioBitRate: Int = 0

  private let inner: StreamVideoAdaptiveBitRateStrategy?
  private let onThroughputBps: @Sendable (Int) -> Void

  init(
    maxVideoBitRate: Int,
    adaptive: Bool,
    onThroughputBps: @escaping @Sendable (Int) -> Void
  ) {
    self.mamimumVideoBitRate = maxVideoBitRate
    self.inner = adaptive
      ? StreamVideoAdaptiveBitRateStrategy(mamimumVideoBitrate: maxVideoBitRate)
      : nil
    self.onThroughputBps = onThroughputBps
  }

  func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
    switch event {
    case .status(let report):
      onThroughputBps(report.currentBytesOutPerSecond * 8)
    case .publishInsufficientBWOccured(let report):
      onThroughputBps(report.currentBytesOutPerSecond * 8)
    case .reset:
      break
    }
    await inner?.adjustBitrate(event, stream: stream)
  }
}
