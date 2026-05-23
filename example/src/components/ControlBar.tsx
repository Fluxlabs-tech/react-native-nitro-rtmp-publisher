import { Pressable, Text, TextInput, View } from 'react-native';
import { styles } from '../styles';

type Props = {
  url: string;
  onUrlChange: (next: string) => void;
  streaming: boolean;
  logCount: number;
  noiseSuppression: boolean;
  onStart: () => void;
  onStop: () => void;
  onSwitch: () => void;
  onOpenLogs: () => void;
  onToggleNoiseSuppression: () => void;
};

/**
 * Bottom control bar: RTMP URL input + Start/Stop/Flip/Events buttons.
 * All callbacks are owned by the parent — this is a pure presenter.
 */
export function ControlBar({
  url,
  onUrlChange,
  streaming,
  logCount,
  noiseSuppression,
  onStart,
  onStop,
  onSwitch,
  onOpenLogs,
  onToggleNoiseSuppression,
}: Props) {
  return (
    <View style={styles.controls}>
      <Text style={styles.label}>RTMP URL</Text>
      <TextInput
        value={url}
        onChangeText={onUrlChange}
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
      </View>
    </View>
  );
}
