package com.margelo.nitro.rtmppublisher

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock

/**
 * Best-effort disconnect-cause classifier — Android mirror of
 * [HybridRtmpPublisherView+DisconnectCause.swift].
 *
 * RootEncoder surfaces a socket failure only as a raw reason string
 * (`onConnectionFailed(reason)`) or a bare `onDisconnect()` — identical whether
 * the phone lost its uplink, a call grabbed the mic, or the ingest server hung
 * up. This module correlates side-channels sampled at failure time to label the
 * cause in the emitted `onConnectionEvent` message (no API change — the message
 * string just gets more specific, e.g. `network-lost (broken pipe)`):
 *
 *  - [ConnectivityManager] default-network callback → network-lost /
 *    network-changed(iface)
 *  - [AudioManager.getMode]  → interrupted-by-call (cellular MODE_IN_CALL /
 *    VoIP MODE_IN_COMMUNICATION — no READ_PHONE_STATE permission required)
 *  - [PowerManager] thermal status → thermal-critical
 *  - sticky ACTION_BATTERY_CHANGED → low-battery (best effort only — a true
 *    battery death kills the process before any callback fires)
 *  - surface torn down → app-backgrounded; none of the above → server-closed
 *
 * Everything here is ADVISORY: a mislabel never changes reconnect behavior, it
 * only annotates the message, so the reads are deliberately cheap.
 */

// ─── ConnectivityManager lifecycle ──────────────────────────────────────────

internal fun HybridRtmpPublisherView.registerNetworkMonitor() {
  if (networkCallback != null) return
  val cm = connectivityManager ?: return
  val cb = object : ConnectivityManager.NetworkCallback() {
    override fun onAvailable(network: Network) {
      networkAvailable = true
    }
    override fun onLost(network: Network) {
      networkAvailable = false
      lastNetworkLossUptimeMs = SystemClock.elapsedRealtime()
    }
    override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
      networkTransport = when {
        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
        else -> "other"
      }
      networkAvailable = true
    }
  }
  safe("registerNetworkMonitor") {
    cm.registerDefaultNetworkCallback(cb)
    networkCallback = cb
  }
}

internal fun HybridRtmpPublisherView.unregisterNetworkMonitor() {
  val cm = connectivityManager ?: return
  val cb = networkCallback ?: return
  safe("unregisterNetworkMonitor") { cm.unregisterNetworkCallback(cb) }
  networkCallback = null
}

// ─── Classifier ─────────────────────────────────────────────────────────────

/**
 * Label a raw RootEncoder failure reason with a likely cause, e.g.
 * `"network-lost (broken pipe)"`. The bare category comes from
 * [disconnectCauseCategory]; a non-blank raw reason is appended for diagnostics.
 */
internal fun HybridRtmpPublisherView.classifyDisconnectCause(rawReason: String): String {
  val category = disconnectCauseCategory()
  return if (rawReason.isBlank()) category else "$category ($rawReason)"
}

/**
 * The bare cause category, ordered most-specific/decisive first so a single
 * dominant signal wins. Shared by the failure path and the silent-stall
 * watchdog. See the file header for what each signal means.
 */
internal fun HybridRtmpPublisherView.disconnectCauseCategory(): String {
  // 1) Surface gone = app backgrounded (Pedro's socket dies with the surface).
  //    Note: both terminal call-sites early-return while !surfaceReady, so this
  //    is a defensive fallback rather than a common path.
  if (!surfaceReady) return "app-backgrounded"

  // 2) Phone call / VoIP — read the audio mode (no permission needed). A
  //    definitive local signal, so it outranks a network read (the call is WHY
  //    the mic/link idled).
  val mode = audioManager?.mode
  if (mode == AudioManager.MODE_IN_CALL || mode == AudioManager.MODE_IN_COMMUNICATION) {
    return "interrupted-by-call"
  }

  // 3) Uplink gone — currently unavailable, or dropped within the last 5s (a
  //    Wi-Fi↔cellular handoff re-attaches quickly but still kills the in-flight
  //    socket, so a bare "currently available" check would miss it).
  val now = SystemClock.elapsedRealtime()
  if (!networkAvailable) return "network-lost"
  if (lastNetworkLossUptimeMs > 0 && now - lastNetworkLossUptimeMs < 5_000) {
    return "network-changed($networkTransport)"
  }

  // 4) Thermal shutdown pressure.
  if (isThermalCritical()) return "thermal-critical"

  // 5) Battery critically low & unplugged — best effort: a real battery death
  //    kills us before any callback fires, so this catches at most the last gasp.
  if (isBatteryCriticallyLow()) return "low-battery"

  // 6) Link's up, no local cause → the server hung up on us (idle timeout, key
  //    expiry, ingest restart, rate-limit, …).
  return "server-closed"
}

private fun HybridRtmpPublisherView.isThermalCritical(): Boolean {
  if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
  // Prefer the cached value the thermal listener keeps fresh; otherwise a single
  // binder call. THERMAL_STATUS_CRITICAL and above means the OS is actively
  // throttling / about to shut components down.
  val status = if (thermalListenerRegistered) {
    lastThermalStatusInt
  } else {
    safe("thermalStatusForCause", default = PowerManager.THERMAL_STATUS_NONE) {
      powerManager?.currentThermalStatus ?: PowerManager.THERMAL_STATUS_NONE
    }
  }
  return status >= PowerManager.THERMAL_STATUS_CRITICAL
}

private fun HybridRtmpPublisherView.isBatteryCriticallyLow(): Boolean {
  return safe("batteryForCause", default = false) {
    // Sticky broadcast → returns the last battery state synchronously, no
    // receiver registration and no permission.
    val intent: Intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
      ?: return@safe false
    val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
    val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
    val statusInt = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
    if (level < 0 || scale <= 0) return@safe false
    val pct = level.toFloat() / scale.toFloat()
    val charging = statusInt == BatteryManager.BATTERY_STATUS_CHARGING ||
      statusInt == BatteryManager.BATTERY_STATUS_FULL
    pct < 0.05f && !charging
  }
}
