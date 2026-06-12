#!/usr/bin/env node
//
// measure-av-drift.mjs — quantify audio/video lip-sync DRIFT in a captured RTMP egress.
//
// WHY: the iOS publisher sends audio and video as two independent zero-based RTMP
// timelines (HaishinKit RTMPTimestamp). If both ride a common clock they stay
// locked; if not, the offset slips over time. This script measures that slip from
// a captured egress so we can tell a STATIC offset (constant — annoying but
// tolerable) from PROGRESSIVE DRIFT (grows ms/min — the real bug) and pin which
// prop combo (beauty / noiseSuppression) triggers it.
//
// METHOD: the robust drift signal is the difference in how much MEDIA TIME each
// track covered over the same capture: audio_span − video_span. First/last-packet
// interleave adds only a bounded (~one packet-interval) uncertainty to that
// difference — it does NOT grow with capture length — so over a long capture a
// real rate drift dwarfs it. (Comparing instantaneous audio_pts vs video_pts is
// fragile: muxer interleave + tail mismatch fake a slope.)
//
// This is a pts-based ESTIMATE. The authoritative check is a CLAP TEST: stream a
// clapperboard / a ms-clock with a per-second beep, and eyeball clap-vs-beep at
// t=0 / 15 / 30 min. Use this script for the number; use the clap to confirm — and
// the clap is the only reliable way to see the static offset or an NS-toggle /
// phone-call re-anchor STEP (RC-2), which a pts dump can't recover.
//
// IMPORTANT — measure the EGRESS, not a local recording. The local MP4 recorder
// writes via AVAssetWriter, which preserves the original buffer PTS relationship;
// the desync lives in the RTMP dual-zero-based timeline, so capture what actually
// left the device, and remux with -c copy (re-encoding rewrites timestamps).
//
// CAPTURE (pick one), then run this script on the result:
//   # A) Local one-binary RTMP server:
//   #    brew install mediamtx && mediamtx &        # rtmp://<mac-ip>:1935
//   #    # point the app at rtmp://<mac-ip>:1935/live/test
//   #    ffmpeg -i rtmp://127.0.0.1:1935/live/test -c copy -t 1800 cap.flv
//   # B) Stream to your real ingest; capture its playback/egress URL with -c copy.
//
// USAGE:
//   node scripts/measure-av-drift.mjs cap.flv
//
// Requires ffprobe on PATH. No npm deps.
//

import { execFileSync } from 'node:child_process';

function ffprobeJson(args) {
  try {
    const out = execFileSync('ffprobe', ['-v', 'error', '-of', 'json', ...args], {
      encoding: 'utf8',
      maxBuffer: 256 * 1024 * 1024, // a 30-min capture has a lot of packets
      // Capture stderr (don't inherit) so a failure surfaces once via our
      // handler instead of also leaking ffprobe's raw line to the terminal.
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return JSON.parse(out || '{}');
  } catch (e) {
    const msg = (e.stderr || e.message || '').toString().trim();
    console.error(`ffprobe failed: ${msg}`);
    process.exit(1);
  }
}

function streamMeta(path) {
  const info = ffprobeJson([
    '-show_streams',
    '-show_entries', 'stream=codec_type,codec_name,sample_rate,avg_frame_rate',
    path,
  ]);
  const meta = {};
  for (const s of info.streams || []) {
    const t = s.codec_type;
    if ((t === 'audio' || t === 'video') && !meta[t]) meta[t] = s;
  }
  if (!meta.audio || !meta.video) {
    console.error('Need both an audio and a video stream in the capture.');
    process.exit(1);
  }
  return meta;
}

function packetPts(path, streamSel) {
  const info = ffprobeJson([
    '-select_streams', streamSel,
    '-show_packets', '-show_entries', 'packet=pts_time',
    path,
  ]);
  const pts = [];
  for (const p of info.packets || []) {
    const t = p.pts_time;
    if (t !== undefined && t !== 'N/A') {
      const v = Number(t);
      if (!Number.isNaN(v)) pts.push(v);
    }
  }
  pts.sort((a, b) => a - b);
  return pts;
}

function median(xs) {
  if (xs.length === 0) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const n = s.length;
  return n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2;
}

function medianInterval(pts) {
  if (pts.length < 2) return 0;
  const diffs = [];
  for (let i = 1; i < pts.length; i++) {
    if (pts[i] > pts[i - 1]) diffs.push(pts[i] - pts[i - 1]);
  }
  return median(diffs);
}

// Format a number with fixed precision + optional leading '+', right-padded to width.
function f(n, prec, width, sign = false) {
  let s = n.toFixed(prec);
  if (sign && n >= 0) s = `+${s}`;
  return s.padStart(width);
}

function main() {
  const file = process.argv[2];
  if (!file) {
    console.error('usage: node scripts/measure-av-drift.mjs <capture.flv|mp4|ts|mkv>');
    process.exit(2);
  }

  const meta = streamMeta(file);
  const aPts = packetPts(file, 'a:0');
  const vPts = packetPts(file, 'v:0');
  if (aPts.length < 2 || vPts.length < 2) {
    console.error('Not enough packet timestamps in both streams.');
    process.exit(1);
  }

  const aInt = medianInterval(aPts);
  const vInt = medianInterval(vPts);

  // DRIFT = difference in media-time each track covered over the capture.
  // Immune to interleave/tail artifacts (uses only each stream's own first/last
  // pts). The first/last interleave adds a bounded (~one packet-interval each)
  // uncertainty that does NOT grow with capture length — so over a long capture a
  // real rate drift dwarfs it.
  const aSpan = aPts[aPts.length - 1] - aPts[0];
  const vSpan = vPts[vPts.length - 1] - vPts[0];
  const overlap = Math.max(
    Math.min(aPts[aPts.length - 1], vPts[vPts.length - 1]) - Math.max(aPts[0], vPts[0]),
    1e-6,
  );
  const driftTotalMs = (aSpan - vSpan) * 1000; // + => audio ran longer (video slow)
  const slopeMsPerMin = (driftTotalMs / overlap) * 60;
  const noiseMs = (aInt + vInt) * 1000;
  // Approx static offset: which timeline starts later. The clap test is the
  // authoritative check for both the static offset AND any mid-stream STEP
  // (an NS-toggle / phone-call re-anchor, RC-2) — neither is reliably
  // recoverable from a pts dump alone.
  const staticOffsetMs = (aPts[0] - vPts[0]) * 1000;

  const am = meta.audio;
  const vm = meta.video;
  const duration = Math.max(aPts[aPts.length - 1], vPts[vPts.length - 1]);
  const withinNoise = Math.abs(driftTotalMs) < noiseMs;

  const line = '──────────────────────────────────────────────────────────────';
  const bar = '══════════════════════════════════════════════════════════════';
  console.log(bar);
  console.log(` A/V drift report — ${file}`);
  console.log(bar);
  console.log(` duration         : ${f(duration, 1, 8)} s   (${(duration / 60).toFixed(1)} min)`);
  console.log(` audio            : ${am.codec_name ?? '?'} @ ${am.sample_rate ?? '?'} Hz`
    + `  (pkt ${(aInt * 1000).toFixed(1)} ms)`);
  console.log(` video            : ${vm.codec_name ?? '?'} @ ${vm.avg_frame_rate ?? '?'} fps`
    + `  (pkt ${(vInt * 1000).toFixed(1)} ms)`);
  console.log(` media covered    : audio ${aSpan.toFixed(2)}s  vs  video ${vSpan.toFixed(2)}s`
    + `  (overlap ${overlap.toFixed(1)}s)`);
  console.log(line);
  console.log(` static offset ~  : ${f(staticOffsetMs, 1, 8, true)} ms   (+ = audio ahead / video late)`);
  console.log(` total drift      : ${f(driftTotalMs, 1, 8, true)} ms   (+ = audio ran longer / video slow)`);
  if (withinNoise) {
    console.log(' DRIFT SLOPE      :   inconclusive (drift < noise floor)');
  } else {
    console.log(` >> DRIFT SLOPE   : ${f(slopeMsPerMin, 2, 8, true)} ms/min   <<`);
  }
  console.log(` noise floor      : ±${f(noiseMs, 1, 6)} ms (on total drift)`);
  console.log(line);
  if (withinNoise) {
    console.log(' DRIFT VERDICT    : ✅ rate-locked / within noise');
    if (duration < 600) {
      console.log('                    (capture ≥30 min to resolve small drift rates)');
    }
  } else if (Math.abs(slopeMsPerMin) < 5.0) {
    console.log(' DRIFT VERDICT    : ⚠️  mild drift — noticeable only on long streams');
  } else {
    console.log(' DRIFT VERDICT    : ❌ PROGRESSIVE DRIFT — lip-sync breaks over time');
  }
  if (Math.abs(staticOffsetMs) > 80) {
    console.log(` OFFSET VERDICT   : ⚠️  large static offset (~${staticOffsetMs >= 0 ? '+' : ''}`
      + `${staticOffsetMs.toFixed(0)} ms) — fixed lip-sync error`);
  }
  console.log(line);
  console.log(' Run the 4 prop combos (≥30 min each) and compare slopes:');
  console.log('   beauty OFF/NS OFF should be ~0; whichever combo first shows a');
  console.log('   non-zero slope identifies the trigger (offscreen video vs NS clock).');
  console.log(' For the static offset and any NS-toggle / phone-call STEP (RC-2),');
  console.log(' use the clap test (clapperboard / ms-clock + per-second beep).');
}

main();
