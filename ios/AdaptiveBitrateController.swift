//
//  AdaptiveBitrateController.swift
//  NitroRtmpPublisher
//
//  Wrapper-side adaptive bitrate controller — the Swift port of the Android
//  controller of the same name (see the Kotlin file for the full design
//  rationale). Replaces HaishinKit's `StreamVideoAdaptiveBitRateStrategy`,
//  which shares the stock Pedro adapter's failure modes:
//
//   - Its congestion trigger is HK's `publishInsufficientBWOccured`, which
//     requires the send queue to grow STRICTLY monotonically for 3
//     consecutive seconds — a sawtoothing queue never fires it.
//   - On `.reset` it jumps straight back to the maximum bitrate, re-flooding
//     a link that just proved it couldn't carry it.
//   - Recovery is +max/10 every 15 clean ticks with no memory of where the
//     link last broke — the classic probe→congest→cut oscillation.
//
//  This controller instead reads the send-queue backlog directly. HaishinKit's
//  `RTMPSocket` queues outgoing chunks in an UNBOUNDED AsyncStream and its
//  `queueBytesOut` counter is exactly "accepted but not yet written to the
//  network" — the same truth signal the Android fork's unbounded
//  PriorityBlockingQueue exposes via `getItemsInCache()`, just in bytes
//  instead of frames. Any sustained backlog means the encoder is producing
//  faster than the socket drains: congestion, with none of the false
//  positives a throughput-only signal has (a static scene undershooting its
//  VBR target looks identical to congestion if you only watch measured bps).
//
//  Shape: AIMD with hysteresis — identical constants and transitions to the
//  Android controller:
//   - Decrease: one step to `(measured capacity − audio) × decreaseFactor`,
//     never below `floorBps`, at most once per DECREASE_COOLDOWN_TICKS.
//   - Increase: probes gated on a drained queue + hold-off after any cut,
//     slow-start doubling on consecutive clean probes, capped by a 60 s
//     *caution ceiling* remembered from the last congestion event.
//   - Panic: backlog ≥ 3 s despite adapting. DIVERGENCE from Android: HK
//     exposes no queue-flush, so the caller can only hold the floor and log
//     (Android clears the queue + requests a keyframe). A reconnect rebuilds
//     the whole HK pipeline, which discards the queue as a side effect.
//   - Reconnect: `targetBps`, the caution ceiling and the hold-off all
//     survive (resume at the adapted target, never below the floor). Only a
//     fresh `onSessionStart` clears the caution — a just-reconnected socket
//     can't take more bitrate for a few seconds, so probing straight back up
//     loops through congestion (see `onReconnected`).
//
//  Zero-throughput ticks are ignored: they are the silent-stall watchdog's
//  domain (`onBitrateTick` in +Streaming.swift), not congestion data.
//
//  Concurrency: an actor. Ticks arrive from HK's NetworkMonitor task via
//  `PublisherBitrateStrategy`; session lifecycle (`onSessionStart` /
//  `onReconnected`) is called from the view's publish/reconnect Tasks. The
//  actor serializes them all.
//
//  ── Intentional divergences from the Kotlin twin (everything else is
//     lockstep — change both files together) ─────────────────────────────
//   1. Backlog units: Android divides queued FRAMES by frames/s (bitrate-
//      independent); iOS divides queued BYTES by a produced-rate estimate
//      guarded with the throughput EWMA (see the comment in `tick`).
//   2. Panic: Android clears the send queue + requests a keyframe; iOS has
//      no queue-flush, so it floor-holds and, after PANIC_ESCALATE_AFTER
//      consecutive panics, asks the caller to force a reconnect (the
//      pipeline rebuild discards the queue). `panicStreak` /
//      `PANIC_ESCALATE_AFTER` therefore exist only on iOS.
//   3. Concurrency: Kotlin is main-thread-confined; Swift is an actor.
//

import Foundation

actor AdaptiveBitrateController {

  /// What the controller wants applied after a `tick`.
  enum Action {
    case none
    /// Apply `bps` to the video encoder.
    case setBitrate(bps: Int, reason: String)
    /// Severe backlog despite adapting. iOS cannot flush HK's send queue —
    /// the caller re-applies `bps` (already the floor) and logs. When
    /// `escalate` is true the backlog has now survived PANIC_ESCALATE_AFTER
    /// consecutive panics (~30 s stuck ≥ PANIC_BACKLOG_SEC): the caller
    /// should force a reconnect — the pipeline rebuild discards the queue,
    /// which is the iOS equivalent of Android's clearCache + keyframe.
    case panic(bps: Int, backlogSec: Double, escalate: Bool)
  }

  nonisolated let ceilingBps: Int
  nonisolated let floorBps: Int
  private let decreaseFactor: Double
  private let increaseFraction: Double

  /// Video bitrate this controller last decided (bps). Applied by the caller.
  private(set) var targetBps: Int

  // Own throughput EWMA — HK's per-second byte counts are raw window deltas,
  // re-smoothed here before capacity decisions are made from them.
  private var ewmaBps = 0.0
  private var lastMeasuredBps = 0

  // Backlog trend (queued bytes, previous tick).
  private var prevQueueBytes = 0

  // Tick bookkeeping. One tick ≈ 1 s (NetworkMonitor cadence). Initialized to
  // "long ago" so cooldowns don't suppress the first genuine action.
  private var tick = 0
  private var stableTicks = 0
  private var lastDecreaseTick = Int.min / 2
  private var lastPanicTick = Int.min / 2
  private var decreasesThisEpisode = 0
  // Consecutive successful probes since the last congested tick. Each one
  // doubles the next probe step (TCP-slow-start style, capped at
  // PROBE_STREAK_MAX_SHIFT doublings) so climbing back from the floor takes
  // seconds, not minutes — a link that can't take it congests on the first
  // oversized probe, which resets the streak and re-arms the caution ceiling.
  private var probeStreak = 0

  // Caution memory: where the link last broke. Probes stop just under it
  // until the expiry tick, then a single probe may cross to re-test.
  private var cautionBps = Int.max
  private var cautionExpiryTick = Int.min / 2

  // Consecutive panics with the backlog still ≥ PANIC_BACKLOG_SEC — the
  // escalation counter behind Action.panic(escalate:). iOS-only (see the
  // divergence map in the header).
  private var panicStreak = 0

  /// `initialBps` seeds `targetBps` at construction (clamped into
  /// floor…ceiling) so the reference can be published to concurrent readers
  /// — applyVideoSettings races a spawned onSessionStart otherwise — without
  /// a window where `targetBps` still reads as the raw ceiling.
  private init(
    ceilingBps: Int,
    floorBps: Int,
    decreaseFactor: Double,
    increaseFraction: Double,
    initialBps: Int?
  ) {
    self.ceilingBps = ceilingBps
    self.floorBps = floorBps
    self.decreaseFactor = decreaseFactor
    self.increaseFraction = increaseFraction
    self.targetBps = min(max(initialBps ?? ceilingBps, floorBps), ceilingBps)
  }

  /// Per-socket measurement/streak state that BOTH a fresh session and a
  /// reconnect must drop (it belongs to the dead socket). Deliberately does
  /// NOT touch the caution ceiling (`cautionBps`/`cautionExpiryTick`) or the
  /// post-cut hold-off (`lastDecreaseTick`) — a reconnect KEEPS those (see
  /// `onReconnected`); only a fresh session clears them.
  private func resetMeasurementState() {
    ewmaBps = 0.0
    lastMeasuredBps = 0
    prevQueueBytes = 0
    stableTicks = 0
    decreasesThisEpisode = 0
    probeStreak = 0
    panicStreak = 0
  }

  /// Fresh session (startStream). Starts from `initialBps` clamped into
  /// floor…ceiling; ALL congestion knowledge from a previous session is
  /// dropped (caution ceiling + hold-off included) — the network may be
  /// different by the next go-live.
  func onSessionStart(initialBps: Int) {
    targetBps = min(max(initialBps, floorBps), ceilingBps)
    lastPanicTick = Int.min / 2
    lastDecreaseTick = Int.min / 2
    cautionBps = Int.max
    cautionExpiryTick = Int.min / 2
    resetMeasurementState()
  }

  /// Socket re-established mid-session (reconnect succeeded). Throughput
  /// history belongs to the dead socket — drop it. The adapted `targetBps`,
  /// the caution ceiling and the post-cut hold-off all SURVIVE: right after a
  /// reconnect the link needs a few seconds before it can carry more (TCP
  /// re-ramp, buffers draining), so probing straight back up re-enters
  /// congestion immediately. On a link whose capacity sits near
  /// `floor + audio`, dropping the caution ceiling here turned recovery into
  /// a probe→congest→panic→stall→reconnect loop that never recovered
  /// (device-confirmed on Android over a WiFi switch — bitrate collapsed to
  /// 0). Keeping the caution ceiling holds probes at ~where the link last
  /// broke until it expires, then they climb; if the new link is genuinely
  /// faster, the ceiling expires within the caution window and recovery
  /// proceeds. (`lastPanicTick` also survives so a reconnect can't tighten
  /// the panic spacing.)
  func onReconnected() {
    resetMeasurementState()
  }

  /// JS called `setVideoBitrateOnFly` while this controller is armed. The
  /// controller owns the encoder bitrate, so instead of silently fighting
  /// the caller (the next probe would revert their value within seconds),
  /// adopt it: the manual value becomes the target, and a manual DECREASE is
  /// treated like an authoritative cut — post-cut hold-off plus a caution
  /// ceiling at the manual level — so it holds for the caution window
  /// (~CAUTION_TICKS s) before probes gently re-test above it. For a
  /// persistent cap, callers should move the ceiling via `setAdaptiveBitrate`
  /// or opt out.
  func onManualBitrate(_ bps: Int) {
    let clamped = min(max(bps, floorBps), ceilingBps)
    if clamped < targetBps {
      lastDecreaseTick = tick
      cautionBps = clamped
      cautionExpiryTick = tick + Self.CAUTION_TICKS
      probeStreak = 0
      stableTicks = 0
    }
    targetBps = clamped
  }

  /// One ~1 s sample from HK's NetworkMonitor. `measuredBps` is the measured
  /// TX bitrate (bytes/s × 8), `queueBytesOut` the send-queue backlog in
  /// bytes, `audioBps` the fixed audio bitrate to exclude from video capacity
  /// math (audio is not adapted).
  func tick(measuredBps: Int, queueBytesOut: Int, audioBps: Int) -> Action {
    tick += 1
    if measuredBps <= 0 {
      // Stall watchdog's domain. Not congestion data, not stability either.
      stableTicks = 0
      prevQueueBytes = queueBytesOut
      return .none
    }
    lastMeasuredBps = measuredBps
    ewmaBps = ewmaBps <= 0.0
      ? Double(measuredBps)
      : ewmaBps * (1 - Self.EWMA_ALPHA) + Double(measuredBps) * Self.EWMA_ALPHA

    // Backlog in seconds of media: queued bits over the rate they were
    // produced at. The queued bytes were encoded at RECENT rates — right
    // after a cut, dividing by the just-cut target understates that rate and
    // inflates backlogSec by ~oldRate/newRate (2 Mbit queued read 0.94 s
    // before a 2 Mbps→400 kbps cut and 3.79 s after it — self-triggering
    // extra cuts and panics). Guard with the throughput EWMA, which still
    // remembers the pre-cut rate for the couple of ticks the old bytes take
    // to drain. Android divides queued FRAMES by frames/s — bitrate-
    // independent, so it needs no such guard.
    let producedBps = max(Double(targetBps + audioBps), ewmaBps, 1)
    let backlogSec = Double(queueBytesOut) * 8.0 / producedBps
    let growthBits = (queueBytesOut - prevQueueBytes) * 8
    prevQueueBytes = queueBytesOut
    if backlogSec < Self.PANIC_BACKLOG_SEC { panicStreak = 0 }

    let congested = backlogSec >= Self.CONGESTED_BACKLOG_SEC ||
      (backlogSec >= Self.EARLY_BACKLOG_SEC &&
       Double(growthBits) > producedBps * Self.EARLY_GROWTH_FRACTION)

    if congested {
      stableTicks = 0
      probeStreak = 0
      var action: Action = .none
      if tick - lastDecreaseTick >= Self.DECREASE_COOLDOWN_TICKS {
        // Saturated socket ⇒ measured ≈ capacity. min(last, ewma): the EWMA
        // lags a sudden capacity drop, the raw sample leads it — the lower of
        // the two converges in one cut instead of three.
        let capacityBps = min(Double(lastMeasuredBps), ewmaBps)
        let videoCapacity = max(0.0, capacityBps - Double(audioBps))
        let proposed = max(
          floorBps,
          min(Int(videoCapacity * decreaseFactor), Int(Double(targetBps) * decreaseFactor))
        )
        if Double(proposed) < Double(targetBps) * (1 - Self.MIN_CHANGE_FRACTION) {
          targetBps = proposed
          lastDecreaseTick = tick
          decreasesThisEpisode += 1
          cautionBps = max(floorBps, Int(videoCapacity * Self.CAUTION_FRACTION))
          cautionExpiryTick = tick + Self.CAUTION_TICKS
          let backlogR = (backlogSec * 10).rounded(.down) / 10
          action = .setBitrate(
            bps: proposed,
            reason: "congestion (backlog=\(backlogR)s capacity≈\(Int(capacityBps) / 1000)kbps)"
          )
        }
      }
      // Still seconds behind live after adapting.
      if backlogSec >= Self.PANIC_BACKLOG_SEC,
         decreasesThisEpisode >= 1,
         tick - lastPanicTick >= Self.PANIC_MIN_INTERVAL_TICKS {
        lastPanicTick = tick
        panicStreak += 1
        return .panic(
          bps: targetBps,
          backlogSec: backlogSec,
          escalate: panicStreak >= Self.PANIC_ESCALATE_AFTER
        )
      }
      return action
    }

    // Not congested. Only a fully drained queue counts toward stability —
    // a draining-but-nonempty queue means the last cut hasn't proven out yet.
    if backlogSec <= Self.HEALTHY_BACKLOG_SEC {
      decreasesThisEpisode = 0
      stableTicks += 1
    } else {
      stableTicks = 0
    }
    if targetBps >= ceilingBps { return .none }
    if stableTicks < Self.STABLE_TICKS_FOR_PROBE { return .none }
    if tick - lastDecreaseTick < Self.HOLD_AFTER_DECREASE_TICKS { return .none }
    let step = max(Int(Double(targetBps) * increaseFraction), Self.MIN_PROBE_STEP_BPS)
      << min(probeStreak, Self.PROBE_STREAK_MAX_SHIFT)
    let unclamped = min(ceilingBps, targetBps + step)
    var proposed = unclamped
    if tick < cautionExpiryTick { proposed = min(proposed, max(cautionBps, targetBps)) }
    if proposed <= targetBps { return .none }
    targetBps = proposed
    stableTicks = 0
    // A caution-capped probe is no evidence the link took the full step — the
    // streak only grows on unclamped probes, so the post-caution re-test
    // starts back at a gentle 1× step instead of an escalated jump.
    probeStreak = proposed < unclamped ? 0 : probeStreak + 1
    return .setBitrate(bps: proposed, reason: "probe (headroom stable)")
  }

  // Constants — keep in lockstep with the Android controller.
  private static let CONGESTED_BACKLOG_SEC = 0.5
  private static let EARLY_BACKLOG_SEC = 0.25
  private static let EARLY_GROWTH_FRACTION = 0.15
  private static let HEALTHY_BACKLOG_SEC = 0.15
  private static let PANIC_BACKLOG_SEC = 3.0

  private static let EWMA_ALPHA = 0.4
  private static let DECREASE_COOLDOWN_TICKS = 3
  private static let HOLD_AFTER_DECREASE_TICKS = 8
  private static let STABLE_TICKS_FOR_PROBE = 5
  private static let CAUTION_FRACTION = 0.9
  private static let CAUTION_TICKS = 60
  private static let PANIC_MIN_INTERVAL_TICKS = 10
  // iOS-only: consecutive panics before Action.panic asks the caller to
  // force a reconnect (~30 s stuck ≥ PANIC_BACKLOG_SEC given the 10-tick
  // panic spacing). Android clears the queue directly and never escalates.
  private static let PANIC_ESCALATE_AFTER = 3
  private static let MIN_CHANGE_FRACTION = 0.05
  private static let MIN_PROBE_STEP_BPS = 50_000
  // Max slow-start doublings of the probe step (8×). Bounded so one probe
  // can overshoot a genuinely-limited link by at most ~one AIMD cycle.
  private static let PROBE_STREAK_MAX_SHIFT = 3

  // Absolute floor. 100 kbps is below watchable quality at 720p, but holding
  // this low lets a marginal link (~100-200 kbps) sustain a degraded picture
  // instead of stalling/reconnecting at a floor it can't carry — pair with a
  // lower prepareVideo resolution if quality at the floor matters.
  private static let MIN_FLOOR_BPS = 100_000
  private static let DEFAULT_DECREASE_PERCENT = 20.0
  private static let DEFAULT_INCREASE_PERCENT = 10.0

  /// Build a controller for `ceilingBps`. `decreasePercent` is the cut size
  /// on congestion (20 → ×0.8), `increasePercent` the probe step when the
  /// link is stable — both mirror the public `setAdaptiveBitrate` params;
  /// pass ≤0 to keep the default. Floor is derived: ceiling/20, never below
  /// `MIN_FLOOR_BPS` (but never above the ceiling itself). `initialBps`
  /// seeds `targetBps` synchronously at construction (nil → ceiling) so the
  /// returned reference is safe to publish immediately.
  static func forCeiling(
    ceilingBps: Int,
    decreasePercent: Double = 0.0,
    increasePercent: Double = 0.0,
    initialBps: Int? = nil
  ) -> AdaptiveBitrateController {
    let dec = min(max(decreasePercent > 0 ? decreasePercent : DEFAULT_DECREASE_PERCENT, 5.0), 50.0)
    let inc = min(max(increasePercent > 0 ? increasePercent : DEFAULT_INCREASE_PERCENT, 1.0), 25.0)
    let floor = min(ceilingBps, max(MIN_FLOOR_BPS, ceilingBps / 20))
    return AdaptiveBitrateController(
      ceilingBps: ceilingBps,
      floorBps: floor,
      decreaseFactor: 1.0 - dec / 100.0,
      increaseFraction: inc / 100.0,
      initialBps: initialBps
    )
  }
}
