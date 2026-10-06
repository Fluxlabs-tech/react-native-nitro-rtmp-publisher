import {
  BottomSheet,
  Button,
  GlassEffectContainer,
  Group,
  HStack,
  Host,
  Image,
  LazyVStack,
  Menu,
  ProgressView,
  ScrollView,
  Spacer,
  Text,
  TextField,
  VStack,
  useNativeState,
  type ImageProps,
} from '@expo/ui/swift-ui';
import {
  autocorrectionDisabled,
  background,
  controlSize,
  disabled,
  fixedSize,
  font,
  foregroundStyle,
  frame,
  keyboardType,
  labelStyle,
  lineLimit,
  monospacedDigit,
  padding,
  preferredColorScheme,
  presentationDetents,
  presentationDragIndicator,
  shapes,
  textInputAutocapitalization,
  tint,
  truncationMode,
} from '@expo/ui/swift-ui/modifiers';
import { useRef, useState } from 'react';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { THERMAL_COLOR } from '../constants';
import type { LogEntry } from '../hooks/useEventLog';
import { circleBorder, glassButton, glassCapsule, glassCircle } from './glass';
import { AMBER, BLUE, RED } from './palette';
import {
  formatCount,
  formatSampleRate,
  PHASE_ACCENT,
  PHASE_LABEL,
  streamPhase,
  type StreamPhase,
} from './status';
import type { StreamOverlayProps } from './types';
import { useGuardedCancel } from './useGuardedCancel';

type SymbolName = NonNullable<ImageProps['systemName']>;

const PHASE_SYMBOL: Record<StreamPhase, SymbolName> = {
  live: 'dot.radiowaves.left.and.right',
  reconnecting: 'arrow.triangle.2.circlepath',
  connecting: 'antenna.radiowaves.left.and.right',
  preview: 'video',
  idle: 'video.slash',
};

const SECONDARY = { type: 'hierarchical', style: 'secondary' } as const;
const PLACEHOLDER_URL = 'rtmp://host:1935/app/stream';

// Sheets don't inherit the host's dark scheme on every iOS version (iOS 16
// presents them light), so force it — the white glass-fallback labels rely on it.
const SHEET = [preferredColorScheme('dark'), presentationDragIndicator('visible')];

/**
 * iOS controls: SwiftUI views hosted over the camera preview, in Liquid Glass
 * on iOS 26+ (`glass.ts` covers older iOS). Two `matchContents` hosts — status
 * along the top, controls along the bottom — so the preview between them stays
 * free for the pinch-to-zoom layer.
 */
export function StreamOverlay(props: StreamOverlayProps) {
  const insets = useSafeAreaInsets();
  return (
    <>
      <Host
        matchContents={{ vertical: true }}
        colorScheme="dark"
        style={{ position: 'absolute', top: insets.top + 8, left: 16, right: 16 }}
      >
        <StatusRow {...props} />
      </Host>
      <Host
        matchContents={{ vertical: true }}
        colorScheme="dark"
        // The URL sheet raises the keyboard; this panel should stay put under it.
        ignoreSafeArea="keyboard"
        style={{ position: 'absolute', left: 16, right: 16, bottom: insets.bottom + 8 }}
      >
        <ControlPanel {...props} />
      </Host>
    </>
  );
}

function StatusRow({
  streaming,
  connecting,
  previewing,
  thermal,
  sampleRate,
  onOpenSecondScreen,
  onInjectDesync,
}: StreamOverlayProps) {
  const phase = streamPhase({ streaming, connecting, previewing });
  return (
    <HStack spacing={8}>
      {/* Container spacing < stack spacing, so the pills never melt together. */}
      <GlassEffectContainer spacing={4}>
        <HStack spacing={8}>
          <Pill symbol={PHASE_SYMBOL[phase]} label={PHASE_LABEL[phase]} tint={PHASE_ACCENT[phase]} />
          {/* Icon-only while cool — the label appears once it's worth reading. */}
          <Pill
            symbol="thermometer.medium"
            symbolColor={THERMAL_COLOR[thermal]}
            label={thermal === 'none' ? undefined : thermal.toUpperCase()}
          />
          {sampleRate != null && <Pill symbol="waveform" label={formatSampleRate(sampleRate)} />}
        </HStack>
      </GlassEffectContainer>
      <Spacer />
      <Menu
        label="Debug"
        systemImage="ladybug"
        modifiers={[
          labelStyle('iconOnly'),
          tint('#FFFFFF'),
          frame({ width: 40, height: 40 }),
          ...glassCircle(),
        ]}
      >
        {/* A publisher-free screen, to check the stream survives navigating away. */}
        <Button
          label="Open Screen 2"
          systemImage="rectangle.portrait.and.arrow.right"
          onPress={onOpenSecondScreen}
        />
        {/* With Denoise on, the audio-drift log jumps by ~400 ms, then the
            self-heal loop walks it back to ~0. */}
        <Button
          label="Inject +400 ms A/V desync"
          systemImage="waveform.path.ecg"
          onPress={onInjectDesync}
          modifiers={[disabled(!streaming)]}
        />
      </Menu>
    </HStack>
  );
}

function Pill({
  symbol,
  symbolColor,
  label,
  tint: accent,
}: {
  symbol: SymbolName;
  symbolColor?: string;
  label?: string;
  tint?: string;
}) {
  return (
    <HStack
      spacing={6}
      modifiers={[padding({ horizontal: 12, vertical: 8 }), ...glassCapsule(accent)]}
    >
      <Image systemName={symbol} size={12} color={symbolColor} />
      {label != null && (
        // Never wrap or squeeze a pill on narrow phones (iPhone X/SE: 375 pt).
        <Text
          modifiers={[
            font({ size: 12, weight: 'semibold' }),
            monospacedDigit(),
            lineLimit(1),
            fixedSize(),
          ]}
        >
          {label}
        </Text>
      )}
    </HStack>
  );
}

function ControlPanel({
  url,
  streaming,
  connecting,
  noiseSuppression,
  beauty,
  logs,
  onChangeUrl,
  onStart,
  onStop,
  onSwitchCamera,
  onToggleNoiseSuppression,
  onToggleBeauty,
  onEnterPip,
  onClearLogs,
}: StreamOverlayProps) {
  const [urlOpen, setUrlOpen] = useState(false);
  const [eventsOpen, setEventsOpen] = useState(false);

  return (
    <GlassEffectContainer spacing={6}>
      <VStack spacing={10}>
        {/* The URL is edited in a sheet rather than inline: the keyboard lives
            in the sheet and never touches the preview underneath. */}
        <BottomSheet
          isPresented={urlOpen}
          onIsPresentedChange={setUrlOpen}
          anchor={<UrlButton url={url} onPress={() => setUrlOpen(true)} />}
        >
          <Group modifiers={[...SHEET, presentationDetents([{ height: 260 }])]}>
            <UrlEditor
              url={url}
              onCancel={() => setUrlOpen(false)}
              onSave={(next) => {
                onChangeUrl(next);
                setUrlOpen(false);
              }}
            />
          </Group>
        </BottomSheet>

        <HStack spacing={10}>
          <PrimaryButton
            streaming={streaming}
            connecting={connecting}
            onStart={onStart}
            onStop={onStop}
          />
          <CircleButton
            label="Flip camera"
            symbol="arrow.triangle.2.circlepath.camera"
            onPress={onSwitchCamera}
          />
          <BottomSheet
            isPresented={eventsOpen}
            onIsPresentedChange={setEventsOpen}
            anchor={
              <Button
                onPress={() => setEventsOpen(true)}
                modifiers={[...glassButton(), controlSize('large')]}
              >
                <HStack spacing={6}>
                  <Image systemName="list.bullet.rectangle" size={15} />
                  <Text modifiers={[monospacedDigit()]}>{formatCount(logs.length)}</Text>
                </HStack>
              </Button>
            }
          >
            <Group modifiers={[...SHEET, presentationDetents(['medium', 'large'])]}>
              <EventsList logs={logs} onClear={onClearLogs} />
            </Group>
          </BottomSheet>
        </HStack>

        <HStack spacing={10}>
          {/* `noiseSuppression` prop — applies live, even mid-stream. */}
          <ToggleButton
            label="Denoise"
            symbol="waveform"
            on={noiseSuppression}
            onPress={onToggleNoiseSuppression}
          />
          <ToggleButton label="Beauty" symbol="sparkles" on={beauty} onPress={onToggleBeauty} />
          {/* Live PiP needs an iPhone on iOS 18+ (with the `voip` background
              mode the config plugin's `enablePictureInPicture` adds) or an M1+
              iPad; elsewhere `enterPictureInPicture()` returns false. The
              `pictureInPictureEnabled` prop also arms auto-enter on Home. */}
          <CircleButton
            label="Picture in Picture"
            symbol="pip.enter"
            size="regular"
            onPress={onEnterPip}
          />
        </HStack>
      </VStack>
    </GlassEffectContainer>
  );
}

function UrlButton({ url, onPress }: { url: string; onPress: () => void }) {
  return (
    <Button onPress={onPress} modifiers={[...glassButton(), controlSize('large')]}>
      <HStack spacing={8}>
        <Image systemName="link" size={14} />
        <Text
          modifiers={[
            lineLimit(1),
            truncationMode('middle'),
            font({ size: 14, design: 'monospaced' }),
            ...(url ? [] : [foregroundStyle(SECONDARY)]),
          ]}
        >
          {url || PLACEHOLDER_URL}
        </Text>
        <Spacer />
        <Image systemName="pencil" size={14} />
      </HStack>
    </Button>
  );
}

/**
 * Go live → (connecting) Cancel → (live) End stream, always in the same slot so
 * the row never reflows. Start can't be re-fired mid-handshake: the button is
 * Cancel by then, and `useGuardedCancel` swallows the second tap of a
 * double-tap.
 */
function PrimaryButton({
  streaming,
  connecting,
  onStart,
  onStop,
}: {
  streaming: boolean;
  connecting: boolean;
  onStart: () => void;
  onStop: () => void;
}) {
  const onCancel = useGuardedCancel(connecting, onStop);
  if (streaming) {
    return (
      <Button onPress={onStop} modifiers={[...glassButton(true), tint(RED), controlSize('large')]}>
        <PrimaryLabel symbol="stop.fill" label="End stream" />
      </Button>
    );
  }
  if (connecting) {
    return (
      <Button onPress={onCancel} modifiers={[...glassButton(true), tint(AMBER), controlSize('large')]}>
        <HStack spacing={8}>
          <Spacer />
          <ProgressView modifiers={[controlSize('small'), tint('#FFFFFF')]} />
          <Text modifiers={[font({ weight: 'semibold' }), lineLimit(1)]}>Cancel</Text>
          <Spacer />
        </HStack>
      </Button>
    );
  }
  return (
    <Button onPress={onStart} modifiers={[...glassButton(true), tint(BLUE), controlSize('large')]}>
      <PrimaryLabel symbol="dot.radiowaves.left.and.right" label="Go live" />
    </Button>
  );
}

function PrimaryLabel({ symbol, label }: { symbol: SymbolName; label: string }) {
  // The Spacers let the button take all the width its row leaves over.
  return (
    <HStack spacing={8}>
      <Spacer />
      <Image systemName={symbol} size={15} />
      <Text modifiers={[font({ weight: 'semibold' }), lineLimit(1)]}>{label}</Text>
      <Spacer />
    </HStack>
  );
}

function CircleButton({
  label,
  symbol,
  size = 'large',
  onPress,
}: {
  label: string;
  symbol: SymbolName;
  size?: 'regular' | 'large';
  onPress: () => void;
}) {
  return (
    <Button
      label={label}
      systemImage={symbol}
      onPress={onPress}
      modifiers={[labelStyle('iconOnly'), ...glassButton(), circleBorder(), controlSize(size)]}
    />
  );
}

function ToggleButton({
  label,
  symbol,
  on,
  onPress,
}: {
  label: string;
  symbol: SymbolName;
  on: boolean;
  onPress: () => void;
}) {
  return (
    <Button
      onPress={onPress}
      modifiers={[...glassButton(on), ...(on ? [tint(BLUE)] : []), controlSize('regular')]}
    >
      <HStack spacing={6}>
        <Spacer />
        <Image systemName={symbol} size={14} />
        <Text>{label}</Text>
        <Image systemName={on ? 'checkmark.circle.fill' : 'circle'} size={13} />
        <Spacer />
      </HStack>
    </Button>
  );
}

function UrlEditor({
  url,
  onCancel,
  onSave,
}: {
  url: string;
  onCancel: () => void;
  onSave: (url: string) => void;
}) {
  // Sheet content mounts on every presentation, so each edit starts from the
  // URL currently in use.
  const text = useNativeState(url);
  const draft = useRef(url);
  return (
    <VStack
      alignment="leading"
      spacing={16}
      modifiers={[padding({ top: 28, leading: 20, trailing: 20, bottom: 20 })]}
    >
      <Text modifiers={[font({ textStyle: 'headline' })]}>RTMP URL</Text>
      <TextField
        text={text}
        autoFocus
        axis="vertical"
        placeholder={PLACEHOLDER_URL}
        onTextChange={(value) => {
          draft.current = value;
        }}
        modifiers={[
          lineLimit(4),
          keyboardType('url'),
          textInputAutocapitalization('never'),
          autocorrectionDisabled(),
          font({ size: 15, design: 'monospaced' }),
          padding({ all: 12 }),
          background(
            { type: 'hierarchical', style: 'quaternary' },
            shapes.roundedRectangle({ cornerRadius: 12 })
          ),
        ]}
      />
      <HStack spacing={12}>
        <Button label="Cancel" onPress={onCancel} modifiers={[...glassButton(), controlSize('large')]} />
        <Spacer />
        <Button
          label="Save"
          systemImage="checkmark"
          onPress={() => onSave(draft.current.trim())}
          modifiers={[...glassButton(true), tint(BLUE), controlSize('large')]}
        />
      </HStack>
    </VStack>
  );
}

function EventsList({ logs, onClear }: { logs: LogEntry[]; onClear: () => void }) {
  return (
    <VStack
      alignment="leading"
      spacing={12}
      modifiers={[padding({ top: 28, leading: 20, trailing: 20 })]}
    >
      <HStack spacing={8}>
        <Text modifiers={[font({ textStyle: 'headline' })]}>Events</Text>
        <Text
          modifiers={[font({ textStyle: 'subheadline' }), foregroundStyle(SECONDARY), monospacedDigit()]}
        >
          {String(logs.length)}
        </Text>
        <Spacer />
        <Button
          label="Clear"
          systemImage="trash"
          onPress={onClear}
          modifiers={[...glassButton(), controlSize('small'), disabled(logs.length === 0)]}
        />
      </HStack>
      <ScrollView>
        <LazyVStack alignment="leading" spacing={6}>
          {logs.length === 0 ? (
            <Text modifiers={[font({ size: 12, design: 'monospaced' }), foregroundStyle(SECONDARY)]}>
              No events yet
            </Text>
          ) : (
            logs.map((l) => (
              <Text key={l.id} modifiers={[font({ size: 11, design: 'monospaced' })]}>
                {`[${l.ts}] ${l.line}`}
              </Text>
            ))
          )}
        </LazyVStack>
      </ScrollView>
    </VStack>
  );
}
