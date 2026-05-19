import { StatusBar } from 'expo-status-bar';
import { useEffect, useMemo, useRef, useState } from 'react';
import {
  Alert,
  PermissionsAndroid,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { callback } from 'react-native-nitro-modules';
import {
  RtmpPublisherView,
  type RtmpConnectionEvent,
  type RtmpPublisherViewMethods,
  type ThermalStatus,
} from 'react-native-nitro-rtmp-publisher';

type LogEntry = { id: number; ts: string; line: string };

const errMsg = (e: unknown) =>
  e instanceof Error ? e.message : String(e);

const THERMAL_COLOR: Record<ThermalStatus, string> = {
  none: '#22c55e',      // green
  light: '#84cc16',     // lime
  moderate: '#eab308',  // yellow
  severe: '#f97316',    // orange
  critical: '#ef4444',  // red
  emergency: '#dc2626', // deep red
  shutdown: '#7f1d1d',  // crimson
};

const VIDEO_WIDTH = 1280;
const VIDEO_HEIGHT = 720;
const VIDEO_FPS = 30;
const VIDEO_BITRATE = 2_500_000;
const VIDEO_IFRAME_INTERVAL = 2;

export default function App() {
  const [url, setUrl] = useState('rtmp://10.0.2.2:1935/live/test');
  const [streaming, setStreaming] = useState(false);
  const [previewing, setPreviewing] = useState(false);
  const [thermal, setThermal] = useState<ThermalStatus>('none');
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const logIdRef = useRef(0);
  const publisherRef = useRef<RtmpPublisherViewMethods | null>(null);
  const initOnceRef = useRef(false);

  const appendLog = (line: string) => {
    const ts = new Date().toLocaleTimeString();
    setLogs((prev) => {
      logIdRef.current += 1;
      return [{ id: logIdRef.current, ts, line }, ...prev].slice(0, 100);
    });
  };

  useEffect(() => {
    (async () => {
      if (Platform.OS !== 'android') return;
      const res = await PermissionsAndroid.requestMultiple([
        PermissionsAndroid.PERMISSIONS.CAMERA,
        PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
      ]);
      const ok =
        res[PermissionsAndroid.PERMISSIONS.CAMERA] ===
          PermissionsAndroid.RESULTS.GRANTED &&
        res[PermissionsAndroid.PERMISSIONS.RECORD_AUDIO] ===
          PermissionsAndroid.RESULTS.GRANTED;
      if (!ok) {
        Alert.alert('Permissions denied', 'CAMERA and RECORD_AUDIO are required');
      } else {
        appendLog('permissions granted');
      }
    })();
  }, []);

  const hybridRef = useMemo(
    () =>
      callback((ref: RtmpPublisherViewMethods) => {
        publisherRef.current = ref;
        if (initOnceRef.current) return;
        initOnceRef.current = true;
        appendLog('view ready, attaching listener');
        ref.setOnConnectionEvent(
          (event: RtmpConnectionEvent, message: string) => {
            appendLog(`event=${event}${message ? ` msg=${message}` : ''}`);
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
          const a = ref.prepareAudio(128_000, 44_100, true);
          appendLog(
            `prepareVideo=${v} prepareAudio=${a} rotation=${rotation}`
          );
          ref.startPreview('back', VIDEO_WIDTH, VIDEO_HEIGHT);
          setPreviewing(true);
          appendLog('startPreview(back)');
          // Adaptive bitrate: cap at `VIDEO_BITRATE`, drop 20% on congestion,
          // recover 5% per tick. Subscribe to bitrate updates so we can log.
          ref.setAdaptiveBitrate(VIDEO_BITRATE, 20, 5);
          ref.setOnBitrateChange((bps: number) => {
            appendLog(`tx=${Math.round(bps / 1000)} kbps`);
          });
          // Thermal monitoring. Threshold = 'light' so every transition fires
          // and the chip stays accurate (not just on severe+ events).
          // Seed initial value since the listener only fires on changes.
          setThermal(ref.getThermalStatus());
          ref.setOnThermalWarning((status: ThermalStatus) => {
            appendLog(`thermal=${status}`);
            setThermal(status);
          });
        } catch (e: unknown) {
          appendLog(`init err: ${errMsg(e)}`);
        }
      }),
    []
  );

  const onStart = () => {
    const ref = publisherRef.current;
    if (!ref) return;
    try {
      ref.startStream(url);
      appendLog(`startStream(${url})`);
    } catch (e: unknown) {
      appendLog(`start err: ${errMsg(e)}`);
    }
  };

  const onStop = () => {
    const ref = publisherRef.current;
    if (!ref) return;
    try {
      ref.stopStream();
      appendLog('stopStream()');
      setStreaming(false);
    } catch (e: unknown) {
      appendLog(`stop err: ${errMsg(e)}`);
    }
  };

  const onSwitch = () => {
    const ref = publisherRef.current;
    if (!ref) return;
    try {
      ref.switchCamera();
      appendLog('switchCamera()');
    } catch (e: unknown) {
      appendLog(`switch err: ${errMsg(e)}`);
    }
  };

  return (
    <View style={styles.container}>
      <StatusBar style="light" />
      <View style={styles.previewBox}>
        <RtmpPublisherView
          style={styles.preview}
          forceHardwareCodec={true}
          videoCodec="h264"
          audioCodec="aac"
          aspectRatioMode="adjust"
          mirrorPreview={false}
          mirrorStream={false}
          thermalWarningThreshold="light"
          audioSource="camcorder"
          autoRotateStream={true}
          streamMode="quality"
          foregroundServiceTitle="Live stream"
          foregroundServiceText="Broadcasting"
          hybridRef={hybridRef}
        />
        <View style={styles.previewOverlay}>
          <Text style={[styles.badge, streaming && styles.badgeOn]}>
            {streaming ? 'LIVE' : previewing ? 'PREVIEW' : 'IDLE'}
          </Text>
          <View style={styles.chip}>
            <View
              style={[
                styles.chipDot,
                { backgroundColor: THERMAL_COLOR[thermal] },
              ]}
            />
            <Text style={styles.chipText}>{thermal.toUpperCase()}</Text>
          </View>
        </View>
      </View>

      <View style={styles.controls}>
        <Text style={styles.label}>RTMP URL</Text>
        <TextInput
          value={url}
          onChangeText={setUrl}
          autoCapitalize="none"
          autoCorrect={false}
          style={styles.input}
          placeholder="rtmp://host:1935/app/stream"
          placeholderTextColor="#666"
        />

        <View style={styles.row}>
          <Pressable
            onPress={onStart}
            disabled={streaming}
            style={[styles.btn, streaming && styles.btnDisabled]}
          >
            <Text style={styles.btnText}>Start</Text>
          </Pressable>
          <Pressable
            onPress={onStop}
            disabled={!streaming}
            style={[styles.btn, styles.btnStop, !streaming && styles.btnDisabled]}
          >
            <Text style={styles.btnText}>Stop</Text>
          </Pressable>
          <Pressable onPress={onSwitch} style={[styles.btn, styles.btnAlt]}>
            <Text style={styles.btnText}>Flip</Text>
          </Pressable>
        </View>

        <Text style={styles.label}>Events</Text>
        <ScrollView style={styles.logs}>
          {logs.map((l) => (
            <Text key={l.id} style={styles.logLine}>
              [{l.ts}] {l.line}
            </Text>
          ))}
        </ScrollView>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#000' },
  previewBox: { width: '100%', aspectRatio: 9 / 16, backgroundColor: '#111' },
  preview: { ...StyleSheet.absoluteFillObject },
  previewOverlay: {
    position: 'absolute',
    top: 48,
    left: 16,
    flexDirection: 'row',
  },
  badge: {
    color: '#fff',
    backgroundColor: '#444',
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 6,
    fontWeight: '700',
    fontSize: 12,
  },
  badgeOn: { backgroundColor: '#dc2626' },
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.55)',
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 999,
    marginLeft: 8,
  },
  chipDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    marginRight: 6,
  },
  chipText: {
    color: '#fff',
    fontWeight: '600',
    fontSize: 11,
    letterSpacing: 0.5,
  },
  controls: { flex: 1, padding: 16 },
  label: { color: '#aaa', marginTop: 8, marginBottom: 4 },
  input: {
    backgroundColor: '#222',
    color: '#fff',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
  },
  row: { flexDirection: 'row', gap: 8, marginTop: 12 },
  btn: {
    flex: 1,
    backgroundColor: '#2563eb',
    borderRadius: 8,
    paddingVertical: 12,
    alignItems: 'center',
  },
  btnStop: { backgroundColor: '#dc2626' },
  btnAlt: { backgroundColor: '#4b5563' },
  btnDisabled: { opacity: 0.4 },
  btnText: { color: '#fff', fontWeight: '600' },
  logs: {
    flex: 1,
    marginTop: 8,
    backgroundColor: '#1a1a1a',
    borderRadius: 8,
    padding: 8,
  },
  logLine: { color: '#9ca3af', fontFamily: 'monospace', fontSize: 11 },
});
