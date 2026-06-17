package com.margelo.nitro.rtmppublisher

import java.util.concurrent.atomic.AtomicInteger

/**
 * File-internal types and constants shared across the HybridRtmpPublisherView
 * partials. Kept out of the main view file so the encoder / observer / system
 * helpers can reference them without dragging in the whole 1k-line surface.
 */

internal const val TAG = "RtmpPublisherView"
internal const val WAKE_LOCK_TAG = "RtmpPublisher::WakeLock"

// Reasonable ceilings for caller-supplied retry config — Pedro accepts any
// value but a runaway count or 10-year backoff isn't useful, just wastes the
// retry budget against a dead endpoint.
internal const val MAX_RETRY_ATTEMPTS = 100
internal const val MAX_RETRY_BACKOFF_MS = 60L * 60L * 1000L  // 1 hour

// How long a connection must stay up before Pedro's session-scoped reTries
// budget is re-armed to autoReconnectMaxAttempts (B4). Refilling instantly on
// connection success would let a success→instant-fail flapping ingest (the
// agoramdn broken-pipe loop: handshake OK, pipe breaks ~3-4s later) reconnect
// forever without ever going terminal — each cycle would restore the budget it
// just spent. 10s is comfortably past the observed flap periods.
internal const val STABLE_CONNECTION_MS = 10_000L

// Reconnect-safe RTMP tuning (Agora-MDN broken-pipe fix). On a reconnect we cap
// the send cache to RECONNECT_CACHE_SIZE so a backlog accumulated while
// disconnected can't burst-flush, and cap the write chunk to RECONNECT_CHUNK_SIZE
// (the size balanced/low-latency use, which Agora accepts — pure RTMP framing, no
// bitrate effect). The mode's full cache is restored STREAM_MODE_RESTORE_DELAY_MS
// after the link re-stabilizes. See applyReconnectSafeTuning.
internal const val RECONNECT_CACHE_SIZE = 60
internal const val RECONNECT_CHUNK_SIZE = 4096
internal const val STREAM_MODE_RESTORE_DELAY_MS = 8_000L

// Silent-stall watchdog (M1): consecutive onNewBitrate ticks (~1s each) at
// bitrate==0 — the sender thread wrote nothing to the socket while we still
// believe we're live (the metric counts bytes accepted into the kernel send
// buffer, NOT server-ACKed bytes, so even a nonzero tick doesn't prove server
// receipt) — before we force a reconnect. 3s of total silence is unambiguous
// on a real link yet short enough to recover quickly; a single transient zero
// tick won't trip it.
internal const val STALL_TICKS = 3

// Foreground-service readiness wait (M8). startForegroundService is async; we
// poll RtmpForegroundService.running this many times, this far apart, before
// starting the encoder (25 × 20ms = 500ms ceiling). Polling (not blocking) is
// required because the service's onStartCommand runs on the same main looper.
internal const val MAX_FGS_WAIT_ATTEMPTS = 25
internal const val FGS_WAIT_POLL_MS = 20L

// Teardown-settle wait before a (re)start. Pedro's disconnect coroutine flips
// RtmpClient's internal isStreaming only in its clear-block, 100ms-5s after
// camera.stopStream() returned — and rtmpClient.connect() silently NO-OPS
// while it's still true (no callback, no error). An immediate stop→start (or a
// restart from the DISCONNECT/CONNECTIONFAILED handler — the supported
// recovery pattern) must wait for the teardown to settle or the new session
// never connects. 120 × 50ms = 6s ceiling, covering the straggler envelope.
internal const val MAX_TEARDOWN_SETTLE_ATTEMPTS = 120
internal const val TEARDOWN_SETTLE_POLL_MS = 50L

// Camera2 only allows one open camera per process. Track the active publisher
// instance so a second mount can fail loudly instead of silently breaking the
// first one's preview. Atomic CAS — two concurrent mounts must not both win.
internal val activePublisherCount = AtomicInteger(0)

internal data class PreviewConfig(
  val facing: CameraFacing,
  val width: Int,
  val height: Int,
)

internal data class VideoCfg(
  val w: Int,
  val h: Int,
  val fps: Int,
  val bitrate: Int,
  val iFrame: Int,
  val rotation: Int,
)

internal data class AudioCfg(
  val bitrate: Int,
  val sampleRate: Int,
  val isStereo: Boolean,
)

// RTMP stream keys live in the URL path. Pedro's connect/auth/publish errors
// quote the full URL, which means stream keys leak straight into logcat
// (visible to `adb logcat`, USB-debug tools, vendor crash reporters, rooted
// devices, etc.). Scrub anything that looks like an rtmp:// or rtmps:// URL.
private val RTMP_URL_REGEX = Regex(
  "(rtmps?://[^/\\s]+)/[^\\s\"']+",
  RegexOption.IGNORE_CASE
)

internal fun String?.scrubRtmpKey(): String =
  (this ?: "null").replace(RTMP_URL_REGEX, "$1/<redacted>")

