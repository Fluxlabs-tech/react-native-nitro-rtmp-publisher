package com.margelo.nitro.rtmppublisher

/**
 * Auto-reconnect glue between Pedro's ConnectChecker callbacks and the
 * publisher's retry policy. The decision logic lives here so the
 * connectChecker in the main file can be a thin pass-through to JS events.
 */

// Outcome of an auto-reconnect attempt, so the caller can tell a genuine
// dead-end (no retry was queued, none is pending → declare terminal) apart from
// "a *different* failure this cycle already owns recovery" (ALREADY_IN_FLIGHT →
// drop this duplicate, DON'T declare terminal). ALREADY_IN_FLIGHT is the fix for
// the two-Pedro-threads-fail-microseconds-apart race: the loser of the
// compareAndSet below used to fall through to a terminal CONNECTIONFAILED while
// the winner's reTry was still queued and might yet succeed — abandoning a live
// retry and lying to JS.
internal enum class ReconnectOutcome { STARTED, ALREADY_IN_FLIGHT, TERMINAL }

internal fun HybridRtmpPublisherView.tryAutoReconnect(reason: String): ReconnectOutcome {
  // Gate order matters: the hard user-stop check comes first so a stopStream
  // racing an in-flight failure can't be overridden (M3).
  if (streamExplicitlyStopped) return ReconnectOutcome.TERMINAL
  if (!shouldBeStreaming) return ReconnectOutcome.TERMINAL
  if (autoReconnectMaxAttempts <= 0) return ReconnectOutcome.TERMINAL
  if (!surfaceReady) return ReconnectOutcome.TERMINAL
  val url = lastStreamUrl ?: return ReconnectOutcome.TERMINAL
  // S2: only one reconnect in flight per failure cycle. Two Pedro I/O threads can
  // fire onConnectionFailed microseconds apart (timeout + broken-pipe); without
  // this both would kick a restart and burn the retry budget twice. The CAS loser
  // reports ALREADY_IN_FLIGHT — the winner already armed a restart + dead-man for
  // this cycle, so the loser must NOT tear the stream down. Released when the
  // restart's startStreamInternal runs / onConnectionSuccess / terminal paths.
  if (!reconnectInProgress.compareAndSet(false, true)) return ReconnectOutcome.ALREADY_IN_FLIGHT
  // Wrapper-managed retry budget. We no longer use Pedro's setReTries counter
  // (that only drives its socket-only reTry, which we've stopped calling), so
  // the budget lives here: give up after autoReconnectMaxAttempts consecutive
  // attempts. Reset to 0 on a successful connect / fresh start.
  if (currentRetryAttempt >= autoReconnectMaxAttempts) {
    reconnectInProgress.set(false)
    return ReconnectOutcome.TERMINAL
  }
  // S5: escalate the backoff across consecutive attempts so we don't hammer a
  // dead / rate-limiting server.
  val attempt = currentRetryAttempt
  currentRetryAttempt = attempt + 1
  val backoff = escalatedBackoffMs(attempt)
  android.util.Log.i(
    TAG,
    "Auto-reconnect (full restart) attempt ${attempt + 1}/$autoReconnectMaxAttempts " +
      "in ${backoff}ms — reason: $reason"
  )
  beginFullRestart(url, backoff)
  return ReconnectOutcome.STARTED
}

// Network-change recovery, kept dead simple by product decision: a plain public
// stopStream() + startStream() cycle — the manual sequence that reliably
// re-homes RTMP onto the new interface (socket-level retry and in-place rebuilds
// do NOT; only a full stop+start does). Called on a default-network switch and
// after the crash guard suppresses a transport abort. stopStream() flips
// streamExplicitlyStopped/shouldBeStreaming, which gates off the failure-driven
// reconnect so the two paths can't fight; the delayed startStream restores them.
internal fun HybridRtmpPublisherView.restartStreamForNetworkChange(reason: String) {
  postToMain {
    if (streamExplicitlyStopped || !shouldBeStreaming || !surfaceReady) return@postToMain
    // Capture the URL BEFORE stopStream() (it nulls lastStreamUrl) — and the
    // dying session's network handle (it zeroes that too), for the re-label
    // check in the resume runnable below.
    val url = lastStreamUrl ?: return@postToMain
    val sessionNetworkHandle = activeNetworkHandle
    android.util.Log.i(TAG, "Recovery ($reason) → stop + restart stream")
    // Tell stopStream() to stamp the DISCONNECT with why we dropped, so JS can
    // distinguish a network switch / transport loss from a user stop.
    pendingDisconnectReason = reason
    stopStream()
    // stopStream() cancels any pending resume, so schedule ours AFTER it — and
    // a genuine USER stopStream() during the settle re-cancels this, so we don't
    // resurrect a stopped stream. startStream() itself clears the
    // streamExplicitlyStopped flag stopStream() just set. A short settle lets
    // the new interface finish coming up before the fresh connect.
    val r = Runnable {
      pendingResumeRunnable = null
      if (!surfaceReady) return@Runnable
      // The transport crash often lands BEFORE any ConnectivityManager callback
      // (the modem can drop the old bearer ahead of the default-network switch
      // announcement), so the failure-time reason can only guess. By NOW —
      // settle elapsed — the system has announced the new default, so re-check:
      // a different handle than the dead session's proves the drop was a network
      // switch. Emit the accurate cause on the RECONNECTING that precedes the
      // fresh start (the DISCONNECT already went out with the honest guess).
      val liveHandle = safe("relabel/activeNetwork", default = 0L) {
        connectivityManager?.activeNetwork?.networkHandle ?: 0L
      }
      val refined =
        if (sessionNetworkHandle != 0L && liveHandle != 0L && liveHandle != sessionNetworkHandle) {
          "network-changed(${currentTransportLabel()})"
        } else reason
      onConnectionEvent?.invoke(RtmpConnectionEvent.RECONNECTING, refined)
      startStream(url)
    }
    pendingResumeRunnable = r
    mainHandler.postDelayed(r, NETWORK_CHANGE_SETTLE_MS)
  }
}

// Shared full-restart mechanics for both the failure-driven (tryAutoReconnect)
// and network-change (rebuildForNetworkChange) paths: cleanly stop the wedged
// socket + release codecs, arm the dead-man across the whole window, and
// schedule a fresh startStreamInternal after `delayMs`. Caller owns the
// reconnectInProgress latch, the budget, and the RECONNECTING emit. Reuses the
// surface-resume runnable slot so a stopStream / onDropView during the wait
// cancels it.
internal fun HybridRtmpPublisherView.beginFullRestart(url: String, delayMs: Long) {
  mainHandler.removeCallbacks(restoreStreamModeRunnable)
  reconnectTuningActive = false
  safe("fullRestart/stopLiveStream") { stopLiveStreamTracked() }
  mainHandler.removeCallbacks(reconnectTimeoutRunnable)
  mainHandler.postDelayed(reconnectTimeoutRunnable, delayMs + reconnectTimeoutMs)
  cancelPendingResume()
  val r = Runnable {
    pendingResumeRunnable = null
    if (shouldBeStreaming && surfaceReady && !streamExplicitlyStopped && !camera.isStreaming) {
      // Full fresh start (reconnectSafe=false): stopLiveStreamTracked() above
      // already discarded the send-cache + encoders, so there's no stale
      // backlog to burst — the gentle tuning is only needed for socket-only
      // reTry, which we no longer use. fromAutoReconnect preserves the retry
      // budget across the restart so a dead server still goes terminal.
      startStreamInternal(lastStreamUrl ?: url, reconnectSafe = false, fromAutoReconnect = true)
    }
  }
  pendingResumeRunnable = r
  mainHandler.postDelayed(r, delayMs)
}

// base · 2^attempt, clamped to [base, MAX_RETRY_BACKOFF_MS]. `coerceIn(0,16)`
// keeps the Long shift well inside its 63-bit range (a count ≥64 wraps).
private fun HybridRtmpPublisherView.escalatedBackoffMs(attempt: Int): Long {
  val base = autoReconnectBackoffMs
  if (base <= 0L) return 0L
  val scaled = base shl attempt.coerceIn(0, 16)
  return scaled.coerceIn(base, MAX_RETRY_BACKOFF_MS)
}
