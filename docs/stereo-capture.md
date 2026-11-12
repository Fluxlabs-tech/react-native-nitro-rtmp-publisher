# Stereo capture

`prepareAudio(..., isStereo)` controls AAC channel count. **On Android, the library silently downgrades stereo → mono on known single-mic / fake-stereo devices.**

This matters because budget Android phones (Realme across the board, budget Oppo A-series, OnePlus Nord N-series, Redmi 12 / A-series, anything on UNISOC or low-end MediaTek) ship a single physical mic capsule. When an app asks for stereo, the audio HAL synthesises a second channel by duplicating the mono signal. That doubling has two downstream costs:

- Doubled `AudioRecord` PCM throughput per callback.
- ~1.6× AAC software-encoder CPU per frame (joint-stereo is cheaper than 2× independent encoding, but not free).

On chips with weak performance cores (e.g. UNISOC Tiger T612) shared with the camera HAL, this is enough to push the audio thread past its ~21 ms deadline, causing dropped AAC frames and audibly chunky / stuttering playback.

## How the downgrade decides

In [`HybridRtmpPublisherView+Encoders.kt`](../android/src/main/java/com/margelo/nitro/rtmppublisher/HybridRtmpPublisherView+Encoders.kt), `resolveEffectiveStereo()` runs three checks in order and forces mono on the first match:

1. **`FAKE_STEREO_BUILTIN_MIC_BRANDS`** — universally-budget brands where every shipped device has the bug. Currently just `realme` (its entire lineup is single-mic). `oppo`/`oneplus`/`redmi` are deliberately **not** in this set — their flagships (Find X, OnePlus 8+, Redmi Note Pro / K) ship real dual-mic arrays and forcing mono there would lose real capability.
2. **`KNOWN_SINGLE_MIC_MODELS`** — exact-match `Build.MODEL` codes for budget SKUs from mixed-lineup brands. Empty by default; populate as field reports come in. Note `Build.MODEL` returns SKU codes, not consumer names — OnePlus Nord N100 is `BE2013`, not `Nord N100`.
3. **`builtInMicCount() < 2`** — fallback for OEMs that correctly expose only one `TYPE_BUILTIN_MIC` entry (some single-mic devices that don't lie in their `audio_policy` config).

If none match, the caller's `isStereo` is honoured. The decision inputs (brand, manufacturer, model, mic count, which check fired) are logged at `Log.INFO` with tag `RtmpPublisherView` — `adb logcat -s RtmpPublisherView:I` shows the line.

## Contributing a new device

Got chunky audio on a device that's not caught? Grab `Build.MODEL` from `adb shell getprop ro.product.model` while the app is running, then add it to `KNOWN_SINGLE_MIC_MODELS` in [`HybridRtmpPublisherView+Encoders.kt`](../android/src/main/java/com/margelo/nitro/rtmppublisher/HybridRtmpPublisherView+Encoders.kt) and open a PR. One-line change.

No-op on iOS — every iPhone has two physical mics and the audio session handles channel routing.
