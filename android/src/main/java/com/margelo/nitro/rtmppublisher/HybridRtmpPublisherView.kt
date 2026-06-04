package com.margelo.nitro.rtmppublisher

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import android.view.OrientationEventListener
import android.view.SurfaceHolder
import android.view.View
import androidx.core.app.PictureInPictureModeChangedInfo
import androidx.core.util.Consumer
import com.pedro.common.ConnectChecker
import com.pedro.encoder.input.video.CameraHelper
import com.pedro.library.base.recording.RecordController
import com.pedro.library.rtmp.RtmpCamera2
import com.pedro.library.util.BitrateAdapter
import com.pedro.library.view.OpenGlView
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Nitro HybridView that wraps RootEncoder's [RtmpCamera2] + [OpenGlView] and
 * exposes the publisher API to JavaScript.
 *
 * All per-frame paths (camera capture, GL render, H.264/AAC encode, RTMP TX)
 * stay native — the JS bridge is only touched on lifecycle, state changes,
 * and (opt-in) bitrate / record-status updates.
 *
 * **File layout.** Kotlin requires every `override fun` to live in this class
 * body, so the spec implementations and tightly-coupled callback objects
 * (ConnectChecker, SurfaceHolder.Callback, RecordController.Listener) stay
 * here. The topical extensions live in sibling files:
 *
 *  - [HybridRtmpPublisherView+Helpers.kt]         — `safe`, `postToMain`,
 *    `cancelPendingResume`
 *  - [HybridRtmpPublisherView+Encoders.kt]        — codec/mirror/audio setup,
 *    `rePrepareEncodersIfNeeded`, `applyStreamMode`
 *  - [HybridRtmpPublisherView+SystemHooks.kt]     — wakelock, keep-screen-on,
 *    foreground service
 *  - [HybridRtmpPublisherView+Observers.kt]       — orientation + thermal
 *  - [HybridRtmpPublisherView+Reconnect.kt]       — `tryAutoReconnect`
 *  - [PublisherMappings.kt]                       — enum mappers
 *  - [PublisherTypes.kt]                          — data classes + constants
 */
@SuppressLint("ViewConstructor")
class HybridRtmpPublisherView(internal val context: Context) : HybridRtmpPublisherViewSpec() {

  // ─── Native views & encoder ──────────────────────────────────────────────

  internal val openGlView = OpenGlView(context)

  @Volatile internal var onConnectionEvent: ((RtmpConnectionEvent, String) -> Unit)? = null
  @Volatile internal var onBitrateChange: ((Double) -> Unit)? = null
  @Volatile internal var onStreamStats: ((Double, Double) -> Unit)? = null
  @Volatile internal var onRecordStatusChange: ((RecordStatus) -> Unit)? = null
  @Volatile internal var onThermalWarning: ((ThermalStatus) -> Unit)? = null

  // Last known preview config. Kept alive across surface destroy/create cycles
  // (host activity background/foreground, rotation) so the preview auto-restores.
  // Cleared only on explicit `stopPreview()` or `onDropView()`.
  internal var lastPreview: PreviewConfig? = null
  // @Volatile: written by JS-thread startStream (768) and main-thread
  // surfaceDestroyed (seed), read in surfaceCreated (resume). The two fields are
  // logically paired, so a torn read would resume with the wrong URL/delay.
  @Volatile internal var pendingStream: String? = null
  // When the surface is destroyed while streaming, we save the URL here so
  // surfaceCreated can re-publish automatically (matches iOS' foreground-resume
  // behaviour in appWillEnterForeground). Carries a delay so the cached
  // pendingStream path (initial mount race) stays zero-delay.
  @Volatile internal var pendingStreamDelayMs: Long = 0L
  // Last URL passed to startStream. Used to seed the auto-resume on the next
  // surface restoration. Cleared on explicit stopStream / onDropView.
  @Volatile internal var lastStreamUrl: String? = null
  // Cancellable handle for the delayed resume. @Volatile because cancelPendingResume
  // may be reached from a Nitro-dispatched method on a non-main thread depending
  // on how the host configures the view bridge; the writes happen on main
  // (surfaceCreated callback) and reads cross-thread must see the latest ref.
  @Volatile internal var pendingResumeRunnable: Runnable? = null

  // One-shot: did we already emit DISCONNECT for the current session? Set by
  // the surface-destroyed path, cleared in startStreamInternal /
  // onConnectionSuccess. Used to suppress the second DISCONNECT that Pedro's
  // own onDisconnect callback would otherwise fire just after we tore the
  // socket down ourselves.
  @Volatile internal var disconnectEmitted = false

  // Warn-once on POST_NOTIFICATIONS: the FG-service preflight is called on
  // every startStreamInternal (including the auto-resume after bg→fg), and
  // spamming the log on every cycle is noise. Reset on stopStream / onDropView.
  @Volatile internal var postNotificationsWarned = false

  // Mutex for thermal listener register/unregister so two concurrent
  // setOnThermalWarning calls can't both pass the registered check and
  // double-subscribe.
  internal val thermalLock = Any()

  // @Volatile: written on main (surface callbacks), read on main in tryAutoReconnect
  // but also consulted from the JS-thread startStream gate — keep visibility
  // consistent with shouldBeStreaming / disconnectEmitted.
  @Volatile internal var surfaceReady = false

  // Encoder prepare-state caches. RootEncoder's BaseEncoder.stop() releases the
  // MediaCodec and flips `prepared` to false, so the next startStream would
  // throw IllegalStateException("not prepared yet"). We cache the last-known
  // prepareVideo / prepareAudio args and silently re-prepare in startStream so
  // JS can stop+start repeatedly without having to call prepare* again.
  internal var lastVideoCfg: VideoCfg? = null
  internal var lastAudioCfg: AudioCfg? = null
  @Volatile internal var videoPrepared = false
  @Volatile internal var audioPrepared = false

  // Auto-reconnect config + state.
  //
  // Default ON (5 attempts / 2s base backoff): a library that ships with
  // reconnect *off* silently gives apps no recovery from the common mid-stream
  // network blip — the dominant "stream failed and never came back" report. Opt
  // out explicitly with setAutoReconnect(0, 0). @Volatile because setAutoReconnect
  // writes on the JS/Nitro thread while tryAutoReconnect reads on main (and a
  // 64-bit Long can tear on 32-bit ARM without it).
  @Volatile internal var autoReconnectMaxAttempts = 5
  @Volatile internal var autoReconnectBackoffMs = 2_000L
  // Warn-once if a stream starts with reconnect explicitly disabled, so the
  // "gave up immediately" failure is distinguishable from "never configured".
  @Volatile internal var autoReconnectDisabledWarned = false

  // User intent to NOT stream: set by stopStream / onDropView, cleared by
  // startStream(Internal). The FIRST gate in tryAutoReconnect — distinct from
  // surfaceReady (surface lifecycle) and shouldBeStreaming (which also clears on
  // terminal failure). A transient surface loss (background / rotate / PIP) must
  // NOT look like an explicit stop, or auto-reconnect dies on every backgrounding.
  @Volatile internal var streamExplicitlyStopped = false

  // Session epoch, bumped just before each fresh camera.startStream. Stale
  // ConnectChecker callbacks from a torn-down session (still queued on Pedro's
  // I/O thread) capture the old value and bail, so they can't emit out-of-order
  // events or retry against the new session. Mirrors iOS' pipelineGeneration.
  // Best-effort on Android: Pedro reuses one ConnectChecker across sessions, so
  // a callback Pedro happens to invoke *after* the bump won't be caught here —
  // the disconnectEmitted dedup + reconnectInProgress latch cover that residue.
  @Volatile internal var pipelineGeneration = 0L

  // One reconnect in flight per failure cycle. Two Pedro I/O threads can fire
  // onConnectionFailed microseconds apart (timeout + broken-pipe); without this
  // both call reTry and burn the retry budget 2x. compareAndSet-guarded in
  // tryAutoReconnect; released in onConnectionStarted (retry handshake began),
  // onConnectionSuccess, and every terminal-failure path.
  internal val reconnectInProgress = AtomicBoolean(false)
  // Consecutive auto-reconnect attempts since the last success, for escalating
  // backoff (base · 2^attempt). Reset on success / fresh start. Touched on main.
  @Volatile internal var currentRetryAttempt = 0

  // Dead-man timer for auto-reconnect. Pedro's streamClient.reTry() can queue
  // a retry that never completes (TCP hang, DNS stall) without firing another
  // onConnectionFailed — without this, shouldBeStreaming stays true forever
  // and JS sits in RECONNECTING with nothing to react to.
  internal val mainHandler = Handler(Looper.getMainLooper())
  // Measured from handshake start (reset in onConnectionStarted), not from
  // queue+backoff time — 45s of pure handshake is generous even for a distant /
  // congested ingest, so this only bites a genuinely hung reconnect.
  internal val reconnectTimeoutMs = 45_000L
  internal val reconnectTimeoutRunnable = Runnable {
    if (shouldBeStreaming && !camera.isStreaming) {
      Log.w(TAG, "Auto-reconnect timed out after ${reconnectTimeoutMs}ms")
      shouldBeStreaming = false
      reconnectInProgress.set(false)
      currentRetryAttempt = 0
      releaseWakeLock()
      setKeepScreenOn(false)
      onConnectionEvent?.invoke(
        RtmpConnectionEvent.CONNECTIONFAILED,
        "reconnect timed out"
      )
    }
  }

  // Silent-stall watchdog (M1/S7). A half-open socket — NAT/firewall idle
  // timeout, Wi-Fi↔LTE handover, Android 14 bg camera/mic revocation — leaves
  // camera.isStreaming==true while zero bytes reach the server and Pedro fires
  // NO failure callback. onNewBitrate then reports bitrate==0 every ~1s tick but
  // the original code only forwarded it. We count consecutive zero-bitrate ticks
  // and force a reconnect (or surface terminal failure) once we're confident the
  // pipe is dead. Touched only on main (onNewBitrate runs via postToMain).
  internal var stallTicks = 0

  // bg→fg resume backoff (S6). Rapid surface recycles (orientation/PIP loops)
  // shouldn't re-publish into the same just-broken network every 1.5s; escalate
  // the resume delay (1.5/3/5s) when destroys come back-to-back. Reset on a
  // healthy onConnectionSuccess. Touched only on main.
  private var lastSurfaceDestroyMs = 0L
  private var resumeDelayLevel = 0

  // Adaptive bitrate. Null when disabled.
  @Volatile internal var bitrateAdapter: BitrateAdapter? = null

  // Baselines for deriving live video fps (for onStreamStats) from the sender's
  // cumulative sent-video-frame count, sampled each onNewBitrate tick (~1s).
  // Reset on stream start. Touched only on main (onNewBitrate runs via postToMain).
  private var lastSentVideoFrames = 0L
  private var lastStatsTsMs = 0L
  // True between `startStream` and an explicit `stopStream` / drop / surface loss.
  // Gates auto-reconnect so we don't retry against a torn-down camera/surface.
  @Volatile internal var shouldBeStreaming = false

  // True iff WE started the FG service (so we know it's safe to stop it on
  // stopStream / drop without yanking some other component's notification).
  internal var fgServiceStartedByUs = false

  // True iff this instance currently holds the single active-publisher slot.
  // Set in startPreviewInternal, cleared in onDropView. Used so multiple
  // mounted views fail loudly instead of silently fighting for the camera.
  internal var holdsActiveSlot = false

  // Thermal monitoring. The OS listener is only registered after JS subscribes
  // via `setOnThermalWarning` — if you never subscribe, the library never
  // touches PowerManager.
  internal var thermalThresholdLevel = PowerManager.THERMAL_STATUS_SEVERE
  @Volatile internal var lastThermalStatusInt = PowerManager.THERMAL_STATUS_NONE
  internal var thermalListenerRegistered = false
  internal val thermalListener =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
      PowerManager.OnThermalStatusChangedListener { status -> onThermalStatusChanged(status) }
    else null

  // Force-FPS-limit state. When true, Camera2 AE_TARGET_FPS_RANGE is locked
  // to [fps, fps]; otherwise auto-exposure can drop to 15fps in low light.
  // The actual call into RootEncoder needs preview to be alive, so we cache
  // the desired value and reapply after each startPreview.
  internal var desiredForceFpsLimit = true

  // Beauty filter. The render lives in the GL pipeline, which is only alive
  // once preview is up — so we cache the desired on/off state and (re)apply it
  // after each startPreview. `beautyFilter` holds the live render instance
  // while it's attached (null when detached). It is always our own
  // [WhiteningBeautyFilterRender] (fair/bright look, not the stock reddish one);
  // only its shader PRECISION is chosen at attach time — highp on capable GPUs,
  // mediump on budget GPUs / under thermal pressure (see [applyBeautyFilter]).
  internal var desiredBeautyFilter = false
  internal var beautyFilter: WhiteningBeautyFilterRender? = null
  // Set when thermal pressure (SEVERE+) forces a running highp beauty filter
  // down to the cheaper mediump shader; cleared when the device cools back to
  // LIGHT/NONE. Driven from the thermal observer (onThermalStatusChanged).
  @Volatile internal var beautyThermalDowngrade = false

  // Orientation listener. Drives setStreamRotation automatically when
  // `autoRotateStream` is true.
  @Volatile internal var lastAutoAppliedRotation = -1
  internal val orientationListener: OrientationEventListener =
    object : OrientationEventListener(context) {
      override fun onOrientationChanged(orientation: Int) {
        if (orientation == ORIENTATION_UNKNOWN) return
        // Snap to nearest 90°. The mapping flips so the *stream* stays upright
        // when the device is held in landscape.
        val rotation = when ((orientation + 45) % 360 / 90) {
          1 -> 270   // landscape right
          2 -> 180   // upside down
          3 -> 90    // landscape left
          else -> 0  // portrait
        }
        if (rotation == lastAutoAppliedRotation) return
        lastAutoAppliedRotation = rotation
        safe("autoRotate") { camera.glInterface.setStreamRotation(rotation) }
      }
    }

  internal var wakeLock: PowerManager.WakeLock? = null

  // Cached system service lookup. Cheap individually but called from hot-ish
  // paths (acquireWakeLock, thermal register/getter); the cache avoids
  // repeated ContextImpl HashMap lookups.
  internal val powerManager: PowerManager? by lazy {
    context.getSystemService(Context.POWER_SERVICE) as? PowerManager
  }

  internal val recordListener = RecordController.Listener { status ->
    val nitro = status.toNitro()
    postToMain { onRecordStatusChange?.invoke(nitro) }
  }

  // Pedro fires ConnectChecker callbacks from its RTMP I/O coroutine threads.
  // We force every JS-bound emission onto the main thread so the Nitro callback
  // and any subsequent state writes (shouldBeStreaming, wakelock, screen-on,
  // reconnect timer, bitrate-adapter mutation) all happen on one thread —
  // removes the read-decide-write window between Pedro thread and main thread.
  internal val connectChecker = object : ConnectChecker {
    // Each callback snapshots `pipelineGeneration` on Pedro's thread BEFORE the
    // main-thread hop and bails on mismatch, so a stale callback from a
    // torn-down session can't poison the current one (M7).
    override fun onConnectionStarted(url: String) {
      val gen = pipelineGeneration
      postToMain {
        if (gen != pipelineGeneration) return@postToMain
        // Measure the dead-man from handshake start, not from queue+backoff time
        // — otherwise a slow-but-valid reconnect gets guillotined at T+30s while
        // the socket is actually coming up (M2). Covers the initial connect too.
        mainHandler.removeCallbacks(reconnectTimeoutRunnable)
        mainHandler.postDelayed(reconnectTimeoutRunnable, reconnectTimeoutMs)
        // The retry handshake has begun — release the in-flight latch so a
        // genuine *new* failure (this handshake failing) starts a fresh cycle (S2).
        reconnectInProgress.set(false)
        onConnectionEvent?.invoke(RtmpConnectionEvent.CONNECTIONSTARTED, url)
      }
    }
    override fun onConnectionSuccess() {
      val gen = pipelineGeneration
      postToMain {
        if (gen != pipelineGeneration) return@postToMain
        mainHandler.removeCallbacks(reconnectTimeoutRunnable)
        reconnectInProgress.set(false)
        currentRetryAttempt = 0
        stallTicks = 0
        resumeDelayLevel = 0
        disconnectEmitted = false
        onConnectionEvent?.invoke(RtmpConnectionEvent.CONNECTIONSUCCESS, "")
      }
    }
    override fun onConnectionFailed(reason: String) {
      val gen = pipelineGeneration
      postToMain {
        if (gen != pipelineGeneration) return@postToMain
        // Surface recycle (bg / rotate / PIP) tears the socket and seeds
        // pendingStream — the surfaceCreated resume path owns the restart, so
        // don't double-report it as a terminal failure here (S3).
        if (!surfaceReady || pendingStream != null) return@postToMain
        if (tryAutoReconnect(reason)) {
          onConnectionEvent?.invoke(RtmpConnectionEvent.RECONNECTING, reason)
        } else {
          mainHandler.removeCallbacks(reconnectTimeoutRunnable)
          shouldBeStreaming = false
          reconnectInProgress.set(false)
          currentRetryAttempt = 0
          disconnectEmitted = false
          releaseWakeLock()
          setKeepScreenOn(false)
          onConnectionEvent?.invoke(RtmpConnectionEvent.CONNECTIONFAILED, reason)
        }
      }
    }
    override fun onNewBitrate(bitrate: Long) {
      val gen = pipelineGeneration
      postToMain {
        if (gen != pipelineGeneration) return@postToMain
        // ── Silent-stall watchdog (M1) ──────────────────────────────────────
        // A half-open socket leaves camera.isStreaming==true with Pedro firing
        // no failure callback, but onNewBitrate keeps ticking at bitrate==0 (no
        // bytes acked over this ~1s window). STALL_TICKS zeros in a row while we
        // believe we're live ⇒ the pipe is dead. Try to reconnect; if reconnect
        // can't run (disabled / surface gone / budget gone), surface a terminal
        // failure so JS stops showing a stream that isn't reaching the server —
        // the headline "no output detected" bug. A nonzero tick (incl. the
        // bitrate adapter's congestion floor — still > 0) resets the counter, so
        // a slow-but-alive link is never torn down here.
        if (shouldBeStreaming && camera.isStreaming && bitrate <= 0L) {
          stallTicks++
          if (stallTicks >= STALL_TICKS && !reconnectInProgress.get()) {
            Log.w(TAG, "Silent stall: no bytes flowing for ${stallTicks}s — forcing reconnect")
            stallTicks = 0
            if (tryAutoReconnect("silent stall: no bytes flowing")) {
              onConnectionEvent?.invoke(RtmpConnectionEvent.RECONNECTING, "silent stall: no bytes flowing")
            } else {
              mainHandler.removeCallbacks(reconnectTimeoutRunnable)
              shouldBeStreaming = false
              reconnectInProgress.set(false)
              currentRetryAttempt = 0
              disconnectEmitted = false
              safe("stopStream(stall)") {
                if (camera.isStreaming) {
                  camera.stopStream()
                  videoPrepared = false
                  audioPrepared = false
                }
              }
              releaseWakeLock()
              setKeepScreenOn(false)
              onConnectionEvent?.invoke(RtmpConnectionEvent.CONNECTIONFAILED, "silent stall: no bytes flowing")
            }
            return@postToMain
          }
        } else {
          stallTicks = 0
        }
        // Feed adaptive-bitrate adapter if enabled. It calls back into
        // `setVideoBitrateOnFly` via its listener, no allocation per tick.
        bitrateAdapter?.let { adapter ->
          val congested = safe("hasCongestion", default = false) {
            camera.streamClient.hasCongestion()
          }
          safe("adaptBitrate") { adapter.adaptBitrate(bitrate, congested) }
        }
        onBitrateChange?.invoke(bitrate.toDouble())
        // Live video fps for onStreamStats: derive from the sender's cumulative
        // sent-video-frame count over this tick. getSentVideoFrames() restarts at
        // 0 on a fresh stream, so a backwards step means "new stream" → baseline.
        onStreamStats?.let { cb ->
          val nowMs = SystemClock.elapsedRealtime()
          val sent = safe("getSentVideoFrames", default = lastSentVideoFrames) {
            camera.streamClient.getSentVideoFrames()
          }
          val base = if (sent < lastSentVideoFrames) 0L else lastSentVideoFrames
          val fps =
            if (lastStatsTsMs == 0L) 0.0
            else (sent - base) * 1000.0 / (nowMs - lastStatsTsMs).coerceAtLeast(1L)
          lastSentVideoFrames = sent
          lastStatsTsMs = nowMs
          cb.invoke(bitrate.toDouble(), fps)
        }
      }
    }
    override fun onDisconnect() {
      val gen = pipelineGeneration
      postToMain {
        if (gen != pipelineGeneration) return@postToMain
        // Surface recycle already emitted DISCONNECT + seeded the resume — let
        // that path own it instead of retrying against a dead surface (S3).
        if (!surfaceReady || pendingStream != null) {
          disconnectEmitted = false
          return@postToMain
        }
        if (tryAutoReconnect("disconnect")) {
          onConnectionEvent?.invoke(RtmpConnectionEvent.RECONNECTING, "disconnect")
        } else {
          mainHandler.removeCallbacks(reconnectTimeoutRunnable)
          shouldBeStreaming = false
          reconnectInProgress.set(false)
          currentRetryAttempt = 0
          releaseWakeLock()
          setKeepScreenOn(false)
          // Suppress the duplicate when surfaceDestroyed already emitted
          // DISCONNECT — Pedro fires its own onDisconnect a moment after our
          // synchronous teardown and JS would otherwise see two in a row.
          if (!disconnectEmitted) {
            onConnectionEvent?.invoke(RtmpConnectionEvent.DISCONNECT, "")
          }
          disconnectEmitted = false
        }
      }
    }
    override fun onAuthError() {
      val gen = pipelineGeneration
      postToMain {
        if (gen != pipelineGeneration) return@postToMain
        onConnectionEvent?.invoke(RtmpConnectionEvent.AUTHERROR, "")
      }
    }
    override fun onAuthSuccess() {
      val gen = pipelineGeneration
      postToMain {
        if (gen != pipelineGeneration) return@postToMain
        onConnectionEvent?.invoke(RtmpConnectionEvent.AUTHSUCCESS, "")
      }
    }
  }

  internal val camera: RtmpCamera2 = RtmpCamera2(openGlView, connectChecker)

  // ─── Picture-in-Picture ───────────────────────────────────────────────────
  // System PIP is a per-Activity concept, so the library observes the host
  // Activity (resolved + cached in `hostActivity`) rather than owning it. The
  // observer (`pipModeListener`) is registered lazily — only when PIP is armed
  // via the `pictureInPictureEnabled` prop or a `setOnPictureInPictureChange`
  // subscription — mirroring the thermal-listener pattern. All the logic lives
  // in [HybridRtmpPublisherView+Pip.kt].
  @Volatile internal var isInPip = false
  @Volatile internal var hostActivity: Activity? = null
  // Guards the check-then-register/unregister of `pipModeListener` so a near-
  // simultaneous prop-set (UI thread) and `setOnPictureInPictureChange` (JS
  // thread) at mount can't both pass the check and double-add the listener
  // (which would double-fire the JS callback and leak one listener on drop).
  // Mirrors the thermal-listener pattern (`thermalLock`).
  internal val pipLock = Any()
  @Volatile internal var pipListenerRegistered = false
  @Volatile internal var onPictureInPictureChange: ((Boolean) -> Unit)? = null
  // Stable reference so add/remove pair up. androidx's listener works on all API
  // levels (never fires below 24); the platform PIP calls themselves are gated
  // 24/26+ at their call sites. See [onPipModeChanged].
  internal val pipModeListener =
    Consumer<PictureInPictureModeChangedInfo> { info ->
      onPipModeChanged(info.isInPictureInPictureMode)
    }

  // Scopes PIP auto-enter to while the stream view is the on-screen content.
  // `setAutoEnterEnabled` is an Activity-GLOBAL flag, so without this it would
  // stay armed after the user navigates away and EVERY screen would enter PIP on
  // background (the reported bug). react-native-screens detaches inactive
  // screens, so leaving the stream screen detaches this view → we clear
  // autoEnter; returning re-arms it (when `pictureInPictureEnabled`). The manual
  // `enterPictureInPicture()` path is unaffected. Registered in `init`, removed
  // in `onDropView`.
  internal val pipAttachListener = object : View.OnAttachStateChangeListener {
    override fun onViewAttachedToWindow(v: View) {
      if (pictureInPictureEnabled) refreshPipParams()
    }
    override fun onViewDetachedFromWindow(v: View) {
      if (pictureInPictureEnabled) disarmPipAutoEnter()
    }
  }

  // Held as a field so onDropView can remove it. Surface-lifecycle callbacks
  // firing on a dropped view would touch a half-released camera and is exactly
  // the kind of "subtle crash 5s after navigation" we want to avoid.
  private val surfaceCallback = object : SurfaceHolder.Callback {
    override fun surfaceCreated(holder: SurfaceHolder) {
      surfaceReady = true
      // Re-open the camera every time the surface comes back (first mount AND
      // background→foreground / rotation).
      val previewOk = lastPreview?.let { p ->
        startPreviewInternal(p.facing, p.width, p.height)
      }
      // If preview was requested AND failed (active-slot collision is the
      // realistic case), bail before touching the stream pipeline — Pedro
      // requires preview to be live to start the encoder.
      if (previewOk == false) return

      pendingStream?.let { url ->
        val delay = pendingStreamDelayMs
        pendingStream = null
        pendingStreamDelayMs = 0L
        if (delay > 0L) {
          // Foreground-resume path. Match iOS' 1500ms grace so:
          //  (1) Android can finish restoring networking after the bg→fg
          //      transition (otherwise the first publish often hits ECONNRESET),
          //  (2) ingests like Facebook Live / YouTube release the previous
          //      session lock — re-publishing immediately under the same
          //      stream key hits NetStream.Publish.BadName.
          onConnectionEvent?.invoke(RtmpConnectionEvent.RECONNECTING, "foreground")
          val r = Runnable {
            pendingResumeRunnable = null
            // Re-read at fire time: JS may have called startStream(newUrl) or
            // refreshed a short-lived signed-URL token in lastStreamUrl during
            // the grace window — the captured `url` could be stale/expired (S6).
            val resumeUrl = lastStreamUrl ?: url
            if (surfaceReady && !camera.isStreaming) {
              startStreamInternal(resumeUrl)
            } else {
              // We promised JS a reconnect via the RECONNECTING event above.
              // If we silently bail here (surface dropped again, race with
              // a manual startStream, etc.), JS sits in RECONNECTING forever.
              onConnectionEvent?.invoke(
                RtmpConnectionEvent.CONNECTIONFAILED,
                "resume aborted (surface gone or already streaming)"
              )
            }
          }
          pendingResumeRunnable = r
          mainHandler.postDelayed(r, delay)
        } else {
          startStreamInternal(url)
        }
      }
    }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
    override fun surfaceDestroyed(holder: SurfaceHolder) {
      surfaceReady = false
      val wasStreaming = camera.isStreaming
      // Capture intent BEFORE cancelling the runnable. If we're in a bg→fg→bg
      // sequence, the resume runnable was already scheduled (so wasStreaming
      // is false because we hadn't restarted yet) — without this we'd lose
      // the resume intent and the user's stream silently dies.
      val hadPendingResume = pendingResumeRunnable != null
      // DO NOT clear shouldBeStreaming here. It is *user intent* to be streaming,
      // not surface lifecycle — clearing it on a transient surface loss
      // (background / rotate / PIP) permanently disabled auto-reconnect on every
      // backgrounding (M3). The just-cleared `surfaceReady=false` (top of this
      // method) + the pendingStream seed below gate tryAutoReconnect and make the
      // ConnectChecker callbacks defer to the surfaceCreated resume path (S3).
      // Drop any in-flight reconnect bookkeeping — the resume restarts clean.
      reconnectInProgress.set(false)
      currentRetryAttempt = 0
      mainHandler.removeCallbacks(reconnectTimeoutRunnable)
      cancelPendingResume()
      try {
        if (camera.isStreaming) {
          camera.stopStream()
          // Codecs released — re-prepare on next start.
          videoPrepared = false
          audioPrepared = false
        }
        if (camera.isOnPreview) camera.stopPreview()
      } catch (e: Exception) {
        // Drop the throwable (its stack-trace prefix would contain the
        // unscrubbed message) and scrub the message ourselves.
        Log.w(TAG, "surfaceDestroyed cleanup failed: " +
          "${e.javaClass.simpleName}: ${e.message.scrubRtmpKey()}")
      }
      releaseWakeLock()
      if (wasStreaming || hadPendingResume) {
        // Seed the next surfaceCreated to auto-republish — matches iOS'
        // foreground-resume semantics. Escalate the delay (1.5/3/5s) when
        // destroys come back-to-back so a rapid orientation/PIP recycle doesn't
        // re-publish into the same just-broken network every 1.5s (S6).
        lastStreamUrl?.let { url ->
          val now = SystemClock.elapsedRealtime()
          val rapid = lastSurfaceDestroyMs != 0L && (now - lastSurfaceDestroyMs) < 8_000L
          lastSurfaceDestroyMs = now
          resumeDelayLevel = if (rapid) (resumeDelayLevel + 1).coerceAtMost(2) else 0
          pendingStream = url
          pendingStreamDelayMs = when (resumeDelayLevel) {
            0 -> 1_500L
            1 -> 3_000L
            else -> 5_000L
          }
        }
        if (wasStreaming) {
          // Only emit DISCONNECT when an actual session was torn down. The
          // hadPendingResume-only case (bg→fg→bg before resume runs) means
          // JS already got DISCONNECT on the first backgrounding — emitting
          // again would just be noise.
          disconnectEmitted = true
          onConnectionEvent?.invoke(
            RtmpConnectionEvent.DISCONNECT,
            "surface destroyed"
          )
        }
      }
    }
  }

  init {
    openGlView.holder.addCallback(surfaceCallback)
    // Scope PIP auto-enter to this view's on-screen lifetime (see pipAttachListener).
    openGlView.addOnAttachStateChangeListener(pipAttachListener)
  }

  override val view: View
    get() = openGlView

  // ─── Props ───────────────────────────────────────────────────────────────

  override var forceHardwareCodec: Boolean = true
    set(value) {
      if (field == value) return
      field = value
      safe("applyCodecType") { applyCodecType() }
    }

  override var videoCodec: VideoCodec = VideoCodec.H264
    set(value) {
      if (field == value) return
      if (camera.isStreaming) {
        Log.w(TAG, "videoCodec change ignored while streaming")
        return
      }
      field = value
      safe("setVideoCodec") { camera.setVideoCodec(value.toPedro()) }
    }

  override var audioCodec: AudioCodec = AudioCodec.AAC
    set(value) {
      if (field == value) return
      if (camera.isStreaming) {
        Log.w(TAG, "audioCodec change ignored while streaming")
        return
      }
      field = value
      safe("setAudioCodec") { camera.setAudioCodec(value.toPedro()) }
    }

  override var aspectRatioMode: AspectRatioMode = AspectRatioMode.ADJUST
    set(value) {
      if (field == value) return
      field = value
      safe("setAspectRatioMode") { openGlView.setAspectRatioMode(value.toPedro()) }
    }

  override var mirrorPreview: Boolean = false
    set(value) {
      if (field == value) return
      field = value
      applyMirrorFlags()
    }

  override var mirrorStream: Boolean = false
    set(value) {
      if (field == value) return
      field = value
      applyMirrorFlags()
    }

  override var thermalWarningThreshold: ThermalStatus = ThermalStatus.SEVERE
    set(value) {
      if (field == value) return
      field = value
      thermalThresholdLevel = value.toPowerManagerStatus()
      // No need to re-register; the listener compares against the latest value.
      if (value == ThermalStatus.NONE) unregisterThermalListener()
    }

  override var audioSource: AudioSource = AudioSource.CAMCORDER
    set(value) {
      if (field == value) return
      if (camera.isStreaming) {
        Log.w(TAG, "audioSource change ignored while streaming")
        return
      }
      field = value
      // If audio was already prepared, re-run prepareAudio with the new source.
      // Pedro's resetAudioEncoder() rebuilds from the encoder's last-applied
      // values, so a bare property write would NOT take effect without this.
      if (audioPrepared) reapplyAudioConfig()
    }

  // On Android, noiseSuppression runs a custom spectral denoiser
  // ([SpectralNoiseSuppressor]) on the captured PCM — NOT the OS NS/AEC.
  // Because that effect is just a field read by the mic thread, it can be
  // swapped live via setCustomAudioEffect with no re-prepare, so this applies
  // immediately even mid-stream.
  override var noiseSuppression: Boolean = false
    set(value) {
      if (field == value) return
      field = value
      applyNoiseSuppressor()
    }

  override var autoRotateStream: Boolean = true
    set(value) {
      if (field == value) return
      field = value
      if (value) enableOrientationListener() else disableOrientationListener()
    }

  override var streamMode: StreamMode = StreamMode.BALANCED
    set(value) {
      if (field == value) return
      if (camera.isStreaming) {
        Log.w(TAG, "streamMode change ignored mid-stream (would glitch the RTMP cache)")
        return
      }
      field = value
      // Apply NOW (before prepareVideo runs) so the timestamp mode is bound
      // into the encoder config rather than racing it. Re-applied at
      // startStream too for safety.
      applyStreamMode()
    }

  override var foregroundServiceTitle: String = ""
    set(value) {
      if (field == value) return
      field = value
      refreshForegroundNotificationIfRunning()
    }
  override var foregroundServiceText: String = ""
    set(value) {
      if (field == value) return
      field = value
      refreshForegroundNotificationIfRunning()
    }
  override var foregroundServiceIcon: String = ""
    set(value) {
      if (field == value) return
      field = value
      refreshForegroundNotificationIfRunning()
    }

  // Push the latest title/text/icon to the live notification mid-stream.
  // The SDK has no separate "update FGS notification" API, so we re-fire
  // startService with the new extras — Android delivers another onStartCommand
  // that re-invokes startForeground with the freshly-built notification.
  private fun refreshForegroundNotificationIfRunning() {
    if (!fgServiceStartedByUs) return
    if (foregroundServiceTitle.isEmpty()) return
    RtmpForegroundService.update(
      context, foregroundServiceTitle, foregroundServiceText, foregroundServiceIcon
    )
  }

  // Arms system PIP: registers the host-Activity PIP observer and (API 31+)
  // flips setAutoEnterEnabled so Home/Recents shrinks into the floating window
  // with no host code. See [HybridRtmpPublisherView+Pip.kt].
  override var pictureInPictureEnabled: Boolean = false
    set(value) {
      if (field == value) return
      field = value
      if (value) registerPipListener() else unregisterPipListener()
      // Refresh params either way: arming installs autoEnter + portrait aspect;
      // disarming clears autoEnter (API 31+). No-op below API 26 / no Activity.
      refreshPipParams()
    }

  // ─── Lifecycle ──────────────────────────────────────────────────────────

  override fun prepareVideo(
    width: Double,
    height: Double,
    fps: Double,
    bitrate: Double,
    iFrameInterval: Double,
    rotation: Double
  ): Boolean {
    if (camera.isStreaming) {
      Log.w(TAG, "prepareVideo ignored while streaming")
      return false
    }
    val w = width.toInt()
    val h = height.toInt()
    val f = fps.toInt()
    val b = bitrate.toInt()
    val i = iFrameInterval.toInt()
    val r = rotation.toInt()
    if (w <= 0 || h <= 0 || f <= 0 || b <= 0) {
      Log.w(TAG, "prepareVideo invalid args (w=$w h=$h fps=$f bitrate=$b)")
      return false
    }
    applyCodecType()
    // Lock in the timestamp mode before the encoder is configured. The prop
    // setter no-ops when streamMode == default (Kotlin initializes the backing
    // field without calling the setter), so we cannot rely on it having run.
    // Without this, CLOCK-mode servers reject the first chunk → broken pipe.
    applyStreamMode()
    val ok = safe("prepareVideo", default = false) {
      camera.prepareVideo(w, h, f, b, i, r)
    }
    if (ok) {
      lastVideoCfg = VideoCfg(w, h, f, b, i, r)
      videoPrepared = true
      // Keep the PIP window aspect ratio tracking the (now-known) stream dims.
      if (pictureInPictureEnabled) refreshPipParams()
    }
    return ok
  }

  override fun prepareAudio(bitrate: Double, sampleRate: Double, isStereo: Boolean): Boolean {
    if (camera.isStreaming) {
      Log.w(TAG, "prepareAudio ignored while streaming")
      return false
    }
    val b = bitrate.toInt()
    val s = sampleRate.toInt()
    if (b <= 0 || s <= 0) {
      Log.w(TAG, "prepareAudio invalid args (bitrate=$b sampleRate=$s)")
      return false
    }
    // applyCodecType() — already done in `prepareVideo` (called first). Calling
    // again is a no-op duplicate.
    val source = audioSource.toMediaRecorderSource()
    // Silently force mono on single-mic phones even if the caller asked for
    // stereo. Fake-stereo synthesis in the HAL doubles audio CPU for zero
    // benefit and is the primary cause of chunky playback on budget UNISOC /
    // MediaTek chips. See [resolveEffectiveStereo] for full rationale.
    val effectiveStereo = resolveEffectiveStereo(isStereo)
    // OS NoiseSuppressor / AEC (`keepDsp`) is driven purely by the audioSource
    // mode now — NOT by `noiseSuppression` (which runs the custom spectral
    // denoiser instead; see [applyNoiseSuppressor]):
    //  1. MIC / VOICE_COMMUNICATION sources implicitly engage DSP because those
    //     sources are tuned for phone-call-style processing.
    //  2. CAMCORDER / VOICE_RECOGNITION / UNPROCESSED keep DSP off so the
    //     broadband signal survives.
    val keepDsp = audioSource == AudioSource.MIC ||
      audioSource == AudioSource.VOICECOMMUNICATION
    val ok = safe("prepareAudio", default = false) {
      camera.prepareAudio(source, b, s, effectiveStereo, keepDsp, keepDsp)
    }
    if (ok) {
      // Cache the EFFECTIVE stereo so reapplyAudioConfig / rePrepareEncoders
      // re-use the resolved value instead of re-running the downgrade check
      // (and risking divergence if the device's mic list changes mid-session).
      lastAudioCfg = AudioCfg(b, s, effectiveStereo)
      audioPrepared = true
      // Install the spectral noise suppressor (when noiseSuppression is on) now
      // that the MicrophoneManager exists and we know the sample rate / channel
      // count. This is the Android noiseSuppression mechanism — separate from
      // the OS keepDsp flags above.
      applyNoiseSuppressor()
    } else {
      // Pedro returns false for two reasons: AudioRecord couldn't open the
      // source (almost always RECORD_AUDIO not granted yet, or the source isn't
      // supported on this device), or the AAC encoder couldn't be selected.
      // Either way the audio track is silently absent from the stream — log
      // loudly so callers can see why and fix the cause.
      Log.w(TAG, "prepareAudio FAILED — audio will be missing from the stream. " +
        "Check RECORD_AUDIO permission, audioSource='$audioSource', " +
        "sampleRate=$s, isStereo=$effectiveStereo, and 'MicrophoneManager: create microphone error' / " +
        "'AudioEncoder: Valid encoder not found' in logcat.")
    }
    return ok
  }

  override fun startPreview(facing: CameraFacing, width: Double, height: Double) {
    val w = width.toInt().coerceAtLeast(1)
    val h = height.toInt().coerceAtLeast(1)
    // Always cache so background→foreground can restore the preview.
    lastPreview = PreviewConfig(facing, w, h)
    if (!surfaceReady) return
    startPreviewInternal(facing, w, h)
  }

  // Returns true iff preview successfully started (or was already running).
  // False on slot collision or exception so callers can skip dependent work
  // — most importantly, the surface-restore path must not try to start a
  // stream against a camera that never opened.
  internal fun startPreviewInternal(facing: CameraFacing, width: Int, height: Int): Boolean {
    // Refuse if another publisher instance already holds the camera —
    // Camera2 doesn't allow concurrent opens from the same process and the
    // failure mode otherwise is silent (a black preview + cryptic logcat).
    if (!holdsActiveSlot) {
      if (!activePublisherCount.compareAndSet(0, 1)) {
        Log.w(TAG, "Refusing to start preview — another <RtmpPublisherView> is active")
        onConnectionEvent?.invoke(
          RtmpConnectionEvent.CONNECTIONFAILED,
          "another <RtmpPublisherView> already holds the camera"
        )
        return false
      }
      holdsActiveSlot = true
    }
    val helperFacing = when (facing) {
      CameraFacing.FRONT -> CameraHelper.Facing.FRONT
      CameraFacing.BACK -> CameraHelper.Facing.BACK
    }
    var ok = false
    safe("startPreview") {
      if (camera.isOnPreview) camera.stopPreview()
      camera.startPreview(helperFacing, width, height)
      // glInterface + camera2 controls are live now — re-apply props that
      // depend on them.
      applyMirrorFlags()
      applyBeautyFilter()
      safe("forceFpsLimit") { camera.forceFpsLimit(desiredForceFpsLimit) }
      if (autoRotateStream) enableOrientationListener()
      ok = true
    }
    return ok
  }

  override fun stopPreview() {
    lastPreview = null
    disableOrientationListener()
    // The GL pipeline (and any attached filter) is torn down with the preview.
    // Drop the stale render instance; `desiredBeautyFilter` survives so the
    // next startPreview re-attaches a fresh one.
    beautyFilter = null
    safe("stopPreview") {
      if (camera.isOnPreview) camera.stopPreview()
    }
  }

  override fun startStream(url: String) {
    if (url.isBlank()) {
      Log.w(TAG, "startStream ignored — empty URL")
      return
    }
    lastStreamUrl = url
    // A fresh start clears any prior explicit-stop intent (M3).
    streamExplicitlyStopped = false
    // An explicit startStream supersedes any pending auto-resume from a prior
    // background sequence.
    cancelPendingResume()
    if (!surfaceReady) {
      pendingStream = url
      pendingStreamDelayMs = 0L
      return
    }
    startStreamInternal(url)
  }

  internal fun startStreamInternal(url: String) {
    // FG service must come up BEFORE we kick off the encoder. On Android 12+
    // background-start restrictions and 14+ FGS-type rules cause this to fail
    // silently otherwise — the encoder runs, the OS kills the camera/mic, and
    // JS only sees a generic disconnect. Surface the failure as CONNECTIONFAILED
    // up front so callers can react (re-prompt for notification permission, etc.).
    if (!ensureForegroundServiceIfRequested()) {
      onConnectionEvent?.invoke(
        RtmpConnectionEvent.CONNECTIONFAILED,
        "foreground service failed to start " +
          "(Android background-start restriction or missing POST_NOTIFICATIONS)"
      )
      return
    }
    acquireWakeLock()
    setKeepScreenOn(true)
    streamExplicitlyStopped = false
    shouldBeStreaming = true
    // Fresh session: clear any in-flight reconnect bookkeeping + stall counter.
    // NOTE: disconnectEmitted is deliberately NOT cleared here — clearing it
    // before the connection is up let a stale onDisconnect from the prior
    // session emit a spurious DISCONNECT (S4). It's cleared on onConnectionSuccess
    // / stopStream / onDropView and every terminal path instead.
    reconnectInProgress.set(false)
    currentRetryAttempt = 0
    stallTicks = 0
    // Reset the video-fps baseline so the first onStreamStats tick of this
    // stream measures from zero (the sender's frame counters restart too).
    lastSentVideoFrames = 0L
    lastStatsTsMs = 0L
    // Pedro's BaseEncoder.stop() releases the MediaCodec and sets prepared=false,
    // so the next BaseEncoder.start() throws "not prepared yet". Re-prepare from
    // cached config before letting Pedro start the encoders.
    rePrepareEncodersIfNeeded()
    // Refresh retry budget for this session — `setReTries` is a counter that
    // ticks down, so we re-set it on every fresh `startStream`.
    if (autoReconnectMaxAttempts > 0) {
      safe("startStream/setReTries") {
        camera.streamClient.setReTries(autoReconnectMaxAttempts)
      }
    } else if (!autoReconnectDisabledWarned) {
      // M5: make "reconnect disabled" distinguishable from "reconnect gave up".
      autoReconnectDisabledWarned = true
      Log.w(TAG, "auto-reconnect is disabled (autoReconnectMaxAttempts=0). A " +
        "mid-stream network blip will end the stream with no retry — call " +
        "setAutoReconnect(attempts, backoffMs) to recover from transient failures.")
    }
    // Reset adaptive-bitrate state so each session starts from the ceiling.
    safe("startStream/bitrateAdapter.reset") { bitrateAdapter?.reset() }
    // Apply stream-mode tuning to the fresh streamClient state.
    applyStreamMode()
    // M8: don't start encoding until the FG service has actually reached the
    // foreground — on Android 14+ a half-started FGS gets camera/mic revoked and
    // the encoder stalls with no callback. Polls without blocking the looper.
    beginStreamWhenServiceReady(url, 0)
  }

  // Wait (non-blocking) for the FG service to reach the foreground, then start
  // the encoder. startForegroundService() dispatches onStartCommand onto THIS
  // looper, so we must yield via postDelayed rather than Thread.sleep — blocking
  // here would starve the very callback that flips `running` true (deadlock).
  private fun beginStreamWhenServiceReady(url: String, attempt: Int) {
    // Nothing to wait on: no FGS requested, build opted out, or it's already up.
    if (!fgServiceStartedByUs || RtmpForegroundService.running) {
      launchEncoder(url)
      return
    }
    if (attempt >= MAX_FGS_WAIT_ATTEMPTS) {
      Log.e(TAG, "Foreground service did not reach the foreground within " +
        "${MAX_FGS_WAIT_ATTEMPTS * FGS_WAIT_POLL_MS}ms — refusing to encode " +
        "(Android 14+ would revoke camera/mic mid-stream).")
      shouldBeStreaming = false
      releaseWakeLock()
      setKeepScreenOn(false)
      onConnectionEvent?.invoke(
        RtmpConnectionEvent.CONNECTIONFAILED,
        "foreground service startup timed out"
      )
      return
    }
    mainHandler.postDelayed({ beginStreamWhenServiceReady(url, attempt + 1) }, FGS_WAIT_POLL_MS)
  }

  // The actual encoder start. Bumps the session epoch (M7) and surfaces a thrown
  // start as CONNECTIONFAILED instead of leaving JS hung (M4).
  private fun launchEncoder(url: String) {
    // A stopStream / surface loss may have raced the FGS-readiness wait.
    if (streamExplicitlyStopped || !shouldBeStreaming || !surfaceReady) {
      Log.w(TAG, "startStream aborted before encode — stopped or surface gone during FGS wait")
      return
    }
    // B2: already live (two start chains overlapped — e.g. a JS startStream
    // racing a surface-resume). camera.startStream() would throw "already
    // streaming" and M4's catch below would wrongly tear down a healthy stream.
    if (camera.isStreaming) {
      Log.w(TAG, "startStream skipped — already streaming")
      return
    }
    pipelineGeneration++
    try {
      camera.startStream(url)
      // Stream is live with final dims — refresh the portrait PIP aspect ratio.
      if (pictureInPictureEnabled) refreshPipParams()
    } catch (e: Exception) {
      // M4: a thrown startStream (codec in a bad state, surface gone, OOM) fires
      // NO ConnectChecker callback — without this JS sits in CONNECTING forever.
      shouldBeStreaming = false
      reconnectInProgress.set(false)
      releaseWakeLock()
      setKeepScreenOn(false)
      Log.w(TAG, "camera.startStream failed: ${e.javaClass.simpleName}: ${e.message.scrubRtmpKey()}")
      onConnectionEvent?.invoke(
        RtmpConnectionEvent.CONNECTIONFAILED,
        "camera.startStream failed: ${e.javaClass.simpleName}"
      )
    }
  }

  override fun stopStream() {
    pendingStream = null
    pendingStreamDelayMs = 0L
    lastStreamUrl = null
    cancelPendingResume()
    // Explicit user stop — the hard gate that stops auto-reconnect/resume from
    // resurrecting the stream (M3). Reset all in-flight reconnect bookkeeping.
    streamExplicitlyStopped = true
    shouldBeStreaming = false
    reconnectInProgress.set(false)
    currentRetryAttempt = 0
    stallTicks = 0
    resumeDelayLevel = 0
    lastSurfaceDestroyMs = 0L
    disconnectEmitted = false
    postNotificationsWarned = false
    mainHandler.removeCallbacks(reconnectTimeoutRunnable)
    safe("stopStream") {
      if (camera.isStreaming) {
        camera.stopStream()
        // Pedro just released the codecs (codec.release() + prepared=false).
        // Mark them so the next startStream re-prepares from the cached config.
        videoPrepared = false
        audioPrepared = false
      }
    }
    releaseWakeLock()
    setKeepScreenOn(false)
    maybeStopForegroundService()
  }

  override fun setAuthorization(user: String, password: String) {
    safe("setAuthorization") { camera.streamClient.setAuthorization(user, password) }
  }

  // ─── Status / readouts ───────────────────────────────────────────────────

  override fun isStreaming(): Boolean = camera.isStreaming
  override fun isOnPreview(): Boolean = camera.isOnPreview

  override fun getCameraOrientation(): Double =
    safe("getCameraOrientation", default = 0.0) {
      CameraHelper.getCameraOrientation(context).toDouble()
    }

  override fun getStreamWidth(): Double = camera.streamWidth.toDouble()
  override fun getStreamHeight(): Double = camera.streamHeight.toDouble()
  override fun getCurrentBitrate(): Double = camera.bitrate.toDouble()

  // ─── Adaptive bitrate / encoder ──────────────────────────────────────────

  override fun setVideoBitrateOnFly(bitrate: Double) {
    val b = bitrate.toInt()
    if (b <= 0) return
    if (!camera.isStreaming) {
      Log.w(TAG, "setVideoBitrateOnFly ignored — not streaming")
      return
    }
    safe("setVideoBitrateOnFly") { camera.setVideoBitrateOnFly(b) }
  }

  override fun setAdaptiveBitrate(
    maxBitrate: Double,
    decreaseRangePercent: Double,
    increaseRangePercent: Double
  ) {
    val max = maxBitrate.toInt()
    if (max <= 0) {
      bitrateAdapter = null
      // Restore the configured ceiling so the user isn't stuck at whatever
      // ABR last reduced to. No-op when not streaming — next prepareVideo
      // will set the bitrate from cached config anyway.
      lastVideoCfg?.let { cfg ->
        if (camera.isStreaming) {
          safe("restoreBitrate") { camera.setVideoBitrateOnFly(cfg.bitrate) }
        }
      }
      return
    }
    val dec = decreaseRangePercent.toFloat().coerceIn(0f, 100f)
    val inc = increaseRangePercent.toFloat().coerceIn(0f, 100f)
    // Mutate the existing adapter in place — preserves its adaptation history
    // (current bitrate, congestion memory) across re-tuning calls.
    val adapter = bitrateAdapter ?: BitrateAdapter { adapted ->
      safe("adaptiveBitrate/apply") {
        if (camera.isStreaming) camera.setVideoBitrateOnFly(adapted)
      }
    }
    adapter.setMaxBitrate(max)
    if (dec > 0f) adapter.decreaseRange = dec
    if (inc > 0f) adapter.increaseRange = inc
    bitrateAdapter = adapter
  }

  // Debounce: at most one keyframe request per second. Multiple IDRs in
  // quick succession waste bandwidth without giving the viewer anything new.
  @Volatile private var lastKeyFrameRequestMs = 0L

  override fun requestKeyFrame() {
    if (!camera.isStreaming) return
    val now = SystemClock.uptimeMillis()
    if (now - lastKeyFrameRequestMs < 1000L) return
    lastKeyFrameRequestMs = now
    safe("requestKeyFrame") { camera.requestKeyFrame() }
  }

  override fun setStreamRotation(rotation: Double) {
    val r = rotation.toInt()
    safe("setStreamRotation") { camera.glInterface.setStreamRotation(r) }
  }

  // ─── FPS lock ────────────────────────────────────────────────────────────

  override fun setForceFpsLimit(enabled: Boolean) {
    desiredForceFpsLimit = enabled
    safe("setForceFpsLimit") { camera.forceFpsLimit(enabled) }
  }

  // ─── Long-stream tuning ─────────────────────────────────────────────────

  override fun forceIncrementalTs(enabled: Boolean) {
    if (camera.isStreaming) {
      Log.w(TAG, "forceIncrementalTs($enabled) overrides the current streamMode " +
        "($streamMode) — call this only if you need to bypass mode tuning.")
    }
    safe("forceIncrementalTs") { camera.streamClient.forceIncrementalTs(enabled) }
  }

  override fun setStreamDelay(delayMs: Double) {
    // Clamp to a sane upper bound — Pedro will allocate buffers per the delay,
    // and JS can pass arbitrary values. 10s is already well past any
    // reasonable interleave / jitter window.
    val d = delayMs.toLong().coerceIn(0L, 10_000L)
    if (camera.isStreaming) {
      Log.w(TAG, "setStreamDelay($d) overrides the current streamMode " +
        "($streamMode) delay — set only if mode tuning isn't enough.")
    }
    safe("setStreamDelay") { camera.streamClient.setDelay(d) }
  }


  // ─── Reconnection ────────────────────────────────────────────────────────

  override fun setReTries(count: Double) {
    // Clamp to a sane ceiling — Pedro counts down internally and a runaway
    // value just exhausts client cycles on a permanently-dead endpoint.
    val c = count.toInt().coerceIn(0, MAX_RETRY_ATTEMPTS)
    safe("setReTries") { camera.streamClient.setReTries(c) }
  }

  override fun reTry(delayMs: Double, reason: String): Boolean {
    val d = delayMs.toLong().coerceIn(0L, MAX_RETRY_BACKOFF_MS)
    return safe("reTry", default = false) {
      val queued = camera.streamClient.reTry(d, reason, null)
      // S1: the manual reTry path (app driving its own setReTries loop) gets no
      // dead-man otherwise — a hung manual retry would never be detected. Arm it
      // here too when the app still intends to stream. Include the caller's delay
      // `d` (Pedro waits it out before connecting; see B1). (Handler ops are
      // thread-safe; reTry may be invoked off-main by Nitro.)
      if (queued && shouldBeStreaming) {
        mainHandler.removeCallbacks(reconnectTimeoutRunnable)
        mainHandler.postDelayed(reconnectTimeoutRunnable, d + reconnectTimeoutMs)
      }
      queued
    }
  }

  override fun setAutoReconnect(maxAttempts: Double, backoffMs: Double) {
    autoReconnectMaxAttempts = maxAttempts.toInt().coerceIn(0, MAX_RETRY_ATTEMPTS)
    autoReconnectBackoffMs = backoffMs.toLong().coerceIn(0L, MAX_RETRY_BACKOFF_MS)
    // Disabling mid-flight: kill any armed dead-man timer too. Otherwise it
    // ticks down to a stale CONNECTIONFAILED 30s later even though Pedro has
    // already stopped retrying.
    if (autoReconnectMaxAttempts == 0) {
      mainHandler.removeCallbacks(reconnectTimeoutRunnable)
    }
    // Seed the budget right away so a manual `reTry()` call works without
    // first going through `startStream`.
    safe("setAutoReconnect/setReTries") {
      camera.streamClient.setReTries(autoReconnectMaxAttempts)
    }
  }

  override fun resetVideoEncoder(): Boolean =
    safe("resetVideoEncoder", default = false) { camera.resetVideoEncoder() }

  override fun resetAudioEncoder(): Boolean =
    safe("resetAudioEncoder", default = false) { camera.resetAudioEncoder() }

  // ─── Camera selection ────────────────────────────────────────────────────

  override fun switchCamera() {
    safe("switchCamera") {
      camera.switchCamera()
      refreshCachedFacing()
      // RootEncoder's OpenGlView resets its preview/stream flip flags when the
      // camera is swapped — re-apply ours so a `<View mirrorPreview mirrorStream/>`
      // setup keeps working after tapping Flip.
      applyMirrorFlags()
    }
  }

  override fun getCamerasAvailable(): Array<String> =
    safe("getCamerasAvailable", default = emptyArray()) {
      camera.camerasAvailable ?: emptyArray()
    }

  override fun getCurrentCameraId(): String =
    safe("getCurrentCameraId", default = "") { camera.currentCameraId ?: "" }

  override fun switchCameraById(id: String) {
    if (id.isBlank()) return
    safe("switchCameraById") {
      camera.switchCamera(id)
      refreshCachedFacing()
      applyMirrorFlags()
    }
  }

  private fun refreshCachedFacing() {
    val current = lastPreview ?: return
    val facing = if (camera.cameraFacing == CameraHelper.Facing.FRONT)
      CameraFacing.FRONT else CameraFacing.BACK
    if (facing != current.facing) lastPreview = current.copy(facing = facing)
  }

  override fun isFrontCamera(): Boolean =
    safe("isFrontCamera", default = false) {
      camera.cameraFacing == CameraHelper.Facing.FRONT
    }

  // ─── Audio control ───────────────────────────────────────────────────────

  override fun setAudioMuted(muted: Boolean) {
    safe("setAudioMuted") {
      if (muted) camera.disableAudio() else camera.enableAudio()
    }
  }

  override fun isAudioMuted(): Boolean =
    safe("isAudioMuted", default = false) { camera.isAudioMuted }

  // ─── Torch (lantern) ─────────────────────────────────────────────────────

  override fun setLanternEnabled(enabled: Boolean) {
    try {
      if (enabled) camera.enableLantern() else camera.disableLantern()
    } catch (e: Exception) {
      Log.w(TAG, "setLanternEnabled($enabled) failed: ${e.message}")
    }
  }

  override fun isLanternEnabled(): Boolean =
    safe("isLanternEnabled", default = false) { camera.isLanternEnabled }

  override fun isLanternSupported(): Boolean =
    safe("isLanternSupported", default = false) { camera.isLanternSupported }

  // ─── Zoom ────────────────────────────────────────────────────────────────

  override fun setZoom(zoom: Double) {
    if (!zoom.isFinite()) {
      Log.w(TAG, "setZoom ignored — non-finite value ($zoom)")
      return
    }
    safe("setZoom") {
      val range = camera.zoomRange
      val min = range?.lower?.toFloat() ?: 1f
      val max = range?.upper?.toFloat() ?: 1f
      camera.setZoom(zoom.toFloat().coerceIn(min, max))
    }
  }

  override fun getZoom(): Double = camera.zoom.toDouble()
  override fun getMinZoom(): Double = (camera.zoomRange?.lower?.toDouble()) ?: 1.0
  override fun getMaxZoom(): Double = (camera.zoomRange?.upper?.toDouble()) ?: 1.0

  // ─── Beauty filter ───────────────────────────────────────────────────────

  override fun setBeautyFilterEnabled(enabled: Boolean) {
    desiredBeautyFilter = enabled
    applyBeautyFilter()
  }

  override fun isBeautyFilterEnabled(): Boolean = desiredBeautyFilter

  // Add/remove the GL render to match `desiredBeautyFilter`. Idempotent and
  // safe to call before preview is up (glInterface throws → swallowed by
  // safe(); startPreview re-runs this once the pipeline is live). Tracks the
  // live instance in `beautyFilter` so we never double-add or leak it.
  //
  // It's always our own [WhiteningBeautyFilterRender] (fair/bright look); only
  // its shader PRECISION is chosen at attach time: budget GPUs (entry Mali /
  // PowerVR / old Adreno) get the mediump build — they run highp at half rate
  // and have the least memory bandwidth to spare while encoding — and capable
  // GPUs get highp UNTIL thermal pressure forces a downgrade (see
  // onThermalStatusChanged). When the target precision changes while the filter
  // is live, this swaps the render in place. Idempotent: a call where the
  // attached precision already matches is a no-op.
  internal fun applyBeautyFilter() {
    safe("applyBeautyFilter") {
      if (!desiredBeautyFilter) {
        beautyFilter?.let { camera.glInterface.removeFilter(it) }
        beautyFilter = null
        return@safe
      }
      val wantHighPrecision = !(isLowEndDevice() || beautyThermalDowngrade)
      val current = beautyFilter
      if (current != null && current.highPrecision == wantHighPrecision) {
        return@safe // already attached at the right precision
      }
      current?.let { camera.glInterface.removeFilter(it) }
      val filter = WhiteningBeautyFilterRender(highPrecision = wantHighPrecision)
      camera.glInterface.setFilter(filter)
      beautyFilter = filter
      Log.i(
        TAG,
        "beauty filter on (" +
          (if (wantHighPrecision) "highp" else "mediump") +
          (if (beautyThermalDowngrade) "/thermal-downgrade" else "") + ")"
      )
    }
  }

  // ─── Exposure ────────────────────────────────────────────────────────────

  override fun setExposure(value: Double) {
    if (!value.isFinite()) {
      Log.w(TAG, "setExposure ignored — non-finite value ($value)")
      return
    }
    safe("setExposure") {
      val clamped = value.toInt().coerceIn(camera.minExposure, camera.maxExposure)
      camera.exposure = clamped
    }
  }

  override fun getExposure(): Double = camera.exposure.toDouble()
  override fun getMinExposure(): Double = camera.minExposure.toDouble()
  override fun getMaxExposure(): Double = camera.maxExposure.toDouble()

  // ─── Focus ───────────────────────────────────────────────────────────────

  override fun setAutoFocusEnabled(enabled: Boolean): Boolean =
    safe("setAutoFocusEnabled", default = false) {
      if (enabled) camera.enableAutoFocus() else camera.disableAutoFocus()
    }

  override fun isAutoFocusEnabled(): Boolean =
    safe("isAutoFocusEnabled", default = false) { camera.isAutoFocusEnabled }

  override fun setFocusDistance(distance: Double) {
    if (!distance.isFinite()) {
      Log.w(TAG, "setFocusDistance ignored — non-finite value ($distance)")
      return
    }
    safe("setFocusDistance") { camera.setFocusDistance(distance.toFloat()) }
  }

  // ─── Stabilization ──────────────────────────────────────────────────────

  override fun setVideoStabilizationEnabled(enabled: Boolean): Boolean =
    safe("setVideoStabilizationEnabled", default = false) {
      if (enabled) camera.enableVideoStabilization()
      else { camera.disableVideoStabilization(); true }
    }

  override fun isVideoStabilizationEnabled(): Boolean =
    safe("isVideoStabilizationEnabled", default = false) { camera.isVideoStabilizationEnabled }

  override fun setOpticalVideoStabilizationEnabled(enabled: Boolean): Boolean =
    safe("setOpticalVideoStabilizationEnabled", default = false) {
      if (enabled) camera.enableOpticalVideoStabilization()
      else { camera.disableOpticalVideoStabilization(); true }
    }

  override fun isOpticalVideoStabilizationEnabled(): Boolean =
    safe("isOpticalVideoStabilizationEnabled", default = false) {
      camera.isOpticalVideoStabilizationEnabled
    }

  // ─── Local recording ─────────────────────────────────────────────────────

  override fun startRecord(path: String): Boolean {
    if (path.isBlank()) {
      Log.w(TAG, "startRecord ignored — empty path")
      return false
    }
    if (camera.recordStatus != RecordController.Status.STOPPED) {
      Log.w(TAG, "startRecord ignored — recorder not in STOPPED state")
      return false
    }
    val ok = safe("startRecord", default = false) {
      camera.startRecord(path, recordListener)
      true
    }
    if (!ok) {
      // Pedro's startRecord opens a FileOutputStream on the given path. On
      // modern Android the common failure modes are storage-related and very
      // unhelpful from the bare exception — surface a concrete pointer here.
      Log.w(TAG, "startRecord FAILED for path '$path'. " +
        "On Android 10+, writes outside app-specific dirs " +
        "(Context.getExternalFilesDir(null)) require MediaStore. " +
        "On Android 9 and below, declare WRITE_EXTERNAL_STORAGE and request it. " +
        "Also verify the parent directory exists and is writable.")
    }
    return ok
  }

  override fun stopRecord() {
    safe("stopRecord") { camera.stopRecord() }
  }

  override fun pauseRecord() {
    safe("pauseRecord") { camera.pauseRecord() }
  }

  override fun resumeRecord() {
    safe("resumeRecord") { camera.resumeRecord() }
  }

  override fun getRecordStatus(): RecordStatus =
    safe("getRecordStatus", default = RecordStatus.STOPPED) {
      camera.recordStatus.toNitro()
    }

  // ─── Event callbacks ────────────────────────────────────────────────────

  override fun setOnConnectionEvent(
    callback: (event: RtmpConnectionEvent, message: String) -> Unit
  ) {
    onConnectionEvent = callback
  }

  override fun setOnBitrateChange(callback: (bitrate: Double) -> Unit) {
    onBitrateChange = callback
  }

  override fun setOnStreamStats(callback: (bitrateBps: Double, videoFps: Double) -> Unit) {
    onStreamStats = callback
  }

  override fun setOnRecordStatusChange(callback: (status: RecordStatus) -> Unit) {
    onRecordStatusChange = callback
  }

  override fun getThermalStatus(): ThermalStatus {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return ThermalStatus.NONE
    // If the listener is registered, the cached value is fresh (updated on
    // every OS state change) — return it instead of doing a binder call.
    if (thermalListenerRegistered) return lastThermalStatusInt.fromPowerManagerStatus()
    return safe("getThermalStatus", default = ThermalStatus.NONE) {
      val pm = powerManager ?: return@safe ThermalStatus.NONE
      pm.currentThermalStatus.fromPowerManagerStatus()
    }
  }

  override fun setOnThermalWarning(callback: (status: ThermalStatus) -> Unit) {
    onThermalWarning = callback
    // Lazy-register the OS listener now that there's actually a subscriber.
    registerThermalListener()
  }

  // ─── Picture-in-Picture ───────────────────────────────────────────────────
  // Thin overrides — the real work lives in [HybridRtmpPublisherView+Pip.kt].

  override fun enterPictureInPicture(): Boolean = requestPictureInPicture()

  override fun isInPictureInPicture(): Boolean = isInPip

  override fun setOnPictureInPictureChange(callback: (isInPip: Boolean) -> Unit) {
    onPictureInPictureChange = callback
    // Lazy-register the observer now that there's a subscriber, even if the
    // `pictureInPictureEnabled` prop was never set (manual-button-only apps).
    registerPipListener()
  }

  // ─── Cleanup ────────────────────────────────────────────────────────────

  override fun onDropView() {
    // Detach the surface callback first so subsequent surface-lifecycle events
    // (which can fire during the cleanup below as the OpenGlView is detached
    // from the window) can't re-enter and touch a half-released camera.
    safe("onDropView/removeSurfaceCallback") {
      openGlView.holder.removeCallback(surfaceCallback)
    }
    // Hard teardown — same intent as an explicit stop, so no resume/reconnect
    // can resurrect the stream during the cleanup below (M3).
    streamExplicitlyStopped = true
    shouldBeStreaming = false
    reconnectInProgress.set(false)
    currentRetryAttempt = 0
    stallTicks = 0
    disconnectEmitted = false
    postNotificationsWarned = false
    lastPreview = null
    pendingStream = null
    pendingStreamDelayMs = 0L
    lastStreamUrl = null
    cancelPendingResume()
    bitrateAdapter = null
    mainHandler.removeCallbacks(reconnectTimeoutRunnable)
    safe("onDropView/stopStream") { if (camera.isStreaming) camera.stopStream() }
    safe("onDropView/stopPreview") { if (camera.isOnPreview) camera.stopPreview() }
    safe("onDropView/stopRecord") {
      if (camera.recordStatus != RecordController.Status.STOPPED) {
        camera.stopRecord()
      }
    }
    releaseWakeLock()
    setKeepScreenOn(false)
    unregisterThermalListener()
    // Clear the Activity-global auto-enter flag so PIP doesn't follow the user to
    // the next screen, and drop the attach observer.
    if (pictureInPictureEnabled) safe("onDropView/disarmPipAutoEnter") { disarmPipAutoEnter() }
    safe("onDropView/removePipAttachListener") {
      openGlView.removeOnAttachStateChangeListener(pipAttachListener)
    }
    unregisterPipListener()
    hostActivity = null
    disableOrientationListener()
    maybeStopForegroundService()
    if (holdsActiveSlot) {
      holdsActiveSlot = false
      activePublisherCount.updateAndGet { (it - 1).coerceAtLeast(0) }
    }
    // Clear JS callbacks LAST, after the cleanup above. Pedro's onDisconnect
    // (triggered by our stopStream) is marshalled through postToMain, so it
    // runs on a later main-thread tick — by which time these are null and
    // the `?.invoke` no-ops. Don't reorder.
    onConnectionEvent = null
    onBitrateChange = null
    onStreamStats = null
    onRecordStatusChange = null
    onThermalWarning = null
    onPictureInPictureChange = null
  }
}
