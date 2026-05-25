package com.margelo.nitro.rtmppublisher

import android.annotation.SuppressLint
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
import com.pedro.common.ConnectChecker
import com.pedro.encoder.input.video.CameraHelper
import com.pedro.library.base.recording.RecordController
import com.pedro.library.rtmp.RtmpCamera2
import com.pedro.library.util.BitrateAdapter
import com.pedro.library.view.OpenGlView

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
  @Volatile internal var onRecordStatusChange: ((RecordStatus) -> Unit)? = null
  @Volatile internal var onThermalWarning: ((ThermalStatus) -> Unit)? = null

  // Last known preview config. Kept alive across surface destroy/create cycles
  // (host activity background/foreground, rotation) so the preview auto-restores.
  // Cleared only on explicit `stopPreview()` or `onDropView()`.
  internal var lastPreview: PreviewConfig? = null
  internal var pendingStream: String? = null
  // When the surface is destroyed while streaming, we save the URL here so
  // surfaceCreated can re-publish automatically (matches iOS' foreground-resume
  // behaviour in appWillEnterForeground). Carries a delay so the cached
  // pendingStream path (initial mount race) stays zero-delay.
  internal var pendingStreamDelayMs: Long = 0L
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

  internal var surfaceReady = false

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
  internal var autoReconnectMaxAttempts = 0
  internal var autoReconnectBackoffMs = 0L

  // Dead-man timer for auto-reconnect. Pedro's streamClient.reTry() can queue
  // a retry that never completes (TCP hang, DNS stall) without firing another
  // onConnectionFailed — without this, shouldBeStreaming stays true forever
  // and JS sits in RECONNECTING with nothing to react to.
  internal val mainHandler = Handler(Looper.getMainLooper())
  internal val reconnectTimeoutMs = 30_000L
  internal val reconnectTimeoutRunnable = Runnable {
    if (shouldBeStreaming && !camera.isStreaming) {
      Log.w(TAG, "Auto-reconnect timed out after ${reconnectTimeoutMs}ms")
      shouldBeStreaming = false
      releaseWakeLock()
      setKeepScreenOn(false)
      onConnectionEvent?.invoke(
        RtmpConnectionEvent.CONNECTIONFAILED,
        "reconnect timed out"
      )
    }
  }

  // Adaptive bitrate. Null when disabled.
  @Volatile internal var bitrateAdapter: BitrateAdapter? = null
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
    override fun onConnectionStarted(url: String) = postToMain {
      onConnectionEvent?.invoke(RtmpConnectionEvent.CONNECTIONSTARTED, url)
    }
    override fun onConnectionSuccess() = postToMain {
      mainHandler.removeCallbacks(reconnectTimeoutRunnable)
      disconnectEmitted = false
      onConnectionEvent?.invoke(RtmpConnectionEvent.CONNECTIONSUCCESS, "")
    }
    override fun onConnectionFailed(reason: String) = postToMain {
      if (tryAutoReconnect(reason)) {
        onConnectionEvent?.invoke(RtmpConnectionEvent.RECONNECTING, reason)
      } else {
        mainHandler.removeCallbacks(reconnectTimeoutRunnable)
        shouldBeStreaming = false
        releaseWakeLock()
        setKeepScreenOn(false)
        onConnectionEvent?.invoke(RtmpConnectionEvent.CONNECTIONFAILED, reason)
      }
    }
    override fun onNewBitrate(bitrate: Long) = postToMain {
      // Feed adaptive-bitrate adapter if enabled. It calls back into
      // `setVideoBitrateOnFly` via its listener, no allocation per tick.
      bitrateAdapter?.let { adapter ->
        val congested = safe("hasCongestion", default = false) {
          camera.streamClient.hasCongestion()
        }
        safe("adaptBitrate") { adapter.adaptBitrate(bitrate, congested) }
      }
      onBitrateChange?.invoke(bitrate.toDouble())
    }
    override fun onDisconnect() = postToMain {
      if (tryAutoReconnect("disconnect")) {
        onConnectionEvent?.invoke(RtmpConnectionEvent.RECONNECTING, "disconnect")
      } else {
        mainHandler.removeCallbacks(reconnectTimeoutRunnable)
        shouldBeStreaming = false
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
    override fun onAuthError() = postToMain {
      onConnectionEvent?.invoke(RtmpConnectionEvent.AUTHERROR, "")
    }
    override fun onAuthSuccess() = postToMain {
      onConnectionEvent?.invoke(RtmpConnectionEvent.AUTHSUCCESS, "")
    }
  }

  internal val camera: RtmpCamera2 = RtmpCamera2(openGlView, connectChecker)

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
            if (surfaceReady && !camera.isStreaming) {
              startStreamInternal(url)
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
      // Disable auto-reconnect BEFORE stopStream: the subsequent onDisconnect
      // would otherwise try to retry against a dead surface.
      shouldBeStreaming = false
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
        // foreground-resume semantics.
        lastStreamUrl?.let { url ->
          pendingStream = url
          pendingStreamDelayMs = 1500L
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

  override var noiseSuppression: Boolean = false
    set(value) {
      if (field == value) return
      if (camera.isStreaming) {
        Log.w(TAG, "noiseSuppression change ignored while streaming")
        return
      }
      field = value
      // Same rationale as audioSource: re-prepare so the new DSP state is
      // applied immediately instead of silently waiting for the next prepareAudio.
      if (audioPrepared) reapplyAudioConfig()
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
    // DSP precedence:
    //  1. Explicit `noiseSuppression={true}` — always on (echoCanceler +
    //     noiseSuppressor + AGC via Android's AudioEffect APIs).
    //  2. Otherwise, MIC / VOICE_COMMUNICATION sources implicitly engage DSP
    //     because those sources are tuned for phone-call-style processing.
    //  3. CAMCORDER / VOICE_RECOGNITION / UNPROCESSED keep DSP off so the
    //     broadband signal survives.
    val keepDsp = noiseSuppression ||
      audioSource == AudioSource.MIC ||
      audioSource == AudioSource.VOICECOMMUNICATION
    val ok = safe("prepareAudio", default = false) {
      camera.prepareAudio(source, b, s, isStereo, keepDsp, keepDsp)
    }
    if (ok) {
      lastAudioCfg = AudioCfg(b, s, isStereo)
      audioPrepared = true
    } else {
      // Pedro returns false for two reasons: AudioRecord couldn't open the
      // source (almost always RECORD_AUDIO not granted yet, or the source isn't
      // supported on this device), or the AAC encoder couldn't be selected.
      // Either way the audio track is silently absent from the stream — log
      // loudly so callers can see why and fix the cause.
      Log.w(TAG, "prepareAudio FAILED — audio will be missing from the stream. " +
        "Check RECORD_AUDIO permission, audioSource='$audioSource', " +
        "sampleRate=$s, isStereo=$isStereo, and 'MicrophoneManager: create microphone error' / " +
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
      safe("forceFpsLimit") { camera.forceFpsLimit(desiredForceFpsLimit) }
      if (autoRotateStream) enableOrientationListener()
      ok = true
    }
    return ok
  }

  override fun stopPreview() {
    lastPreview = null
    disableOrientationListener()
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
    safe("startStream") {
      acquireWakeLock()
      setKeepScreenOn(true)
      shouldBeStreaming = true
      disconnectEmitted = false
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
      }
      // Reset adaptive-bitrate state so each session starts from the ceiling.
      bitrateAdapter?.reset()
      // Apply stream-mode tuning to the fresh streamClient state.
      applyStreamMode()
      camera.startStream(url)
    }
  }

  override fun stopStream() {
    pendingStream = null
    pendingStreamDelayMs = 0L
    lastStreamUrl = null
    cancelPendingResume()
    shouldBeStreaming = false
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
      camera.streamClient.reTry(d, reason, null)
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

  // ─── Cleanup ────────────────────────────────────────────────────────────

  override fun onDropView() {
    // Detach the surface callback first so subsequent surface-lifecycle events
    // (which can fire during the cleanup below as the OpenGlView is detached
    // from the window) can't re-enter and touch a half-released camera.
    safe("onDropView/removeSurfaceCallback") {
      openGlView.holder.removeCallback(surfaceCallback)
    }
    shouldBeStreaming = false
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
    onRecordStatusChange = null
    onThermalWarning = null
  }
}
