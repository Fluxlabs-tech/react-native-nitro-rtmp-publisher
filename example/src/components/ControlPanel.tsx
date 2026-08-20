import { useState } from 'react';
import { Pressable, ScrollView, Text, View } from 'react-native';
import type { BeautyLook } from 'react-native-nitro-rtmp-publisher';
import {
  BeautyTuner,
  GOLDEN_PR28,
  type BeautyParams,
} from './BeautyTuner';
import { LogPanel } from './LogPanel';
import { LookBar } from './LookBar';
import type { LogEntry } from '../hooks/useEventLog';
import { styles } from '../styles';

type Tab = 'beauty' | 'stream' | 'debug' | 'logs';

type Props = {
  // stream
  url: string;
  onEditUrl: () => void;
  streaming: boolean;
  connecting: boolean;
  previewing: boolean;
  onStart: () => void;
  onStop: () => void;
  onSwitch: () => void;
  facing: string;
  recording: boolean;
  onToggleRecord: () => void;
  onEnterPip: () => void;
  noiseSuppression: boolean;
  onToggleNoiseSuppression: () => void;
  // beauty
  beauty: boolean;
  onToggleBeauty: () => void;
  look: BeautyLook;
  lookIntensity: number;
  onChangeLook: (look: BeautyLook) => void;
  onChangeLookIntensity: (intensity: number) => void;
  params: BeautyParams;
  onChangeParams: (next: BeautyParams) => void;
  // debug
  thermal: string | null;
  sampleRate: number | null;
  buildTag: string;
  onNavigateSecond: () => void;
  onInjectDesync: () => void;
  // logs
  logs: LogEntry[];
  logTags: string[];
  logCounts: { total: number; warn: number; error: number };
  onClearLogs: () => void;
  // chrome
  onHideUi: () => void;
};

function Kv({ k, v }: { k: string; v: string }) {
  return (
    <View style={styles.kvRow}>
      <Text style={styles.kvKey}>{k}</Text>
      <Text style={styles.kvVal}>{v}</Text>
    </View>
  );
}

/**
 * Bottom control surface. The tab bar sits BELOW the scrolling body so it is
 * anchored to the screen bottom: content grows upward and the tabs never move
 * under your thumb when a panel changes height.
 *
 * Deliberately an overlay on a persistent preview
 * rather than routed screens: beauty cannot be judged without watching the
 * footage change, so navigating away from the preview to reach a control would
 * defeat the point.
 *
 * Only the Beauty tab's chips and slider are product surface. Everything else
 * here is a test instrument.
 */
export function ControlPanel({
  url,
  onEditUrl,
  streaming,
  connecting,
  previewing,
  onStart,
  onStop,
  onSwitch,
  facing,
  recording,
  onToggleRecord,
  onEnterPip,
  noiseSuppression,
  onToggleNoiseSuppression,
  beauty,
  onToggleBeauty,
  look,
  lookIntensity,
  onChangeLook,
  onChangeLookIntensity,
  params,
  onChangeParams,
  thermal,
  sampleRate,
  buildTag,
  onNavigateSecond,
  onInjectDesync,
  logs,
  logTags,
  logCounts,
  onClearLogs,
  onHideUi,
}: Props) {
  const [tab, setTab] = useState<Tab>('beauty');
  const [showCalibration, setShowCalibration] = useState(false);

  const startDisabled = streaming || connecting;
  const stopDisabled = !streaming && !connecting;
  const startLabel = connecting && !streaming ? 'Connecting…' : 'Start';

  const TABS: { key: Tab; label: string; badge?: number }[] = [
    { key: 'beauty', label: 'Beauty' },
    { key: 'stream', label: 'Stream' },
    { key: 'debug', label: 'Debug' },
    { key: 'logs', label: 'Logs', badge: logCounts.error || undefined },
  ];

  return (
    <View style={styles.panel}>

      <ScrollView style={styles.panelBody} nestedScrollEnabled>
        {tab === 'beauty' ? (
          <View>
            <View style={styles.row}>
              <Pressable
                onPress={onToggleBeauty}
                style={[styles.btn, beauty ? styles.btn : styles.btnAlt]}
              >
                <Text style={styles.btnText}>
                  Beauty: {beauty ? 'ON' : 'OFF'}
                </Text>
              </Pressable>
            </View>

            {beauty ? (
              <LookBar
                look={look}
                intensity={lookIntensity}
                onChangeLook={onChangeLook}
                onChangeIntensity={onChangeLookIntensity}
              />
            ) : (
              <Text style={styles.hint}>
                Turn Beauty on to reach the looks. Off is the unfiltered camera.
              </Text>
            )}

            <Pressable
              onPress={() => setShowCalibration((v) => !v)}
              style={[styles.btn, styles.btnAlt, styles.btnWide]}
            >
              <Text style={styles.btnText}>
                {showCalibration ? '▾' : '▸'} Base calibration (internal)
              </Text>
            </Pressable>

            {showCalibration ? (
              <View>
                <Text style={styles.hint}>
                  Not seller-facing. Golden restores PR #28 exactly: its base
                  constants plus Warm, whose LUT slot is identity. Set Sat to 1.00
                  to A/B a look against the raw v0.15.0 character instead.
                </Text>
                <View style={styles.row}>
                  <Pressable
                    onPress={() => {
                      onChangeParams(GOLDEN_PR28);
                      onChangeLook('warm');
                      onChangeLookIntensity(0);
                    }}
                    style={[styles.btn, styles.btnAlt]}
                  >
                    <Text style={styles.btnText}>Golden PR #28</Text>
                  </Pressable>
                </View>
                <BeautyTuner params={params} onChange={onChangeParams} />
              </View>
            ) : null}
          </View>
        ) : null}

        {tab === 'stream' ? (
          <View>
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
                style={[
                  styles.btn,
                  styles.btnStop,
                  stopDisabled && styles.btnDisabled,
                ]}
              >
                <Text style={styles.btnText}>Stop</Text>
              </Pressable>
            </View>

            <View style={styles.row}>
              <Pressable onPress={onSwitch} style={[styles.btn, styles.btnAlt]}>
                <Text style={styles.btnText}>Flip ({facing})</Text>
              </Pressable>
              <Pressable
                onPress={onToggleRecord}
                style={[styles.btn, recording ? styles.btnStop : styles.btnAlt]}
              >
                <Text style={styles.btnText}>
                  {recording ? '■ REC' : '● REC'}
                </Text>
              </Pressable>
            </View>

            <View style={styles.row}>
              <Pressable
                onPress={onToggleNoiseSuppression}
                style={[styles.btn, noiseSuppression ? styles.btn : styles.btnAlt]}
              >
                <Text style={styles.btnText}>
                  NS: {noiseSuppression ? 'ON' : 'OFF'}
                </Text>
              </Pressable>
              <Pressable onPress={onEnterPip} style={[styles.btn, styles.btnAlt]}>
                <Text style={styles.btnText}>PIP</Text>
              </Pressable>
            </View>
          </View>
        ) : null}

        {tab === 'debug' ? (
          <View>
            <Kv k="build" v={buildTag} />
            <Kv
              k="state"
              v={`${streaming ? 'streaming' : connecting ? 'connecting' : 'idle'}${
                previewing ? ' · preview' : ''
              }`}
            />
            <Kv k="thermal" v={thermal ?? '—'} />
            <Kv k="sampleRate" v={sampleRate ? `${sampleRate} Hz` : '—'} />
            <Kv k="camera" v={facing} />
            <Kv k="beauty" v={beauty ? 'on' : 'off'} />
            <Kv
              k="look"
              v={`${look} @ ${Math.round(lookIntensity * 100)}%`}
            />
            <Kv
              k="base"
              v={`temp ${params.temperature.toFixed(2)} · sat ${params.saturation.toFixed(
                2
              )} · lift ${params.skinLift.toFixed(2)}`}
            />

            <View style={styles.row}>
              <Pressable
                onPress={onNavigateSecond}
                style={[styles.btn, styles.btnAlt]}
              >
                <Text style={styles.btnText}>Screen 2 (PIP scope)</Text>
              </Pressable>
            </View>
            {streaming ? (
              <View style={styles.row}>
                <Pressable
                  onPress={onInjectDesync}
                  style={[styles.btn, styles.btnStop]}
                >
                  <Text style={styles.btnText}>Inject +400ms desync</Text>
                </Pressable>
              </View>
            ) : null}
          </View>
        ) : null}

        {tab === 'logs' ? (
          <LogPanel
            logs={logs}
            tags={logTags}
            counts={logCounts}
            onClear={onClearLogs}
          />
        ) : null}
      </ScrollView>

      <View style={styles.tabBar}>
        {TABS.map((t) => (
          <Pressable
            key={t.key}
            onPress={() => setTab(t.key)}
            style={[styles.tab, tab === t.key && styles.tabOn]}
          >
            <Text style={[styles.tabText, tab === t.key && styles.tabTextOn]}>
              {t.label}
              {t.badge ? ` ${t.badge}` : ''}
            </Text>
          </Pressable>
        ))}
        <Pressable onPress={onHideUi} style={styles.tab}>
          <Text style={styles.tabText}>Hide</Text>
        </Pressable>
      </View>
    </View>
  );
}
