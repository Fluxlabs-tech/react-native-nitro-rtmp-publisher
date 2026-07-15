package com.margelo.nitro.rtmppublisher

import android.util.Log
import java.lang.ref.WeakReference

/**
 * Stops an abrupt RTMP(S) transport failure from CRASHING THE WHOLE APP.
 *
 * Pedro streams over ktor's CIO socket. On an abrupt transport loss — most
 * reliably a network-interface switch (Wi-Fi↔cellular) while publishing over
 * RTMPS — ktor's TLS encoder actor coroutine (`cio-tls-encoder`, on
 * `Dispatchers.IO`) throws from inside a coroutine Pedro never wraps:
 *
 *   FATAL EXCEPTION: DefaultDispatcher-worker-N
 *   java.io.IOException: Software caused connection abort
 *       at io.ktor.network.tls.TLSClientHandshake$output$1.invokeSuspend(...)
 *
 * kotlinx.coroutines routes that uncaught exception to the thread's default
 * uncaught-exception handler, which kills the process (device-confirmed: the
 * app PID changes on every switch). Because the process dies, NONE of the
 * reconnect / network-change logic can run — the stream "just never recovers."
 *
 * This installs a process-wide uncaught-exception handler that SWALLOWS only
 * that one benign shape — an `IOException` whose stack passes through
 * `io.ktor.*` — and delegates everything else untouched to the handler that
 * was already installed (so real crashes, and Crashlytics-style reporters,
 * are unaffected). After swallowing, it nudges the active publisher to
 * recover (a network switch also independently triggers the rebuild). An
 * RTMPS publisher losing its socket is a normal event to recover from, not a
 * reason to crash — so suppressing it is correct behaviour, not just a patch.
 */
internal object RtmpTransportCrashGuard {
  @Volatile private var installed = false
  @Volatile private var activeView: WeakReference<HybridRtmpPublisherView>? = null

  fun install(view: HybridRtmpPublisherView) {
    activeView = WeakReference(view)
    if (installed) return
    synchronized(this) {
      if (installed) return
      val previous = Thread.getDefaultUncaughtExceptionHandler()
      Thread.setDefaultUncaughtExceptionHandler { thread, error ->
        if (isBenignTransportCrash(error)) {
          Log.w(
            TAG,
            "Suppressed RTMP(S) transport exception on '${thread.name}' — the socket " +
              "aborted (e.g. a network switch). Recovering instead of crashing.",
            error
          )
          activeView?.get()?.onTransportCrashSuppressed()
          return@setDefaultUncaughtExceptionHandler
        }
        previous?.uncaughtException(thread, error)
      }
      installed = true
    }
  }

  fun clear(view: HybridRtmpPublisherView) {
    if (activeView?.get() === view) activeView = null
  }

  // Benign iff the throwable chain has an IOException AND any frame in it comes
  // from ktor (io.ktor.*) — i.e. it's a socket/TLS transport failure from the
  // RTMP pipeline, not an app bug that happens to reach the default handler.
  private fun isBenignTransportCrash(error: Throwable): Boolean {
    var current: Throwable? = error
    var depth = 0
    var sawIoException = false
    var sawKtorFrame = false
    while (current != null && depth < 10) {
      if (current is java.io.IOException) sawIoException = true
      if (current.stackTrace.any { it.className.startsWith("io.ktor.") }) sawKtorFrame = true
      if (sawIoException && sawKtorFrame) return true
      current = current.cause
      depth++
    }
    return false
  }
}
