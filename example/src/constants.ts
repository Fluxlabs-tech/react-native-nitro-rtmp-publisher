import type { ThermalStatus } from 'react-native-nitro-rtmp-publisher';

// ────────────────────────────────────────────────────────────────────────────
// Encoder defaults — same value on iOS + Android.
// `width` / `height` describe the natural landscape sensor output; the library
// swaps internally to portrait when the rotation arg is 0/180.
// ────────────────────────────────────────────────────────────────────────────

export const VIDEO_WIDTH = 1280;
export const VIDEO_HEIGHT = 720;
export const VIDEO_FPS = 30;
export const VIDEO_BITRATE = 2_500_000;
export const VIDEO_IFRAME_INTERVAL = 2;

export const AUDIO_BITRATE = 128_000;
export const AUDIO_SAMPLE_RATE = 44_100;
export const AUDIO_STEREO = true;

// ────────────────────────────────────────────────────────────────────────────
// UI palette
// ────────────────────────────────────────────────────────────────────────────

export const THERMAL_COLOR: Record<ThermalStatus, string> = {
  none: '#22c55e',
  light: '#84cc16',
  moderate: '#eab308',
  severe: '#f97316',
  critical: '#ef4444',
  emergency: '#dc2626',
  shutdown: '#7f1d1d',
};

export const DEFAULT_RTMP_URL = 'rtmp://10.0.2.2:1935/live/test';

// ────────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────────

export const errMsg = (e: unknown): string =>
  e instanceof Error ? e.message : String(e);
