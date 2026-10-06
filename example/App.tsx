import { NavigationContainer } from '@react-navigation/native';
import {
  createNativeStackNavigator,
  type NativeStackScreenProps,
} from '@react-navigation/native-stack';
import { StatusBar } from 'expo-status-bar';
import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState, View } from 'react-native';
import {
  RtmpPublisherView,
  type CameraFacing,
} from 'react-native-nitro-rtmp-publisher';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { DEFAULT_RTMP_URL, errMsg, getDeviceSampleRate } from './src/constants';
import { useEventLog } from './src/hooks/useEventLog';
import { usePermissions } from './src/hooks/usePermissions';
import { usePinchZoom } from './src/hooks/usePinchZoom';
import { usePublisher } from './src/hooks/usePublisher';
import { styles } from './src/styles';
// Platform files: SwiftUI + Liquid Glass on iOS, Jetpack Compose on Android
// (`@expo/ui`). Metro picks `.ios.tsx` / `.android.tsx`.
import { SecondScreen } from './src/ui/SecondScreen';
import { StreamOverlay } from './src/ui/StreamOverlay';

type RootStackParamList = {
  Stream: undefined;
  Second: undefined;
};

function StreamScreen({
  navigation,
}: NativeStackScreenProps<RootStackParamList, 'Stream'>) {
  const [url, setUrl] = useState(DEFAULT_RTMP_URL);
  // Tracks the camera the user is currently shooting with. Used to mirror
  // both preview AND stream on the front camera (selfie convention) and
  // leave the back camera un-mirrored.
  const [facing, setFacing] = useState<CameraFacing>('back');
  const isFront = facing === 'front';
  // Toggle for the noiseSuppression prop. Applies live on both platforms (see
  // onToggleNoiseSuppression). Default OFF — `audioSource="camcorder"` already
  // engages iOS's light built-in NR via `.videoRecording` mode. Only flip this
  // on when you're streaming from a genuinely noisy environment.
  const [noiseSuppression, setNoiseSuppression] = useState(false);
  // Beauty filter (GPU skin-smoothing). Supported on both platforms.
  const [beauty, setBeauty] = useState(false);
  // Device's native audio capture rate, probed via the AudioManager module
  // (Android: PROPERTY_OUTPUT_SAMPLE_RATE; iOS: AVAudioSession.sampleRate).
  // Stays `null` until the native call resolves — we gate the publisher
  // view's render on this so `prepareAudio` always uses the correct rate
  // and never the fallback. Picking the wrong rate forces the OS sample-
  // rate converter, which on budget UNISOC/MediaTek chips muffles 5-10 kHz.
  const [sampleRate, setSampleRate] = useState<number | null>(null);
  // True only while the app is in the foreground. Pressing Home flips this to
  // false *before* the PIP shrink animation starts, so we can hide the controls
  // ahead of the transition — otherwise they'd be visible (scaled down) during
  // the shrink and then vanish, which reads as a jitter. `pipActive` (which only
  // becomes true *after* the transition) still governs the exit so controls
  // re-appear cleanly once we're back full-screen.
  const [appActive, setAppActive] = useState(true);

  const { logs, append, clear } = useEventLog();
  const permissionsReady = usePermissions(append);

  useEffect(() => {
    const sub = AppState.addEventListener('change', (s) =>
      setAppActive(s === 'active')
    );
    return () => sub.remove();
  }, []);

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
    pipActive,
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
      // Applies live on both platforms — no resetAudioEncoder() needed. Android
      // swaps the custom spectral-denoiser effect in the prop setter; iOS
      // re-runs AVAudioSession.setCategory in its didSet. So flipping the prop
      // is enough, even mid-stream.
      append(`noiseSuppression=${next}`);
      return next;
    });
  }, [append]);

  const onToggleBeauty = useCallback(() => {
    setBeauty((prev) => {
      const next = !prev;
      try {
        publisherRef.current?.setBeautyFilterEnabled(next);
        append(`beautyFilter=${next}`);
      } catch (e: unknown) {
        append(`beauty err: ${errMsg(e)}`);
      }
      return next;
    });
  }, [append, publisherRef]);

  const onEnterPip = useCallback(() => {
    try {
      const ok = publisherRef.current?.enterPictureInPicture();
      append(`enterPictureInPicture()=${ok}`);
    } catch (e: unknown) {
      append(`pip err: ${errMsg(e)}`);
    }
  }, [append, publisherRef]);

  // DEBUG (iOS, NS on): inject a +400ms A/V desync and watch the self-heal
  // loop recover it — the `audio-drift` log skew spikes then decays to 0.
  const onInjectDesync = useCallback(() => {
    publisherRef.current?.injectAudioDesyncForTesting(400);
    append('injected +400ms desync — watch audio-drift heal to ~0');
  }, [append, publisherRef]);

  // Last time a flip was actually dispatched. The native side already
  // coalesces rapid flips (an in-flight camera attach absorbs extra taps and
  // reconverges to the latest facing once it finishes), so the freeze is gone
  // even with the button mashed. This ~250ms throttle is a pure UX nicety: it
  // drops ultra-rapid double-fires so the LOCAL `facing` state (which drives the
  // mirror props) stays in lock-step with the native intent — we skip BOTH the
  // native call and the local toggle together so they never desync.
  const lastSwitchAtRef = useRef(0);
  const onSwitch = useCallback(() => {
    const ref = publisherRef.current;
    if (!ref) return;
    const now = Date.now();
    if (now - lastSwitchAtRef.current < 250) return;
    lastSwitchAtRef.current = now;
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

  // Show overlays/controls only when full-screen AND foregrounded. Hiding on
  // background (Home press) pre-empts the PIP shrink so they don't flash; the
  // pipActive gate keeps them hidden through the exit grow until we settle.
  const showControls = !pipActive && appActive;

  return (
    // No KeyboardAvoidingView and no text input on this screen: the RTMP URL is
    // edited in a native sheet with its own window, so the keyboard can never
    // resize the preview / PIP layout. `collapsable={false}` keeps the
    // publisher's parent from being flattened away — re-parenting its
    // SurfaceView restarts the Android camera surface.
    <View style={styles.container} collapsable={false}>
      <StatusBar style="light" />

      {/*
       * Camera preview — an absolute, full-window layer. It is intentionally
       * NOT in a flex column above the controls: keeping it independent means
       * showing/hiding the controls (e.g. on the PIP enter/exit transition)
       * never resizes or moves the preview, which otherwise caused a one-frame
       * jitter as the PIP window settled.
       *
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
          aspectRatioMode="fill"
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
          // Spectral noise suppression on Android; Apple Voice Processing on
          // iOS. Toggled live from the "Denoise" control.
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
          // Arm system PIP: auto-enters the floating window on Home/Recents —
          // Android API 31+, and iOS on the live tier (iPhone iOS 18+ with the
          // `voip` background mode, M1+ iPad). The "PiP" button also triggers
          // it manually (the only path on Android 8–11).
          pictureInPictureEnabled={true}
          hybridRef={hybridRef}
        />
      ) : (
        <View style={styles.preview} />
      )}

      {/* Transparent pinch-to-zoom layer over the full-window preview. */}
      <View style={styles.pinchLayer} {...pinchHandlers} pointerEvents="box-only" />

      {/* Absolutely positioned and hidden in PIP, so mounting/unmounting them
          never moves the preview underneath (no PIP transition jitter). */}
      {showControls && (
        <StreamOverlay
          url={url}
          streaming={streaming}
          connecting={connecting}
          previewing={previewing}
          thermal={thermal}
          sampleRate={sampleRate}
          noiseSuppression={noiseSuppression}
          beauty={beauty}
          logs={logs}
          onChangeUrl={setUrl}
          onStart={onStart}
          onStop={onStop}
          onSwitchCamera={onSwitch}
          onToggleNoiseSuppression={onToggleNoiseSuppression}
          onToggleBeauty={onToggleBeauty}
          onEnterPip={onEnterPip}
          onInjectDesync={onInjectDesync}
          onOpenSecondScreen={() => navigation.navigate('Second')}
          onClearLogs={clear}
        />
      )}
    </View>
  );
}

// A publisher-free screen. The streaming screen stays MOUNTED while we're here
// (native-stack keeps it in the tree), so on Android this is exactly the case
// that must NOT auto-enter PIP.
function SecondRoute({
  navigation,
}: NativeStackScreenProps<RootStackParamList, 'Second'>) {
  return (
    <View style={styles.secondScreen}>
      <StatusBar style="light" />
      <SecondScreen onBack={() => navigation.goBack()} />
    </View>
  );
}

const Stack = createNativeStackNavigator<RootStackParamList>();

export default function App() {
  return (
    <SafeAreaProvider>
      <NavigationContainer>
        <Stack.Navigator screenOptions={{ headerShown: false }}>
          <Stack.Screen name="Stream" component={StreamScreen} />
          <Stack.Screen name="Second" component={SecondRoute} />
        </Stack.Navigator>
      </NavigationContainer>
    </SafeAreaProvider>
  );
}
