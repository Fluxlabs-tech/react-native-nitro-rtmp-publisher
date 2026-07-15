//
//  HybridRtmpPublisherView+DisconnectCause.swift
//  NitroRtmpPublisher
//
//  Best-effort disconnect-cause classifier. iOS surfaces a socket drop only as a
//  generic RTMP code (`NetConnection.Connect.Closed`) — identical whether the
//  phone lost its uplink, a call grabbed the audio session, or the ingest server
//  hung up. This module correlates side-channels captured at drop time to label
//  the cause in the `.disconnect` / `.connectionfailed` / `.reconnecting` message
//  (no API change — the existing `(event, message)` callback just gets a more
//  specific message, e.g. `network-lost (NetConnection.Connect.Closed)`):
//
//    • NWPathMonitor            → network-lost / network-changed(iface); ALSO
//                                  fires the proactive stop+restart when the
//                                  default path leaves the session's interface
//                                  (see restartStreamForNetworkChange below —
//                                  that part is behavior, not just labeling)
//    • audio-session .began     → interrupted-by-call (phone call / Siri / alarm)
//    • ProcessInfo thermalState → thermal-critical
//    • UIDevice batteryLevel    → low-battery (best effort only — a true battery
//                                  death kills the process before any callback
//                                  can fire, so this catches at most the last gasp)
//    • app background           → app-backgrounded
//    • none of the above        → server-closed (link's up, no local cause)
//
//  Everything here is ADVISORY: a mislabel never changes reconnect behavior, it
//  only annotates the message, so the cross-thread reads are deliberately cheap.
//

import Foundation
import Network
import UIKit

extension HybridRtmpPublisherView {

  // ─── NWPathMonitor lifecycle ─────────────────────────────────────────────

  /// Start watching the network path. Called once from `init`. The handler runs
  /// on `networkMonitorQueue`; it stashes the latest reachability + interface
  /// behind `netStateLock` so `disconnectCauseCategory` (RTMP status thread) can
  /// read it race-free. Also stamps `_lastNetworkLossUptime` on every drop so a
  /// brief flap (a Wi-Fi→cellular handoff that re-satisfies within a few seconds)
  /// is still attributable when the socket death lands just after re-connection.
  /// Additionally fires the PROACTIVE network-change restart when the default
  /// path's interface moves away from the one the live session is bound to.
  func startNetworkMonitor() {
    guard networkMonitor == nil else { return }
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let satisfied = (path.status == .satisfied)
      let iface: String
      if path.usesInterfaceType(.wifi) { iface = "wifi" }
      else if path.usesInterfaceType(.cellular) { iface = "cellular" }
      else if path.usesInterfaceType(.wiredEthernet) { iface = "ethernet" }
      else if path.usesInterfaceType(.other) { iface = "other" }
      else { iface = "none" }
      self.netStateLock.lock()
      if !satisfied { self._lastNetworkLossUptime = ProcessInfo.processInfo.systemUptime }
      self._networkSatisfied = satisfied
      self._networkInterface = iface
      let sessionIface = self._sessionInterface
      self.netStateLock.unlock()
      // Proactive network-change restart (Android parity:
      // onDefaultNetworkAvailable → restartStreamForNetworkChange). The default
      // path now runs on a DIFFERENT interface than the one the session bound
      // at connect time. This matters most for cellular→wifi joins: iOS keeps
      // established TCP flows on cellular (make-before-break), so without this
      // the stream would silently stay on cellular — burning mobile data with
      // wifi available and never emitting any event. The shouldBeStreaming read
      // here is only a cheap pre-filter; restartStreamForNetworkChange re-checks
      // everything serialized on main.
      if satisfied, isRealInterface(sessionIface), isRealInterface(iface),
         iface != sessionIface, self.shouldBeStreaming {
        self.restartStreamForNetworkChange(reason: "network-changed(\(iface))")
      }
    }
    networkMonitor = monitor
    monitor.start(queue: networkMonitorQueue)
  }

  func stopNetworkMonitor() {
    networkMonitor?.cancel()
    networkMonitor = nil
  }

  // ─── Battery monitoring ──────────────────────────────────────────────────

  /// Enable battery telemetry so the classifier has a level/state to read. Must
  /// run on main (UIKit); cheap and idempotent. The cached scalars are refreshed
  /// here and by the `batteryStateDidChange` observers registered in `init`.
  func enableBatteryMonitoring() {
    onMain { [weak self] in
      UIDevice.current.isBatteryMonitoringEnabled = true
      self?.refreshBatteryCache()
    }
  }

  /// Notification target (main thread) for battery level/state changes. Also
  /// invoked once from `enableBatteryMonitoring` to prime the cache.
  @objc func batteryStateDidChange() {
    refreshBatteryCache()
  }

  /// Read UIDevice battery on main and cache the scalars the classifier reads.
  /// Reading UIDevice off-main trips the Main Thread Checker, hence the cache.
  func refreshBatteryCache() {
    cachedBatteryLevel = UIDevice.current.batteryLevel
    cachedBatteryUnplugged = (UIDevice.current.batteryState == .unplugged)
  }

  // ─── Classifier ──────────────────────────────────────────────────────────

  /// Map a raw RTMP close / `connectFailed` code to a likely human cause,
  /// e.g. `"network-lost (NetConnection.Connect.Closed)"`. The bare category
  /// comes from `disconnectCauseCategory`; the raw code is appended for
  /// diagnostics so nothing is lost.
  func classifyDisconnectCause(rtmpCode: String) -> String {
    return "\(disconnectCauseCategory()) (\(rtmpCode))"
  }

  /// The bare cause category, ordered most-specific/decisive first so a single
  /// dominant signal wins. Shared by the socket-close path and the silent-stall
  /// watchdog. See the file header for what each signal means.
  func disconnectCauseCategory() -> String {
    // 1) App suspended — iOS reaps the RTMP socket on background.
    if isInBackground { return "app-backgrounded" }

    // 2) Phone call / Siri / alarm — an audio-session interruption is live, or
    //    fired within the last few seconds, or the capture session is paused by
    //    the audio device being grabbed by another client. A definitive local
    //    signal, so it outranks a network read (the call is WHY the link idled).
    let now = ProcessInfo.processInfo.systemUptime
    if audioInterruptionActive || captureInterrupted
        || (lastAudioInterruptionUptime > 0 && now - lastAudioInterruptionUptime < 8) {
      return "interrupted-by-call"
    }

    // 3) Uplink gone — path currently unsatisfied, or dropped within the last 5s
    //    (a Wi-Fi↔cellular handoff re-satisfies quickly but still kills the
    //    in-flight socket, so a bare "currently satisfied" check would miss it).
    netStateLock.lock()
    let satisfied = _networkSatisfied
    let iface = _networkInterface
    let lastLoss = _lastNetworkLossUptime
    let sessionIface = _sessionInterface
    netStateLock.unlock()
    if !satisfied { return "network-lost" }
    if lastLoss > 0 && now - lastLoss < 5 { return "network-changed(\(iface))" }
    // 3b) No unsatisfied blip was recorded, but the default path's interface no
    //     longer matches the one this session bound at (re)connect time — a
    //     make-before-break handoff (typically a cellular→wifi join): iOS brings
    //     the new path up before the old flow dies, so the socket death lands
    //     with the path "satisfied" throughout and the 5s window above misses
    //     it. Without this the drop would fall through to the server-closed
    //     guess. Android parity: the live-vs-bound handle check (3b) in
    //     +DisconnectCause.kt.
    if isRealInterface(sessionIface), isRealInterface(iface), iface != sessionIface {
      return "network-changed(\(iface))"
    }

    // 4) Thermal shutdown pressure (iOS throttles/kills the app when critical).
    if ProcessInfo.processInfo.thermalState == .critical { return "thermal-critical" }

    // 5) Battery critically low & unplugged — best effort: a real battery death
    //    kills us before any event fires, so this only ever catches the last gasp.
    if cachedBatteryLevel >= 0, cachedBatteryLevel < 0.05, cachedBatteryUnplugged {
      return "low-battery"
    }

    // 6) Link's up, no local interruption → the server hung up on us
    //    (idle timeout, key expiry, ingest restart, rate-limit, …).
    return "server-closed"
  }

  // ─── Network-change recovery ─────────────────────────────────────────────

  /// Stamp the interface the (re)starting session binds to — the baseline the
  /// proactive network-change trigger and the classifier's 3b check compare
  /// the live path against. Called from `startStream` and from each reconnect
  /// attempt (a reconnect often lands on a different network).
  func baselineSessionInterface() {
    netStateLock.lock()
    _sessionInterface = _networkInterface
    netStateLock.unlock()
  }

  /// Network-change recovery, kept dead simple by product decision (Android
  /// parity: +Reconnect.kt's restartStreamForNetworkChange): a plain public
  /// stopStream() + startStream() cycle — the sequence that reliably re-homes
  /// RTMP onto the new interface. stopStream() flips shouldBeStreaming, which
  /// gates off both the reactive reconnect machinery and duplicate path-update
  /// triggers, so the paths can't fight; the delayed startStream restores it.
  func restartStreamForNetworkChange(reason: String) {
    onMain { [weak self] in
      guard let self else { return }
      guard self.shouldBeStreaming, !self.isInBackground else { return }
      // Capture the URL BEFORE stopStream() (it nulls lastFullStreamUrl).
      guard let url = self.lastFullStreamUrl else { return }
      self.log("Recovery (\(reason)) → stop + restart stream")
      // Stamp the DISCONNECT stopStream() is about to emit with why we
      // dropped, so JS can tell a network switch from a user stop.
      self.pendingDisconnectReason = reason
      try? self.stopStream()
      // stopStream() cancelled any pending resume, so schedule ours AFTER it —
      // and a genuine USER stopStream() during the settle re-cancels this, so
      // a deliberate stop is never resurrected. The 1.5s settle (Android
      // parity: NETWORK_CHANGE_SETTLE_MS) lets the new interface finish coming
      // up before the fresh connect.
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.networkChangeResumeWork = nil
        // A user re-start (or anything else) claimed the session during the
        // settle — theirs wins; don't stack a second publish on it. And if the
        // app backgrounded meanwhile, a connect would only burn a timeout.
        guard !self.shouldBeStreaming, !self.isPublishingInFlight(),
              !self.isInBackground else { return }
        // Re-read the interface at fire time: the settle gave the OS time to
        // finish the switch, so the RECONNECTING that precedes the fresh start
        // names the network we're ACTUALLY resuming on (a double-flap during
        // the settle would otherwise carry a stale label).
        self.netStateLock.lock()
        let iface = self._networkInterface
        let satisfied = self._networkSatisfied
        self.netStateLock.unlock()
        let refined = (satisfied && isRealInterface(iface))
          ? "network-changed(\(iface))" : reason
        self.emitConnectionEvent(.reconnecting, refined)
        try? self.startStream(url: url)
      }
      self.networkChangeResumeWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
  }
}

/// True for a concrete session-bindable interface label — filters the
/// "no baseline yet" ("", "unknown") and pathless ("none") states out of the
/// network-change detection.
private func isRealInterface(_ iface: String) -> Bool {
  iface == "wifi" || iface == "cellular" || iface == "ethernet" || iface == "other"
}
