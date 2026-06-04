package com.margelo.nitro.rtmppublisher

/**
 * Auto-reconnect glue between Pedro's ConnectChecker callbacks and the
 * publisher's retry policy. The decision logic lives here so the
 * connectChecker in the main file can be a thin pass-through to JS events.
 */

internal fun HybridRtmpPublisherView.tryAutoReconnect(reason: String): Boolean {
  // Gate order matters: the hard user-stop check comes first so a stopStream
  // racing an in-flight failure can't be overridden (M3).
  if (streamExplicitlyStopped) return false
  if (!shouldBeStreaming) return false
  if (autoReconnectMaxAttempts <= 0) return false
  if (!surfaceReady) return false
  // S2: only one reconnect in flight per failure cycle. Two Pedro I/O threads can
  // fire onConnectionFailed microseconds apart (timeout + broken-pipe); without
  // this both would call reTry and burn the retry budget twice. Released in
  // onConnectionStarted (handshake began) / onConnectionSuccess / terminal paths.
  if (!reconnectInProgress.compareAndSet(false, true)) return false
  // S5: escalate the backoff across consecutive attempts so we don't hammer a
  // dead / rate-limiting server. Reset to attempt 0 on success / fresh start.
  val attempt = currentRetryAttempt
  currentRetryAttempt = attempt + 1
  val backoff = escalatedBackoffMs(attempt)
  val queued = safe("reTry(auto)", default = false) {
    camera.streamClient.reTry(backoff, reason, null)
  }
  // S1/M2: arm the dead-man whenever a reconnect is *attempted* (not only when
  // Pedro confirms it queued — a partially-queued retry that hangs still needs a
  // timeout). Pedro waits `backoff` ms before it even calls connect, and only
  // then does onConnectionStarted fire to reset this to a fresh handshake-only
  // `reconnectTimeoutMs` window — so the INITIAL arm must include the backoff,
  // else a large/escalated backoff (up to 1h) gets guillotined mid-wait (B1).
  mainHandler.removeCallbacks(reconnectTimeoutRunnable)
  mainHandler.postDelayed(reconnectTimeoutRunnable, backoff + reconnectTimeoutMs)
  if (!queued) {
    // Pedro refused (budget exhausted / not in a retryable state). Release the
    // latch so a later failure can try again; the caller emits terminal failure.
    reconnectInProgress.set(false)
  }
  return queued
}

// base · 2^attempt, clamped to [base, MAX_RETRY_BACKOFF_MS]. `coerceIn(0,16)`
// keeps the Long shift well inside its 63-bit range (a count ≥64 wraps).
private fun HybridRtmpPublisherView.escalatedBackoffMs(attempt: Int): Long {
  val base = autoReconnectBackoffMs
  if (base <= 0L) return 0L
  val scaled = base shl attempt.coerceIn(0, 16)
  return scaled.coerceIn(base, MAX_RETRY_BACKOFF_MS)
}
