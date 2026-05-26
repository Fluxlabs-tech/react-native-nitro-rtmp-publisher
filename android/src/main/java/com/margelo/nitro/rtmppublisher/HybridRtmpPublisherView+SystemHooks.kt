package com.margelo.nitro.rtmppublisher

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Talk-to-the-OS layer: wake lock, keep-screen-on, and the foreground service
 * that keeps the streaming pipeline alive when the host activity backgrounds.
 * Everything here is essentially boilerplate but extremely load-bearing on
 * Android 12+ where the OS aggressively kills background camera/mic users.
 */

// ─── Wake lock ────────────────────────────────────────────────────────────

internal fun HybridRtmpPublisherView.acquireWakeLock() {
  if (wakeLock?.isHeld == true) return
  // Release any stale ref (wakelock that expired the 10h cap, or was released
  // out-of-band). Without this, allocating a fresh lock overwrites the field
  // and the old WakeLock token stays in PowerManagerService's tracking map —
  // a slow leak that compounds across multi-session streams.
  releaseWakeLock()
  try {
    val pm = powerManager ?: return
    val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
      setReferenceCounted(false)
    }
    lock.acquire(10 * 60 * 60 * 1000L /* 10h cap */)
    wakeLock = lock
  } catch (e: Exception) {
    Log.w(TAG, "acquireWakeLock failed: ${e.message}")
  }
}

internal fun HybridRtmpPublisherView.releaseWakeLock() {
  val lock = wakeLock ?: return
  try {
    if (lock.isHeld) lock.release()
  } catch (e: Exception) {
    Log.w(TAG, "releaseWakeLock failed: ${e.message}")
  }
  wakeLock = null
}

internal fun HybridRtmpPublisherView.setKeepScreenOn(on: Boolean) {
  // `openGlView.keepScreenOn` is a `View` setter and must be invoked on the
  // main thread (it touches the view hierarchy). startStream / stopStream
  // are dispatched from the JS thread by Nitro, so without a hop we hit
  // CalledFromWrongThreadException ("Only the original thread that created
  // a view hierarchy can touch its views. Expected: main Calling: mqt_v_js"),
  // safe() swallows it, and the flag silently never sets — leading to a
  // dim screen mid-stream on devices without our keep-alive flag.
  postToMain {
    safe("setKeepScreenOn") { openGlView.keepScreenOn = on }
  }
}

// ─── Foreground service ──────────────────────────────────────────────────
//
// Returns true iff the caller can safely proceed to start the stream.
//  - empty title: no FG service was requested → caller responsible for
//    keeping app in foreground; warn loud and proceed.
//  - non-empty title: service must actually start; if it doesn't, refuse.
internal fun HybridRtmpPublisherView.ensureForegroundServiceIfRequested(): Boolean {
  if (foregroundServiceTitle.isEmpty()) {
    Log.w(TAG, "startStream called without foregroundServiceTitle — on Android " +
      "14+ the OS will revoke camera/mic when the app backgrounds. Set " +
      "foregroundServiceTitle to keep the stream alive in background.")
    return true
  }
  // Pre-flight: POST_NOTIFICATIONS is runtime-granted on Android 13+. Without
  // it, the FG-service notification doesn't surface and some OEMs (Pixel,
  // OnePlus, Xiaomi) silently kill the service. We can't request the
  // permission from a library (no Activity here), but we can warn loud so the
  // caller knows to ask in JS before invoking startStream. Warn-once per
  // session so a bg→fg cycle doesn't spam the log.
  if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !postNotificationsWarned) {
    val granted = ContextCompat.checkSelfPermission(
      context, Manifest.permission.POST_NOTIFICATIONS
    ) == PackageManager.PERMISSION_GRANTED
    if (!granted) {
      Log.w(TAG, "POST_NOTIFICATIONS not granted (Android 13+). The FG-service " +
        "notification will not appear; some OEMs may kill the service mid-stream. " +
        "Request the permission from JS before calling startStream.")
      postNotificationsWarned = true
    }
  }
  // Always attempt start() — don't early-return on RtmpForegroundService.running.
  // The flag can lie: OEM-killed services don't fire onDestroy, so `running`
  // stays true while the service is actually gone. startForegroundService is
  // idempotent for the same component (Android dedups), so re-issuing a live
  // service just delivers another onStartCommand (we use that for live
  // notification updates anyway).
  val ok = RtmpForegroundService.start(
    context, foregroundServiceTitle, foregroundServiceText, foregroundServiceIcon
  )
  if (ok) {
    fgServiceStartedByUs = true
    return true
  }
  Log.e(TAG, "Foreground service start failed — likely Android 12+ " +
    "background-start restriction, or POST_NOTIFICATIONS not granted on 13+.")
  return false
}

internal fun HybridRtmpPublisherView.maybeStopForegroundService() {
  if (!fgServiceStartedByUs) return
  safe("stopForegroundService") { RtmpForegroundService.stop(context) }
  fgServiceStartedByUs = false
}
