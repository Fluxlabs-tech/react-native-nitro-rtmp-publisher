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
//    • NWPathMonitor            → network-lost / network-changed(iface)
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
      self.netStateLock.unlock()
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
    netStateLock.unlock()
    if !satisfied { return "network-lost" }
    if lastLoss > 0 && now - lastLoss < 5 { return "network-changed(\(iface))" }

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
}
