//
//  HybridRtmpPublisherView+Streaming.swift
//  NitroRtmpPublisher
//
//  RTMP transport: startStream / stopStream + the full reconnect /
//  rebuild-pipeline / status-observer machinery underneath. Also owns
//  encoder settings application (applyVideoSettings / applyAudioSettings)
//  and the bitrate timer + adaptive-bitrate strategy plumbing — those
//  live here because both depend on the active `RTMPStream` actor.
//

import AVFoundation
import Foundation
import HaishinKit
import NitroModules
import RTMPHaishinKit
import UIKit
import VideoToolbox

extension HybridRtmpPublisherView {

  // ─── Lifecycle: stream ───────────────────────────────────────────────────

  func startStream(url: String) throws {
    if url.isBlank {
      log("startStream ignored — empty URL")
      return
    }
    // Atomic acquire — bails when another publish (manual or auto-reconnect)
    // is already running. Replaces an earlier check-and-set sequence that
    // wasn't atomic across the JS thread and the reconnect Task continuation.
    guard tryClaimPublishSlot() else {
      log("startStream ignored — a connect/publish is already in flight")
      return
    }
    let (rawConnectUrl, streamKey) = splitRtmpUrl(url)
    let connectUrl = applyAuthToConnectUrl(rawConnectUrl)
    currentRtmpConnectUrl = connectUrl
    pendingStreamKey = streamKey
    shouldBeStreaming = true
    retriesRemaining = autoReconnectMaxAttempts

    applyStreamMode()
    pinVideoOrientation()

    onMain { UIApplication.shared.isIdleTimerDisabled = true }

    publishTask = Task { [weak self] in
      guard let self else { return }
      // Only release the slot if WE'RE still the owner. If the Task got
      // cancelled, the canceller (stopStream / onDropView) has already
      // called `releasePublishSlot()` and possibly a new publish has
      // claimed the slot — releasing here would clobber that new owner's
      // claim. Swift cancellation is cooperative, so this Task body may
      // run for seconds after `cancel()`, long enough for a JS user to
      // tap Start again.
      defer {
        if !Task.isCancelled { self.releasePublishSlot() }
      }
      do {
        try Task.checkCancellation()
        await self.rebuildPipeline(streamKey: streamKey)
        try Task.checkCancellation()
        _ = try await self.connection.connect(connectUrl)
        try Task.checkCancellation()
        _ = try await self.stream.publish(streamKey, type: .live)
        try Task.checkCancellation()
        self.cachedIsStreaming = true
        // Replenish the auto-reconnect budget — a JS user who configured
        // `setAutoReconnect(5, …)` expects 5 fresh attempts per disconnect,
        // not a per-startStream lifetime quota. Without this, a stream
        // that survived a couple of mid-session blips has fewer retries
        // available for the next blip.
        self.retriesRemaining = self.autoReconnectMaxAttempts
        self.emitConnectionEvent(.connectionsuccess, "")
        self.startBitrateTimer()
      } catch is CancellationError {
        // Drop / stop happened mid-handshake. Silent exit — no event emit,
        // no auto-reconnect. ARC will reclaim the new connection/stream
        // we built in rebuildPipeline once the awaits finish naturally.
        self.cachedIsStreaming = false
      } catch {
        self.cachedIsStreaming = false
        let desc = self.sanitizeError(error)
        self.log("connect/publish failed: \(desc)")
        self.stopBitrateTimer()
        // Skip the failure emit if a terminal stream-level event
        // (handleStreamStatus.publishBadName / .failed / etc.) already
        // cleared `shouldBeStreaming`. That event also already emitted
        // a `.connectionfailed` / `.autherror`; without this guard the
        // publish() timeout 15s later would emit a duplicate.
        if self.shouldBeStreaming {
          if !self.tryAutoReconnect(reason: desc) {
            self.shouldBeStreaming = false
            self.emitConnectionEvent(.connectionfailed, desc)
          }
        }
      }
    }

    emitConnectionEvent(.connectionstarted, sanitizeUrl(connectUrl))
  }

  func stopStream() throws {
    let wasStreaming = cachedIsStreaming || isPublishingInFlight()
    shouldBeStreaming = false
    pendingStreamKey = nil
    currentRtmpConnectUrl = nil
    reconnectTask?.cancel()
    reconnectTask = nil
    reconnectScheduled = false
    publishTask?.cancel()
    publishTask = nil
    // Release the publish slot synchronously. The cancelled Task's `defer`
    // won't run until its body unwinds (could be seconds while
    // `connection.connect()` is mid-handshake), and until then a
    // subsequent `startStream` tap would see the slot still claimed and
    // be silently dropped. The publishTask's own defer skips the release
    // when `Task.isCancelled` is true so we don't double-release.
    releasePublishSlot()
    cachedIsStreaming = false
    // Cancel observers BEFORE we kick off the fire-and-forget close. If we
    // leave them subscribed, `connection.close()` eventually yields
    // `connectClosed` into the status stream → `handleRtmpStatus` emits a
    // second `.disconnect` to JS on top of the one we emit below. Also
    // bump the generation so any in-flight observer event from the dying
    // connection fails its pipeline-generation check and bails before
    // touching the handler.
    pipelineGeneration &+= 1
    statusObserverTask?.cancel()
    streamStatusObserverTask?.cancel()
    // Fire-and-forget — both close() calls block awaiting AMF responses (up
    // to 15s each on a dropped socket). The user wants stopStream to return
    // immediately; we don't care about the polite RTMP goodbye.
    let oldStream = self.stream
    let oldConnection = self.connection
    Task { _ = try? await oldStream.close() }
    Task { try? await oldConnection.close() }
    stopBitrateTimer()
    onMain { UIApplication.shared.isIdleTimerDisabled = false }
    // Match the implicit contract of "natural" disconnects — JS-side state
    // machines that listen on `disconnect` to teardown their UI should
    // get the same terminal event whether the disconnect was user-initiated
    // (this path) or driven by the server / network (handleRtmpStatus).
    if wasStreaming {
      emitConnectionEvent(.disconnect, "stopStream")
    }
  }

  func setAuthorization(user: String, password: String) throws {
    // Both empty → clear stored credentials.
    if user.isEmpty && password.isEmpty {
      pendingAuthUser = nil
      pendingAuthPass = nil
      return
    }
    // Both non-empty → store. Partial credentials are silently dropped
    // with a log because `applyAuthToConnectUrl` requires both fields,
    // and accepting only one would silently bypass auth at publish time.
    if user.isEmpty || password.isEmpty {
      log("setAuthorization ignored — partial credentials (user='\(user.isEmpty ? "" : "<set>")', password='\(password.isEmpty ? "" : "<set>")')")
      return
    }
    pendingAuthUser = user
    pendingAuthPass = password
  }

  func requestKeyFrame() throws {
    guard cachedIsStreaming, lastVideoCfg != nil else { return }
    let now = Date().timeIntervalSince1970 * 1000
    if now - lastKeyFrameRequestMs < 1000 { return }
    lastKeyFrameRequestMs = now
    // Nudge bitrate by 1 bps then restore — forces VideoToolbox to emit a
    // fresh IDR. VideoToolbox debounces bitrate changes that arrive within
    // the same encode tick, so a back-to-back set→reset would no-op. The
    // 100 ms gap is enough for the encoder to ack the first change before
    // we revert.
    Task { [weak self] in
      guard let self else { return }
      var settings = await self.stream.videoSettings
      let original = settings.bitRate
      settings.bitRate = max(1, original + 1)
      try? await self.stream.setVideoSettings(settings)
      try? await Task.sleep(nanoseconds: 100_000_000)
      settings.bitRate = original
      try? await self.stream.setVideoSettings(settings)
    }
  }

  func setStreamRotation(rotation: Double) throws {
    let r = Int(rotation)
    let orientation: AVCaptureVideoOrientation
    switch r {
    case 90:  orientation = .landscapeRight
    case 180: orientation = .portraitUpsideDown
    case 270: orientation = .landscapeLeft
    default:  orientation = .portrait
    }
    userRotationOverride = orientation
    // Update the stored rotation AND re-fire applyVideoSettings — the encoder
    // bakes the portrait/landscape dimension swap into VideoCodecSettings
    // at apply time using `cfg.rotation`. Just pushing the orientation to
    // the mixer would leave the encoder producing the original (now
    // mismatched) aspect ratio; servers fix it via SAR but the stream is
    // technically wrong.
    if var cfg = lastVideoCfg {
      cfg.rotation = r
      lastVideoCfg = cfg
      applyVideoSettings()
    } else {
      Task { await self.mixer.setVideoOrientation(orientation) }
    }
  }

  // ─── Sync getters ────────────────────────────────────────────────────────

  func isStreaming() throws -> Bool { return cachedIsStreaming }
  func getStreamWidth() throws -> Double { return Double(lastVideoCfg?.width ?? 0) }
  func getStreamHeight() throws -> Double { return Double(lastVideoCfg?.height ?? 0) }
  func getCurrentBitrate() throws -> Double { return Double(adaptiveCurrentBitrate) }

  // ─── Reconnection ────────────────────────────────────────────────────────

  func setReTries(count: Double) throws {
    let c = max(0, Int(count))
    retriesRemaining = c
    // Keep `autoReconnectMaxAttempts` >= the user-requested count so two
    // things hold simultaneously:
    //   1. `setReTries` standalone (without `setAutoReconnect`) works —
    //      `tryAutoReconnect` requires `autoReconnectMaxAttempts > 0` to
    //      do anything.
    //   2. The on-success "replenish retriesRemaining = autoReconnectMaxAttempts"
    //      step doesn't silently shrink the user's just-set budget when
    //      `setAutoReconnect` was configured with a smaller cap.
    if c > 0 {
      autoReconnectMaxAttempts = Swift.max(autoReconnectMaxAttempts, c)
    }
  }

  func reTry(delayMs: Double, reason: String) throws -> Bool {
    if retriesRemaining <= 0 { return false }
    retriesRemaining -= 1
    scheduleReconnect(delayMs: Int64(delayMs), reason: reason)
    return true
  }

  func setAutoReconnect(maxAttempts: Double, backoffMs: Double) throws {
    autoReconnectMaxAttempts = max(0, Int(maxAttempts))
    autoReconnectBackoffMs = max(0, Int64(backoffMs))
    retriesRemaining = autoReconnectMaxAttempts
  }

  func tryAutoReconnect(reason: String) -> Bool {
    guard shouldBeStreaming, autoReconnectMaxAttempts > 0 else { return false }
    if retriesRemaining <= 0 { return false }
    // Don't try to reconnect while the app is suspended — iOS won't let us
    // open a new socket and we'd just waste a retry slot on a guaranteed
    // timeout. `appWillEnterForeground` re-arms `retriesRemaining` and
    // schedules a fresh reconnect when we come back.
    if isInBackground {
      log("auto-reconnect suppressed while backgrounded (reason: \(reason))")
      return true
    }
    // Dedupe across paths. The same underlying failure can fire both
    // `handleRtmpStatus(connectClosed)` AND `publishTask.catch` (because
    // `connection.connect()` threw) within microseconds. Without this gate,
    // each call decrements `retriesRemaining`, schedules its own reconnect
    // (the first gets cancelled in scheduleReconnect), and emits a
    // duplicate `.reconnecting` to JS. Returning `true` here tells the
    // caller "I've got it" without doing the work twice.
    if reconnectScheduled {
      log("auto-reconnect already scheduled, ignoring duplicate (reason: \(reason))")
      return true
    }
    retriesRemaining -= 1
    scheduleReconnect(delayMs: autoReconnectBackoffMs, reason: reason)
    emitConnectionEvent(.reconnecting, reason)
    return true
  }

  func scheduleReconnect(delayMs: Int64, reason: String) {
    reconnectTask?.cancel()
    reconnectScheduled = true
    reconnectTask = Task { [weak self] in
      // Clear the dedupe flag when this Task completes naturally. If we
      // were CANCELLED, skip the clear — cancellation happens when either
      // (a) a new `scheduleReconnect` superseded us (and already set the
      // flag back to true), or (b) stopStream/onDropView is tearing down
      // and has set it to false explicitly. In either case, clearing here
      // is wrong: case (a) would re-enable a duplicate auto-reconnect
      // because `tryAutoReconnect` would see false; case (b) is redundant.
      defer {
        if !Task.isCancelled {
          self?.reconnectScheduled = false
        }
      }
      // Honor cancellation during the backoff delay — `Task.sleep` throws
      // `CancellationError` when cancelled, so we bail without firing the
      // reconnect. DispatchWorkItem.cancel() can't do this once the work
      // has begun executing.
      if delayMs > 0 {
        do { try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
        catch { return }
      }
      if Task.isCancelled { return }
      guard let self = self, self.shouldBeStreaming else { return }
      guard let url = self.currentRtmpConnectUrl, let key = self.pendingStreamKey else { return }

      guard self.tryClaimPublishSlot() else {
        // Another publish raced ahead of us between the cancellation-check
        // above and the claim — bail out cleanly.
        return
      }
      self.emitConnectionEvent(.connectionstarted, self.sanitizeUrl(url))
      // See the matching defer in startStream — skip release when cancelled.
      defer {
        if !Task.isCancelled { self.releasePublishSlot() }
      }
      do {
        try Task.checkCancellation()
        await self.rebuildPipeline(streamKey: key)
        try Task.checkCancellation()
        _ = try await self.connection.connect(url)
        try Task.checkCancellation()
        _ = try await self.stream.publish(key, type: .live)
        try Task.checkCancellation()
        self.cachedIsStreaming = true
        // Replenish — see startStream's success path for rationale.
        self.retriesRemaining = self.autoReconnectMaxAttempts
        self.emitConnectionEvent(.connectionsuccess, "")
        self.startBitrateTimer()
      } catch is CancellationError {
        self.cachedIsStreaming = false
      } catch {
        self.cachedIsStreaming = false
        let desc = self.sanitizeError(error)
        self.log("retry connect failed: \(desc)")
        self.stopBitrateTimer()
        // Same dedupe as startStream's catch — skip emit if a terminal
        // stream-level event already announced the failure.
        if self.shouldBeStreaming {
          if !self.tryAutoReconnect(reason: desc) {
            self.shouldBeStreaming = false
            self.emitConnectionEvent(.connectionfailed, desc)
          }
        }
      }
    }
  }

  // ─── Adaptive bitrate / on-the-fly tuning ────────────────────────────────

  func setVideoBitrateOnFly(bitrate: Double) throws {
    let b = Int(bitrate)
    guard b > 0 else { return }
    guard cachedIsStreaming else {
      log("setVideoBitrateOnFly ignored — not streaming")
      return
    }
    Task { [weak self] in
      guard let self else { return }
      var s = await self.stream.videoSettings
      s.bitRate = b
      try? await self.stream.setVideoSettings(s)
    }
    adaptiveCurrentBitrate = b
  }

  func setAdaptiveBitrate(
    maxBitrate: Double, decreaseRangePercent: Double, increaseRangePercent: Double
  ) throws {
    let max = Int(maxBitrate)
    if max <= 0 {
      adaptiveEnabled = false
    } else {
      adaptiveMaxBitrate = max
      adaptiveDecreasePct = decreaseRangePercent.clamped(0, 100)
      adaptiveIncreasePct = increaseRangePercent.clamped(0, 100)
      adaptiveEnabled = true
    }
    // Reinstall the strategy on the active stream — the strategy holds
    // `mamimumVideoBitRate` as a `let`, so changing the cap means creating
    // a new instance. Safe to call mid-stream.
    //
    // Race note: if a `rebuildPipeline` is in flight between this Task's
    // spawn and execution, we may install the strategy on the soon-to-be
    // discarded stream. Benign — that stream is being released anyway,
    // and `rebuildPipeline` independently installs its own strategy on
    // the new stream. The JS user just sees a one-tick delay before
    // their new max-bitrate takes effect on the reconnected session.
    Task { [weak self] in
      guard let self else { return }
      await self.installBitrateStrategy(on: self.stream)
    }
  }

  /// Build a `PublisherBitrateStrategy` from current adaptive settings and
  /// attach it to the given stream. The strategy:
  ///  - feeds measured throughput into `lastMeasuredBps` (for the timer to
  ///    forward to JS)
  ///  - delegates to HK's `StreamVideoAdaptiveBitRateStrategy` only when
  ///    `adaptiveEnabled` is true
  func installBitrateStrategy(on stream: RTMPStream) async {
    let cap = adaptiveEnabled ? adaptiveMaxBitrate : (lastVideoCfg?.bitrate ?? 0)
    let strategy = PublisherBitrateStrategy(
      maxVideoBitRate: cap,
      adaptive: adaptiveEnabled
    ) { [weak self] bps in
      self?.lastMeasuredBps = Double(bps)
    }
    await stream.setBitRateStrategy(strategy)
  }

  func resetVideoEncoder() throws -> Bool {
    applyVideoSettings()
    return true
  }

  func resetAudioEncoder() throws -> Bool {
    applyAudioSettings()
    return true
  }

  // ─── Encoder settings application ────────────────────────────────────────

  func applyVideoSettings() {
    guard let cfg = lastVideoCfg else { return }

    let r = cfg.rotation
    let orientation: AVCaptureVideoOrientation
    switch r {
    case 90:  orientation = .landscapeRight
    case 180: orientation = .portraitUpsideDown
    case 270: orientation = .landscapeLeft
    default:  orientation = .portrait
    }

    // Swap encoder dimensions for portrait. See the original 1.x comment —
    // JS passes Android-convention landscape dims and we rotate internally.
    let isPortrait = (orientation == .portrait || orientation == .portraitUpsideDown)
    let encodedWidth  = isPortrait ? min(cfg.width, cfg.height) : max(cfg.width, cfg.height)
    let encodedHeight = isPortrait ? max(cfg.width, cfg.height) : min(cfg.width, cfg.height)

    Task { [weak self] in
      guard let self else { return }
      var settings = await self.stream.videoSettings
      settings.videoSize = .init(width: encodedWidth, height: encodedHeight)
      settings.bitRate = cfg.bitrate
      settings.maxKeyFrameIntervalDuration = Int32(cfg.iFrameInterval)
      settings.scalingMode = .trim
      if self.videoCodec == .h265 {
        settings.profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel as String
      } else {
        settings.profileLevel = kVTProfileLevel_H264_Baseline_AutoLevel as String
      }
      try? await self.stream.setVideoSettings(settings)
      try? await self.mixer.setFrameRate(Float64(cfg.fps))
      await self.mixer.setVideoOrientation(orientation)
    }
  }

  func applyAudioSettings() {
    guard let cfg = lastAudioCfg else { return }
    let muted = cachedAudioMuted
    Task { [weak self] in
      guard let self else { return }
      var settings = await self.stream.audioSettings
      settings.bitRate = cfg.bitrate
      try? await self.stream.setAudioSettings(settings)
      // Preserve the user's mute state across rebuilds — AudioMixerSettings
      // resets `isMuted` to false on init, so a re-apply (e.g. after
      // prepareAudio) would silently unmute the user.
      var mixerSettings = AudioMixerSettings(
        sampleRate: Float64(cfg.sampleRate),
        channels: UInt32(cfg.isStereo ? 2 : 1)
      )
      mixerSettings.isMuted = muted
      await self.mixer.setAudioMixerSettings(mixerSettings)
    }
  }

  func applyStreamMode() {
    // HaishinKit 2.x doesn't expose the same chunkSize / qualityOfService
    // knobs on RTMPConnection that 1.x had at the public API surface — most
    // pipeline tuning is hidden inside the actor now. We keep the prop in
    // the spec for API parity; the practical effect is encoder bitrate
    // adjustments via adaptive bitrate.
  }

  // ─── Bitrate timer ───────────────────────────────────────────────────────

  func startBitrateTimer() {
    stopBitrateTimer()
    // Reset so stale samples from a previous publish don't bleed into the new
    // session before the first NetworkMonitor tick (~3s).
    lastMeasuredBps = 0
    // Count video frames only when a stats consumer is subscribed; this also
    // resets the counter so the first fps tick measures only the new interval.
    previewFrameTap.setCounting(onStreamStats != nil)
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + 1.0, repeating: 1.0)
    t.setEventHandler { [weak self] in self?.onBitrateTick() }
    t.resume()
    bitrateTimer = t
  }

  func stopBitrateTimer() {
    bitrateTimer?.cancel()
    bitrateTimer = nil
    previewFrameTap.setCounting(false)
  }

  func onBitrateTick() {
    let measured = lastMeasuredBps
    // Only sample fps when a stats consumer is subscribed (the frame counter is
    // otherwise off, so this is a no-op). Read on main; the timer fires at 1.0s.
    let wantsStats = onStreamStats != nil
    let fps = wantsStats ? Double(previewFrameTap.takeFrameCount()) : 0
    // Always snapshot the encoder's configured bitrate so the sync
    // `getCurrentBitrate()` reflects adaptive-bitrate adjustments. Without
    // this, the cache only updates when adaptive ticks happen, leaving JS
    // reading a stale "the bitrate we asked for at startStream time" value.
    Task { [weak self] in
      guard let self else { return }
      let vBps = await self.stream.videoSettings.bitRate
      self.adaptiveCurrentBitrate = vBps
      let bps: Double
      if measured > 0 {
        // Real measured throughput from PublisherBitrateStrategy (~3s
        // cadence from HK's NetworkMonitor). Prefer over the configured
        // value because it tells JS what's actually leaving the device.
        bps = measured
      } else {
        // No real sample yet — fall back to encoder configured rate so
        // the UI shows *something* instead of zero in the first ~3s.
        let aBps = await self.stream.audioSettings.bitRate
        bps = Double(vBps + aBps)
      }
      self.emitBitrateChange(bps)
      if wantsStats { self.emitStreamStats(bps, fps) }
    }
  }

  // ─── RTMP status event handler (from connection.status AsyncStream) ──────

  func handleRtmpStatus(_ status: RTMPStatus) {
    let code = status.code
    switch code {
    case RTMPConnection.Code.connectSuccess.rawValue:
      // Internal state transition only — pin orientation now that we have a
      // live connection, but DON'T emit `.connectionsuccess` to JS yet.
      // `connectSuccess` is NetConnection.Connect.Success (AMF handshake
      // done); the publish hasn't started yet. The post-publish path in
      // `startStream` / `scheduleReconnect` emits `.connectionsuccess`
      // once we actually have a publishing stream — that's the moment
      // JS should treat us as "live". Without this elision, JS sees two
      // `.connectionsuccess` events ~2s apart (handshake → publish).
      adaptiveCurrentBitrate = lastVideoCfg?.bitrate ?? adaptiveCurrentBitrate
      pinVideoOrientation()
    case RTMPConnection.Code.connectFailed.rawValue,
         RTMPConnection.Code.connectClosed.rawValue:
      let isFailed = (code == RTMPConnection.Code.connectFailed.rawValue)
      stopBitrateTimer()
      cachedIsStreaming = false
      if tryAutoReconnect(reason: code) { return }
      shouldBeStreaming = false
      emitConnectionEvent(isFailed ? .connectionfailed : .disconnect, code)
    case RTMPConnection.Code.connectRejected.rawValue,
         RTMPConnection.Code.connectInvalidApp.rawValue:
      let desc = status.description
      let isAuth = desc.lowercased().contains("auth") || desc.lowercased().contains("not authorized")
      if isAuth {
        emitConnectionEvent(.autherror, desc)
      } else {
        emitConnectionEvent(.connectionfailed, desc)
      }
    default:
      break
    }
  }

  // ─── NetStream.* status events (from RTMPStream.status AsyncStream) ──────
  //
  // `connection.status` carries NetConnection.* events (handshake / connect /
  // auth). The per-stream status carries NetStream.Publish.*, .Unpublish.*,
  // .Failed, .Play.* — these would otherwise only surface as a generic
  // `requestTimedOut` from the publish() continuation, masking the real
  // reason (bad stream name, server-side rejection, …).

  func handleStreamStatus(_ status: RTMPStatus) {
    let code = status.code
    let desc = status.description
    switch code {
    case RTMPStream.Code.publishStart.rawValue:
      // Server has accepted the publish — best-effort confirmation. We
      // already emitted .connectionsuccess from the connect path; this
      // is just useful diagnostic info.
      log("publishStart: \(desc)")
    case RTMPStream.Code.unpublishSuccess.rawValue:
      log("unpublishSuccess: \(desc)")
    case RTMPStream.Code.publishBadName.rawValue:
      // The stream key was rejected (auth expired, duplicate, malformed).
      // Surface this to JS now — without the publishTask teardown below,
      // the publish() continuation would still time out 15s later and the
      // catch block would emit a duplicate `.connectionfailed`. Also clear
      // `shouldBeStreaming` so a later background/foreground cycle doesn't
      // auto-reconnect against the same bad name.
      cachedIsStreaming = false
      shouldBeStreaming = false
      stopBitrateTimer()
      // Tear down the in-flight publish synchronously so JS users who
      // react to this event by tapping Start again can claim the slot
      // immediately instead of waiting for the 15s publish timeout.
      // publish() doesn't honor cancellation; the body keeps running
      // until publish times out, but its `defer` will skip the release
      // (Task.isCancelled is true) so we don't double-release.
      publishTask?.cancel()
      publishTask = nil
      releasePublishSlot()
      let isAuth = desc.lowercased().contains("auth") || desc.lowercased().contains("not authorized")
      emitConnectionEvent(isAuth ? .autherror : .connectionfailed, "publishBadName: \(desc)")
    case RTMPStream.Code.failed.rawValue,
         RTMPStream.Code.playFailed.rawValue,
         RTMPStream.Code.playStreamNotFound.rawValue:
      // Terminal stream-level failure — same rationale as publishBadName:
      // server-side rejection that won't resolve on retry. Tear down the
      // publish so the slot frees immediately.
      cachedIsStreaming = false
      shouldBeStreaming = false
      stopBitrateTimer()
      publishTask?.cancel()
      publishTask = nil
      releasePublishSlot()
      emitConnectionEvent(.connectionfailed, "\(code): \(desc)")
    default:
      break
    }
  }

  func subscribeToStreamStatus(_ stream: RTMPStream) {
    streamStatusObserverTask?.cancel()
    let generation = pipelineGeneration
    streamStatusObserverTask = Task { [weak self] in
      for await status in await stream.status {
        // `guard let self` INSIDE the loop — without this, a strong-self
        // local promoted at the top of the Task body would keep `self`
        // alive across `await iterator.next()` (the long wait between
        // status events). On a torn-down old connection that wait can
        // last until the actor deallocates, blocking deinit for up to
        // 15s after `onDropView`.
        guard let self else { return }
        // Drop stale events from a torn-down stream actor. Swift Task
        // cancellation is cooperative — one event in flight at cancel time
        // can still reach this point. Without the guard, it stomps on the
        // new session's state.
        if self.pipelineGeneration != generation { return }
        self.handleStreamStatus(status)
      }
    }
  }

  /// (Re)subscribe to `self.connection.status`. The closure captures a
  /// snapshot of the current connection AND pipeline generation so a later
  /// rebuild (which swaps `self.connection` for a fresh actor and bumps the
  /// generation) doesn't leave us reacting to the dead AsyncStream — and,
  /// crucially, doesn't let a late `connectClosed` from the old connection
  /// emit a spurious `.disconnect` while the new session is healthy.
  func subscribeToConnectionStatus() {
    statusObserverTask?.cancel()
    let conn = self.connection
    let generation = pipelineGeneration
    statusObserverTask = Task { [weak self] in
      for await status in await conn.status {
        // See subscribeToStreamStatus for why `guard let self` lives
        // inside the loop body, not at the top of the Task.
        guard let self else { return }
        if self.pipelineGeneration != generation { return }
        self.handleRtmpStatus(status)
      }
    }
  }

  /// Tear down the connection + stream actors and build fresh ones. Used by
  /// initial `startStream` and every auto-reconnect cycle.
  ///
  /// Recording note: the active `StreamRecorder` (if any) is *not* touched
  /// here — it's attached as its own mixer output, independent of the
  /// stream actor. That's deliberate: a brief network blip that triggers
  /// a reconnect shouldn't tear the recording file. The recording keeps
  /// receiving frames through the rebuild and surfaces a single seamless
  /// MP4 to the user. Downside: if the rebuild fails terminally, the
  /// recording also has to be stopped explicitly (via `stopRecord` or
  /// `onDropView`).
  ///
  /// Settings race note: `applyVideoSettings` / `applyAudioSettings` Tasks
  /// kicked off elsewhere read `self.stream` lazily. If they race with this
  /// rebuild, they may either apply settings to the old (about-to-discard)
  /// stream or the new one. Both branches are harmless: the rebuild itself
  /// re-fires both `applyVideoSettings` and `applyAudioSettings` on the
  /// fresh stream below, so the new session always ends up with the
  /// latest settings.
  func rebuildPipeline(streamKey: String) async {
    // Bump the generation BEFORE cancelling — once incremented, any in-flight
    // status event from the old observers will fail the generation check and
    // bail out before reaching `handleRtmpStatus` / `handleStreamStatus`.
    // Cancelling alone isn't enough: Swift cancellation is cooperative and
    // a status value already pulled from the AsyncStream iterator still
    // fires one final handler call.
    pipelineGeneration &+= 1
    statusObserverTask?.cancel()
    streamStatusObserverTask?.cancel()

    let oldStream = self.stream
    let oldConnection = self.connection
    await self.mixer.removeOutput(oldStream)

    // Fire-and-forget the polite RTMP goodbye. RTMPStream.close() sends an
    // unpublish AMF command and awaits `unpublishSuccess` for up to
    // `requestTimeout` (15s); RTMPConnection.close() then walks every stream,
    // calling `FCUnpublish` + `deleteStream` and awaiting responses with the
    // same 15s ceiling. On a dead socket (the common case after a background
    // suspension) those calls always time out — awaiting them serially adds
    // up to ~30s of unrecoverable latency before we can even start the new
    // publish. ARC reclaims both actors once these tasks complete, and the
    // OS closes the abandoned TCP socket when references drop. The server
    // gets a clean RST either way.
    Task { _ = try? await oldStream.close() }
    Task { try? await oldConnection.close() }

    let newConnection = RTMPConnection(requestTimeout: 15_000)
    let newStream = RTMPStream(connection: newConnection, fcPublishName: streamKey)
    self.connection = newConnection
    self.stream = newStream

    subscribeToConnectionStatus()
    subscribeToStreamStatus(newStream)
    await self.mixer.addOutput(newStream)
    await installBitrateStrategy(on: newStream)
    applyVideoSettings()
    applyAudioSettings()
  }
}
