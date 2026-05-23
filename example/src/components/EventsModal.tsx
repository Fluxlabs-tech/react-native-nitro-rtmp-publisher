import { Modal, Pressable, ScrollView, Text, View } from 'react-native';
import type { LogEntry } from '../hooks/useEventLog';
import { styles } from '../styles';

type Props = {
  visible: boolean;
  logs: LogEntry[];
  onClose: () => void;
  onClear: () => void;
};

/**
 * Bottom-sheet modal that lists the most recent publisher events. Renders
 * nothing when `visible` is false (driven by parent state).
 */
export function EventsModal({ visible, logs, onClose, onClear }: Props) {
  return (
    <Modal
      visible={visible}
      transparent
      animationType="fade"
      onRequestClose={onClose}
    >
      <Pressable style={styles.modalBackdrop} onPress={onClose}>
        <View
          style={styles.modalSheet}
          onStartShouldSetResponder={() => true}
        >
          <View style={styles.modalHeader}>
            <Text style={styles.modalTitle}>Events</Text>
            <Pressable onPress={onClear} style={styles.modalHeaderBtn}>
              <Text style={styles.modalHeaderBtnText}>Clear</Text>
            </Pressable>
            <Pressable onPress={onClose} style={styles.modalHeaderBtn}>
              <Text style={styles.modalHeaderBtnText}>Close</Text>
            </Pressable>
          </View>
          <ScrollView style={styles.modalLogs}>
            {logs.length === 0 ? (
              <Text style={styles.logLineMuted}>(no events yet)</Text>
            ) : (
              logs.map((l) => (
                <Text key={l.id} style={styles.logLine}>
                  [{l.ts}] {l.line}
                </Text>
              ))
            )}
          </ScrollView>
        </View>
      </Pressable>
    </Modal>
  );
}
