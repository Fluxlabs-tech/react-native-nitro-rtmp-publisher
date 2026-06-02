import { useEffect, useState } from 'react';
import {
  KeyboardAvoidingView,
  Modal,
  Pressable,
  Text,
  TextInput,
  View,
} from 'react-native';
import { styles } from '../styles';

type Props = {
  visible: boolean;
  url: string;
  onSave: (url: string) => void;
  onClose: () => void;
};

/**
 * URL editor in a separate Modal. This is deliberate: the TextInput (and its
 * keyboard) live in the Modal's own window, so opening the keyboard here can
 * NOT resize the main streaming screen — which is what previously broke the
 * camera preview in Picture-in-Picture (an inline input under a
 * KeyboardAvoidingView mis-sized the preview surface). The streaming screen
 * itself now has no text input at all.
 */
export function UrlModal({ visible, url, onSave, onClose }: Props) {
  const [draft, setDraft] = useState(url);

  // Re-seed the draft from the current URL each time the sheet opens.
  useEffect(() => {
    if (visible) setDraft(url);
  }, [visible, url]);

  return (
    <Modal
      visible={visible}
      transparent
      animationType="fade"
      onRequestClose={onClose}
    >
      {/* `padding` (both platforms) reacts to keyboard-show events directly, so
          it lifts the bottom sheet above the keyboard even inside a Modal whose
          window doesn't adjustResize. */}
      <KeyboardAvoidingView style={styles.modalBackdrop} behavior="padding">
        <View style={styles.urlSheet}>
          <Text style={styles.modalTitle}>RTMP URL</Text>
          <TextInput
            value={draft}
            onChangeText={setDraft}
            autoCapitalize="none"
            autoCorrect={false}
            autoFocus
            multiline
            style={[styles.input, { marginTop: 12 }]}
            placeholder="rtmp://host:1935/app/stream"
            placeholderTextColor="#666"
          />
          <View style={styles.row}>
            <Pressable onPress={onClose} style={[styles.btn, styles.btnAlt]}>
              <Text style={styles.btnText}>Cancel</Text>
            </Pressable>
            <Pressable onPress={() => onSave(draft.trim())} style={styles.btn}>
              <Text style={styles.btnText}>Save</Text>
            </Pressable>
          </View>
        </View>
      </KeyboardAvoidingView>
    </Modal>
  );
}
