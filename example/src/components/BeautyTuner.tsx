import { Pressable, Text, View } from 'react-native';
import { styles } from '../styles';

export type BeautyParams = {
  temperature: number;
  saturation: number;
  skinLift: number;
};

/**
 * RAW baseline — mathematically colour-neutral. saturation 1.0 leaves the
 * source's own chroma untouched, so this is NOT the product look.
 */
export const RAW_PARAMS: BeautyParams = {
  temperature: 0,
  saturation: 1.0,
  skinLift: 0,
};

/**
 * PRODUCT BASE — PR #28's shipped constants. Deliberately more saturated than
 * RAW; keep the two names distinct, because looks are offsets from THIS, not
 * from RAW. Changing this changes what Warm means — run scripts/parity.py.
 */
export const BASE_PARAMS: BeautyParams = {
  temperature: 0,
  saturation: 1.7,
  skinLift: 0.05,
};

/**
 * The regression oracle. These are PR #28's compile-time constants, and Warm's
 * LUT slot is identity, so this base with look=warm reproduces PR #28 exactly.
 * `scripts/parity.py` asserts that bit-for-bit against commit 80518aa.
 */
export const GOLDEN_PR28: BeautyParams = BASE_PARAMS;

const ROWS: {
  key: keyof BeautyParams;
  label: string;
  step: number;
  min: number;
  max: number;
}[] = [
  { key: 'temperature', label: 'Temp', step: 0.1, min: -1, max: 1 },
  { key: 'saturation', label: 'Sat ', step: 0.05, min: 0, max: 2 },
  { key: 'skinLift', label: 'Lift', step: 0.01, min: 0, max: 0.25 },
];

type Props = {
  params: BeautyParams;
  onChange: (next: BeautyParams) => void;
};

/**
 * Raw tuning controls, deliberately built before any Warm/White/Cool preset
 * exists — the presets should be frozen from values discovered here on real
 * faces, not invented first. Steps rather than a slider so no native dependency
 * is added for a debug control.
 */
export function BeautyTuner({ params, onChange }: Props) {
  const bump = (key: keyof BeautyParams, dir: number) => {
    const row = ROWS.find((r) => r.key === key)!;
    const raw = params[key] + dir * row.step;
    // step arithmetic drifts (0.1+0.2=0.30000000000000004), so snap to the step
    const snapped = Math.round(raw / row.step) * row.step;
    const next = Math.min(row.max, Math.max(row.min, snapped));
    onChange({ ...params, [key]: next });
  };

  return (
    <View>
      {ROWS.map((row) => (
        <View key={row.key} style={styles.row}>
          <Text style={[styles.btnText, { width: 44 }]}>{row.label}</Text>
          <Pressable
            onPress={() => bump(row.key, -1)}
            style={[styles.btn, styles.btnAlt, { flex: 0, paddingHorizontal: 18 }]}
          >
            <Text style={styles.btnText}>−</Text>
          </Pressable>
          <Text style={[styles.btnText, { width: 58, textAlign: 'center' }]}>
            {params[row.key].toFixed(2)}
          </Text>
          <Pressable
            onPress={() => bump(row.key, 1)}
            style={[styles.btn, styles.btnAlt, { flex: 0, paddingHorizontal: 18 }]}
          >
            <Text style={styles.btnText}>+</Text>
          </Pressable>
          <Pressable
            onPress={() => onChange({ ...params, [row.key]: BASE_PARAMS[row.key] })}
            style={[styles.btn, styles.btnAlt, { flex: 0, paddingHorizontal: 10 }]}
          >
            <Text style={styles.btnText}>base</Text>
          </Pressable>
        </View>
      ))}

    </View>
  );
}
