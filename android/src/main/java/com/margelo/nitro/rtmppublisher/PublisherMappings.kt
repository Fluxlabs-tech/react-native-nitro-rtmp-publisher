package com.margelo.nitro.rtmppublisher

import android.media.MediaRecorder
import android.os.Build
import android.os.PowerManager
import com.pedro.common.AudioCodec as PedroAudioCodec
import com.pedro.common.VideoCodec as PedroVideoCodec
import com.pedro.encoder.utils.gl.AspectRatioMode as PedroAspectRatioMode
import com.pedro.library.base.recording.RecordController

/**
 * One-way enum mappers between Nitro spec types (what JS sees) and RootEncoder
 * / Android framework types (what the native side speaks). Kept off the main
 * view file so the conversion logic is greppable without scrolling past 1k
 * lines of lifecycle code.
 */

internal fun VideoCodec.toPedro(): PedroVideoCodec = when (this) {
  VideoCodec.H264 -> PedroVideoCodec.H264
  VideoCodec.H265 -> PedroVideoCodec.H265
  VideoCodec.AV1  -> PedroVideoCodec.AV1
}

internal fun AudioCodec.toPedro(): PedroAudioCodec = when (this) {
  AudioCodec.AAC  -> PedroAudioCodec.AAC
  AudioCodec.G711 -> PedroAudioCodec.G711
  AudioCodec.OPUS -> PedroAudioCodec.OPUS
}

internal fun AspectRatioMode.toPedro(): PedroAspectRatioMode = when (this) {
  AspectRatioMode.FILL   -> PedroAspectRatioMode.Fill
  AspectRatioMode.ADJUST -> PedroAspectRatioMode.Adjust
  AspectRatioMode.NONE   -> PedroAspectRatioMode.NONE
}

internal fun RecordController.Status.toNitro(): RecordStatus = when (this) {
  RecordController.Status.STARTED   -> RecordStatus.STARTED
  RecordController.Status.STOPPED   -> RecordStatus.STOPPED
  RecordController.Status.RECORDING -> RecordStatus.RECORDING
  RecordController.Status.PAUSED    -> RecordStatus.PAUSED
  RecordController.Status.RESUMED   -> RecordStatus.RESUMED
}

internal fun ThermalStatus.toPowerManagerStatus(): Int = when (this) {
  ThermalStatus.NONE      -> PowerManager.THERMAL_STATUS_NONE
  ThermalStatus.LIGHT     -> PowerManager.THERMAL_STATUS_LIGHT
  ThermalStatus.MODERATE  -> PowerManager.THERMAL_STATUS_MODERATE
  ThermalStatus.SEVERE    -> PowerManager.THERMAL_STATUS_SEVERE
  ThermalStatus.CRITICAL  -> PowerManager.THERMAL_STATUS_CRITICAL
  ThermalStatus.EMERGENCY -> PowerManager.THERMAL_STATUS_EMERGENCY
  ThermalStatus.SHUTDOWN  -> PowerManager.THERMAL_STATUS_SHUTDOWN
}

internal fun Int.fromPowerManagerStatus(): ThermalStatus = when (this) {
  PowerManager.THERMAL_STATUS_NONE      -> ThermalStatus.NONE
  PowerManager.THERMAL_STATUS_LIGHT     -> ThermalStatus.LIGHT
  PowerManager.THERMAL_STATUS_MODERATE  -> ThermalStatus.MODERATE
  PowerManager.THERMAL_STATUS_SEVERE    -> ThermalStatus.SEVERE
  PowerManager.THERMAL_STATUS_CRITICAL  -> ThermalStatus.CRITICAL
  PowerManager.THERMAL_STATUS_EMERGENCY -> ThermalStatus.EMERGENCY
  PowerManager.THERMAL_STATUS_SHUTDOWN  -> ThermalStatus.SHUTDOWN
  else                                  -> ThermalStatus.NONE
}

internal fun AudioSource.toMediaRecorderSource(): Int = when (this) {
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
