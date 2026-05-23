package com.margelo.nitro.rtmppublisher

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.media.MediaRecorder
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import android.view.OrientationEventListener
import android.view.SurfaceHolder
import android.view.View
import androidx.core.content.ContextCompat
import com.margelo.nitro.views.HybridView
import com.pedro.common.AudioCodec as PedroAudioCodec
import com.pedro.common.ConnectChecker
import com.pedro.common.VideoCodec as PedroVideoCodec
import com.pedro.encoder.TimestampMode
import com.pedro.encoder.input.video.CameraHelper
import com.pedro.encoder.utils.CodecUtil
import com.pedro.encoder.utils.gl.AspectRatioMode as PedroAspectRatioMode
import com.pedro.library.base.recording.RecordController
import com.pedro.library.rtmp.RtmpCamera2
import com.pedro.library.util.BitrateAdapter
import com.pedro.library.view.OpenGlView

private const val TAG = "RtmpPublisherView"
private const val WAKE_LOCK_TAG = "RtmpPublisher::WakeLock"

// Camera2 only allows one open camera per process. Track the active publisher
// instance so a second mount can fail loudly instead of silently breaking the
// first one's preview.
@Volatile private var activePublisherCount = 0

/**
 * Nitro HybridView that wraps RootEncoder's [RtmpCamera2] + [OpenGlView] and
 * exposes the publisher API to JavaScript.
 *
 * All per-frame paths (camera capture, GL render, H.264/AAC encode, RTMP TX)
 * stay native — the JS bridge is only touched on lifecycle, state changes,
 * and (opt-in) bitrate / record-status updates.
 */
@SuppressLint("ViewConstructor")
class HybridRtmpPublisherView(private val context: Context) : HybridRtmpPublisherViewSpec() {

  // ─── Native views & encoder ──────────────────────────────────────────────

  private val openGlView = OpenGlView(context)

  @Volatile private var onConnectionEvent: ((RtmpConnectionEvent, String) -> Unit)? = null
  @Volatile private var onBitrateChange: ((Double) -> Unit)? = null
  @Volatile private var onRecordStatusChange: ((RecordStatus) -> Unit)? = null
  @Volatile private var onThermalWarning: ((ThermalStatus) -> Unit)? = null

  // Last known preview config. Kept alive across surface destroy/create cycles
  // (host activity background/foreground, rotation) so the preview auto-restores.
  // Cleared only on explicit `stopPreview()` or `onDropView()`.
  private var lastPreview: PreviewConfig? = null
  private var pendingStream: String? = null
  private var surfaceReady = false

  // Encoder prepare-state caches. RootEncoder's BaseEncoder.stop() releases the
  // MediaCodec and flips `prepared` to false, so the next startStream would
  // throw IllegalStateException("not prepared yet"). We cache the last-known
  // prepareVideo / prepareAudio args and silently re-prepare in startStream so
  // JS can stop+start repeatedly without having to call prepare* again.
  private var lastVideoCfg: VideoCfg? = null
  private var lastAudioCfg: AudioCfg? = null
  @Volatile private var videoPrepared = false
  @Volatile private var audioPrepared = false

  // Auto-reconnect config + state.
  private var autoReconnectMaxAttempts = 0
  private var autoReconnectBackoffMs = 0L

  // Adaptive bitrate. Null when disabled.
  @Volatile private var bitrateAdapter: BitrateAdapter? = null
  // True between `startStream` and an explicit `stopStream` / drop / surface loss.
  // Gates auto-reconnect so we don't retry against a torn-down camera/surface.
  @Volatile private var shouldBeStreaming = false

  // True iff WE started the FG service (so we know it's safe to stop it on
  // stopStream / drop without yanking some other component's notification).
  private var fgServiceStartedByUs = false

  // True iff this instance currently holds the single active-publisher slot.
  // Set in startPreviewInternal, cleared in onDropView. Used so multiple
  // mounted views fail loudly instead of silently fighting for the camera.
  private var holdsActiveSlot = false

  // Thermal monitoring. The OS listener is only registered after JS subscribes
  // via `setOnThermalWarning` — if you never subscribe, the library never
  // touches PowerManager.
  private var thermalThresholdLevel = PowerManager.THERMAL_STATUS_SEVERE
  @Volatile private var lastThermalStatusInt = PowerManager.THERMAL_STATUS_NONE
  private var thermalListenerRegistered = false
  private val thermalListener =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
      PowerManager.OnThermalStatusChangedListener { status -> onThermalStatusChanged(status) }
    else null

  // Force-FPS-limit state. When true, Camera2 AE_TARGET_FPS_RANGE is locked
  // to [fps, fps]; otherwise auto-exposure can drop to 15fps in low light.
  // The actual call into RootEncoder needs preview to be alive, so we cache
  // the desired value and reapply after each startPreview.
  private var desiredForceFpsLimit = true

  // Orientation listener. Drives setStreamRotation automatically when
  // `autoRotateStream` is true.
  @Volatile private var lastAutoAppliedRotation = -1
  private val orientationListener: OrientationEventListener =
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

  private var wakeLock: PowerManager.WakeLock? = null

  // Cached system service lookup. Cheap individually but called from hot-ish
  // paths (acquireWakeLock, thermal register/getter); the cache avoids
  // repeated ContextImpl HashMap lookups.
  private val powerManager: PowerManager? by lazy {
    context.getSystemService(Context.POWER_SERVICE) as? PowerManager
  }

  private val recordListener = RecordController.Listener { status ->
    onRecordStatusChange?.invoke(status.toNitro())
  }

  private val connectChecker = object : ConnectChecker {
    override fun onConnectionStarted(url: String) {
      onConnectionEvent?.invoke(RtmpConnectionEvent.CONNECTIONSTARTED, url)
    }
    override fun onConnectionSuccess() {
      onConnectionEvent?.invoke(RtmpConnectionEvent.CONNECTIONSUCCESS, "")
    }
    override fun onConnectionFailed(reason: String) {
      if (tryAutoReconnect(reason)) {
        onConnectionEvent?.invoke(RtmpConnectionEvent.RECONNECTING, reason)
        return
      }
      shouldBeStreaming = false
      releaseWakeLock()
      setKeepScreenOn(false)
      onConnectionEvent?.invoke(RtmpConnectionEvent.CONNECTIONFAILED, reason)
    }
    override fun onNewBitrate(bitrate: Long) {
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
    override fun onDisconnect() {
      if (tryAutoReconnect("disconnect")) {
        onConnectionEvent?.invoke(RtmpConnectionEvent.RECONNECTING, "disconnect")
        return
      }
      shouldBeStreaming = false
      releaseWakeLock()
      setKeepScreenOn(false)
      onConnectionEvent?.invoke(RtmpConnectionEvent.DISCONNECT, "")
    }
    override fun onAuthError() {
      onConnectionEvent?.invoke(RtmpConnectionEvent.AUTHERROR, "")
    }
    override fun onAuthSuccess() {
      onConnectionEvent?.invoke(RtmpConnectionEvent.AUTHSUCCESS, "")
    }
  }

  private val camera: RtmpCamera2 = RtmpCamera2(openGlView, connectChecker)

  init {
    openGlView.holder.addCallback(object : SurfaceHolder.Callback {
      override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceReady = true
        // Re-open the camera every time the surface comes back (first mount AND
        // background→foreground / rotation). Stream auto-resume is intentionally
        // NOT done — JS already got a `disconnect` event and can decide.
        lastPreview?.let { p -> startPreviewInternal(p.facing, p.width, p.height) }
        pendingStream?.let { url ->
          startStreamInternal(url)
          pendingStream = null
        }
      }
      override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
      override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceReady = false
        val wasStreaming = camera.isStreaming
        // Disable auto-reconnect BEFORE stopStream: the subsequent onDisconnect
        // would otherwise try to retry against a dead surface.
        shouldBeStreaming = false
        try {
          if (camera.isStreaming) {
            camera.stopStream()
            // Codecs released — re-prepare on next start.
            videoPrepared = false
            audioPrepared = false
          }
          if (camera.isOnPreview) camera.stopPreview()
        } catch (e: Exception) {
          Log.w(TAG, "Error during surfaceDestroyed cleanup", e)
        }
        releaseWakeLock()
        if (wasStreaming) {
          // The stream was forcibly torn down by the host (rotation, backgrounding,
          // unmount). Notify JS so its `streaming` state doesn't silently diverge.
          onConnectionEvent?.invoke(
            RtmpConnectionEvent.DISCONNECT,
            "surface destroyed"
          )
        }
      }
    })
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
      // Reapplied on the next prepareAudio call. If audio is already prepared,
      // the user should resetAudioEncoder() to pick this up.
    }

  override var noiseSuppression: Boolean = false
    set(value) {
      if (field == value) return
      if (camera.isStreaming) {
        Log.w(TAG, "noiseSuppression change ignored while streaming")
        return
      }
      field = value
      // Applied on the next prepareAudio call. Existing AudioRecord session
      // won't have the new DSP state until the encoder is re-prepared, so
      // recommend the caller invoke resetAudioEncoder() afterwards.
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
  override var foregroundServiceText: String = ""

  private fun applyCodecType() {
    val videoType = if (forceHardwareCodec) CodecUtil.CodecType.HARDWARE
                    else CodecUtil.CodecType.FIRST_COMPATIBLE_FOUND
    // AAC encoder is software on most Android devices (`c2.android.aac.encoder`
    // / `OMX.google.aac.encoder`). Forcing HARDWARE there makes Pedro's
    // chooseEncoder return null, prepareAudioEncoder returns false, and the
    // entire audio track is silently dropped from the RTMP stream. Always let
    // it pick whichever AAC encoder the device actually ships.
    val audioType = CodecUtil.CodecType.FIRST_COMPATIBLE_FOUND
    camera.forceCodecType(videoType, audioType)
  }

  private fun applyMirrorFlags() {
    // glInterface is only fully initialised once preview is up. Wrap in
    // try/catch so a prop set before preview never crashes the JS side.
    safe("applyMirrorFlags") {
      camera.glInterface.setIsPreviewHorizontalFlip(mirrorPreview)
      camera.glInterface.setIsStreamHorizontalFlip(mirrorStream)
    }
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

  // Re-prepare the encoders that Pedro released in stopStream. Skips work if
  // they're already prepared (first ever start, or JS explicitly re-prepared).
  private fun rePrepareEncodersIfNeeded() {
    if (!videoPrepared) {
      val v = lastVideoCfg
      if (v != null) {
        applyCodecType()
        applyStreamMode()
        val ok = safe("rePrepareVideo", default = false) {
          camera.prepareVideo(v.w, v.h, v.fps, v.bitrate, v.iFrame, v.rotation)
        }
        if (ok) videoPrepared = true
      }
    }
    if (!audioPrepared) {
      val a = lastAudioCfg
      if (a != null) {
        val source = audioSource.toMediaRecorderSource()
        val keepDsp = noiseSuppression ||
          audioSource == AudioSource.MIC ||
          audioSource == AudioSource.VOICECOMMUNICATION
        val ok = safe("rePrepareAudio", default = false) {
          camera.prepareAudio(source, a.bitrate, a.sampleRate, a.isStereo, keepDsp, keepDsp)
        }
        if (ok) audioPrepared = true
      }
    }
  }

  override fun startPreview(facing: CameraFacing, width: Double, height: Double) {
    val w = width.toInt().coerceAtLeast(1)
    val h = height.toInt().coerceAtLeast(1)
    // Always cache so background→foreground can restore the preview.
    lastPreview = PreviewConfig(facing, w, h)
    if (!surfaceReady) return
    startPreviewInternal(facing, w, h)
  }

  private fun startPreviewInternal(facing: CameraFacing, width: Int, height: Int) {
    // Refuse if another publisher instance already holds the camera —
    // Camera2 doesn't allow concurrent opens from the same process and the
    // failure mode otherwise is silent (a black preview + cryptic logcat).
    if (!holdsActiveSlot) {
      if (activePublisherCount > 0) {
        Log.w(TAG, "Refusing to start preview — another <RtmpPublisherView> is active")
        onConnectionEvent?.invoke(
          RtmpConnectionEvent.CONNECTIONFAILED,
          "another <RtmpPublisherView> already holds the camera"
        )
        return
      }
      activePublisherCount += 1
      holdsActiveSlot = true
    }
    val helperFacing = when (facing) {
      CameraFacing.FRONT -> CameraHelper.Facing.FRONT
      CameraFacing.BACK -> CameraHelper.Facing.BACK
    }
    safe("startPreview") {
      if (camera.isOnPreview) camera.stopPreview()
      camera.startPreview(helperFacing, width, height)
      // glInterface + camera2 controls are live now — re-apply props that
      // depend on them.
      applyMirrorFlags()
      safe("forceFpsLimit") { camera.forceFpsLimit(desiredForceFpsLimit) }
      if (autoRotateStream) enableOrientationListener()
    }
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
    if (!surfaceReady) {
      pendingStream = url
      return
    }
    startStreamInternal(url)
  }

  private fun startStreamInternal(url: String) {
    safe("startStream") {
      maybeStartForegroundService()
      acquireWakeLock()
      setKeepScreenOn(true)
      shouldBeStreaming = true
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
    shouldBeStreaming = false
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
    safe("forceIncrementalTs") { camera.streamClient.forceIncrementalTs(enabled) }
  }

  override fun setStreamDelay(delayMs: Double) {
    val d = delayMs.toLong()
    safe("setStreamDelay") { camera.streamClient.setDelay(d) }
  }


  // ─── Reconnection ────────────────────────────────────────────────────────

  override fun setReTries(count: Double) {
    val c = count.toInt().coerceAtLeast(0)
    safe("setReTries") { camera.streamClient.setReTries(c) }
  }

  override fun reTry(delayMs: Double, reason: String): Boolean {
    val d = delayMs.toLong().coerceAtLeast(0L)
    return safe("reTry", default = false) {
      camera.streamClient.reTry(d, reason, null)
    }
  }

  override fun setAutoReconnect(maxAttempts: Double, backoffMs: Double) {
    autoReconnectMaxAttempts = maxAttempts.toInt().coerceAtLeast(0)
    autoReconnectBackoffMs = backoffMs.toLong().coerceAtLeast(0L)
    // Seed the budget right away so a manual `reTry()` call works without
    // first going through `startStream`.
    safe("setAutoReconnect/setReTries") {
      camera.streamClient.setReTries(autoReconnectMaxAttempts)
    }
  }

  private fun tryAutoReconnect(reason: String): Boolean {
    if (!shouldBeStreaming) return false
    if (autoReconnectMaxAttempts <= 0) return false
    if (!surfaceReady) return false
    return safe("reTry(auto)", default = false) {
      camera.streamClient.reTry(autoReconnectBackoffMs, reason, null)
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
    return safe("startRecord", default = false) {
      camera.startRecord(path, recordListener)
      true
    }
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
    shouldBeStreaming = false
    lastPreview = null
    pendingStream = null
    bitrateAdapter = null
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
      activePublisherCount = (activePublisherCount - 1).coerceAtLeast(0)
    }
    onConnectionEvent = null
    onBitrateChange = null
    onRecordStatusChange = null
    onThermalWarning = null
  }

  // ─── Wake-lock helpers ──────────────────────────────────────────────────

  private fun acquireWakeLock() {
    if (wakeLock?.isHeld == true) return
    try {
      val pm = powerManager ?: return
      val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
        setReferenceCounted(false)
      }
      lock.acquire(10 * 60 * 60 * 1000L /* 10h cap */)
      wakeLock = lock
    } catch (e: Exception) {
      Log.w(TAG, "acquireWakeLock failed: ${e.message}")
    }
  }

  private fun releaseWakeLock() {
    val lock = wakeLock ?: return
    try {
      if (lock.isHeld) lock.release()
    } catch (e: Exception) {
      Log.w(TAG, "releaseWakeLock failed: ${e.message}")
    }
    wakeLock = null
  }

  private fun setKeepScreenOn(on: Boolean) {
    safe("setKeepScreenOn") { openGlView.keepScreenOn = on }
  }

  // ─── Stream-mode helper ─────────────────────────────────────────────────

  private fun applyStreamMode() {
    val client = safe("applyStreamMode/client", default = null) { camera.streamClient }
      ?: return
    // Note on send delay: Pedro's `forceIncrementalTs(true)` is literally just
    // `setDelay(300L)` (and `forceIncrementalTs(false)` is a no-op). We use
    // `setDelay(...)` directly so it's obvious what's actually happening. The
    // delay buffers the first ~Nms of frames before sending, which lets the
    // sender interleave the video config (SPS/PPS), the first IDR keyframe,
    // and audio config in the right order — fragile ingests (YouTube, some
    // Nginx-RTMP setups) reject the publish if audio arrives before SPS/IDR.
    when (streamMode) {
      StreamMode.LOWLATENCY -> safe("streamMode/lowLatency") {
        client.resizeCache(60)               // ~1s at 30fps video frames
        client.setWriteChunkSize(4096)       // small chunks
        client.setDelay(0L)                  // no buffering — accepts the fragile-ingest risk
        client.setBitrateExponentialFactor(2f)
        // Use BUFFER timestamps (encoder pts) — lowest added latency.
        safe("setTimestampMode/lowLatency") {
          camera.setTimestampMode(TimestampMode.BUFFER, TimestampMode.BUFFER)
        }
      }
      StreamMode.BALANCED -> safe("streamMode/balanced") {
        client.resizeCache(120)
        client.setWriteChunkSize(4096)
        client.setDelay(150L)                // small buffer for interleave; trades 150ms latency for ingest compat
        client.setBitrateExponentialFactor(1f)
        safe("setTimestampMode/balanced") {
          camera.setTimestampMode(TimestampMode.CLOCK, TimestampMode.CLOCK)
        }
      }
      StreamMode.QUALITY -> safe("streamMode/quality") {
        client.resizeCache(240)              // ~4s of frames buffered
        client.setWriteChunkSize(8192)
        client.setDelay(300L)                // large buffer — safe even on slow/fragile ingests
        client.setBitrateExponentialFactor(0.5f)
        // CLOCK timestamps are derived from monotonic system clock — best
        // for long sessions where MediaCodec PTS may drift.
        safe("setTimestampMode/quality") {
          camera.setTimestampMode(TimestampMode.CLOCK, TimestampMode.CLOCK)
        }
      }
    }
  }

  // ─── Foreground service helpers ─────────────────────────────────────────

  private fun maybeStartForegroundService() {
    if (foregroundServiceTitle.isEmpty()) return
    if (RtmpForegroundService.running) return
    if (RtmpForegroundService.start(context, foregroundServiceTitle, foregroundServiceText)) {
      fgServiceStartedByUs = true
    }
  }

  private fun maybeStopForegroundService() {
    if (!fgServiceStartedByUs) return
    safe("stopForegroundService") { RtmpForegroundService.stop(context) }
    fgServiceStartedByUs = false
  }

  // ─── Orientation helpers ─────────────────────────────────────────────────

  private fun enableOrientationListener() {
    if (!autoRotateStream) return
    if (orientationListener.canDetectOrientation()) {
      safe("enableOrientationListener") { orientationListener.enable() }
    }
  }

  private fun disableOrientationListener() {
    safe("disableOrientationListener") { orientationListener.disable() }
    lastAutoAppliedRotation = -1
  }

  // ─── Thermal helpers ────────────────────────────────────────────────────

  private fun registerThermalListener() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
    if (thermalListenerRegistered) return
    val listener = thermalListener ?: return
    val pm = powerManager ?: return
    safe("registerThermalListener") {
      pm.addThermalStatusListener(ContextCompat.getMainExecutor(context), listener)
      lastThermalStatusInt = pm.currentThermalStatus
      thermalListenerRegistered = true
    }
  }

  private fun unregisterThermalListener() {
    if (!thermalListenerRegistered) return
    val listener = thermalListener ?: return
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
    val pm = powerManager ?: return
    safe("unregisterThermalListener") {
      pm.removeThermalStatusListener(listener)
    }
    thermalListenerRegistered = false
  }

  private fun onThermalStatusChanged(newStatus: Int) {
    val previous = lastThermalStatusInt
    lastThermalStatusInt = newStatus
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

  // ─── Error-bounded execution ────────────────────────────────────────────

  private inline fun safe(op: String, crossinline block: () -> Unit) {
    try {
      block()
    } catch (e: Exception) {
      Log.w(TAG, "$op failed: ${e.message}", e)
    }
  }

  private inline fun <T> safe(op: String, default: T, crossinline block: () -> T): T {
    return try {
      block()
    } catch (e: Exception) {
      Log.w(TAG, "$op failed: ${e.message}", e)
      default
    }
  }

  private data class PreviewConfig(val facing: CameraFacing, val width: Int, val height: Int)

  private data class VideoCfg(
    val w: Int,
    val h: Int,
    val fps: Int,
    val bitrate: Int,
    val iFrame: Int,
    val rotation: Int,
  )

  private data class AudioCfg(
    val bitrate: Int,
    val sampleRate: Int,
    val isStereo: Boolean,
  )
}

// ────────────────────────────────────────────────────────────────────────────
// Enum mappers between Nitro and RootEncoder
// ────────────────────────────────────────────────────────────────────────────

private fun VideoCodec.toPedro(): PedroVideoCodec = when (this) {
  VideoCodec.H264 -> PedroVideoCodec.H264
  VideoCodec.H265 -> PedroVideoCodec.H265
  VideoCodec.AV1  -> PedroVideoCodec.AV1
}

private fun AudioCodec.toPedro(): PedroAudioCodec = when (this) {
  AudioCodec.AAC  -> PedroAudioCodec.AAC
  AudioCodec.G711 -> PedroAudioCodec.G711
  AudioCodec.OPUS -> PedroAudioCodec.OPUS
}

private fun AspectRatioMode.toPedro(): PedroAspectRatioMode = when (this) {
  AspectRatioMode.FILL   -> PedroAspectRatioMode.Fill
  AspectRatioMode.ADJUST -> PedroAspectRatioMode.Adjust
  AspectRatioMode.NONE   -> PedroAspectRatioMode.NONE
}

private fun RecordController.Status.toNitro(): RecordStatus = when (this) {
  RecordController.Status.STARTED   -> RecordStatus.STARTED
  RecordController.Status.STOPPED   -> RecordStatus.STOPPED
  RecordController.Status.RECORDING -> RecordStatus.RECORDING
  RecordController.Status.PAUSED    -> RecordStatus.PAUSED
  RecordController.Status.RESUMED   -> RecordStatus.RESUMED
}

private fun ThermalStatus.toPowerManagerStatus(): Int = when (this) {
  ThermalStatus.NONE      -> PowerManager.THERMAL_STATUS_NONE
  ThermalStatus.LIGHT     -> PowerManager.THERMAL_STATUS_LIGHT
  ThermalStatus.MODERATE  -> PowerManager.THERMAL_STATUS_MODERATE
  ThermalStatus.SEVERE    -> PowerManager.THERMAL_STATUS_SEVERE
  ThermalStatus.CRITICAL  -> PowerManager.THERMAL_STATUS_CRITICAL
  ThermalStatus.EMERGENCY -> PowerManager.THERMAL_STATUS_EMERGENCY
  ThermalStatus.SHUTDOWN  -> PowerManager.THERMAL_STATUS_SHUTDOWN
}

private fun Int.fromPowerManagerStatus(): ThermalStatus = when (this) {
  PowerManager.THERMAL_STATUS_NONE      -> ThermalStatus.NONE
  PowerManager.THERMAL_STATUS_LIGHT     -> ThermalStatus.LIGHT
  PowerManager.THERMAL_STATUS_MODERATE  -> ThermalStatus.MODERATE
  PowerManager.THERMAL_STATUS_SEVERE    -> ThermalStatus.SEVERE
  PowerManager.THERMAL_STATUS_CRITICAL  -> ThermalStatus.CRITICAL
  PowerManager.THERMAL_STATUS_EMERGENCY -> ThermalStatus.EMERGENCY
  PowerManager.THERMAL_STATUS_SHUTDOWN  -> ThermalStatus.SHUTDOWN
  else                                  -> ThermalStatus.NONE
}

private fun AudioSource.toMediaRecorderSource(): Int = when (this) {
  AudioSource.MIC                -> MediaRecorder.AudioSource.MIC
  AudioSource.CAMCORDER          -> MediaRecorder.AudioSource.CAMCORDER
  AudioSource.VOICERECOGNITION   -> MediaRecorder.AudioSource.VOICE_RECOGNITION
  AudioSource.VOICECOMMUNICATION -> MediaRecorder.AudioSource.VOICE_COMMUNICATION
  AudioSource.UNPROCESSED -> {
    // UNPROCESSED is API 24+. Fall back to VOICE_RECOGNITION on older devices.
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N)
      MediaRecorder.AudioSource.UNPROCESSED
    else
      MediaRecorder.AudioSource.VOICE_RECOGNITION
  }
}
