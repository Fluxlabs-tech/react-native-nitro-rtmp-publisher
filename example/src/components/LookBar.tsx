import { useRef } from 'react';
import { PanResponder, Pressable, Text, View } from 'react-native';
import type { BeautyLook } from 'react-native-nitro-rtmp-publisher';
import { styles } from '../styles';

const LOOKS: BeautyLook[] = ['warm', 'bright', 'cool'];

type Props = {
  look: BeautyLook;
  intensity: number;
  onChangeLook: (look: BeautyLook) => void;
  onChangeIntensity: (intensity: number) => void;
};

/**
 * The product surface: three looks and one intensity scrubber, nothing else.
 * There is no "off" chip — beauty on/off is the Beauty button, so while the
 * filter is on one look is always selected.
 *
 * PanResponder rather than a slider package: the example app has no slider
 * dependency and a drag track is ~15 lines. Absolute positioning, so a tap
 * anywhere on the track seeks there instead of only nudging.
 */
export function LookBar({
  look,
  intensity,
  onChangeLook,
  onChangeIntensity,
}: Props) {
  const width = useRef(0);

  // Held in a ref so the responder can be created once and still call the
  // latest handler — recreating PanResponder per render drops in-flight drags.
  const seek = useRef((x: number) => {});
  seek.current = (x: number) => {
    if (width.current <= 0) return;
    const v = Math.min(1, Math.max(0, x / width.current));
    onChangeIntensity(Math.round(v * 100) / 100);
  };

  const pan = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onMoveShouldSetPanResponder: () => true,
      onPanResponderGrant: (e) => seek.current(e.nativeEvent.locationX),
      onPanResponderMove: (e) => seek.current(e.nativeEvent.locationX),
      // Without this a fast drag settles wherever the last move event landed,
      // which is short of the finger — lifting at the far right gave 85, not 100.
      onPanResponderRelease: (e) => seek.current(e.nativeEvent.locationX),
    })
  ).current;

  return (
    <View>
      <View style={styles.row}>
        {LOOKS.map((l) => (
          <Pressable
            key={l}
            onPress={() => onChangeLook(l)}
            style={[styles.btn, look === l ? styles.btn : styles.btnAlt]}
          >
            <Text style={styles.btnText}>{l}</Text>
          </Pressable>
        ))}
      </View>

      <View style={styles.row}>
        <View
          {...pan.panHandlers}
          onLayout={(e) => {
            width.current = e.nativeEvent.layout.width;
          }}
          style={styles.lookTrack}
        >
          {/* pointerEvents none, or the fill becomes the touch target and
              locationX is measured against it instead of the track. */}
          <View
            pointerEvents="none"
            style={[styles.lookFill, { width: `${intensity * 100}%` }]}
          />
          <Text pointerEvents="none" style={styles.lookValue}>
            {Math.round(intensity * 100)}
          </Text>
        </View>
      </View>
    </View>
  );
}
