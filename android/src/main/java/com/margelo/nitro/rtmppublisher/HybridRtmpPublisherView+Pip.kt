package com.margelo.nitro.rtmppublisher

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Rect
import android.os.Build
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.annotation.RequiresApi
import com.facebook.react.uimanager.ThemedReactContext

/**
 * Android system Picture-in-Picture.
 *
 * PIP is a per-Activity concept, but this library only owns a View, so it
 * *observes* the host Activity instead of subclassing it:
 *
 *  - **Arming** ([HybridRtmpPublisherView.pictureInPictureEnabled]) registers a
 *    [androidx.activity.ComponentActivity.addOnPictureInPictureModeChangedListener]
 *    — available on RN's `ReactActivity` (which is a `ComponentActivity`) with
 *    no host override required — and, on API 31+, sets `setAutoEnterEnabled` so
 *    the OS shrinks into the floating window on Home/Recents automatically.
 *  - **Manual entry** ([requestPictureInPicture]) covers API 26–30 (no
 *    auto-enter) and a "PIP" button.
 *  - The window is kept **portrait** to match the portrait stream via a clamped
 *    aspect-ratio [Rational].
 *
 * Everything touching the Activity/window is marshalled to the main thread with
 * [postToMain] (Nitro dispatches view methods on the JS thread) and wrapped in
 * [safe]. No-ops cleanly below API 26 or when no Activity can be resolved.
 */

// PIP aspect ratio must sit within Android's accepted band — roughly
// 0.41841 (1:2.39) .. 2.39 — or setPictureInPictureParams throws
// IllegalArgumentException. We clamp just inside with a small float margin.
private const val PIP_MIN_RATIO = 0.42f
private const val PIP_MAX_RATIO = 2.38f

// ─── Activity resolution ────────────────────────────────────────────────────

// Resolve the host Activity. Prefers the LIVE ThemedReactContext.currentActivity
// (the context Nitro hands the view IS a ThemedReactContext) so we never pin a
// destroyed Activity if the host recreates it (a Context leak + stale-target
// risk). Falls back to the last-known ref, then to unwrapping the ContextWrapper
// chain. `hostActivity` is kept up to date for `unregisterPipListener` and
// cleared in `onDropView`.
internal fun HybridRtmpPublisherView.resolveActivity(): Activity? {
  (context as? ThemedReactContext)?.currentActivity?.let {
    hostActivity = it
    return it
  }
  hostActivity?.let { return it }
  var c: Context? = context
  while (c is ContextWrapper) {
    if (c is Activity) { hostActivity = c; return c }
    c = c.baseContext
  }
  return null
}

// Safe read of the Activity's PIP state (API 24+; false below, false on error).
internal fun HybridRtmpPublisherView.activityInPipCompat(): Boolean {
  if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
  return safe("activityInPipCompat", default = false) {
    resolveActivity()?.isInPictureInPictureMode == true
  }
}

// ─── Params ─────────────────────────────────────────────────────────────────

@RequiresApi(Build.VERSION_CODES.O)
internal fun HybridRtmpPublisherView.buildPipParams(): PictureInPictureParams {
  val builder = PictureInPictureParams.Builder()
  // Match the PIP window to the phone's screen aspect ratio so the floating
  // window is a scaled-down version of the on-screen preview. The preview view
  // size (== the screen content in fullscreen) is the source of truth; fall
  // back to the display metrics before it's been laid out. (buildPipParams
  // always runs on the main thread — via refreshPipParams / requestPictureInPicture
  // postToMain — so reading the View's width/height here is safe.)
  val metrics = context.resources.displayMetrics
  val w = openGlView.width.takeIf { it > 0 } ?: metrics.widthPixels
  val h = openGlView.height.takeIf { it > 0 } ?: metrics.heightPixels
  builder.setAspectRatio(clampPipRational(w, h))
  // Source-rect hint = on-screen preview bounds → smooth enter animation.
  val rect = Rect()
  if (openGlView.getGlobalVisibleRect(rect) && rect.width() > 0 && rect.height() > 0) {
    builder.setSourceRectHint(rect)
  }
  if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
    // Auto-enter on Home/Recents (only while armed) + smoother video resize.
    builder.setAutoEnterEnabled(pictureInPictureEnabled)
    builder.setSeamlessResizeEnabled(true)
  }
  return builder.build()
}

// Clamp to Android's accepted aspect band, biased portrait to match the stream.
private fun clampPipRational(width: Int, height: Int): Rational {
  val w = width.coerceAtLeast(1)
  val h = height.coerceAtLeast(1)
  val ratio = w.toFloat() / h.toFloat()
  return when {
    ratio < PIP_MIN_RATIO -> Rational(21, 50)   // 0.42 — steepest portrait we allow
    ratio > PIP_MAX_RATIO -> Rational(119, 50)   // 2.38 — widest landscape we allow
    else -> Rational(w, h)
  }
}

// setPictureInPictureParams keeps autoEnter + the portrait aspect fresh. Called
// on arm, on prepareVideo success, and after startStream (dims finalised).
internal fun HybridRtmpPublisherView.refreshPipParams() {
  if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
  postToMain {
    safe("refreshPipParams") {
      resolveActivity()?.setPictureInPictureParams(buildPipParams())
    }
  }
}

// ─── Entry ──────────────────────────────────────────────────────────────────

// Backing impl for the JS `enterPictureInPicture()` method. Returns whether the
// request was *accepted* (preconditions met + dispatched); the actual enter runs
// on main and the real enter/exit is reported via [onPipModeChanged].
internal fun HybridRtmpPublisherView.requestPictureInPicture(): Boolean {
  if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
  val activity = resolveActivity() ?: return false
  if (activityInPipCompat()) return false // already in PIP
  postToMain {
    safe("enterPictureInPicture") {
      activity.enterPictureInPictureMode(buildPipParams())
    }
  }
  return true
}

// ─── Observation ──────────────────────────────────────────────────────────

internal fun HybridRtmpPublisherView.registerPipListener() {
  // Resolve outside the lock (it can do a binder read); the check-then-add is
  // guarded so concurrent prop-set + setOnPictureInPictureChange can't double-add.
  val activity = resolveActivity() as? ComponentActivity ?: return
  synchronized(pipLock) {
    if (pipListenerRegistered) return
    safe("registerPipListener") {
      activity.addOnPictureInPictureModeChangedListener(pipModeListener)
      pipListenerRegistered = true
      // Seed current state so isInPictureInPicture() is correct immediately.
      isInPip = activityInPipCompat()
    }
  }
}

internal fun HybridRtmpPublisherView.unregisterPipListener() {
  val activity = (hostActivity ?: resolveActivity()) as? ComponentActivity
  synchronized(pipLock) {
    if (!pipListenerRegistered) return
    safe("unregisterPipListener") {
      activity?.removeOnPictureInPictureModeChangedListener(pipModeListener)
    }
    pipListenerRegistered = false
  }
}

// Fired by `pipModeListener` AFTER the transition completes.
internal fun HybridRtmpPublisherView.onPipModeChanged(inPip: Boolean) {
  isInPip = inPip
  postToMain { onPictureInPictureChange?.invoke(inPip) }
}
