package com.margelo.nitro.rtmppublisher

import kotlin.math.max
import kotlin.math.min

/**
 * Wrapper-side adaptive bitrate controller. Replaces Pedro's `BitrateAdapter`,
 * which is structurally broken against the 2.6.1-zoop fork:
 *
 *  - The fork's sender queue is an unbounded `PriorityBlockingQueue`, so
 *    `hasCongestion()` compares the queue size against
 *    `remainingCapacity()` = `Int.MAX_VALUE` and reads ~0% forever — the
 *    adapter's only *decrease* branch is dead code.
 *  - The surviving branch re-targets to `measuredThroughput × increaseRange`
 *    (default ×1.2) every 5 s. On a constrained link that pins the encoder
 *    20% ABOVE what the link carries; the unbounded queue absorbs the
 *    overshoot, so backlog (= viewer latency) grows without bound and the
 *    5 s re-target chases every throughput fluctuation ×1.2 — a sawtooth.
 *  - It has no floor (a transient dip collapses the target toward zero — the
 *    ~0.5 Mbps field collapses) and no hold-off between direction changes.
 *
 * This controller instead reads the truth signal the unbounded queue makes
 * available: **send-queue backlog**, in seconds of media
 * (`getItemsInCache() / (videoFps + audioFps)`). Frames are never dropped in
 * this fork, so any sustained backlog means "encoder is producing faster than
 * the socket drains" — exactly congestion, with none of the false positives a
 * throughput-only signal has (a static scene undershooting its VBR target
 * looks identical to congestion if you only watch measured bps).
 *
 * Shape: AIMD with hysteresis.
 *  - **Decrease** (multiplicative, one step per [DECREASE_COOLDOWN_TICKS]):
 *    under backlog the socket is saturated, so measured throughput ≈ link
 *    capacity; jump straight to `capacity × decreaseFactor` (audio excluded —
 *    audio bitrate is fixed, only video adapts) instead of stepping down
 *    blindly. Converges in one step, bounded below by [floorBps].
 *  - **Increase** (probe): only after [STABLE_TICKS_FOR_PROBE] ticks with an
 *    empty queue AND [HOLD_AFTER_DECREASE_TICKS] since the last cut. Each
 *    consecutive clean probe doubles the next step (slow-start, capped at
 *    [PROBE_STREAK_MAX_SHIFT] doublings) so climbing back from the floor
 *    takes seconds, not minutes. After congestion, a *caution ceiling*
 *    (~90% of the capacity that broke) caps probes for [CAUTION_TICKS] so
 *    recovery doesn't immediately re-enter congestion — that
 *    probe→congest→cut cycle is the visible "periodic jitter" a plain AIMD
 *    produces on a capacity-limited link. The caution ceiling and hold-off
 *    SURVIVE [onReconnected] (only a fresh [onSessionStart] clears them):
 *    a just-reconnected socket can't take more bitrate for a few seconds, so
 *    probing straight back up loops through congestion.
 *  - **Panic** ([Action.PanicClear]): backlog past [PANIC_BACKLOG_SEC] even
 *    after adapting means seconds of glass-to-glass latency already queued
 *    and still growing; the caller clears the send queue and requests a
 *    keyframe to snap the viewer back to live (brief freeze beats runaway
 *    latency — this fork never drops frames on its own).
 *
 * Zero-throughput ticks are ignored entirely: they are the silent-stall
 * watchdog's domain (see `onNewBitrate` in [HybridRtmpPublisherView]), not
 * congestion data. This removes the stall-zero-pollution hazard the old
 * Pedro-adapter feed had to gate against.
 *
 * Threading: tick-state is only touched from [tick] / [onSessionStart] /
 * [onReconnected]. Ticks run on the main thread (onNewBitrate posts there);
 * arming/re-tuning swaps the whole controller reference (a `@Volatile` field
 * on the view), matching how the old `bitrateAdapter` field was handled.
 *
 * ── Intentional divergences from the Swift twin (everything else is
 *    lockstep — change both files together) ──────────────────────────────
 *  1. Backlog units: Android divides queued FRAMES by frames/s (bitrate-
 *     independent); iOS divides queued BYTES by a produced-rate estimate
 *     guarded with the throughput EWMA.
 *  2. Panic: Android clears the send queue + requests a keyframe; iOS has
 *     no queue-flush, so it floor-holds and escalates repeated panics into
 *     a forced reconnect (`panicStreak` exists only there).
 *  3. Concurrency: Kotlin is main-thread-confined; Swift is an actor.
 *
 * [initialBps] seeds [targetBps] at construction (0 → ceiling) so a freshly
 * built controller is safe to publish to concurrent readers immediately.
 */
internal class AdaptiveBitrateController(
  val ceilingBps: Int,
  val floorBps: Int,
  private val decreaseFactor: Double,
  private val increaseFraction: Double,
  initialBps: Int = 0,
) {

  /** What the controller wants applied after a [tick]. */
  sealed interface Action {
    object None : Action

    /** Apply [bps] via `setVideoBitrateOnFly`. */
    data class SetBitrate(val bps: Int, val reason: String) : Action

    /**
     * Severe backlog: apply [bps], clear the send queue and request a
     * keyframe (the queued [backlogSec] seconds are unrecoverable latency).
     */
    data class PanicClear(val bps: Int, val backlogSec: Double) : Action
  }

  /** Video bitrate this controller last decided (bps). Applied by the view. */
  @Volatile var targetBps: Int =
    if (initialBps > 0) initialBps.coerceIn(floorBps, ceilingBps) else ceilingBps
    private set

  // Own throughput EWMA. The value Pedro reports is already mode-shaped
  // (setBitrateExponentialFactor 0.5 / 1.0 / 2.0 — and 2.0 EXTRAPOLATES
  // past the real measurement in lowLatency mode), so it is re-smoothed
  // here before capacity decisions are made from it.
  private var ewmaBps = 0.0
  private var lastMeasuredBps = 0L

  // Backlog trend (items, previous tick).
  private var prevQueueItems = 0

  // Tick bookkeeping. One tick ≈ 1 s (onNewBitrate cadence). Initialized to
  // "long ago" so cooldowns don't suppress the first genuine action.
  private var tick = 0
  private var stableTicks = 0
  private var lastDecreaseTick = Int.MIN_VALUE / 2
  private var lastPanicTick = Int.MIN_VALUE / 2
  private var decreasesThisEpisode = 0
  // Consecutive successful probes since the last congested tick. Each one
  // doubles the next probe step (TCP-slow-start style, capped at
  // [PROBE_STREAK_MAX_SHIFT] doublings) so climbing back from the floor takes
  // seconds, not minutes — a link that can't take it congests on the first
  // oversized probe, which resets the streak and re-arms the caution ceiling.
  private var probeStreak = 0

  // Caution memory: where the link last broke. Probes stop just under it
  // until the expiry tick, then a single probe may cross to re-test.
  private var cautionBps = Int.MAX_VALUE
  private var cautionExpiryTick = Int.MIN_VALUE / 2

  /**
   * Per-socket measurement/streak state that BOTH a fresh session and a
   * reconnect must drop (it belongs to the dead socket). Deliberately does
   * NOT touch the caution ceiling ([cautionBps]/[cautionExpiryTick]) or the
   * post-cut hold-off ([lastDecreaseTick]) — a reconnect KEEPS those (see
   * [onReconnected]); only a fresh session clears them.
   */
  private fun resetMeasurementState() {
    ewmaBps = 0.0
    lastMeasuredBps = 0L
    prevQueueItems = 0
    stableTicks = 0
    decreasesThisEpisode = 0
    probeStreak = 0
  }

  /**
   * Fresh session (startStream). Starts from [initialBps] clamped into
   * [floorBps]..[ceilingBps]; ALL congestion knowledge from a previous
   * session is dropped (caution ceiling + hold-off included) — the network
   * may be different by the next go-live.
   */
  fun onSessionStart(initialBps: Int) {
    targetBps = initialBps.coerceIn(floorBps, ceilingBps)
    lastPanicTick = Int.MIN_VALUE / 2
    lastDecreaseTick = Int.MIN_VALUE / 2
    cautionBps = Int.MAX_VALUE
    cautionExpiryTick = Int.MIN_VALUE / 2
    resetMeasurementState()
  }

  /**
   * Socket re-established mid-session (reTry succeeded). Throughput history
   * belongs to the dead socket — drop it. The adapted [targetBps], the
   * caution ceiling and the post-cut hold-off all SURVIVE: right after a
   * reconnect the link needs a few seconds before it can carry more (TCP
   * re-ramp, buffers draining), so probing straight back up re-enters
   * congestion immediately. On a link whose capacity sits near
   * `floor + audio`, dropping the caution ceiling here turned recovery into a
   * probe→congest→panic→silent-stall→reconnect loop that never recovered
   * (device-confirmed on a WiFi switch — bitrate collapsed to 0). Keeping the
   * caution ceiling holds probes at ~where the link last broke until it
   * expires, then they climb; if the new link is genuinely faster, the
   * ceiling expires within the caution window and recovery proceeds.
   */
  fun onReconnected() {
    resetMeasurementState()
  }

  /**
   * JS called `setVideoBitrateOnFly` while this controller is armed. The
   * controller owns the encoder bitrate, so instead of silently fighting the
   * caller (the next probe would revert their value within seconds), adopt
   * it: the manual value becomes the target, and a manual DECREASE is
   * treated like an authoritative cut — post-cut hold-off plus a caution
   * ceiling at the manual level — so it holds for the caution window
   * (~[CAUTION_TICKS] s) before probes gently re-test above it. For a
   * persistent cap, callers should move the ceiling via `setAdaptiveBitrate`
   * or opt out.
   */
  fun onManualBitrate(bps: Int) {
    val clamped = bps.coerceIn(floorBps, ceilingBps)
    if (clamped < targetBps) {
      lastDecreaseTick = tick
      cautionBps = clamped
      cautionExpiryTick = tick + CAUTION_TICKS
      probeStreak = 0
      stableTicks = 0
    }
    targetBps = clamped
  }

  /**
   * One ~1 s sample. [measuredBps] is the sender's reported TX bitrate,
   * [queueItems] the send-queue depth, [itemsPerSec] the expected media-frame
   * production rate (video fps + audio AAC-frame rate), [audioBps] the fixed
   * audio bitrate to exclude from video capacity math.
   */
  fun tick(measuredBps: Long, queueItems: Int, itemsPerSec: Double, audioBps: Int): Action {
    tick++
    if (measuredBps <= 0L) {
      // Stall watchdog's domain. Not congestion data, not stability either.
      stableTicks = 0
      prevQueueItems = queueItems
      return Action.None
    }
    lastMeasuredBps = measuredBps
    ewmaBps =
      if (ewmaBps <= 0.0) measuredBps.toDouble()
      else ewmaBps * (1 - EWMA_ALPHA) + measuredBps * EWMA_ALPHA

    val perSec = if (itemsPerSec > 1.0) itemsPerSec else DEFAULT_ITEMS_PER_SEC
    val backlogSec = queueItems / perSec
    val growth = queueItems - prevQueueItems
    prevQueueItems = queueItems

    val congested = backlogSec >= CONGESTED_BACKLOG_SEC ||
      (backlogSec >= EARLY_BACKLOG_SEC && growth > perSec * EARLY_GROWTH_FRACTION)

    if (congested) {
      stableTicks = 0
      probeStreak = 0
      var action: Action = Action.None
      if (tick - lastDecreaseTick >= DECREASE_COOLDOWN_TICKS) {
        // Saturated socket ⇒ measured ≈ capacity. min(last, ewma): the EWMA
        // lags a sudden capacity drop, the raw sample leads it — the lower of
        // the two converges in one cut instead of three.
        val capacityBps = min(lastMeasuredBps.toDouble(), ewmaBps)
        val videoCapacity = max(0.0, capacityBps - audioBps)
        val proposed = max(
          floorBps,
          min((videoCapacity * decreaseFactor).toInt(), (targetBps * decreaseFactor).toInt())
        )
        if (proposed < targetBps * (1 - MIN_CHANGE_FRACTION)) {
          targetBps = proposed
          lastDecreaseTick = tick
          decreasesThisEpisode++
          cautionBps = max(floorBps, (videoCapacity * CAUTION_FRACTION).toInt())
          cautionExpiryTick = tick + CAUTION_TICKS
          action = Action.SetBitrate(
            proposed,
            "congestion (backlog=${backlogSec.round1()}s capacity≈${capacityBps.toInt() / 1000}kbps)"
          )
        }
      }
      // Still seconds behind live after adapting — drop the backlog.
      if (backlogSec >= PANIC_BACKLOG_SEC &&
        decreasesThisEpisode >= 1 &&
        tick - lastPanicTick >= PANIC_MIN_INTERVAL_TICKS
      ) {
        lastPanicTick = tick
        return Action.PanicClear(targetBps, backlogSec)
      }
      return action
    }

    // Not congested. Only a fully drained queue counts toward stability —
    // a draining-but-nonempty queue means the last cut hasn't proven out yet.
    if (backlogSec <= HEALTHY_BACKLOG_SEC) {
      decreasesThisEpisode = 0
      stableTicks++
    } else {
      stableTicks = 0
    }
    if (targetBps >= ceilingBps) return Action.None
    if (stableTicks < STABLE_TICKS_FOR_PROBE) return Action.None
    if (tick - lastDecreaseTick < HOLD_AFTER_DECREASE_TICKS) return Action.None
    val step = max((targetBps * increaseFraction).toInt(), MIN_PROBE_STEP_BPS) shl
      min(probeStreak, PROBE_STREAK_MAX_SHIFT)
    val unclamped = min(ceilingBps, targetBps + step)
    var proposed = unclamped
    if (tick < cautionExpiryTick) proposed = min(proposed, max(cautionBps, targetBps))
    if (proposed <= targetBps) return Action.None
    targetBps = proposed
    stableTicks = 0
    // A caution-capped probe is no evidence the link took the full step — the
    // streak only grows on unclamped probes, so the post-caution re-test
    // starts back at a gentle 1× step instead of an escalated jump.
    probeStreak = if (proposed < unclamped) 0 else probeStreak + 1
    return Action.SetBitrate(proposed, "probe (headroom stable)")
  }

  private fun Double.round1(): Double = (this * 10).toInt() / 10.0

  companion object {
    // Backlog thresholds, in seconds of queued media. Healthy operation is a
    // ~0-item queue (the sender drains as frames arrive), so even 0.5 s is an
    // unambiguous signal; 0.25 s + growing catches the onset one tick sooner.
    private const val CONGESTED_BACKLOG_SEC = 0.5
    private const val EARLY_BACKLOG_SEC = 0.25
    private const val EARLY_GROWTH_FRACTION = 0.15
    private const val HEALTHY_BACKLOG_SEC = 0.15
    private const val PANIC_BACKLOG_SEC = 3.0

    private const val EWMA_ALPHA = 0.4
    private const val DECREASE_COOLDOWN_TICKS = 3
    private const val HOLD_AFTER_DECREASE_TICKS = 8
    private const val STABLE_TICKS_FOR_PROBE = 5
    private const val CAUTION_FRACTION = 0.9
    private const val CAUTION_TICKS = 60
    private const val PANIC_MIN_INTERVAL_TICKS = 10
    private const val MIN_CHANGE_FRACTION = 0.05
    private const val MIN_PROBE_STEP_BPS = 50_000
    // Max slow-start doublings of the probe step (8×). Bounded so one probe
    // can overshoot a genuinely-limited link by at most ~one AIMD cycle.
    private const val PROBE_STREAK_MAX_SHIFT = 3

    // 30 fps video + 44.1 kHz AAC (~43 frames/s) — fallback when configs are
    // missing; only used to convert items → seconds.
    private const val DEFAULT_ITEMS_PER_SEC = 73.0

    // Absolute floor. 100 kbps is below watchable quality at 720p, but holding
    // this low lets a marginal link (~100-200 kbps) sustain a degraded picture
    // instead of stalling/reconnecting at a floor it can't carry — pair with a
    // lower prepareVideo resolution if quality at the floor matters.
    private const val MIN_FLOOR_BPS = 100_000
    private const val DEFAULT_DECREASE_PERCENT = 20.0
    private const val DEFAULT_INCREASE_PERCENT = 10.0

    /**
     * Build a controller for [ceilingBps]. [decreasePercent] is the cut size
     * on congestion (20 → ×0.8), [increasePercent] the probe step when the
     * link is stable — both mirror the public `setAdaptiveBitrate` params;
     * pass ≤0 to keep the default. Floor is derived: ceiling/20, never below
     * [MIN_FLOOR_BPS] (but never above the ceiling itself). [initialBps]
     * seeds [targetBps] synchronously at construction (0 → ceiling) so the
     * returned reference is safe to publish immediately.
     */
    fun forCeiling(
      ceilingBps: Int,
      decreasePercent: Double = 0.0,
      increasePercent: Double = 0.0,
      initialBps: Int = 0,
    ): AdaptiveBitrateController {
      val dec = (if (decreasePercent > 0) decreasePercent else DEFAULT_DECREASE_PERCENT)
        .coerceIn(5.0, 50.0)
      val inc = (if (increasePercent > 0) increasePercent else DEFAULT_INCREASE_PERCENT)
        .coerceIn(1.0, 25.0)
      // Deliberately min/max, NOT coerceIn(MIN_FLOOR_BPS, ceilingBps) — that
      // form throws when the ceiling sits below MIN_FLOOR_BPS (tiny ceilings
      // are legal; the floor just collapses onto them).
      val floor = min(ceilingBps, max(MIN_FLOOR_BPS, ceilingBps / 20))
      return AdaptiveBitrateController(
        ceilingBps = ceilingBps,
        floorBps = floor,
        decreaseFactor = 1.0 - dec / 100.0,
        increaseFraction = inc / 100.0,
        initialBps = initialBps,
      )
    }
  }
}
