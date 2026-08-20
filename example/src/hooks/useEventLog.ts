import { useCallback, useMemo, useRef, useState } from 'react';

export type LogLevel = 'info' | 'warn' | 'error';

export type LogEntry = {
  id: number;
  /** ms since the first log line — easier to reason about than wall clock. */
  t: number;
  ts: string;
  level: LogLevel;
  tag: string;
  line: string;
};

const MAX_ENTRIES = 400;

/** Guessed when a call site doesn't say, so plain one-arg calls still colour right. */
function detectLevel(line: string): LogLevel {
  const l = line.toLowerCase();
  if (/\berr\b|error|fail|denied|exception|refused|unavailable/.test(l)) {
    return 'error';
  }
  if (/warn|missing|retry|drop|desync|timeout|throttl|severe/.test(l)) {
    return 'warn';
  }
  return 'info';
}

const pad = (n: number, w = 2) => String(n).padStart(w, '0');

function stamp(d: Date) {
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(
    d.getMilliseconds(),
    3
  )}`;
}

/**
 * Event log for the test harness. Every line is also mirrored to `console.log`
 * with a fixed `[EX ...]` prefix, so a whole session can be captured from a
 * terminal instead of squinting at the phone:
 *
 *   adb logcat -s ReactNativeJS:V | grep EX
 *
 * That matters for beauty work specifically — look, slot, intensity and the base
 * params change faster than you can screenshot them.
 */
export function useEventLog() {
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const idRef = useRef(0);
  const t0Ref = useRef<number | null>(null);

  const append = useCallback(
    (line: string, level?: LogLevel, tag: string = 'app') => {
      const now = Date.now();
      if (t0Ref.current == null) t0Ref.current = now;
      const t = now - t0Ref.current;
      const lvl = level ?? detectLevel(line);

      console.log(`[EX ${lvl.toUpperCase()} ${tag} +${t}ms] ${line}`);

      setLogs((prev) => {
        idRef.current += 1;
        const entry: LogEntry = {
          id: idRef.current,
          t,
          ts: stamp(new Date(now)),
          level: lvl,
          tag,
          line,
        };
        return [entry, ...prev].slice(0, MAX_ENTRIES);
      });
    },
    []
  );

  const clear = useCallback(() => {
    t0Ref.current = null;
    setLogs([]);
  }, []);

  const counts = useMemo(() => {
    let warn = 0;
    let error = 0;
    for (const l of logs) {
      if (l.level === 'warn') warn += 1;
      else if (l.level === 'error') error += 1;
    }
    return { total: logs.length, warn, error };
  }, [logs]);

  const tags = useMemo(
    () => Array.from(new Set(logs.map((l) => l.tag))).sort(),
    [logs]
  );

  return { logs, append, clear, counts, tags };
}
