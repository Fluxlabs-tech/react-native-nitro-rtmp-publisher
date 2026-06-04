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

// Silent-stall watchdog (M1): consecutive onNewBitrate ticks (~1s each) at
// bitrate==0 — no bytes acked to the server while we still believe we're live —
// before we force a reconnect. 3s of total silence is unambiguous on a real
// link yet short enough to recover quickly; a single transient zero tick won't
// trip it.
internal const val STALL_TICKS = 3

// Foreground-service readiness wait (M8). startForegroundService is async; we
// poll RtmpForegroundService.running this many times, this far apart, before
// starting the encoder (25 × 20ms = 500ms ceiling). Polling (not blocking) is
// required because the service's onStartCommand runs on the same main looper.
internal const val MAX_FGS_WAIT_ATTEMPTS = 25
internal const val FGS_WAIT_POLL_MS = 20L

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

