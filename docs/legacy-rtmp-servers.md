# iOS: streaming to Agora or other servers with a legacy RTMP architecture

> **TL;DR** — If your iOS stream takes ~15–17 s to connect to **Agora** (or any ingest built on a **legacy RTMP / Adobe Flash Media Server architecture**) while the same app connects in 2–4 s everywhere else, pass `legacyRtmpCompatibility` to `RtmpPublisherView`. It's **off by default**; most servers don't need it.

**Symptom (iOS only).** Publishing takes **~15–17 seconds** to fire `connectionSuccess`, while the *same* app reaches the same event in 2–4 s on YouTube, Twitch, Facebook/Instagram Live, and OBS relays — and Android connects to the *same* URL in ~4 s. Once connected the stream is perfectly healthy; only the *start* is slow. The most common place this shows up is **Agora's RTLS ingest** (`rtmp://rtls-ingress-*.agoramdn.com/live/…`), but it can happen with any server that presents an old Flash-Media-Server-style RTMP front end.

**Why it happens.** These servers identify themselves as something like `fmsVer = FMS/3,0,1,123` — i.e. they emulate a 2008-era Adobe Flash Media Server and expect the old **FMLE** (Flash Media Live Encoder) publish handshake. The iOS RTMP engine this library uses (HaishinKit) follows that handshake strictly: before it sends `createStream` / `publish`, it sends two FMLE-compatibility commands, `releaseStream` and `FCPublish`, and **waits for the server to acknowledge them**. Modern servers reply instantly. These legacy servers simply never reply to those two commands — so HaishinKit blocks on each until its internal request timeout (~15 s) expires, *then* continues. That timeout is the entire delay. OBS/`librtmp` and Android (the Pedro engine) send those same commands **fire-and-forget** and never wait for a reply, which is exactly why they're fast against the same server and iOS is not.

## What this option changes, and why it's safe

By default the publisher gives HaishinKit the stream key as its FMLE publish name. HaishinKit then sends `releaseStream` and `FCPublish` before `createStream`, and waits for both replies.

With the `legacyRtmpCompatibility` prop on, the publisher leaves that name out and sends the two commands itself, right after the connection opens, without waiting for replies:

```swift
Task { _ = try? await connection.call("releaseStream", arguments: streamKey) }
Task { _ = try? await connection.call("FCPublish", arguments: streamKey) }
```

Legacy servers that care about these commands still receive them, and `publish` no longer waits ~15 s for replies that never come. OBS and the Android engine already behave this way. Against modern servers nothing observable changes: they reply at once either way.

One difference from HaishinKit's own sequence: the two commands now follow `createStream` instead of preceding it (`connect → createStream → releaseStream → FCPublish → publish`).

**Why it's opt-in / off by default.** Most ingests connect fine with HaishinKit's own sequence, so the publisher keeps it unless you ask. Enable it **only** if you publish to Agora RTLS or another legacy FMS/FMLE-style server that's slow to connect on iOS.

> In 1.x this was a config-plugin option, `ios.legacyRtmpCompatibility`, that patched HaishinKit's source at `pod install`. That option is gone: the plugin ignores it, so move it to the prop.

## How to enable it

Pass the prop to the view:

```tsx
<RtmpPublisherView
  legacyRtmpCompatibility={true}
  // …
/>
```

It is read each time a stream starts or reconnects, so an app that publishes to different servers can turn it on only for the ones that need it, and an over-the-air update can change it. Android never waits for these answers and ignores the prop.
