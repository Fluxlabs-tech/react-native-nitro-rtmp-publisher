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
  const [streaming, setStreaming] = useState(false);
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
            if (event === 'connectionSuccess') setStreaming(true);
            if (
              event === 'disconnect' ||
              event === 'connectionFailed' ||
              event === 'authError'
            ) {
              setStreaming(false);
            }
            // 'reconnecting' keeps `streaming` as-is — UI can show a spinner.
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

  return { hybridRef, publisherRef, streaming, previewing, thermal, setStreaming };
}
