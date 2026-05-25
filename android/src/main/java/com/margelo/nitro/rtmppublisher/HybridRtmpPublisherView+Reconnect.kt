package com.margelo.nitro.rtmppublisher

/**
 * Auto-reconnect glue between Pedro's ConnectChecker callbacks and the
 * publisher's retry policy. The decision logic lives here so the
 * connectChecker in the main file can be a thin pass-through to JS events.
 */

internal fun HybridRtmpPublisherView.tryAutoReconnect(reason: String): Boolean {
  if (!shouldBeStreaming) return false
  if (autoReconnectMaxAttempts <= 0) return false
  if (!surfaceReady) return false
  val queued = safe("reTry(auto)", default = false) {
    camera.streamClient.reTry(autoReconnectBackoffMs, reason, null)
  }
  if (queued) {
    // Arm the dead-man timer. Cleared on onConnectionSuccess, on a subsequent
    // permanent failure, or on stopStream / onDropView.
    mainHandler.removeCallbacks(reconnectTimeoutRunnable)
    mainHandler.postDelayed(reconnectTimeoutRunnable, autoReconnectBackoffMs + reconnectTimeoutMs)
  }
  return queued
}
