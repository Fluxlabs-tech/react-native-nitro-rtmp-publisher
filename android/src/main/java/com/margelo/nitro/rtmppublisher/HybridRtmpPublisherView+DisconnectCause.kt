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
      onDefaultNetworkAvailable(network)
    }
    override fun onLost(network: Network) {
      networkAvailable = false
      lastNetworkLossUptimeMs = SystemClock.elapsedRealtime()
    }
    override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
      networkTransport = transportLabelFor(caps)
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

// Called from the default-network callback's onAvailable. A new default
// network became available; if its handle differs from the one we were on AND
// we're mid-stream, the default network switched under us — the live RTMP
// socket is bound to the dead interface, so force a full rebuild bound to the
// new network. Fires PROACTIVELY (before Pedro even reports the socket break),
// and the reconnectInProgress latch dedups against the failure-driven path.
internal fun HybridRtmpPublisherView.onDefaultNetworkAvailable(network: Network) {
  val handle = network.networkHandle
  val prev = activeNetworkHandle
  // First network seen — baseline only; the normal connect path owns the
  // initial link (startStreamInternal re-baselines at every start anyway).
  if (prev == 0L) {
    activeNetworkHandle = handle
    return
  }
  if (prev == handle) return
  // Default network switched under a live stream → stop + restart. Deliberately
  // do NOT overwrite activeNetworkHandle here: it tracks the network the CURRENT
  // session is bound to (the restart's startStreamInternal re-baselines it), and
  // both the disconnect classifier's 3b check and the restart's late re-labeling
  // rely on the pre-switch value to recognize "the default moved under us".
  // Transport is read live — the cached networkTransport lags the switch (the
  // new network's onCapabilitiesChanged hasn't landed yet), which used to label
  // a cellular→wifi join "network-changed(cellular)".
  restartStreamForNetworkChange("network-changed(${currentTransportLabel()})")
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
    return "network-changed(${currentTransportLabel()})"
  }
  // 3b) The default network switched, but neither onLost nor the proactive
  //     onDefaultNetworkAvailable callback has updated our signals yet: both can
  //     land AFTER Pedro reports the dead socket, and a fresh interface coming up
  //     while the old one lingers fires no onLost at all (so the 5s window above
  //     misses it — this is the "network switch mislabeled server-closed" case).
  //     Compare the LIVE default-network handle against the one the current
  //     socket is bound to: a mismatch is a switch we haven't processed, so name
  //     it rather than falling through to the server-closed guess below. Reads
  //     the transport live (cached networkTransport also lags the switch).
  //     activeNetworkHandle==0L ⇒ never baselined ⇒ skip.
  val boundHandle = activeNetworkHandle
  if (boundHandle != 0L) {
    val liveHandle = connectivityManager?.activeNetwork?.networkHandle
    if (liveHandle != null && liveHandle != boundHandle) {
      return "network-changed(${currentTransportLabel()})"
    }
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

// Map a NetworkCapabilities to our coarse transport label. Shared by the
// onCapabilitiesChanged cache and the live read below so the two can't drift.
private fun transportLabelFor(caps: NetworkCapabilities): String = when {
  caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
  caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
  caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
  else -> "other"
}

// Transport of the CURRENT default network, read straight from the system so it
// reflects a just-completed switch even before our onCapabilitiesChanged lands.
// Falls back to the cached [networkTransport] on any read hiccup. internal: also
// used by restartStreamForNetworkChange's late re-labeling in +Reconnect.kt.
internal fun HybridRtmpPublisherView.currentTransportLabel(): String =
  safe("currentTransportLabel", default = networkTransport) {
    val net = connectivityManager?.activeNetwork ?: return@safe networkTransport
    val caps = connectivityManager?.getNetworkCapabilities(net) ?: return@safe networkTransport
    transportLabelFor(caps)
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
