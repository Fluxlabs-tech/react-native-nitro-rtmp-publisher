import { useCallback, useRef, useState } from 'react';

export type LogEntry = { id: number; ts: string; line: string };

const MAX_ENTRIES = 100;

/**
 * Append-only log buffer for surfacing publisher events / errors in a UI
 * sheet. Caps at `MAX_ENTRIES` to keep memory bounded.
 */
export function useEventLog() {
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const idRef = useRef(0);

  const append = useCallback((line: string) => {
    const ts = new Date().toLocaleTimeString();
    setLogs((prev) => {
      idRef.current += 1;
      return [{ id: idRef.current, ts, line }, ...prev].slice(0, MAX_ENTRIES);
    });
  }, []);

  const clear = useCallback(() => setLogs([]), []);

  return { logs, append, clear };
}
