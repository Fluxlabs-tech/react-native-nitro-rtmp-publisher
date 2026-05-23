import { Pressable, Text, TextInput, View } from 'react-native';
import { styles } from '../styles';

type Props = {
  url: string;
  onUrlChange: (next: string) => void;
  streaming: boolean;
  logCount: number;
  onStart: () => void;
  onStop: () => void;
  onSwitch: () => void;
  onOpenLogs: () => void;
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
  onStart,
  onStop,
  onSwitch,
  onOpenLogs,
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
    </View>
  );
}
