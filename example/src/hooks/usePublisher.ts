import { useMemo, useRef, useState } from 'react';
import { callback } from 'react-native-nitro-modules';
import type {
  RtmpConnectionEvent,
  RtmpPublisherViewMethods,
  ThermalStatus,
} from 'react-native-nitro-rtmp-publisher';
import {
  AUDIO_BITRATE,
  AUDIO_STEREO,
  errMsg,
  VIDEO_BITRATE,
  VIDEO_FPS,
  VIDEO_HEIGHT,
  VIDEO_IFRAME_INTERVAL,
  VIDEO_WIDTH,
} from '../constants';

/**
 * Sets up the publisher view once it's first ready, wires connection /
 * bitrate / thermal listeners, prepares the encoder, and starts the preview.
 *
 * `sampleRate` is the resolved device sample rate (queried via
 * `getDeviceSampleRate()` in the parent). The parent gates rendering until
 * the value is known, so by the time this hook's `hybridRef` callback
 * fires we already have the correct rate to pass to `prepareAudio()`.
 *
 * Returns a stable `hybridRef` to pass to `<RtmpPublisherView hybridRef>`,
 * a `publisherRef` for imperative calls (start/stop/zoom/etc.), and the
 * derived UI state (`streaming`, `previewing`, `thermal`).
 */
export function usePublisher(append: (line: string) => void, sampleRate: number) {
  // `streaming` is true only after a successful publish.
  // `connecting` is true while there's an in-flight attempt — covers both
  // the first connect after `startStream` and any native auto-reconnect
  // (e.g. when coming back from background). The UI should disable Start
  // on `streaming || connecting` so the user can't fire a second
  // `startStream` while the native side is mid-reconnect.
  const [streaming, setStreaming] = useState(false);
  const [connecting, setConnecting] = useState(false);
  const [previewing, setPreviewing] = useState(false);
  const [thermal, setThermal] = useState<ThermalStatus>('none');
  // True while the app is in the Android PIP floating window — used to hide
  // overlays/controls (they're meaningless in the tiny window).
  const [pipActive, setPipActive] = useState(false);
  const publisherRef = useRef<RtmpPublisherViewMethods | null>(null);
  const initOnceRef = useRef(false);

  const hybridRef = useMemo(
    () =>
      callback((ref: RtmpPublisherViewMethods) => {
        publisherRef.current = ref;
        if (initOnceRef.current) return;
        initOnceRef.current = true;
        append('view ready, attaching listener');

        ref.setOnConnectionEvent(
          (event: RtmpConnectionEvent, message: string) => {
            append(`event=${event}${message ? ` msg=${message}` : ''}`);
            switch (event) {
              case 'connectionStarted':
              case 'reconnecting':
                // Native is actively trying. Block the Start button.
                setConnecting(true);
                break;
              case 'connectionSuccess':
                setConnecting(false);
                setStreaming(true);
                break;
              case 'disconnect':
              case 'connectionFailed':
              case 'authError':
                setConnecting(false);
                setStreaming(false);
                break;
            }
          }
        );

        // 5 retries, 3-second backoff. Budget is re-seeded on every startStream.
        ref.setAutoReconnect(5, 3000);

        try {
          // Configure encoder BEFORE startPreview so the GL pipeline picks up
          // the correct stream rotation up-front (avoids preview/stream race).
          const rotation = ref.getCameraOrientation();
          const v = ref.prepareVideo(
            VIDEO_WIDTH,
            VIDEO_HEIGHT,
            VIDEO_FPS,
            VIDEO_BITRATE,
            VIDEO_IFRAME_INTERVAL,
            rotation
          );
          const a = ref.prepareAudio(AUDIO_BITRATE, sampleRate, AUDIO_STEREO);
          append(
            `prepareVideo=${v} prepareAudio=${a} ` +
              `sampleRate=${sampleRate} rotation=${rotation}`
          );

          ref.startPreview('back', VIDEO_WIDTH, VIDEO_HEIGHT);
          setPreviewing(true);
          append('startPreview(back)');

          // Adaptive bitrate: cap at `VIDEO_BITRATE`, drop 20% on congestion,
          // recover 5% per tick.
          ref.setAdaptiveBitrate(VIDEO_BITRATE, 20, 5);
          // Combined stream stats (measured TX bitrate + live video fps) in one
          // callback. Superset of setOnBitrateChange — use this when you also
          // want the frame rate. fps is the sent rate on Android, the
          // encoder-input rate on iOS.
          ref.setOnStreamStats((bitrateBps: number, videoFps: number) => {
            append(`tx=${Math.round(bitrateBps / 1000)} kbps · ${Math.round(videoFps)} fps`);
          });

          // Thermal monitoring. Seed initial value since the listener only
          // fires on changes.
          setThermal(ref.getThermalStatus());
          ref.setOnThermalWarning((status: ThermalStatus) => {
            append(`thermal=${status}`);
            setThermal(status);
          });

          // PIP enter/exit — hide overlays in the floating window. Android-only
          // (no-op on iOS). The `pictureInPictureEnabled` prop arms auto-enter
          // on Home/Recents (API 31+); the "PIP" button calls
          // enterPictureInPicture() for the manual path / Android 8–11.
          ref.setOnPictureInPictureChange((isInPip: boolean) => {
            append(`pip=${isInPip}`);
            setPipActive(isInPip);
          });

          // iOS audio-clock drift telemetry (fires only while noiseSuppression
          // is ON). Apple Voice Processing runs on a separate audio clock from
          // the camera; the library re-aligns it to the capture clock so A/V
          // can't drift. This reports each ~20ms of net correction — watch
          // `total` climb to see the real clock skew being absorbed. No-op on
          // Android (audio is captured in-session there).
          ref.setOnAudioDriftCorrection(
            (correctionMs: number, totalCorrectionMs: number) => {
              if (Math.abs(totalCorrectionMs) < 1.5) {
                append(`audio-drift ✓ SYNCED (~0ms)`);
              } else {
                append(
                  `audio-drift ${correctionMs >= 0 ? '+' : ''}${correctionMs.toFixed(1)}ms ` +
                    `(total ${totalCorrectionMs >= 0 ? '+' : ''}${totalCorrectionMs.toFixed(1)}ms)`
                );
              }
            }
          );
        } catch (e: unknown) {
          append(`init err: ${errMsg(e)}`);
        }
      }),
    // `sampleRate` is captured in the closure for prepareAudio. In practice
    // it's stable for the lifetime of this hook (parent gates render until
    // the probe resolves), but include it in deps to keep React's exhaustive-
    // deps lint happy and to survive any future code that does swap it.
    [append, sampleRate]
  );

  return {
    hybridRef,
    publisherRef,
    streaming,
    connecting,
    previewing,
    thermal,
    pipActive,
    setStreaming,
    setConnecting,
  };
}
