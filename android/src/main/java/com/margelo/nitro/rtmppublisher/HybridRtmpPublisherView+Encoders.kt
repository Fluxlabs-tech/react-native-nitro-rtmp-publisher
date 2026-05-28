package com.margelo.nitro.rtmppublisher

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.util.Log
import com.pedro.encoder.TimestampMode
import com.pedro.encoder.input.video.CameraHelper
import com.pedro.encoder.utils.CodecUtil

/**
 * OEMs whose audio_policy config exposes multiple `BUILTIN_MIC` entries
 * (`@:bottom` + `@:back` etc.) even though the phone physically ships a
 * single capsule. On these devices the HAL synthesises the second channel
 * by duplicating mono — doubling AudioRecord throughput and AAC encoder
 * CPU for zero perceived stereo, and on budget chipsets pushing the audio
 * thread past its 21 ms deadline (chunky playback).
 *
 * Counting `AudioDeviceInfo` entries doesn't catch these because Android
 * trusts the config XML; we have to fall back to brand string. Add to this
 * set if you find another OEM doing the same thing.
 */
private val FAKE_STEREO_BUILTIN_MIC_BRANDS = setOf(
  "realme",
  "oppo",
  "oneplus",
  // Xiaomi/Redmi budget SKUs do the same; mid-range and flagship usually
  // ship real dual-mic arrays. Coarse-grained: catches more false
  // positives but the cost (mono instead of fake-stereo) is acceptable.
  "redmi",
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
  val micCount = builtInMicCount()
  // Brand override comes first — Realme/Oppo/OnePlus/Redmi expose multiple
  // BUILTIN_MIC entries in their audio_policy XML even though only one
  // capsule physically exists. The count heuristic alone is fooled by
  // this; brand string is the only reliable signal. See
  // [FAKE_STEREO_BUILTIN_MIC_BRANDS] for the rationale.
  val brandForcesMono = brand in FAKE_STEREO_BUILTIN_MIC_BRANDS ||
    manufacturer in FAKE_STEREO_BUILTIN_MIC_BRANDS
  // Always log the decision inputs so it's observable in logcat without
  // a debugger attached.
  Log.i(
    TAG,
    "resolveEffectiveStereo: requested=true, brand=$brand, manufacturer=$manufacturer, " +
      "builtInMicCount=${micCount ?: "?"}, brandForcesMono=$brandForcesMono"
  )
  if (brandForcesMono) {
    Log.i(TAG, "isStereo=true on known fake-stereo OEM ($manufacturer); capturing mono")
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
  val keepDsp = noiseSuppression ||
    audioSource == AudioSource.MIC ||
    audioSource == AudioSource.VOICECOMMUNICATION
  val ok = safe("reapplyAudio", default = false) {
    camera.prepareAudio(source, a.bitrate, a.sampleRate, a.isStereo, keepDsp, keepDsp)
  }
  audioPrepared = ok
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
