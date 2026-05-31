//
//  AudioDenoisePipeline.swift
//
//  Audio capture for the iOS `noiseSuppression` path.
//
//  Approach (iOS-native): instead of a hand-rolled spectral denoiser (which dulls
//  the voice), we enable Apple's **Voice Processing I/O** on the AVAudioEngine
//  input node — the same ML-tuned noise suppressor + echo canceller used by
//  FaceTime/Siri — and crucially DISABLE its automatic gain control. AGC is what
//  made `AVAudioSession.Mode.voiceChat` sound "phone-call" (it compresses/levels
//  the voice); turning it off keeps the voice's natural dynamics while still
//  getting Apple's high-quality, non-muffling noise removal.
//
//  HaishinKit's `MediaMixer` is an actor with no audio-effect hook and captures
//  via AVCaptureSession (which does NOT run Voice Processing IO), so we own
//  capture with AVAudioEngine, let the input node clean the audio, and forward
//  the already-processed buffers to the mixer via `mixer.append`. Only used while
//  `noiseSuppression` is ON; when OFF the view uses `mixer.attachAudio(mic)`.
//
//  Ordering: the tap fires on one serial audio thread. We copy the (already
//  noise-suppressed) buffer there and hand it to a single-consumer `AsyncStream`
//  `Task` that calls the actor-isolated `mixer.append` IN ORDER, preserving the
//  `when` timestamp so A/V sync is anchored at capture time.
//
//  Trade-off: Apple's processor is voice-isolation, so non-voice background
//  (incl. music) is suppressed along with steady noise — but the voice is NOT
//  muffled and NOT gain-compressed.
//

@preconcurrency import AVFoundation
import HaishinKit

final class AudioDenoisePipeline {

  private let engine = AVAudioEngine()
  private var continuation: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>.Continuation?
  private var consumerTask: Task<Void, Never>?
  private(set) var isRunning = false
  // Remembered so the configuration-change handler can restart the graph.
  private weak var mixer: MediaMixer?
  private var configObserver: NSObjectProtocol?

  enum PipelineError: Error { case invalidInputFormat }

  /// Start capturing through Apple's Voice Processing (AGC off) and feeding
  /// `mixer`. Caller must have an active `.playAndRecord` session already (see
  /// `configureAudioSession`). Throws if voice processing or the engine can't
  /// start — caller should fall back to `mixer.attachAudio(mic)`.
  func start(mixer: MediaMixer) throws {
    if isRunning { return }
    self.mixer = mixer

    let input = engine.inputNode

    // Apple's NS + AEC on the input node. Must be set while the engine is stopped.
    try input.setVoiceProcessingEnabled(true)
    // Disable the auto-gain that gives voiceChat its compressed "phone-call"
    // sound — we want the voice's natural level/dynamics preserved.
    if #available(iOS 15.0, *) {
      input.isVoiceProcessingAGCEnabled = false
    }

    // Tap the node's OUTPUT (the voice-processed signal).
    let format = input.outputFormat(forBus: 0)
    guard format.channelCount > 0, format.sampleRate > 0 else {
      try? input.setVoiceProcessingEnabled(false)
      throw PipelineError.invalidInputFormat
    }

    // Large bounded queue as a safety valve. The high-priority consumer below
    // keeps this near-empty in normal use (append is cheap), so brief hiccups
    // never reach the limit — i.e. no drop-on-hiccup jitter. The cap only kicks
    // in on a sustained stall, where dropping is preferable to unbounded memory
    // growth (~couple seconds of audio at typical buffer sizes).
    var captured: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>.Continuation?
    let stream = AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>(
      bufferingPolicy: .bufferingNewest(96)
    ) { captured = $0 }
    continuation = captured

    // High priority so the consumer drains promptly and at a regular cadence —
    // a default-priority Task can be scheduled unevenly, bunching appends and
    // jittering the encoder's audio clock.
    consumerTask = Task(priority: .high) { [weak mixer] in
      for await (buffer, when) in stream {
        await mixer?.append(buffer, when: when, track: 0)
      }
    }

    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
      guard let self else { return }
      // The engine reuses `buffer` after this returns and the consumer reads it
      // asynchronously — hand off an owned copy.
      guard let owned = Self.copy(buffer) else { return }
      self.continuation?.yield((owned, when))
    }

    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      try? input.setVoiceProcessingEnabled(false)
      continuation?.finish(); continuation = nil
      consumerTask?.cancel(); consumerTask = nil
      throw error
    }
    isRunning = true

    // An audio route change mid-stream (plugging in headphones / connecting a BT
    // device) makes AVAudioEngine post this and stop itself — the input format
    // can also change. Rebuild the graph so audio keeps flowing instead of
    // silently dying until the next interruption/foreground cycle.
    configObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: .main
    ) { [weak self] _ in
      self?.handleConfigurationChange()
    }
  }

  private func handleConfigurationChange() {
    guard isRunning, let mixer else { return }
    // The engine already stopped itself; do a clean stop (clears the tap, stream,
    // consumer, observer, voice processing) and start fresh so the tap re-reads
    // the new input format. The brief gap is inherent to the route change.
    stop()
    do {
      try start(mixer: mixer)
    } catch {
      // Couldn't recover the spectral path — leave audio to whatever the caller
      // falls back to; nothing more we can safely do here.
    }
  }

  func stop() {
    if !isRunning { return }
    isRunning = false
    if let configObserver {
      NotificationCenter.default.removeObserver(configObserver)
      self.configObserver = nil
    }
    let input = engine.inputNode
    input.removeTap(onBus: 0)
    engine.stop()
    // Leave voice processing disabled so a later plain-mic capture isn't affected.
    try? input.setVoiceProcessingEnabled(false)
    continuation?.finish(); continuation = nil
    consumerTask?.cancel(); consumerTask = nil
  }

  /// Deep-copy an `AVAudioPCMBuffer` (float32) so it outlives the tap callback.
  private static func copy(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard
      let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameCapacity),
      let s = src.floatChannelData, let d = dst.floatChannelData
    else { return nil }
    dst.frameLength = src.frameLength
    let n = Int(src.frameLength)
    let channels = Int(src.format.channelCount)
    for ch in 0..<channels {
      d[ch].update(from: s[ch], count: n)
    }
    return dst
  }
}
