import { Pressable, Text, View } from 'react-native';
import { styles } from '../styles';

type Props = {
  url: string;
  /** Open the URL editor (a separate modal — no inline keyboard on this screen). */
  onEditUrl: () => void;
  streaming: boolean;
  /**
   * True while a connect / reconnect attempt is in flight (after Start tap,
   * during native auto-reconnect on background→foreground, etc.). Used
   * alongside `streaming` to keep Start disabled until the publisher is
   * either fully connected or fully idle — prevents the user from firing a
   * second `startStream` while the first is still mid-handshake.
   */
  connecting: boolean;
  logCount: number;
  noiseSuppression: boolean;
  /** Current beauty-filter on/off state. */
  beauty: boolean;
  onStart: () => void;
  onStop: () => void;
  onSwitch: () => void;
  onOpenLogs: () => void;
  onToggleNoiseSuppression: () => void;
  onToggleBeauty: () => void;
  /** Enter Android Picture-in-Picture (no-op on iOS). */
  onEnterPip: () => void;
};

/**
 * Bottom control bar: RTMP URL input + Start/Stop/Flip/Events buttons.
 * All callbacks are owned by the parent — this is a pure presenter.
 */
export function ControlBar({
  url,
  onEditUrl,
  streaming,
  connecting,
  logCount,
  noiseSuppression,
  beauty,
  onStart,
  onStop,
  onSwitch,
  onOpenLogs,
  onToggleNoiseSuppression,
  onToggleBeauty,
  onEnterPip,
}: Props) {
  // Start is enabled only when the publisher is fully idle. Stop stays
  // enabled while connecting so the user can cancel an in-flight attempt
  // (covers stuck-on-handshake and the background-reconnect edge case).
  const startDisabled = streaming || connecting;
  const stopDisabled = !streaming && !connecting;
  const startLabel = connecting && !streaming ? 'Connecting…' : 'Start';
  return (
    <View style={styles.controls}>
      <Text style={styles.label}>RTMP URL</Text>
      {/* No inline TextInput on the streaming screen — editing opens a modal so
          the keyboard can never resize the preview (PIP-safe). */}
      <Pressable onPress={onEditUrl} style={styles.input}>
        <Text numberOfLines={1} style={{ color: url ? '#fff' : '#666' }}>
          {url || 'rtmp://host:1935/app/stream'}
        </Text>
      </Pressable>

      <View style={styles.row}>
        <Pressable
          onPress={onStart}
          disabled={startDisabled}
          style={[styles.btn, startDisabled && styles.btnDisabled]}
        >
          <Text style={styles.btnText}>{startLabel}</Text>
        </Pressable>
        <Pressable
          onPress={onStop}
          disabled={stopDisabled}
          style={[styles.btn, styles.btnStop, stopDisabled && styles.btnDisabled]}
        >
          <Text style={styles.btnText}>Stop</Text>
        </Pressable>
        <Pressable onPress={onSwitch} style={[styles.btn, styles.btnAlt]}>
          <Text style={styles.btnText}>Flip</Text>
        </Pressable>
        <Pressable onPress={onOpenLogs} style={[styles.btn, styles.btnAlt]}>
          <Text style={styles.btnText}>Events ({logCount})</Text>
        </Pressable>
      </View>

      {/* Secondary controls row — audio toggles. Stays visually distinct from
          the primary Start/Stop row so the user can tell at a glance which
          actions affect the stream vs. session config. */}
      <View style={styles.row}>
        <Pressable
          onPress={onToggleNoiseSuppression}
          style={[styles.btn, noiseSuppression ? styles.btn : styles.btnAlt]}
        >
          <Text style={styles.btnText}>
            NS: {noiseSuppression ? 'ON' : 'OFF'}
          </Text>
        </Pressable>
        <Pressable
          onPress={onToggleBeauty}
          style={[styles.btn, beauty ? styles.btn : styles.btnAlt]}
        >
          <Text style={styles.btnText}>Beauty: {beauty ? 'ON' : 'OFF'}</Text>
        </Pressable>
        <Pressable onPress={onEnterPip} style={[styles.btn, styles.btnAlt]}>
          <Text style={styles.btnText}>PIP</Text>
        </Pressable>
      </View>
    </View>
  );
}
