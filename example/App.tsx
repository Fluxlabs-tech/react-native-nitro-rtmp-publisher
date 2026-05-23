import { StatusBar } from 'expo-status-bar';
import { useCallback, useState } from 'react';
import { KeyboardAvoidingView, Platform, View } from 'react-native';
import {
  RtmpPublisherView,
  type CameraFacing,
} from 'react-native-nitro-rtmp-publisher';

import { ControlBar } from './src/components/ControlBar';
import { EventsModal } from './src/components/EventsModal';
import { PreviewOverlay } from './src/components/PreviewOverlay';
import { DEFAULT_RTMP_URL, errMsg } from './src/constants';
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

  const { logs, append, clear } = useEventLog();
  const permissionsReady = usePermissions(append);
  const { hybridRef, publisherRef, streaming, previewing, thermal, setStreaming } =
    usePublisher(append);

  const pinchHandlers = usePinchZoom(publisherRef, ({ zoom, min, max }) => {
    append(`zoom=${zoom.toFixed(2)} (${min.toFixed(2)}..${max.toFixed(2)})`);
  });

  const onStart = useCallback(() => {
    const ref = publisherRef.current;
    if (!ref) return;
    try {
      ref.startStream(url);
      append(`startStream(${url})`);
    } catch (e: unknown) {
      append(`start err: ${errMsg(e)}`);
    }
  }, [url, append, publisherRef]);

  const onStop = useCallback(() => {
    const ref = publisherRef.current;
    if (!ref) return;
    try {
      ref.stopStream();
      append('stopStream()');
      setStreaming(false);
    } catch (e: unknown) {
      append(`stop err: ${errMsg(e)}`);
    }
  }, [append, publisherRef, setStreaming]);

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
        {permissionsReady ? (
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
            // Camcorder mic source: gentle AGC, broadband pickup — the
            // recommended default for live video streaming on both platforms.
            audioSource="camcorder"
            // Engage built-in noise suppression + echo cancellation + AGC.
            // Overlays on top of the camcorder source on Android, and on iOS
            // forces `AVAudioSession.Mode.voiceChat` (Apple's Voice Processing
            // IO unit). Set to `false` if you want raw broadband audio.
            noiseSuppression={true}
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
        />
      </View>

      <ControlBar
        url={url}
        onUrlChange={setUrl}
        streaming={streaming}
        logCount={logs.length}
        onStart={onStart}
        onStop={onStop}
        onSwitch={onSwitch}
        onOpenLogs={() => setLogsOpen(true)}
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
