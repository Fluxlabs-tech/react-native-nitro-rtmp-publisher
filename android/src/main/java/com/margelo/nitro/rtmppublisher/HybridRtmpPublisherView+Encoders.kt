package com.margelo.nitro.rtmppublisher

import android.app.ActivityManager
import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.util.Log
import com.pedro.encoder.TimestampMode
import com.pedro.encoder.input.audio.NoAudioEffect
import com.pedro.encoder.input.video.CameraHelper
import com.pedro.encoder.utils.CodecUtil

/**
 * OEMs whose ENTIRE lineup is budget single-mic and exposes multiple
 * `BUILTIN_MIC` entries in `audio_policy` config (HAL synthesises the
 * second channel by duplicating mono → doubling AudioRecord throughput
 * and AAC encoder CPU for zero perceived stereo → chunky playback on
 * budget chipsets that miss the 21 ms encoder deadline).
 *
 * **Restricted to brands where every shipped device has the problem.**
 * `oppo` / `oneplus` / `redmi` were originally included here but their
 * lineups span both fake-stereo budget tiers AND real-stereo flagships
 * (Find X, OnePlus 8+, Redmi Note Pro / K series). Forcing those
 * flagships to mono would lose real stereo capability — so they're
 * handled via [KNOWN_SINGLE_MIC_MODELS] on a per-device basis instead.
 *
 * Add to this set only if a brand is universally single-mic (no
 * flagship lineup exists under the brand name).
 */
private val FAKE_STEREO_BUILTIN_MIC_BRANDS = setOf(
  "realme",
)

/**
 * Specific `Build.MODEL` codes (NOT consumer names — Android exposes the
 * SKU code via `Build.MODEL`, e.g. "BE2013" for OnePlus Nord N100, not
 * "Nord N100") known to ship a single mic capsule with fake-stereo
 * synthesis. Used for brands whose lineups span both real-stereo
 * flagships and fake-stereo budget tiers, where brand-level matching
 * would force mono on capable devices.
 *
 * Matching is case-insensitive exact-match against `Build.MODEL`. Add
 * new entries as field reports come in. Reference for common ones:
 * - OnePlus Nord N100 = `BE2013`, N200 = `DE2118`, N300 = `CPH2389`
 * - Oppo A77 5G = `CPH2477`, Oppo A78 = `CPH2565`
 * - Redmi 12 = `23053RN02A`, Redmi A1 = `220733SI`
 *
 * Empty by default — populate when a real user reports chunky audio on
 * a device whose brand isn't in [FAKE_STEREO_BUILTIN_MIC_BRANDS].
 */
private val KNOWN_SINGLE_MIC_MODELS = setOf<String>(
  // Seed example: the Realme C75x ("RMX5313") we diagnosed in v0.6.2.
  // Already covered by the brand=realme check above, listed here only as
  // a worked example of the format for future entries.
  // "RMX5313",
)

/**
 * Encoder + GL pipeline configuration. Codec selection, mirror flags, audio
 * re-prepare on source change, encoder re-prepare after Pedro releases the
 * MediaCodec on stopStream, and the streamMode tuning that picks RTMP cache
 * size / chunk size / timestamp mode for the active session.
 */

internal fun HybridRtmpPublisherView.applyCodecType() {
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

/**
 * Coarse "go easy on the GPU" signal, used to pick the mediump beauty shader
 * over the stock highp one (see [HybridRtmpPublisherView.applyBeautyFilter]).
 *
 * Leans on Android's own low-RAM flag (OEMs set `ro.config.low_ram` on budget
 * SKUs) plus a total-RAM threshold: **8 GB and below is treated as budget**,
 * so only 12 GB+ flagships default to highp. RAM is a proxy for GPU tier —
 * reliable GPU detection needs a live GL context — but it tracks the hardware
 * well: that band ships the weaker GPUs that run `highp` at half rate and have
 * the least memory bandwidth to spare while the camera ISP, GL pipeline, and
 * H.264 encoder all contend for it. The threshold errs generous on purpose:
 * mediump is visually indistinguishable from highp here, so a false positive
 * costs nothing, while leaving a budget phone on highp risks frames / heat.
 */
internal fun HybridRtmpPublisherView.isLowEndDevice(): Boolean {
  val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
    ?: return false
  if (am.isLowRamDevice) return true
  val info = ActivityManager.MemoryInfo()
  am.getMemoryInfo(info)
  // totalMem under-reports marketed RAM (the kernel/firmware reserves a slice),
  // so round up to recover the marketed figure (3.7 GiB → 4, 7.5 GiB → 8)
  // before comparing — otherwise a raw-bytes cutoff clips the boundary.
  val marketedGb = Math.ceil(info.totalMem / (1024.0 * 1024 * 1024)).toInt()
  return marketedGb <= 8
}

internal fun HybridRtmpPublisherView.applyMirrorFlags() {
  // `mirrorPreview` controls the publisher (on-screen) view ONLY.
  // `mirrorStream` controls the subscriber (encoded RTMP) view ONLY.
  // The two are fully independent — changing one never affects the other.
  //
  // Front-camera inversion: Pedro's `setIsPreviewHorizontalFlip(true)` on
  // the GL render produces the selfie view (raw camera horizontally flipped
  // → user's raised left hand appears on the left of the screen). iOS with
  // the same prop value produces the raw / viewer-perspective view (left
  // hand on the right of the screen). To match iOS so the same JSX gives
  // the same visual on both platforms, we INVERT the flag's effect on the
  // front camera. Back camera is left literal — Pedro's raw output for the
  // back camera already matches the natural viewing convention.
  //
  // Net effect with the example's `mirrorPreview={isFront} mirrorStream={isFront}`:
  //   Front camera, both = true  → both flags applied as `false` → raw preview + raw stream (matches iOS)
  //   Back  camera, both = false → both flags applied as `false` → raw preview + raw stream
  //   Asymmetric (e.g. mirrorPreview=true, mirrorStream=false on front):
  //     preview = raw (publisher sees natural)
  //     stream  = flipped (subscriber sees the publisher mirrored)
  //
  // glInterface is only fully initialised once preview is up — per-call
  // safe() so a prop set before preview never crashes the JS side, and a
  // failed preview-flip can't block the stream-flip (and vice versa).
  val isFront = safe("applyMirrorFlags/facing", default = false) {
    camera.cameraFacing == CameraHelper.Facing.FRONT
  }
  val previewFlip = if (isFront) !mirrorPreview else mirrorPreview
  val streamFlip  = if (isFront) !mirrorStream  else mirrorStream
  safe("applyMirrorFlags/preview") {
    camera.glInterface.setIsPreviewHorizontalFlip(previewFlip)
  }
  safe("applyMirrorFlags/stream") {
    camera.glInterface.setIsStreamHorizontalFlip(streamFlip)
  }
}

/**
 * How many distinct physical built-in mic capsules the device exposes to
 * AudioManager — used as the signal of "true stereo capable" vs "single
 * capsule with fake-stereo synthesis".
 *
 * Why count physical entries instead of a single device's channelCount?
 * Many single-mic phones (Realme C75x, most UNISOC/budget MediaTek phones,
 * countless Oppo/Xiaomi budget SKUs) ship one capsule but report
 * `channelCounts = [1, 2]` on their lone BUILTIN_MIC entry, claiming
 * stereo support. The HAL accepts the stereo request and synthesises the
 * second channel by duplicating the mono signal — exactly the failure
 * mode we want to avoid. Counting separately-registered AudioDeviceInfo
 * entries works around the lie: Pixel / Galaxy / OnePlus 8+ multi-mic
 * arrays expose 2-3 entries (`@:bottom`, `@:top`, sometimes `@:back`),
 * single-capsule phones expose exactly 1.
 *
 * Returns null if AudioManager is unavailable (extremely rare).
 */
internal fun HybridRtmpPublisherView.builtInMicCount(): Int? {
  val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    ?: return null
  return safe("builtInMicCount", default = null) {
    am.getDevices(AudioManager.GET_DEVICES_INPUTS)
      .count { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }
  }
}

/**
 * Resolves the caller's `isStereo` flag against the hardware reality.
 *
 * Forces mono when:
 *   - Only one built-in mic capsule is exposed (single-capsule phone — all
 *     budget tier and a chunk of mid-range), OR
 *   - We can't enumerate (defensive fallback also forces mono since stereo
 *     on a single-capsule device is a CPU tax with no benefit).
 *
 * Cost of getting this wrong (asking for stereo on a single-mic device):
 *   - 2× AudioRecord PCM bytes per callback
 *   - ~1.6× AAC software-encoder CPU per frame
 *   - On low-end UNISOC/MediaTek chips, audio thread misses its 21 ms
 *     deadline → encoder drops frames → audibly chunky playback
 *
 * Legitimate multi-mic devices (Pixel 6+, Galaxy S20+, OnePlus 8+, every
 * iPhone) expose 2+ BUILTIN_MIC entries and keep stereo as requested.
 */
internal fun HybridRtmpPublisherView.resolveEffectiveStereo(requestedStereo: Boolean): Boolean {
  if (!requestedStereo) return false
  val brand = Build.BRAND.lowercase()
  val manufacturer = Build.MANUFACTURER.lowercase()
  val model = Build.MODEL.uppercase()
  val micCount = builtInMicCount()
  // Brand override: universally single-mic brands (just `realme` today;
  // see [FAKE_STEREO_BUILTIN_MIC_BRANDS] for why oppo/oneplus/redmi are
  // NOT in this set even though their budget tier shares the bug).
  val brandForcesMono = brand in FAKE_STEREO_BUILTIN_MIC_BRANDS ||
    manufacturer in FAKE_STEREO_BUILTIN_MIC_BRANDS
  // Model override: catches specific budget SKUs from mixed-lineup brands
  // (Oppo A-series, OnePlus Nord N, Redmi 12, etc.) without forcing mono
  // on flagship siblings under the same brand.
  val modelForcesMono = model in KNOWN_SINGLE_MIC_MODELS
  Log.i(
    TAG,
    "resolveEffectiveStereo: requested=true, brand=$brand, manufacturer=$manufacturer, " +
      "model=$model, builtInMicCount=${micCount ?: "?"}, " +
      "brandForcesMono=$brandForcesMono, modelForcesMono=$modelForcesMono"
  )
  if (brandForcesMono) {
    Log.i(TAG, "isStereo=true on known fake-stereo brand ($manufacturer); capturing mono")
    return false
  }
  if (modelForcesMono) {
    Log.i(TAG, "isStereo=true on known fake-stereo model ($model); capturing mono")
    return false
  }
  if (micCount != null && micCount >= 2) return true
  Log.i(
    TAG,
    "isStereo=true requested but device exposes ${micCount ?: "?"} built-in mic(s); " +
      "capturing mono to avoid fake-stereo synthesis (would double AAC CPU for no benefit)"
  )
  return false
}

internal fun HybridRtmpPublisherView.reapplyAudioConfig() {
  val a = lastAudioCfg ?: return
  val source = audioSource.toMediaRecorderSource()
  val keepDsp = audioSource == AudioSource.MIC ||
    audioSource == AudioSource.VOICECOMMUNICATION
  val ok = safe("reapplyAudio", default = false) {
    camera.prepareAudio(source, a.bitrate, a.sampleRate, a.isStereo, keepDsp, keepDsp)
  }
  audioPrepared = ok
  // prepareAudio rebuilds the MicrophoneManager, which drops any previously
  // installed custom effect — so re-install (or clear) the spectral denoiser.
  applyNoiseSuppressor()
}

/**
 * Install / clear the spectral noise suppressor ([SpectralNoiseSuppressor]) on
 * RootEncoder's mic tap — the Android mechanism behind the [noiseSuppression]
 * prop.
 *
 * Note this is NOT the OS `NoiseSuppressor` / `AcousticEchoCanceler`: those are
 * the `keepDsp` flags passed to `prepareAudio`, which are now driven purely by
 * the [audioSource] mode (MIC / VOICE_COMMUNICATION engage phone-call DSP).
 * `noiseSuppression` deliberately bypasses them because they barely touch a
 * steady fan — it runs this custom spectral denoiser instead.
 *
 * The effect is sample-rate- and channel-count-specific, so it is rebuilt from
 * [lastAudioCfg] whenever audio is (re)prepared. When audio hasn't been
 * prepared yet there is no MicrophoneManager to attach to — the prop value is
 * just remembered and applied at the next [HybridRtmpPublisherView.prepareAudio].
 *
 * Live-swappable: `setCustomAudioEffect` only swaps a field read by the mic
 * thread, so toggling mid-stream is safe (a fresh instance re-learns the noise
 * floor over its short bootstrap window).
 */
internal fun HybridRtmpPublisherView.applyNoiseSuppressor() {
  val a = lastAudioCfg ?: return
  if (noiseSuppression) {
    val channels = if (a.isStereo) 2 else 1
    safe("applyNoiseSuppressor/on") {
      camera.setCustomAudioEffect(SpectralNoiseSuppressor(a.sampleRate, channels))
    }
  } else {
    safe("applyNoiseSuppressor/off") {
      camera.setCustomAudioEffect(NoAudioEffect())
    }
  }
}

// Re-prepare the encoders that Pedro released in stopStream. Skips work if
// they're already prepared (first ever start, or JS explicitly re-prepared).
internal fun HybridRtmpPublisherView.rePrepareEncodersIfNeeded() {
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
      val keepDsp = audioSource == AudioSource.MIC ||
        audioSource == AudioSource.VOICECOMMUNICATION
      val ok = safe("rePrepareAudio", default = false) {
        camera.prepareAudio(source, a.bitrate, a.sampleRate, a.isStereo, keepDsp, keepDsp)
      }
      if (ok) {
        audioPrepared = true
        // The fresh MicrophoneManager has no effect attached yet — re-install.
        applyNoiseSuppressor()
      }
    }
  }
}

// ─── Stream-mode tuning ───────────────────────────────────────────────────
//
// Note on send delay: Pedro's `forceIncrementalTs(true)` is literally just
// `setDelay(300L)` (and `forceIncrementalTs(false)` is a no-op). We use
// `setDelay(...)` directly so it's obvious what's actually happening. The
// delay buffers the first ~Nms of frames before sending, which lets the
// sender interleave the video config (SPS/PPS), the first IDR keyframe,
// and audio config in the right order — fragile ingests (YouTube, some
// Nginx-RTMP setups) reject the publish if audio arrives before SPS/IDR.
//
// Per-call safe wrapping — a single failing setter must not skip the rest
// (notably setTimestampMode, whose absence causes broken-pipe on CLOCK-mode
// ingests like agoramdn.com).
internal fun HybridRtmpPublisherView.applyStreamMode() {
  val client = safe("applyStreamMode/client", default = null) { camera.streamClient }
    ?: return
  // The mode is invisible in field logs otherwise — and it decides chunk size /
  // cache depth, which is exactly what stall/broken-pipe reports hinge on
  // (e.g. the agoramdn 8192-chunk quirk).
  Log.i(TAG, "applyStreamMode: $streamMode")
  when (streamMode) {
    StreamMode.LOWLATENCY -> {
      safe("streamMode/lowLatency/resizeCache") { client.resizeCache(60) }
      safe("streamMode/lowLatency/chunkSize")   { client.setWriteChunkSize(4096) }
      safe("streamMode/lowLatency/delay")       { client.setDelay(0L) }
      safe("streamMode/lowLatency/expFactor")   { client.setBitrateExponentialFactor(2f) }
      safe("streamMode/lowLatency/tsMode")      {
        camera.setTimestampMode(TimestampMode.BUFFER, TimestampMode.BUFFER)
      }
    }
    StreamMode.BALANCED -> {
      safe("streamMode/balanced/resizeCache") { client.resizeCache(120) }
      safe("streamMode/balanced/chunkSize")   { client.setWriteChunkSize(4096) }
      safe("streamMode/balanced/delay")       { client.setDelay(150L) }
      safe("streamMode/balanced/expFactor")   { client.setBitrateExponentialFactor(1f) }
      safe("streamMode/balanced/tsMode")      {
        camera.setTimestampMode(TimestampMode.CLOCK, TimestampMode.CLOCK)
      }
    }
    StreamMode.QUALITY -> {
      safe("streamMode/quality/resizeCache") { client.resizeCache(240) }
      safe("streamMode/quality/chunkSize")   { client.setWriteChunkSize(8192) }
      safe("streamMode/quality/delay")       { client.setDelay(300L) }
      safe("streamMode/quality/expFactor")   { client.setBitrateExponentialFactor(0.5f) }
      safe("streamMode/quality/tsMode")      {
        camera.setTimestampMode(TimestampMode.CLOCK, TimestampMode.CLOCK)
      }
    }
  }
}
