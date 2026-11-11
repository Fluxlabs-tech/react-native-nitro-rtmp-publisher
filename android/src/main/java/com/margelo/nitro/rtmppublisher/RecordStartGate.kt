package com.margelo.nitro.rtmppublisher

import android.media.MediaCodec
import com.pedro.library.base.recording.RecordController
import java.io.FileDescriptor
import java.nio.ByteBuffer
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/**
 * Keeps encoder frames away from RootEncoder's recorder while a recording is
 * being started.
 *
 * RootEncoder 2.8's recorder marks itself STARTED, and starts taking frames,
 * before it has created the MediaMuxer. A keyframe that arrives in that gap
 * (about as long as it takes to create the file) "starts" the recording with
 * no muxer: the recorder reports RECORDING, then drops every frame, and the
 * file stays empty with no error. RootEncoder 2.6 created the muxer first.
 *
 * Here the encoder threads wait for startRecord to return instead, so the
 * first frame the recorder sees always finds its muxer. No frame is dropped.
 */
internal class RecordStartGate(
  private val recorder: RecordController
) : RecordController by recorder {
  private val gate = ReentrantReadWriteLock()

  override fun startRecord(
    path: String,
    listener: RecordController.Listener?,
    tracks: RecordController.RecordTracks
  ) = gate.write { recorder.startRecord(path, listener, tracks) }

  override fun startRecord(
    fd: FileDescriptor,
    listener: RecordController.Listener?,
    tracks: RecordController.RecordTracks
  ) = gate.write { recorder.startRecord(fd, listener, tracks) }

  override fun recordVideo(videoBuffer: ByteBuffer, videoInfo: MediaCodec.BufferInfo) =
    gate.read { recorder.recordVideo(videoBuffer, videoInfo) }

  override fun recordAudio(audioBuffer: ByteBuffer, audioInfo: MediaCodec.BufferInfo) =
    gate.read { recorder.recordAudio(audioBuffer, audioInfo) }
}
