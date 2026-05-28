import ReactNativeAudioManager from "@arjit123/react-native-audio-manager";
import type { ThermalStatus } from "react-native-nitro-rtmp-publisher";

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
// Static fallback used when the native AudioManager probe fails (Expo
// module unlinked after a hot-reload, native call throws, returns garbage,
// etc.). 48 kHz is the universal native capture rate on Android and iOS;
// only ancient hardware would deviate. At runtime, prefer
// `getDeviceSampleRate()` below — it queries the OS for the real value.
export const AUDIO_SAMPLE_RATE_FALLBACK = 48_000;
export const AUDIO_STEREO = true;

/**
 * Resolve the device's preferred audio sample rate at runtime via
 * `@arjit123/react-native-audio-manager`.
 *
 * - Android: `AudioManager.getProperty(PROPERTY_OUTPUT_SAMPLE_RATE)` — the
 *   OS's native rate. Input and output share the same rate on every
 *   shipped Android device, so this is also the right value for
 *   AudioRecord. Asking for any other rate forces the HAL sample-rate
 *   converter, which on budget UNISOC/MediaTek chips audibly muffles the
 *   5–10 kHz range (consonant clarity).
 * - iOS: `AVAudioSession.sharedInstance().sampleRate` — the active
 *   session rate, always 48 kHz on shipping iPhones.
 *
 * Returns `AUDIO_SAMPLE_RATE_FALLBACK` if the native call throws or
 * returns something obviously bogus (non-finite, ≤ 0, > 192 kHz).
 */
export async function getDeviceSampleRate(): Promise<number> {
  try {
    const rate = await ReactNativeAudioManager.getSampleRate();
    if (!Number.isFinite(rate) || rate <= 0 || rate > 192_000) {
      return AUDIO_SAMPLE_RATE_FALLBACK;
    }
    return Math.round(rate);
  } catch {
    return AUDIO_SAMPLE_RATE_FALLBACK;
  }
}

// ────────────────────────────────────────────────────────────────────────────
// UI palette
// ────────────────────────────────────────────────────────────────────────────

export const THERMAL_COLOR: Record<ThermalStatus, string> = {
  none: "#22c55e",
  light: "#84cc16",
  moderate: "#eab308",
  severe: "#f97316",
  critical: "#ef4444",
  emergency: "#dc2626",
  shutdown: "#7f1d1d",
};

export const DEFAULT_RTMP_URL = "rtmp://10.0.2.2:1935/live/test";

// ────────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────────

export const errMsg = (e: unknown): string =>
  e instanceof Error ? e.message : String(e);
