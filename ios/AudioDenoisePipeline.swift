//
//  AudioDenoisePipeline.swift
//  NitroRtmpPublisher
//
//  iOS `noiseSuppression` path — Apple Voice Processing + self-healing A/V sync.
//
//  WHY THIS DESIGN. Apple's Voice Processing I/O (AVAudioEngine input node with
//  `setVoiceProcessingEnabled(true)`) is the best iOS noise suppressor — ML NS +
//  echo cancellation, no muffling — and we disable its auto-gain so the voice
//  keeps its natural level. The hard part is A/V sync, because VP captures on a
//  separate audio-HAL clock from the camera (AVCaptureSession), and HaishinKit
//  ships audio + video as two independent timelines anchored once at t=0. Two
//  failure modes (both verified against HaishinKit 2.2.5 source):
//    • CONSTANT OFFSET: VP delivers each buffer timestamped LATE by its input-
//      chain latency (~60–150 ms), which becomes a permanent audio-behind-video
//      offset.
//    • RATE DRIFT: the audio HAL clock vs the host/capture clock differ by tens
//      of ppm, integrating into lip-sync drift over a long stream.
//
//  THE FIX (self-healing). Two cooperating parts:
//    1. ANCHOR ALIGNMENT — shift the appended timestamp earlier by the measured
//       input latency so the audio anchors at its true acoustic time, lined up
//       with the video capture clock. Removes the constant offset.
//    2. CONTINUOUS RESYNC — a control loop resamples each buffer to outN = N ±
//       a few samples so the CUMULATIVE output sample count tracks elapsed host-
//       clock time. This locks the audio rate to the video clock AND actively
//       drives any residual/injected offset back to zero (self-healing). We
//       report a CONSISTENT cumulative `sampleTime` with each buffer so
//       HaishinKit's AudioRingBuffer honors the resampled output (the earlier
//       drop/insert corrector failed precisely because it left `when.sampleTime`
//       at the raw HAL value, so the ring backfilled silence and reverted it).
//
//  Correction is ≤ `maxStep` samples/buffer via linear interpolation — identity
//  when no correction is needed (the common case), sub-sample and inaudible for
//  ppm drift, and a brief, gentle pitch glide while healing a large offset.
//
//  Ordering: the tap fires on one serial audio thread; we copy the buffer and a
//  single high-priority consumer Task runs the control loop and calls the
//  actor-isolated `mixer.append` IN ORDER. The sync state is touched only on
//  that consumer, so it needs no locking. If VP can't start we fall back to the
//  plain mic.
//

@preconcurrency import AVFoundation
import HaishinKit

final class AudioDenoisePipeline {

  private let engine = AVAudioEngine()
  private var continuation: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>.Continuation?
  private var consumerTask: Task<Void, Never>?
  private(set) var isRunning = false
  private weak var mixer: MediaMixer?
  private var configObserver: NSObjectProtocol?

  // ── Sync state (consumer-thread only) ─────────────────────────────────────
  private var nominalRate: Double = 0
  // Constant input-chain latency (s) by which Apple VP delivers audio LATE; we
  // subtract it from each appended timestamp so audio anchors at its true
  // acoustic time. Re-measured each start(); capped so a bogus API reading can't
  // wildly over-compensate.
  private var inputLatencySeconds: Double = 0
  private let maxLatencyComp: Double = 0.30
  // Fine calibration (ms) added to the measured input latency. MORE comp shifts
  // the audio EARLIER (we move the anchor earlier to undo VP's late delivery);
  // LESS comp (negative trim) shifts it LATER. Empirically the audio sits ~21 ms
  // EARLY at trim 0 (one buffer of inherent A/V look-ahead), so −21 delays it
  // back into sync. The net comp may go negative (audio is shifted later than
  // raw) when inputLatency < the trim.
  private let latencyTrimMs: Double = -21
  // Control loop: cumulative output samples should track elapsed host time.
  private var haveAnchor = false
  private var anchorHostSeconds: Double = 0
  private var emittedOutput: Double = 0          // cumulative output frames appended
  private let controlGain: Double = 0.25         // correct 25% of the error per buffer
  // ADAPTIVE recovery rate: the per-buffer correction is capped as a fraction of
  // the buffer, and the cap SCALES with how far out of sync we are. A big offset
  // recovers aggressively (worth a brief pitch glide); a small one recovers
  // gently so it stays inaudible; and because the tier shrinks as the offset
  // heals, the correction naturally tapers near sync (no overshoot/warble at the
  // end). At 1024 frames / 48 kHz, ~1 sample/buffer ≈ 1 ms/sec of recovery, so:
  //   ≥500 ms  → n/4  (~250 ms/sec)  severe → snap back in ~2 s
  //   ≥200 ms  → n/12 (~85 ms/sec)   medium
  //   <200 ms  → n/48 (~20 ms/sec)   gentle, ~inaudible
  // (Real drift is tens of ppm → <1 sample/buffer, far below even the gentle
  // cap, so steady-state correction is always sub-sample and silent.)
  //
  // The tier is keyed off the PEAK offset of the current recovery episode (not
  // the instantaneous error) so a big desync recovers FULLY at the fast rate
  // instead of crawling once it dips under a threshold.
  private func maxStep(_ n: Int, peakMs: Double) -> Int {
    if peakMs >= 200 { return max(16, n / 4) }   // ≈250 ms/s — fast (≈1.6 s for 400 ms)
    if peakMs >= 50 { return max(16, n / 10) }   // ≈100 ms/s — medium
    return max(8, n / 48)                         // ≈20 ms/s — gentle (tiny residual drift)
  }
  private var recoveryPeakMs: Double = 0
  // Debug: a deliberate desync to inject (samples; + = audio ahead). Queued by
  // injectDesync (cross-thread, lock-guarded), then drained into injectRemaining
  // and applied gradually via resampled frames (consumer-thread only).
  private var pendingInjectSamples: Double = 0
  private var injectRemaining: Double = 0
  // Monitor/telemetry of the residual A/V sync error.
  private var lastReportedMs: Double = 0
  private let reportStepMs: Double = 20
  private let syncThresholdMs: Double = 1.0      // |skew| under this = "in sync"
  private var reportedSynced = true
  /// Telemetry: (deltaMs since last call, totalMs = current A/V sync error in ms).
  /// `totalMs` spikes when audio drifts/is injected and the control loop drives
  /// it back to ~0; an event fires the instant it crosses into sync
  /// (|totalMs| < `syncThresholdMs`), so reaching 0 is observable. Invoked on the
  /// consumer Task.
  var onDriftCorrection: ((Double, Double) -> Void)?

  enum PipelineError: Error { case invalidInputFormat }

  /// Inject a deliberate A/V desync for testing the self-heal (debug only).
  /// Positive ms jumps the audio ahead of video, negative behind; the control
  /// loop then drives it back to zero over a few seconds. Called from the JS
  /// thread, applied on the audio consumer — guarded by `injectLock` so the
  /// cross-thread write is actually seen (a plain unsynchronized Double can be
  /// lost to the consumer's core).
  private let injectLock = NSLock()
  func injectDesync(ms: Double) {
    injectLock.lock()
    pendingInjectSamples = ms / 1000 * (nominalRate > 0 ? nominalRate : 48000)
    injectLock.unlock()
  }

  /// Start capturing through Apple's Voice Processing (AGC off), sync-locked to
  /// the capture clock, feeding `mixer`. Caller must have an active
  /// `.playAndRecord` session already. Throws if VP / the engine can't start —
  /// caller should fall back to `mixer.attachAudio(mic)`.
  func start(mixer: MediaMixer) throws {
    if isRunning { return }
    self.mixer = mixer

    let input = engine.inputNode
    // Apple NS + AEC on the input node (AGC off). Must be set while stopped.
    try input.setVoiceProcessingEnabled(true)
    if #available(iOS 15.0, *) {
      input.isVoiceProcessingAGCEnabled = false
    }

    let format = input.outputFormat(forBus: 0)
    guard format.channelCount > 0, format.sampleRate > 0 else {
      try? input.setVoiceProcessingEnabled(false)
      throw PipelineError.invalidInputFormat
    }
    nominalRate = format.sampleRate

    // Fresh segment: reset the loop anchor + re-measure input latency for the
    // ACTIVE route (built-in / BT / wired differ, and VP adds to it).
    haveAnchor = false
    emittedOutput = 0
    lastReportedMs = 0
    reportedSynced = true
    pendingInjectSamples = 0
    injectRemaining = 0
    recoveryPeakMs = 0
    // Compensate the VP delivery latency by AVAudioSession.inputLatency (the
    // documented recipe to recover a tap buffer's true acoustic time). Do NOT add
    // ioBufferDuration + node.presentationLatency on top — presentationLatency
    // already folds in the I/O path, so summing all three double-counts and
    // over-shifts the audio EARLY (the ~100 ms-early symptom). `latencyTrimMs`
    // is a fine calibration knob from on-device clap testing (+ = compensate
    // more, i.e. push audio later; − = less).
    let session = AVAudioSession.sharedInstance()
    let measured = session.inputLatency + latencyTrimMs / 1000
    // Allow a NEGATIVE net comp (shift audio later) so we can pull audio back
    // when it sits early even at zero hardware latency.
    inputLatencySeconds = max(-maxLatencyComp, min(maxLatencyComp, measured))
    print("[NitroRTMP] VP latency comp: inputLatency=\(session.inputLatency) ioBuffer=\(session.ioBufferDuration) node.presentation=\(input.presentationLatency) trim=\(latencyTrimMs)ms → compensating \(Int(inputLatencySeconds * 1000))ms")

    var captured: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>.Continuation?
    let stream = AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>(
      bufferingPolicy: .bufferingNewest(96)
    ) { captured = $0 }
    continuation = captured

    consumerTask = Task(priority: .high) { [weak self] in
      for await (buffer, when) in stream {
        guard let self else { break }
        let (outBuffer, outWhen) = self.compensate(buffer, when)
        await self.mixer?.append(outBuffer, when: outWhen, track: 0)
      }
    }

    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
      guard let self else { return }
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
    stop()
    do {
      try start(mixer: mixer)
    } catch {
      // Couldn't recover VP — leave audio to whatever the caller falls back to.
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
    try? input.setVoiceProcessingEnabled(false)
    continuation?.finish(); continuation = nil
    consumerTask?.cancel(); consumerTask = nil
  }

  /// Run the resync control loop: resample the buffer to outN frames so the
  /// cumulative output tracks elapsed host time, and stamp it with a consistent
  /// cumulative `sampleTime` + a latency-compensated `hostTime`. Returns the
  /// buffer + timestamp to append. Consumer-thread only.
  private func compensate(_ input: AVAudioPCMBuffer, _ when: AVAudioTime) -> (AVAudioPCMBuffer, AVAudioTime) {
    let n = Int(input.frameLength)
    guard when.isHostTimeValid, nominalRate > 0, n > 0, let inCh = input.floatChannelData else {
      let start = AVAudioFramePosition(emittedOutput)
      emittedOutput += Double(max(0, n))
      return (input, AVAudioTime(hostTime: when.hostTime, sampleTime: start, atRate: nominalRate))
    }

    let hostSeconds = AVAudioTime.seconds(forHostTime: when.hostTime)
    if !haveAnchor {
      anchorHostSeconds = hostSeconds
      emittedOutput = 0
      lastReportedMs = 0
      reportedSynced = true
      haveAnchor = true
    }
    // Debug inject: queue a deliberate desync. We apply it through the SAME
    // resample path the recovery uses (a burst of biased outN over a few
    // buffers) — NOT a bare `emittedOutput += K` jump. A counter jump makes the
    // reported sampleTime leap ahead of HaishinKit's ring, which backfills K
    // silence that the recovery can never retract (it accumulates over repeated
    // injects). Driving it through outN keeps when.sampleTime and the ring's
    // sampleTime locked (skip stays 0, no silence), so the loop heals it cleanly
    // with zero residual — matching how real clock drift behaves.
    injectLock.lock()
    let injectReq = pendingInjectSamples
    pendingInjectSamples = 0
    injectLock.unlock()
    if injectReq != 0 { injectRemaining += injectReq }

    // Control loop → desired output frame count. `skewMs` is the A/V sync error
    // measured at the point the loop TARGETS (cumulative output vs elapsed time,
    // BEFORE this buffer is counted) so it converges to 0 — measuring after would
    // leave a constant one-buffer (~21 ms) look-ahead baseline.
    var outN = n
    var skewMs = 0.0
    let elapsed = hostSeconds - anchorHostSeconds
    if elapsed > 0 {
      let target = elapsed * nominalRate
      let error = target - emittedOutput        // >0 = behind → emit more
      skewMs = -error / nominalRate * 1000       // + = audio ahead of video
      // Latch the tier to the PEAK offset of this episode (reset once synced) so
      // the whole recovery runs at the speed the severity warrants.
      if abs(skewMs) < 25 { recoveryPeakMs = 0 }
      recoveryPeakMs = max(recoveryPeakMs, abs(skewMs))
      let step = maxStep(n, peakMs: recoveryPeakMs)
      var corr: Int
      if injectRemaining != 0 {
        // Burst the queued desync in via real resampled frames (overrides the
        // normal correction this buffer); the loop heals it once the burst drains.
        let burstCap = max(16, n / 4)
        var b = Int(injectRemaining.rounded())
        if b > burstCap { b = burstCap }
        if b < -burstCap { b = -burstCap }
        injectRemaining -= Double(b)
        corr = b
      } else {
        corr = Int((controlGain * error).rounded())
        if corr > step { corr = step }
        if corr < -step { corr = -step }
      }
      outN = max(1, n + corr)
    }

    // Build the timestamp: cumulative output sampleTime (so HaishinKit's ring
    // honors the resampled count), hostTime shifted earlier by the latency.
    let startSample = AVAudioFramePosition(emittedOutput)
    let latTicks = AVAudioTime.hostTime(forSeconds: abs(inputLatencySeconds))
    let shiftedHost: UInt64
    if inputLatencySeconds >= 0 {
      shiftedHost = when.hostTime > latTicks ? when.hostTime - latTicks : when.hostTime  // earlier
    } else {
      shiftedHost = when.hostTime &+ latTicks                                            // later
    }
    let outWhen = AVAudioTime(hostTime: shiftedHost, sampleTime: startSample, atRate: nominalRate)

    let result: AVAudioPCMBuffer
    if outN == n {
      result = input                            // identity — no resample, no alloc
    } else if let outBuf = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: AVAudioFrameCount(outN)),
              let outCh = outBuf.floatChannelData {
      // Linear-interpolation resample of n input frames → outN output frames.
      let channels = Int(input.format.channelCount)
      let scale = Double(n) / Double(outN)
      for ch in 0..<channels {
        let s = inCh[ch], d = outCh[ch]
        for j in 0..<outN {
          let pos = Double(j) * scale
          let i = min(Int(pos), n - 1)
          let frac = Float(pos - Double(i))
          let a = s[i]
          let b = s[min(i + 1, n - 1)]
          d[j] = a + (b - a) * frac
        }
      }
      outBuf.frameLength = AVAudioFrameCount(outN)
      result = outBuf
    } else {
      result = input                            // alloc failed → passthrough
      outN = n
    }

    emittedOutput += Double(outN)

    // Telemetry: the residual A/V sync error (`skewMs`, measured pre-buffer) the
    // loop is driving to zero. Report each recovery step (≥ reportStepMs change)
    // AND every transition in/out of the synced band — so a recovery is reported
    // as it heals AND a final event fires the moment it reaches ~0 (synced).
    if elapsed > 0 {
      let synced = abs(skewMs) < syncThresholdMs
      if abs(skewMs - lastReportedMs) >= reportStepMs || synced != reportedSynced {
        let step = skewMs - lastReportedMs
        lastReportedMs = skewMs
        reportedSynced = synced
        onDriftCorrection?(step, skewMs)
      }
    }
    return (result, outWhen)
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
