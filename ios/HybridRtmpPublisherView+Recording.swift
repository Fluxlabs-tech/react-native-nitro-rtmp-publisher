//
//  HybridRtmpPublisherView+Recording.swift
//  NitroRtmpPublisher
//
//  Local recording via HK's `StreamRecorder`. The recorder is attached
//  to the `MediaMixer` (NOT the RTMPStream) so a network blip that
//  triggers a publish-stream rebuild doesn't tear the recording file —
//  the recorder keeps consuming captured frames straight from the mixer
//  through the reconnect. Trade-off: the recording has to be stopped
//  explicitly via `stopRecord` or `onDropView`.
//

import AVFoundation
import Foundation
import HaishinKit
import NitroModules

extension HybridRtmpPublisherView {

  func startRecord(path: String) throws -> Bool {
    if path.isBlank { return false }
    // Two-stage guard. `recordStatus` only flips to `.started` /
    // `.recording` inside the Task that calls `startRecording` async, so
    // a fast double-call from JS would see `recordStatus == .stopped` on
    // both invocations and spawn two recorders. `recorder` is set
    // synchronously below, so checking it short-circuits the second call.
    if recorder != nil || recordStatus != .stopped { return false }
    let destination = URL(fileURLWithPath: path)
    pendingRecordOutputUrl = destination
    let rec = StreamRecorder()
    recorder = rec
    let recVideoCodec: AVVideoCodecType = (videoCodec == .h265) ? .hevc : .h264
    let settings: [AVMediaType: [String: any Sendable]] = [
      .audio: [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: lastAudioCfg?.sampleRate ?? 44_100,
        AVNumberOfChannelsKey: (lastAudioCfg?.isStereo ?? true) ? 2 : 1,
      ],
      .video: [
        AVVideoCodecKey: recVideoCodec,
        AVVideoWidthKey: lastVideoCfg?.width ?? 1280,
        AVVideoHeightKey: lastVideoCfg?.height ?? 720,
      ],
    ]
    Task { [weak self] in
      guard let self else { return }
      do {
        await self.mixer.addOutput(rec)
        // Race check: if `stopRecord` ran while we were awaiting `addOutput`,
        // `self.recorder` is now nil (or a different instance). Without this
        // check, we'd proceed to `rec.startRecording()` AFTER stopRecord
        // already ran its `rec.stopRecording()` on a not-yet-started writer
        // (which throws). Net effect: the recorder gets started but never
        // stopped — AVAssetWriter dangles, disk space leaks.
        guard self.recorder === rec else {
          await self.mixer.removeOutput(rec)
          return
        }
        try await rec.startRecording(destination, settings: settings)
        // One more check — `stopRecord` could have raced past `addOutput`
        // but before `startRecording`. If so, immediately finalize.
        if self.recorder !== rec {
          await self.mixer.removeOutput(rec)
          _ = try? await rec.stopRecording()
          return
        }
        self.transitionRecordStatus(.started)
        self.transitionRecordStatus(.recording)
      } catch {
        self.log("startRecording failed: \(error)")
        // Detach to avoid leaking the recorder as an active mixer output —
        // it would otherwise keep receiving sample buffers and burning CPU
        // until the whole mixer tears down.
        await self.mixer.removeOutput(rec)
        self.recorder = nil
        self.transitionRecordStatus(.stopped)
      }
    }
    return true
  }

  func stopRecord() throws {
    guard let rec = recorder else {
      transitionRecordStatus(.stopped)
      return
    }
    recorder = nil
    Task { [weak self] in
      guard let self else { return }
      // Detach from the mixer FIRST so no more sample buffers get pushed
      // into a stopping recorder. Otherwise the recorder is held alive
      // by the mixer's `outputs` array forever (until the whole publisher
      // view drops) and continues consuming frames after stopRecording
      // returns — small but real CPU + memory leak per record session.
      await self.mixer.removeOutput(rec)
      do {
        let producedURL = try await rec.stopRecording()
        if let dest = self.pendingRecordOutputUrl, producedURL.path != dest.path {
          try? FileManager.default.removeItem(at: dest)
          try? FileManager.default.moveItem(at: producedURL, to: dest)
        }
        self.pendingRecordOutputUrl = nil
        self.transitionRecordStatus(.stopped)
      } catch {
        self.log("stopRecording failed: \(error)")
        self.transitionRecordStatus(.stopped)
      }
    }
  }

  func pauseRecord() throws { transitionRecordStatus(.paused) }
  func resumeRecord() throws {
    transitionRecordStatus(.resumed)
    transitionRecordStatus(.recording)
  }
  func getRecordStatus() throws -> RecordStatus { return recordStatus }

  func transitionRecordStatus(_ next: RecordStatus) {
    recordStatus = next
    emitRecordStatusChange(next)
  }
}
