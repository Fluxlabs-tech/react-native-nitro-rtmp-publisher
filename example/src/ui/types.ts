import type { ThermalStatus } from 'react-native-nitro-rtmp-publisher';
import type { LogEntry } from '../hooks/useEventLog';

/**
 * Props shared by the native overlays — `StreamOverlay.ios.tsx` (SwiftUI +
 * Liquid Glass) and `StreamOverlay.android.tsx` (Jetpack Compose / Material 3).
 * State flows in, user intents flow out; the publisher itself stays in App.tsx.
 */
export type StreamOverlayProps = {
  url: string;
  streaming: boolean;
  /** An initial connect or a native auto-reconnect is in flight. */
  connecting: boolean;
  previewing: boolean;
  thermal: ThermalStatus;
  /** Resolved device capture rate; `null` while the probe is in flight. */
  sampleRate: number | null;
  noiseSuppression: boolean;
  beauty: boolean;
  logs: LogEntry[];
  onChangeUrl: (url: string) => void;
  onStart: () => void;
  onStop: () => void;
  onSwitchCamera: () => void;
  onToggleNoiseSuppression: () => void;
  onToggleBeauty: () => void;
  /** Android system Picture-in-Picture (the library no-ops it on iOS). */
  onEnterPip: () => void;
  /** iOS-only debug hook — the Android implementation is a no-op. */
  onInjectDesync: () => void;
  onOpenSecondScreen: () => void;
  onClearLogs: () => void;
};

export type SecondScreenProps = {
  onBack: () => void;
};
