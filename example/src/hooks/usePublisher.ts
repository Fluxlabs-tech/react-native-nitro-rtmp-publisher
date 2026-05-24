import { useMemo, useRef, useState } from 'react';
import { callback } from 'react-native-nitro-modules';
import type {
  RtmpConnectionEvent,
  RtmpPublisherViewMethods,
  ThermalStatus,
} from 'react-native-nitro-rtmp-publisher';
import {
  AUDIO_BITRATE,
  AUDIO_SAMPLE_RATE,
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
 * Returns a stable `hybridRef` to pass to `<RtmpPublisherView hybridRef>`,
 * a `publisherRef` for imperative calls (start/stop/zoom/etc.), and the
 * derived UI state (`streaming`, `previewing`, `thermal`).
 */
export function usePublisher(append: (line: string) => void) {
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
          const a = ref.prepareAudio(
            AUDIO_BITRATE,
            AUDIO_SAMPLE_RATE,
            AUDIO_STEREO
          );
          append(`prepareVideo=${v} prepareAudio=${a} rotation=${rotation}`);

          ref.startPreview('back', VIDEO_WIDTH, VIDEO_HEIGHT);
          setPreviewing(true);
          append('startPreview(back)');

          // Adaptive bitrate: cap at `VIDEO_BITRATE`, drop 20% on congestion,
          // recover 5% per tick.
          ref.setAdaptiveBitrate(VIDEO_BITRATE, 20, 5);
          ref.setOnBitrateChange((bps: number) => {
            append(`tx=${Math.round(bps / 1000)} kbps`);
          });

          // Thermal monitoring. Seed initial value since the listener only
          // fires on changes.
          setThermal(ref.getThermalStatus());
          ref.setOnThermalWarning((status: ThermalStatus) => {
            append(`thermal=${status}`);
            setThermal(status);
          });
        } catch (e: unknown) {
          append(`init err: ${errMsg(e)}`);
        }
      }),
    [append]
  );

  return {
    hybridRef,
    publisherRef,
    streaming,
    connecting,
    previewing,
    thermal,
    setStreaming,
    setConnecting,
  };
}
