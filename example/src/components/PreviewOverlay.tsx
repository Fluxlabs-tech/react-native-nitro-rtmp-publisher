import { Text, View } from 'react-native';
import type { ThermalStatus } from 'react-native-nitro-rtmp-publisher';
import { THERMAL_COLOR } from '../constants';
import { styles } from '../styles';

type Props = {
  streaming: boolean;
  previewing: boolean;
  thermal: ThermalStatus;
};

/**
 * Status overlay on top of the camera preview. Shows LIVE / PREVIEW / IDLE
 * and the OS thermal state. Matches the original example styling.
 */
export function PreviewOverlay({ streaming, previewing, thermal }: Props) {
  const label = streaming ? 'LIVE' : previewing ? 'PREVIEW' : 'IDLE';
  return (
    <View style={styles.previewOverlay}>
      <Text style={[styles.badge, streaming && styles.badgeOn]}>{label}</Text>
      <View style={styles.chip}>
        <View
          style={[styles.chipDot, { backgroundColor: THERMAL_COLOR[thermal] }]}
        />
        <Text style={styles.chipText}>{thermal.toUpperCase()}</Text>
      </View>
    </View>
  );
}
