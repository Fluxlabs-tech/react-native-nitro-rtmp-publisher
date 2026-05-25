package com.margelo.nitro.rtmppublisher

import com.pedro.encoder.TimestampMode
import com.pedro.encoder.input.video.CameraHelper
import com.pedro.encoder.utils.CodecUtil

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
