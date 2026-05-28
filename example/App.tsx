import { StatusBar } from 'expo-status-bar';
import { useCallback, useEffect, useState } from 'react';
import { KeyboardAvoidingView, Platform, View } from 'react-native';
import {
  RtmpPublisherView,
  type CameraFacing,
} from 'react-native-nitro-rtmp-publisher';

import { ControlBar } from './src/components/ControlBar';
import { EventsModal } from './src/components/EventsModal';
import { PreviewOverlay } from './src/components/PreviewOverlay';
import { DEFAULT_RTMP_URL, errMsg, getDeviceSampleRate } from './src/constants';
import { useEventLog } from './src/hooks/useEventLog';
import { usePermissions } from './src/hooks/usePermissions';
import { usePinchZoom } from './src/hooks/usePinchZoom';
import { usePublisher } from './src/hooks/usePublisher';
import { styles } from './src/styles';

export default function App() {
  const [url, setUrl] = useState(DEFAULT_RTMP_URL);
  const [logsOpen, setLogsOpen] = useState(false);
  // Tracks the camera the user is currently shooting with. Used to mirror
  // both preview AND stream on the front camera (selfie convention) and
  // leave the back camera un-mirrored.
  const [facing, setFacing] = useState<CameraFacing>('back');
  const isFront = facing === 'front';
  // Toggle for the noiseSuppression prop. iOS applies it live by re-running
  // AVAudioSession.setCategory in the prop setter. Android requires
  // resetAudioEncoder() to rebuild the AudioRecord pipeline with the new
  // NoiseSuppressor / AcousticEchoCanceler flags — we trigger that below.
  // Default OFF — `audioSource="camcorder"` already engages iOS's light
  // built-in NR via `.videoRecording` mode. Only flip this on (button below)
  // when you're streaming from a genuinely noisy environment and accept the
  // tradeoff: AGC will compress your voice in exchange for killing background.
  const [noiseSuppression, setNoiseSuppression] = useState(false);
  // Device's native audio capture rate, probed via the AudioManager module
  // (Android: PROPERTY_OUTPUT_SAMPLE_RATE; iOS: AVAudioSession.sampleRate).
  // Stays `null` until the native call resolves — we gate the publisher
  // view's render on this so `prepareAudio` always uses the correct rate
  // and never the fallback. Picking the wrong rate forces the OS sample-
  // rate converter, which on budget UNISOC/MediaTek chips muffles 5-10 kHz.
  const [sampleRate, setSampleRate] = useState<number | null>(null);

  const { logs, append, clear } = useEventLog();
  const permissionsReady = usePermissions(append);

  // Probe the device's native sample rate once on mount.
  useEffect(() => {
    let cancelled = false;
    getDeviceSampleRate().then((rate) => {
      if (cancelled) return;
      setSampleRate(rate);
      append(`device sampleRate=${rate}`);
    });
    return () => {
      cancelled = true;
    };
  }, [append]);

  const {
    hybridRef,
    publisherRef,
    streaming,
    connecting,
    previewing,
    thermal,
    setStreaming,
    setConnecting,
  } = usePublisher(append, sampleRate ?? 48_000);

  const pinchHandlers = usePinchZoom(publisherRef, ({ zoom, min, max }) => {
    append(`zoom=${zoom.toFixed(2)} (${min.toFixed(2)}..${max.toFixed(2)})`);
  });

  const onStart = useCallback(() => {
    const ref = publisherRef.current;
    if (!ref) return;
    try {
      // Optimistically flip into "connecting" so the Start button disables
      // before the first native event lands — avoids a double-tap firing a
      // second startStream while the first is still mid-connect.
      setConnecting(true);
      ref.startStream(url);
      append(`startStream(${url})`);
    } catch (e: unknown) {
      setConnecting(false);
      append(`start err: ${errMsg(e)}`);
    }
  }, [url, append, publisherRef, setConnecting]);

  const onStop = useCallback(() => {
    const ref = publisherRef.current;
    if (!ref) return;
    try {
      ref.stopStream();
      append('stopStream()');
      setStreaming(false);
      setConnecting(false);
    } catch (e: unknown) {
      append(`stop err: ${errMsg(e)}`);
    }
  }, [append, publisherRef, setStreaming, setConnecting]);

  const onToggleNoiseSuppression = useCallback(() => {
    setNoiseSuppression((prev) => {
      const next = !prev;
      append(`noiseSuppression=${next}`);
      // On Android the new NS flag only takes effect on a fresh prepareAudio,
      // so rebuild the audio encoder once the prop has propagated. iOS already
      // applies live in the prop's didSet, so this is harmless there.
      setTimeout(() => {
        try {
          publisherRef.current?.resetAudioEncoder();
        } catch (e: unknown) {
          append(`resetAudioEncoder err: ${errMsg(e)}`);
        }
      }, 0);
      return next;
    });
  }, [append, publisherRef]);

  const onSwitch = useCallback(() => {
    const ref = publisherRef.current;
    if (!ref) return;
    try {
      ref.switchCamera();
      // Update derived state so the mirror props flip to match the new camera.
      // We toggle locally rather than calling `ref.isFrontCamera()` because
      // switchCamera is best-effort and may race with the prop setter.
      setFacing((prev) => (prev === 'back' ? 'front' : 'back'));
      append('switchCamera()');
    } catch (e: unknown) {
      append(`switch err: ${errMsg(e)}`);
    }
  }, [append, publisherRef]);

  return (
    <KeyboardAvoidingView
      style={styles.container}
      // iOS: `padding` adds bottom padding equal to the keyboard height, which
      // shrinks the preview area and slides the controls (including the URL
      // input) above the keyboard.
      // Android: `height` resizes the root view as the keyboard opens. The
      // platform's own `windowSoftInputMode=adjustResize` (set by Expo by
      // default) gives the same effect, so `undefined` is fine — using
      // `'height'` here is a safety net.
      behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
    >
      <StatusBar style="light" />

      <View style={styles.previewBox}>
        {/*
         * Two gates before the publisher mounts:
         *   1. `permissionsReady` — RECORD_AUDIO / CAMERA granted.
         *   2. `sampleRate != null` — the native AudioManager probe has
         *      returned, so `prepareAudio()` runs once with the correct
         *      device-native rate instead of a fallback. Mounting earlier
         *      and re-mounting later would tear down/rebuild AudioRecord
         *      and leak HAL state on UNISOC.
         */}
        {permissionsReady && sampleRate != null ? (
          <RtmpPublisherView
            style={styles.preview}
            // Pin both encoders to hardware (Android-critical; iOS no-op).
            forceHardwareCodec={true}
            // RTMP servers require H.264 video + AAC audio in 99% of cases.
            videoCodec="h264"
            audioCodec="aac"
            // Letterbox to fit when preview aspect ≠ stream aspect.
            aspectRatioMode="adjust"
            // Selfie convention: front camera mirrored for both preview AND
            // stream so the streamer and viewer see the same orientation.
            mirrorPreview={isFront}
            mirrorStream={isFront}
            // Only warn when the device is hot enough that the encoder might
            // start dropping frames. (`'light'` would also trigger on minor
            // warm-ups, which is too noisy for production UIs.)
            thermalWarningThreshold="severe"
            // Camcorder mic source: gentle AGC, broadband pickup, light
            // noise reduction built into iOS's `.videoRecording` mode. The
            // right default for live streaming — natural voice with some
            // ambient cleanup, no AGC crushing.
            audioSource="camcorder"
            // Engage built-in noise suppression + echo cancellation + AGC.
            // Overlays on top of the camcorder source on Android, and on iOS
            // forces `AVAudioSession.Mode.voiceChat` (Apple's Voice Processing
            // IO unit). Toggled live from the "NS" button in the controls.
            noiseSuppression={noiseSuppression}
            // Lock orientation to portrait. Flip to `true` if you want the
            // stream to auto-rotate with the device.
            autoRotateStream={false}
            // ~3s glass-to-glass latency — good general-purpose default.
            // Switch to `'quality'` for >1hr broadcasts, `'lowLatency'` for
            // interactive/video-call-style streams.
            streamMode="quality"
            // Android-only: keeps the process alive during backgrounding
            // (notification shows these strings). Silently ignored on iOS,
            // where the `audio` UIBackgroundMode in app.json does the same job.
            foregroundServiceTitle="Live stream"
            foregroundServiceText="Broadcasting"
            foregroundServiceIcon=""
            hybridRef={hybridRef}
          />
        ) : (
          <View style={styles.preview} />
        )}

        {/* Transparent overlay that captures two-finger pinch → setZoom. */}
        <View style={styles.pinchLayer} {...pinchHandlers} pointerEvents="box-only" />

        <PreviewOverlay
          streaming={streaming}
          previewing={previewing}
          thermal={thermal}
          sampleRate={sampleRate}
        />
      </View>

      <ControlBar
        url={url}
        onUrlChange={setUrl}
        streaming={streaming}
        connecting={connecting}
        logCount={logs.length}
        noiseSuppression={noiseSuppression}
        onStart={onStart}
        onStop={onStop}
        onSwitch={onSwitch}
        onOpenLogs={() => setLogsOpen(true)}
        onToggleNoiseSuppression={onToggleNoiseSuppression}
      />

      <EventsModal
        visible={logsOpen}
        logs={logs}
        onClose={() => setLogsOpen(false)}
        onClear={clear}
      />
    </KeyboardAvoidingView>
  );
}
