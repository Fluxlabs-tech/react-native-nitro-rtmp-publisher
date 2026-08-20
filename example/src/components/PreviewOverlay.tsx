import { Pressable, Text, View } from 'react-native';
import type { ThermalStatus } from 'react-native-nitro-rtmp-publisher';
import { THERMAL_COLOR } from '../constants';
import type { ProcStats } from '../hooks/useProcStats';
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
  /** Process RAM / CPU, so a look change can be judged against its cost. */
  stats: ProcStats;
  onSwitchCamera: () => void;
};

/**
 * Status overlay on top of the camera preview. Left: LIVE / PREVIEW / IDLE,
 * thermal state, and current process RAM / CPU. Right: capture sample rate and
 * a camera flip button — flipping to the selfie camera to look at a face should
 * not mean opening a panel over the preview.
 */
export function PreviewOverlay({
  streaming,
  previewing,
  thermal,
  sampleRate,
  stats,
  onSwitchCamera,
}: Props) {
  const label = streaming ? 'LIVE' : previewing ? 'PREVIEW' : 'IDLE';
  const ram = stats.rssMb == null ? '—' : `${Math.round(stats.rssMb)} MB`;
  const cpu = stats.cpuPct == null ? '—' : `${Math.round(stats.cpuPct)}%`;
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
      <View style={styles.statsOverlay}>
        <View style={styles.chip}>
          <Text style={styles.chipText}>
            {stats.err ? 'proc n/a' : `RAM ${ram}  CPU ${cpu}`}
          </Text>
        </View>
      </View>

      <View style={styles.previewOverlayRight}>
        {sampleRate != null && (
          <View style={styles.chip}>
            <Text style={styles.chipText}>
              {(sampleRate / 1000).toFixed(1).replace(/\.0$/, '')} kHz
            </Text>
          </View>
        )}
        <Pressable onPress={onSwitchCamera} style={styles.flipBtn}>
          <Text style={styles.flipIcon}>⇄</Text>
        </Pressable>
      </View>
    </>
  );
}
