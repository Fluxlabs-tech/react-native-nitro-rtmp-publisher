import { AMBER, RED } from './palette';

/**
 * What the status pill shows. `connecting` covers the first handshake after
 * Start; `reconnecting` is a native auto-reconnect while already live.
 */
export type StreamPhase = 'live' | 'reconnecting' | 'connecting' | 'preview' | 'idle';

export function streamPhase({
  streaming,
  connecting,
  previewing,
}: {
  streaming: boolean;
  connecting: boolean;
  previewing: boolean;
}): StreamPhase {
  if (streaming) return connecting ? 'reconnecting' : 'live';
  if (connecting) return 'connecting';
  return previewing ? 'preview' : 'idle';
}

export const PHASE_LABEL: Record<StreamPhase, string> = {
  live: 'LIVE',
  reconnecting: 'RECONNECTING',
  connecting: 'CONNECTING',
  preview: 'PREVIEW',
  idle: 'IDLE',
};

/** Accent per phase: red while on air, amber while (re)connecting. */
export const PHASE_ACCENT: Record<StreamPhase, string | undefined> = {
  live: RED,
  reconnecting: AMBER,
  connecting: AMBER,
  preview: undefined,
  idle: undefined,
};

/** 48000 → "48 kHz", 44100 → "44.1 kHz". */
export function formatSampleRate(rate: number): string {
  return `${(rate / 1000).toFixed(1).replace(/\.0$/, '')} kHz`;
}

export function formatCount(count: number): string {
  return count > 99 ? '99+' : String(count);
}
