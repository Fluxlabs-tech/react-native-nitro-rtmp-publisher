import { useMemo, useState } from 'react';
import { Pressable, ScrollView, Text, View } from 'react-native';
import type { LogEntry, LogLevel } from '../hooks/useEventLog';
import { styles } from '../styles';

type Props = {
  logs: LogEntry[];
  tags: string[];
  counts: { total: number; warn: number; error: number };
  onClear: () => void;
};

const LEVEL_FILTERS: { key: 'all' | LogLevel; label: string }[] = [
  { key: 'all', label: 'all' },
  { key: 'warn', label: 'warn+' },
  { key: 'error', label: 'err' },
];

const LEVEL_STYLE: Record<LogLevel, object> = {
  info: styles.logInfo,
  warn: styles.logWarn,
  error: styles.logError,
};

/**
 * Scrollable event list with level and tag filters. Newest first, so the thing
 * that just happened is always at the top without scrolling.
 */
export function LogPanel({ logs, tags, counts, onClear }: Props) {
  const [level, setLevel] = useState<'all' | LogLevel>('all');
  const [tag, setTag] = useState<string | null>(null);

  const shown = useMemo(
    () =>
      logs.filter((l) => {
        if (tag && l.tag !== tag) return false;
        if (level === 'error') return l.level === 'error';
        if (level === 'warn') return l.level !== 'info';
        return true;
      }),
    [logs, level, tag]
  );

  return (
    <View>
      <View style={styles.row}>
        {LEVEL_FILTERS.map((f) => (
          <Pressable
            key={f.key}
            onPress={() => setLevel(f.key)}
            style={[styles.filterChip, level === f.key ? styles.filterChipOn : styles.filterChipOff]}
          >
            <Text style={styles.filterChipText}>{f.label}</Text>
          </Pressable>
        ))}
        <Pressable onPress={onClear} style={[styles.filterChip, styles.filterChipOff]}>
          <Text style={styles.filterChipText}>clear</Text>
        </Pressable>
      </View>

      {tags.length > 1 ? (
        <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.tagRow}>
          <Pressable
            onPress={() => setTag(null)}
            style={[styles.filterChip, tag === null ? styles.filterChipOn : styles.filterChipOff]}
          >
            <Text style={styles.filterChipText}>all tags</Text>
          </Pressable>
          {tags.map((t) => (
            <Pressable
              key={t}
              onPress={() => setTag(t === tag ? null : t)}
              style={[styles.filterChip, t === tag ? styles.filterChipOn : styles.filterChipOff]}
            >
              <Text style={styles.filterChipText}>{t}</Text>
            </Pressable>
          ))}
        </ScrollView>
      ) : null}

      <Text style={styles.logMeta}>
        {shown.length}/{counts.total} shown · {counts.warn} warn · {counts.error} err
        {'  ·  adb logcat -s ReactNativeJS:V | grep EX'}
      </Text>

      <ScrollView style={styles.logScroll} nestedScrollEnabled>
        {shown.length === 0 ? (
          <Text style={styles.logLineMuted}>(nothing matches)</Text>
        ) : (
          shown.map((l) => (
            <Text key={l.id} style={[styles.logLine, LEVEL_STYLE[l.level]]}>
              {l.ts} <Text style={styles.logTag}>{l.tag}</Text> {l.line}
            </Text>
          ))
        )}
      </ScrollView>
    </View>
  );
}
