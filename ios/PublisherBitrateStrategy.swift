//
//  PublisherBitrateStrategy.swift
//  NitroRtmpPublisher
//
//  Custom HaishinKit bit-rate strategy installed on every active RTMPStream.
//
//  HK's `NetworkMonitor` is private on `RTMPConnection`, so we can't read
//  `totalBytesOut` / `currentBytesOutPerSecond` directly. But HK *does*
//  call `stream.bitRateStrategy?.adjustBitrate(event, stream:)` once per
//  second — that's our hook into the otherwise-internal transport data.
//  This strategy:
//
//   1. Forwards `currentBytesOutPerSecond × 8` to a Sendable sink so the
//      JS-side `onBitrateChange` reports actual measured send rate.
//   2. When adaptive bitrate is armed, feeds each report — measured
//      throughput AND `currentQueueBytesOut`, the send-queue backlog — into
//      the shared [AdaptiveBitrateController] and applies whatever it
//      decides to `stream.videoSettings.bitRate`. HK's own event
//      classification (`publishInsufficientBWOccured`) is ignored: the
//      controller runs its own backlog thresholds, which fire on any
//      sustained queue (HK's needs 3 STRICTLY monotonic growth ticks).
//
//  `.panic` divergence from Android: HK exposes no send-queue flush, so a
//  runaway backlog can only be held at the floor and logged. Once the
//  controller reports the backlog has survived repeated panics
//  (`escalate == true`, ~30 s stuck ≥3 s behind live), the
//  `onPanicEscalation` sink asks the view to force a reconnect — the
//  pipeline rebuild discards the queue wholesale, which is the iOS
//  equivalent of Android's clearCache + keyframe.
//

import Foundation
import HaishinKit

final class PublisherBitrateStrategy: StreamBitRateStrategy, @unchecked Sendable {
  let mamimumVideoBitRate: Int
  let mamimumAudioBitRate: Int = 0

  private let controller: AdaptiveBitrateController?
  private let audioBps: Int
  private let onThroughputBps: @Sendable (Int) -> Void
  private let onBitrateApplied: @Sendable (Int) -> Void
  private let onPanicEscalation: @Sendable (Double) -> Void
  private let log: @Sendable (String) -> Void

  init(
    maxVideoBitRate: Int,
    controller: AdaptiveBitrateController?,
    audioBps: Int,
    onThroughputBps: @escaping @Sendable (Int) -> Void,
    onBitrateApplied: @escaping @Sendable (Int) -> Void,
    onPanicEscalation: @escaping @Sendable (Double) -> Void,
    log: @escaping @Sendable (String) -> Void
  ) {
    self.mamimumVideoBitRate = maxVideoBitRate
    self.controller = controller
    self.audioBps = audioBps
    self.onThroughputBps = onThroughputBps
    self.onBitrateApplied = onBitrateApplied
    self.onPanicEscalation = onPanicEscalation
    self.log = log
  }

  /// The one place ABR decisions touch the encoder: write videoSettings and
  /// mirror the value to the view (getCurrentBitrate cache) so the reported
  /// bitrate can't diverge from the applied one.
  private func apply(_ bps: Int, on stream: some StreamConvertible) async {
    var settings = await stream.videoSettings
    settings.bitRate = bps
    try? await stream.setVideoSettings(settings)
    onBitrateApplied(bps)
  }

  func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
    let report: NetworkMonitorReport
    switch event {
    case .status(let r):
      report = r
    case .publishInsufficientBWOccured(let r):
      report = r
    case .reset:
      return
    }
    let measuredBps = report.currentBytesOutPerSecond * 8
    onThroughputBps(measuredBps)
    guard let controller else { return }

    let action = await controller.tick(
      measuredBps: measuredBps,
      queueBytesOut: report.currentQueueBytesOut,
      audioBps: audioBps
    )
    switch action {
    case .none:
      break
    case .setBitrate(let bps, let reason):
      log("ABR \(reason) → \(bps / 1000) kbps")
      await apply(bps, on: stream)
    case .panic(let bps, let backlogSec, let escalate):
      // Seat the floor target; the backlog itself can't be dropped here (no
      // HK queue-flush). Escalation hands the problem to the view, whose
      // reconnect rebuilds the pipeline and discards the queue.
      log("ABR backlog \((backlogSec * 10).rounded(.down) / 10)s despite adaptation — " +
        "holding floor (\(bps / 1000) kbps)" +
        (escalate ? "; escalating to reconnect" : "; HaishinKit exposes no send-queue flush"))
      await apply(bps, on: stream)
      if escalate { onPanicEscalation(backlogSec) }
    }
  }
}
