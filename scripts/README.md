# scripts

Maintainer tooling (not shipped to npm consumers).

## `measure-av-drift.mjs` — quantify iOS A/V lip-sync drift

Diagnoses the audio/video desync described in the `ios-av-sync` analysis: the
publisher sends audio and video as two independent zero-based RTMP timelines, so
if they don't share a clock the offset slips over time. This script measures the
slip from a captured **egress** and tells a static offset (constant) from
**progressive drift** (grows ms/min — the real bug).

Requires `ffmpeg`/`ffprobe` on `PATH`. Runs on the repo's Node toolchain — no npm deps.

### 1. Capture the egress (not a local recording)

The local MP4 recorder preserves the original PTS relationship; the desync lives
in the RTMP dual-timeline, so capture what actually leaves the device, and remux
with `-c copy` (re-encoding rewrites timestamps and hides the drift).

```sh
brew install mediamtx        # one-binary RTMP server
mediamtx &                   # listens on rtmp://<your-mac-ip>:1935
# point the app at  rtmp://<your-mac-ip>:1935/live/test
ffmpeg -i rtmp://127.0.0.1:1935/live/test -c copy -t 1800 cap.flv
```

(Or stream to your real ingest and capture its playback/egress URL with `-c copy`.)

### 2. Analyze

```sh
node scripts/measure-av-drift.mjs cap.flv
```

`DRIFT SLOPE` in ms/min is the headline. `beauty OFF / NS OFF` should read
`rate-locked`. Captures under ~30 min report `inconclusive` when the drift is
below the measurement noise floor — stream longer.

### 3. Repro matrix (build `npm run ios:device`)

Run each ≥30 min on a real device (ideally an iPhone 14) and compare slopes — the
first combo with a non-zero slope identifies the trigger:

| # | `beautyFilter` | `noiseSuppression` | expectation |
|---|---|---|---|
| 1 | off | off | control — ~0 slope |
| 2 | off | on  | static offset, little/no slope |
| 3 | on  | off | progressive drift |
| 4 | on  | on  | drift + offset (worst) |

### 4. Static offset + RC-2 step → clap test

The pts dump can't reliably recover the static offset or a mid-stream re-anchor
**step** (the NS-toggle / phone-call jump, RC-2). Confirm those visually: stream
a clapperboard or a millisecond clock with a per-second beep, and compare
clap-vs-beep alignment at t=0 / 15 / 30 min. For RC-2 specifically, toggle
`noiseSuppression` (or trigger a phone call) mid-stream and check whether the
alignment steps.
