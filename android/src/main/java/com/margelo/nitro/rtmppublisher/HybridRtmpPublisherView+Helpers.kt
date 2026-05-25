package com.margelo.nitro.rtmppublisher

import android.os.Looper
import android.util.Log

/**
 * Universal helpers: thread marshalling, pending-resume cancellation, and the
 * try/catch envelope every camera/encoder/network call goes through. Anything
 * touched by more than one of the topical extension files lives here.
 */

// Hop to main if we're on a background thread; run inline if already on main
// (avoids needlessly deferring connectChecker handling when JS invoked us
// synchronously, e.g. via switchCamera mid-stream).
internal fun HybridRtmpPublisherView.postToMain(block: () -> Unit) {
  if (Looper.myLooper() == Looper.getMainLooper()) block()
  else mainHandler.post(block)
}

internal fun HybridRtmpPublisherView.cancelPendingResume() {
  // Read into a local, null out the field, THEN remove from the handler queue.
  // If another thread assigns a fresh Runnable between our read and null-out
  // we'd clobber the new value with `= null`; reading first and writing once
  // narrows that window to a single store. Reads/writes are @Volatile.
  val r = pendingResumeRunnable ?: return
  pendingResumeRunnable = null
  mainHandler.removeCallbacks(r)
}

// ─── Error-bounded execution ──────────────────────────────────────────────
// All camera / encoder / Pedro calls go through these. RootEncoder throws
// IllegalStateException liberally (pre-init access, post-release access,
// surface-gone, etc.) and we don't want to crash the JS side over any of it.
//
// We deliberately do NOT pass the Throwable to Log.w. Pedro's exception
// messages frequently embed the full RTMP URL (with stream key), and
// Log.w(tag, msg, tr) prints tr.stackTrace which begins with tr.message —
// scrubbing only `msg` would leave the key in the stack-trace prefix.
// Including the exception class name keeps the log diagnostic.

internal inline fun safe(op: String, crossinline block: () -> Unit) {
  try {
    block()
  } catch (e: Exception) {
    Log.w(TAG, "$op failed: ${e.javaClass.simpleName}: ${e.message.scrubRtmpKey()}")
  }
}

internal inline fun <T> safe(op: String, default: T, crossinline block: () -> T): T {
  return try {
    block()
  } catch (e: Exception) {
    Log.w(TAG, "$op failed: ${e.javaClass.simpleName}: ${e.message.scrubRtmpKey()}")
    default
  }
}
