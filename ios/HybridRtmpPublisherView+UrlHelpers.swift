//
//  HybridRtmpPublisherView+UrlHelpers.swift
//  NitroRtmpPublisher
//
//  URL parsing + sanitization helpers. Lives as an extension on the
//  publisher view because `applyAuthToConnectUrl` reads the stored
//  `pendingAuth*` credentials and `splitRtmpUrl` calls `log()` for the
//  non-RTMP-scheme warning.
//

import Foundation

extension HybridRtmpPublisherView {

  /// Strip the `user:password@` component from an RTMP URL. We embed AMF
  /// credentials directly into the URL inside `applyAuthToConnectUrl`
  /// (`rtmp://u:p@host/app`), but anything we hand to JS or write to the
  /// logger MUST have those stripped — otherwise the password leaks into
  /// JS event streams, third-party crash-reporting payloads, and the iOS
  /// device console (debug logs persist in iOS diagnostic dumps).
  func sanitizeUrl(_ url: String) -> String {
    guard var comps = URLComponents(string: url),
          comps.user != nil || comps.password != nil else {
      return url
    }
    comps.user = nil
    comps.password = nil
    return comps.string ?? url
  }

  /// Strip credentials from `Error` descriptions before they hit logs or JS.
  /// HaishinKit's `RTMPConnection.Error.unsupportedCommand(command)` carries
  /// the URL verbatim, and Swift's default error `description` interpolates
  /// it. We can't introspect arbitrary `Error` values, so we run the textual
  /// description through a regex sweep that nukes any embedded user:pass@.
  func sanitizeError(_ error: Error) -> String {
    let raw = "\(error)"
    // Match `://user:pass@host` and replace with `://host`. Greedy on the
    // password segment is fine — RTMP URLs only have one userinfo.
    let pattern = "://([^:/@]+):([^@/]+)@"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }
    let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
    return regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "://")
  }

  /// Rewrite `rtmp://host/app` → `rtmp://user:pass@host/app` if creds were set
  /// via `setAuthorization`. Some Wowza / Nimble setups need credentials in
  /// the URL rather than as a separate AMF auth challenge.
  func applyAuthToConnectUrl(_ connectUrl: String) -> String {
    guard let user = pendingAuthUser, !user.isEmpty,
          let pass = pendingAuthPass, !pass.isEmpty,
          let comps = URLComponents(string: connectUrl), comps.user == nil else {
      return connectUrl
    }
    var c = URLComponents(string: connectUrl) ?? URLComponents()
    let enc = { (s: String) in
      s.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? s
    }
    c.user = enc(user)
    c.password = enc(pass)
    return c.string ?? connectUrl
  }

  /// Split an RTMP URL into `(connectUrl, streamKey)`.
  ///
  /// Naive last-slash split fails on URLs where the query string is part of
  /// the publish name (`rtmp://host/app/streamName?auth=…`) — using
  /// `String.range(of:"/", options:.backwards)` on the raw URL would split at
  /// the `/` inside `auth=path/whatever` when servers embed slashes in
  /// signed params. We split on the last `/` BEFORE any `?`, then re-attach
  /// the query string to the stream key so HK passes it verbatim in the
  /// publish AMF command (FB Live / Instagram / Wowza signed auth all rely
  /// on this).
  ///
  /// Also lightly validates the scheme — anything other than `rtmp://` /
  /// `rtmps://` gets a warning log. HK itself will reject the connect later
  /// with `unsupportedCommand`, but logging here makes the failure mode
  /// obvious to integrators.
  func splitRtmpUrl(_ url: String) -> (connectUrl: String, streamKey: String) {
    if let comps = URLComponents(string: url),
       let scheme = comps.scheme?.lowercased(),
       scheme != "rtmp" && scheme != "rtmps" {
      log("splitRtmpUrl: non-RTMP scheme '\(scheme)' — connect will fail")
    }
    let pathPart: String
    let queryPart: String
    if let q = url.range(of: "?") {
      pathPart = String(url[..<q.lowerBound])
      queryPart = String(url[q.lowerBound...])  // includes the "?"
    } else {
      pathPart = url
      queryPart = ""
    }
    // Search for the path-segment `/` AFTER the scheme's `://` delimiter.
    // Without this, a path-less URL like `rtmp://host` splits at the `/`
    // inside `://` and produces garbage (`rtmp:/`, `host`).
    let pathSearchStart: String.Index =
      pathPart.range(of: "://").map { $0.upperBound } ?? pathPart.startIndex
    guard let lastSlash = pathPart.range(
            of: "/",
            options: .backwards,
            range: pathSearchStart..<pathPart.endIndex) else {
      return (url, "")
    }
    let connect = String(pathPart[..<lastSlash.lowerBound])
    let name = String(pathPart[lastSlash.upperBound...])
    return (connect, name + queryPart)
  }
}
