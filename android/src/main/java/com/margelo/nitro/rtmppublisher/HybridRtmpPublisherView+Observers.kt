package com.margelo.nitro.rtmppublisher

import android.os.Build
import android.os.PowerManager
import androidx.core.content.ContextCompat

/**
 * OS observers that the view opts into: device-orientation (drives auto-stream
 * rotation) and PowerManager.OnThermalStatusChangedListener (drives the
 * thermal-warning event JS subscribes to). Both are lazy — registered only
 * when there's an actual subscriber on the JS side.
 */

// ─── Orientation ──────────────────────────────────────────────────────────

internal fun HybridRtmpPublisherView.enableOrientationListener() {
  if (!autoRotateStream) return
  if (orientationListener.canDetectOrientation()) {
    safe("enableOrientationListener") { orientationListener.enable() }
  }
}

internal fun HybridRtmpPublisherView.disableOrientationListener() {
  safe("disableOrientationListener") { orientationListener.disable() }
  lastAutoAppliedRotation = -1
}

// ─── Thermal ──────────────────────────────────────────────────────────────

// `synchronized(thermalLock)` guards the check-then-set so two concurrent
// `setOnThermalWarning` calls can't both pass the registered check and
// double-subscribe (which would leave one listener stuck after the matching
// unregister). The lock object lives on the view; the helpers extend it.
internal fun HybridRtmpPublisherView.registerThermalListener() {
  if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
  val listener = thermalListener ?: return
  val pm = powerManager ?: return
  synchronized(thermalLock) {
    if (thermalListenerRegistered) return
    safe("registerThermalListener") {
      pm.addThermalStatusListener(ContextCompat.getMainExecutor(context), listener)
      lastThermalStatusInt = pm.currentThermalStatus
      thermalListenerRegistered = true
    }
  }
}

internal fun HybridRtmpPublisherView.unregisterThermalListener() {
  if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
  val listener = thermalListener ?: return
  val pm = powerManager ?: return
  synchronized(thermalLock) {
    if (!thermalListenerRegistered) return
    safe("unregisterThermalListener") {
      pm.removeThermalStatusListener(listener)
    }
    thermalListenerRegistered = false
  }
}

internal fun HybridRtmpPublisherView.onThermalStatusChanged(newStatus: Int) {
  val previous = lastThermalStatusInt
  lastThermalStatusInt = newStatus

  // Auto-degrade the beauty filter under thermal pressure: highp → mediump at
  // SEVERE+, restore at LIGHT/NONE. MODERATE is a hysteresis dead zone so an
  // oscillation around the boundary doesn't recompile the GL program every
  // tick. No-op on budget devices (already mediump) and when beauty is off.
  val wantDowngrade = when {
    newStatus >= PowerManager.THERMAL_STATUS_SEVERE -> true
    newStatus <= PowerManager.THERMAL_STATUS_LIGHT -> false
    else -> beautyThermalDowngrade
  }
  if (wantDowngrade != beautyThermalDowngrade) {
    beautyThermalDowngrade = wantDowngrade
    if (desiredBeautyFilter) applyBeautyFilter()
  }

  val threshold = thermalThresholdLevel
  // Fire when:
  //  - new state >= threshold (entering / staying in warning zone), OR
  //  - previous state was >= threshold AND new state is < threshold (clearing).
  val enteringOrInZone = newStatus >= threshold
  val justCleared = previous >= threshold && newStatus < threshold
  if (enteringOrInZone || justCleared) {
    onThermalWarning?.invoke(newStatus.fromPowerManagerStatus())
  }
}
