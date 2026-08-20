import { useEffect, useRef, useState } from 'react';
import * as FileSystem from 'expo-file-system/legacy';

/** Android page size and clock ticks. Both fixed at 4096 / 100 on every device we ship to. */
const PAGE_BYTES = 4096;
const CLK_TCK = 100;

export type ProcStats = {
  /** Resident set size in MB, or null if /proc is unreadable. */
  rssMb: number | null;
  /** Process CPU across all threads. Can exceed 100 on multiple cores. */
  cpuPct: number | null;
  err: string | null;
};

/**
 * Reads this process's own RSS and CPU from /proc. No native module needed —
 * a process can always read its own /proc entries.
 *
 * Process scope is deliberately the right scope here: it covers the JS thread,
 * the GL thread and the encoder together, which is what "what does the beauty
 * filter actually cost" means. It is not a per-shader measurement and should not
 * be quoted as one — use `ab_load.py` for that.
 */
export function useProcStats(intervalMs = 1000): ProcStats {
  const [stats, setStats] = useState<ProcStats>({
    rssMb: null,
    cpuPct: null,
    err: null,
  });
  const prev = useRef<{ ticks: number; at: number } | null>(null);

  useEffect(() => {
    let cancelled = false;

    const sample = async () => {
      try {
        const statm = await FileSystem.readAsStringAsync(
          'file:///proc/self/statm'
        );
        // field 2 of statm is resident pages
        const pages = Number(statm.trim().split(/\s+/)[1]);
        const rssMb = (pages * PAGE_BYTES) / (1024 * 1024);

        const stat = await FileSystem.readAsStringAsync(
          'file:///proc/self/stat'
        );
        // comm (field 2) can contain spaces and parens, so index from the LAST
        // ')' rather than splitting the whole line.
        const rest = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/);
        // rest[0] is field 3 (state), so utime (14) and stime (15) are 11 and 12
        const ticks = Number(rest[11]) + Number(rest[12]);

        const at = Date.now();
        let cpuPct: number | null = null;
        if (prev.current) {
          const dt = (at - prev.current.at) / 1000;
          if (dt > 0) {
            cpuPct = ((ticks - prev.current.ticks) / CLK_TCK / dt) * 100;
          }
        }
        prev.current = { ticks, at };

        if (!cancelled) setStats({ rssMb, cpuPct, err: null });
      } catch (e: unknown) {
        if (!cancelled) {
          setStats({
            rssMb: null,
            cpuPct: null,
            err: e instanceof Error ? e.message : String(e),
          });
        }
      }
    };

    sample();
    const id = setInterval(sample, intervalMs);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [intervalMs]);

  return stats;
}
