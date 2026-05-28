import { Text, View } from 'react-native';
import type { ThermalStatus } from 'react-native-nitro-rtmp-publisher';
import { THERMAL_COLOR } from '../constants';
import { styles } from '../styles';

type Props = {
  streaming: boolean;
  previewing: boolean;
  thermal: ThermalStatus;
  /**
   * Device's resolved native sample rate (from `getDeviceSampleRate()` in
   * App.tsx). `null` while the probe is in flight — we just hide the chip
   * during that brief window. Once resolved, displayed top-right as
   * "48 kHz" so you can confirm at a glance which rate the publisher
   * actually opened the mic with (and whether the OEM agreed with your
   * expectation).
   */
  sampleRate: number | null;
};

/**
 * Status overlay on top of the camera preview. Shows LIVE / PREVIEW / IDLE
 * + thermal state on the left, and the resolved capture sample rate on
 * the right. Matches the original example styling.
 */
export function PreviewOverlay({
  streaming,
  previewing,
  thermal,
  sampleRate,
}: Props) {
  const label = streaming ? 'LIVE' : previewing ? 'PREVIEW' : 'IDLE';
  return (
    <>
      <View style={styles.previewOverlay}>
        <Text style={[styles.badge, streaming && styles.badgeOn]}>{label}</Text>
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
      {sampleRate != null && (
        <View style={styles.previewOverlayRight}>
          <View style={styles.chip}>
            <Text style={styles.chipText}>
              {(sampleRate / 1000).toFixed(1).replace(/\.0$/, '')} kHz
            </Text>
          </View>
        </View>
      )}
    </>
  );
}
