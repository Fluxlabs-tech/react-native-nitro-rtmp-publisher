import {
  AssistChip,
  Button,
  CircularProgressIndicator,
  Column,
  DropdownMenu,
  DropdownMenuItem,
  FilledTonalButton,
  FilledTonalIconButton,
  FilterChip,
  Host,
  Icon,
  LazyColumn,
  ModalBottomSheet,
  OutlinedTextField,
  Row,
  Shape,
  Spacer,
  Surface,
  Text,
  TextButton,
  useNativeState,
  type ModalBottomSheetRef,
} from '@expo/ui/jetpack-compose';
import {
  fillMaxWidth,
  height,
  padding,
  paddingAll,
  size,
  weight,
} from '@expo/ui/jetpack-compose/modifiers';
import { useRef, useState, type RefObject } from 'react';
import type { ImageSourcePropType } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { THERMAL_COLOR } from '../constants';
import type { LogEntry } from '../hooks/useEventLog';
import { icons } from './icons';
import { AMBER, FIELD, MUTED, PANEL, RED, SCRIM, SEED_COLOR } from './palette';
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

const PHASE_ICON: Record<StreamPhase, ImageSourcePropType> = {
  live: icons.sensors,
  reconnecting: icons.sync,
  connecting: icons.sync,
  preview: icons.videocam,
  idle: icons.videocamOff,
};

const PLACEHOLDER_URL = 'rtmp://host:1935/app/stream';
const MONO = { fontFamily: 'monospace', fontSize: 12 } as const;

// Shape helpers are element factories (no hooks), called directly like in Expo's own examples.
function rounded(radius: number) {
  return Shape.RoundedCorner({
    cornerRadii: { topStart: radius, topEnd: radius, bottomStart: radius, bottomEnd: radius },
  });
}

/** Animate a sheet out before unmounting it. */
async function hideSheet(ref: RefObject<ModalBottomSheetRef | null>, done: () => void) {
  try {
    await ref.current?.hide();
  } finally {
    done();
  }
}

/**
 * Android controls: Jetpack Compose (Material 3) hosted over the camera
 * preview. Two `matchContents` hosts — status along the top, controls along
 * the bottom — so the preview between them stays free for pinch-to-zoom.
 */
export function StreamOverlay(props: StreamOverlayProps) {
  const insets = useSafeAreaInsets();
  return (
    <>
      <Host
        matchContents={{ vertical: true }}
        colorScheme="dark"
        seedColor={SEED_COLOR}
        style={{ position: 'absolute', top: insets.top + 8, left: 12, right: 12 }}
      >
        <StatusRow {...props} />
      </Host>
      <Host
        matchContents={{ vertical: true }}
        colorScheme="dark"
        seedColor={SEED_COLOR}
        style={{ position: 'absolute', left: 12, right: 12, bottom: insets.bottom + 12 }}
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
}: StreamOverlayProps) {
  const phase = streamPhase({ streaming, connecting, previewing });
  const [menuOpen, setMenuOpen] = useState(false);
  return (
    <Row modifiers={[fillMaxWidth()]} horizontalArrangement="spaceBetween" verticalAlignment="center">
      <Row horizontalArrangement={{ spacedBy: 8 }} verticalAlignment="center">
        <Pill icon={PHASE_ICON[phase]} label={PHASE_LABEL[phase]} color={PHASE_ACCENT[phase]} />
        {/* Icon-only while cool — the label appears once it's worth reading. */}
        <Pill
          icon={icons.thermostat}
          iconTint={THERMAL_COLOR[thermal]}
          label={thermal === 'none' ? undefined : thermal.toUpperCase()}
        />
        {sampleRate != null && <Pill icon={icons.graphicEq} label={formatSampleRate(sampleRate)} />}
      </Row>
      <DropdownMenu expanded={menuOpen} onDismissRequest={() => setMenuOpen(false)}>
        <DropdownMenu.Trigger>
          <FilledTonalIconButton onClick={() => setMenuOpen(true)}>
            <Icon source={icons.bugReport} size={20} contentDescription="Debug" />
          </FilledTonalIconButton>
        </DropdownMenu.Trigger>
        <DropdownMenu.Items>
          {/* Publisher-free screen: pressing Home there must NOT enter PiP. */}
          <DropdownMenuItem
            onClick={() => {
              setMenuOpen(false);
              onOpenSecondScreen();
            }}
          >
            <DropdownMenuItem.LeadingIcon>
              <Icon source={icons.arrowForward} size={20} />
            </DropdownMenuItem.LeadingIcon>
            <DropdownMenuItem.Text>
              <Text>Open Screen 2 (PiP scope test)</Text>
            </DropdownMenuItem.Text>
          </DropdownMenuItem>
        </DropdownMenu.Items>
      </DropdownMenu>
    </Row>
  );
}

function Pill({
  icon,
  iconTint,
  label,
  color = SCRIM,
}: {
  icon: ImageSourcePropType;
  iconTint?: string;
  label?: string;
  color?: string;
}) {
  return (
    <Surface shape={Shape.Pill({})} color={color} contentColor="#FFFFFF">
      <Row
        horizontalArrangement={{ spacedBy: 6 }}
        verticalAlignment="center"
        modifiers={[label != null ? padding(10, 6, 12, 6) : paddingAll(6)]}
      >
        <Icon source={icon} size={16} tint={iconTint} />
        {label != null && (
          // Never wrap a pill on narrow phones.
          <Text
            maxLines={1}
            softWrap={false}
            style={{ typography: 'labelMedium', fontWeight: '600', letterSpacing: 0.5 }}
          >
            {label}
          </Text>
        )}
      </Row>
    </Surface>
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
  const urlSheet = useRef<ModalBottomSheetRef>(null);

  return (
    <>
      <Surface shape={rounded(28)} color={PANEL} contentColor="#FFFFFF" modifiers={[fillMaxWidth()]}>
        <Column verticalArrangement={{ spacedBy: 12 }} modifiers={[paddingAll(14)]}>
          {/* The URL is edited in a bottom sheet, which has its own window, so
              the keyboard can never resize the preview / PiP layout. */}
          <Surface
            onClick={() => setUrlOpen(true)}
            shape={rounded(16)}
            color={FIELD}
            modifiers={[fillMaxWidth()]}
          >
            <Row
              horizontalArrangement={{ spacedBy: 10 }}
              verticalAlignment="center"
              modifiers={[paddingAll(12)]}
            >
              <Icon source={icons.link} size={18} tint={MUTED} />
              <Text
                maxLines={1}
                overflow="ellipsis"
                color={url ? undefined : MUTED}
                style={MONO}
                modifiers={[weight(1)]}
              >
                {url || PLACEHOLDER_URL}
              </Text>
              <Icon source={icons.edit} size={18} tint={MUTED} />
            </Row>
          </Surface>

          <Row
            horizontalArrangement={{ spacedBy: 8 }}
            verticalAlignment="center"
            modifiers={[fillMaxWidth()]}
          >
            <PrimaryButton
              streaming={streaming}
              connecting={connecting}
              onStart={onStart}
              onStop={onStop}
            />
            <FilledTonalIconButton onClick={onSwitchCamera}>
              <Icon source={icons.cameraSwitch} contentDescription="Flip camera" />
            </FilledTonalIconButton>
            {/* Count inside the button (as on iOS). A BadgedBox badge added after
                mount stays a bare dot — `Badge` only checks for content once. */}
            <FilledTonalButton
              onClick={() => setEventsOpen(true)}
              contentPadding={{ start: 12, end: 14 }}
              modifiers={[height(48)]}
            >
              <Icon source={icons.receiptLong} size={18} contentDescription="Events" />
              <Spacer modifiers={[size(6, 0)]} />
              <Text>{formatCount(logs.length)}</Text>
            </FilledTonalButton>
          </Row>

          <Row horizontalArrangement={{ spacedBy: 8 }} verticalAlignment="center">
            {/* `noiseSuppression` prop — applies live, even mid-stream. */}
            <FilterChip selected={noiseSuppression} onClick={onToggleNoiseSuppression}>
              <FilterChip.LeadingIcon>
                <Icon source={icons.noiseAware} size={18} />
              </FilterChip.LeadingIcon>
              <FilterChip.Label>
                <Text>Denoise</Text>
              </FilterChip.Label>
            </FilterChip>
            <FilterChip selected={beauty} onClick={onToggleBeauty}>
              <FilterChip.LeadingIcon>
                <Icon source={icons.faceRetouching} size={18} />
              </FilterChip.LeadingIcon>
              <FilterChip.Label>
                <Text>Beauty</Text>
              </FilterChip.Label>
            </FilterChip>
            {/* Manual entry (and the only path on Android 8–11); API 31+ also
                auto-enters on Home via the `pictureInPictureEnabled` prop. */}
            <AssistChip onClick={onEnterPip}>
              <AssistChip.LeadingIcon>
                <Icon source={icons.pictureInPicture} size={18} />
              </AssistChip.LeadingIcon>
              <AssistChip.Label>
                <Text>PiP</Text>
              </AssistChip.Label>
            </AssistChip>
          </Row>
        </Column>
      </Surface>

      {urlOpen && (
        <ModalBottomSheet
          ref={urlSheet}
          skipPartiallyExpanded
          onDismissRequest={() => setUrlOpen(false)}
        >
          <UrlEditor
            url={url}
            onCancel={() => hideSheet(urlSheet, () => setUrlOpen(false))}
            onSave={(next) => {
              onChangeUrl(next);
              hideSheet(urlSheet, () => setUrlOpen(false));
            }}
          />
        </ModalBottomSheet>
      )}
      {eventsOpen && (
        <ModalBottomSheet onDismissRequest={() => setEventsOpen(false)}>
          <EventsList logs={logs} onClear={onClearLogs} />
        </ModalBottomSheet>
      )}
    </>
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
      <Button
        onClick={onStop}
        colors={{ containerColor: RED, contentColor: '#FFFFFF' }}
        modifiers={[weight(1), height(48)]}
      >
        <Icon source={icons.stop} size={18} />
        <Spacer modifiers={[size(8, 0)]} />
        <Text>End stream</Text>
      </Button>
    );
  }
  if (connecting) {
    return (
      <Button
        onClick={onCancel}
        colors={{ containerColor: AMBER, contentColor: '#000000' }}
        modifiers={[weight(1), height(48)]}
      >
        <CircularProgressIndicator color="#000000" strokeWidth={2} modifiers={[size(16, 16)]} />
        <Spacer modifiers={[size(10, 0)]} />
        <Text maxLines={1}>Cancel</Text>
      </Button>
    );
  }
  return (
    <Button onClick={onStart} modifiers={[weight(1), height(48)]}>
      <Icon source={icons.sensors} size={18} />
      <Spacer modifiers={[size(8, 0)]} />
      <Text>Go live</Text>
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
  // Sheet content mounts on every open, so each edit starts from the URL
  // currently in use.
  const value = useNativeState(url);
  const draft = useRef(url);
  return (
    <Column verticalArrangement={{ spacedBy: 16 }} modifiers={[fillMaxWidth(), padding(24, 0, 24, 24)]}>
      <Text style={{ typography: 'titleLarge' }}>RTMP URL</Text>
      <OutlinedTextField
        value={value}
        autoFocus
        maxLines={4}
        onValueChange={(next) => {
          draft.current = next;
        }}
        keyboardOptions={{
          keyboardType: 'uri',
          imeAction: 'done',
          capitalization: 'none',
          autoCorrectEnabled: false,
        }}
        keyboardActions={{ onDone: (next) => onSave(next.trim()) }}
        textStyle={{ fontFamily: 'monospace', fontSize: 14 }}
        modifiers={[fillMaxWidth()]}
      >
        <OutlinedTextField.Label>
          <Text>Server URL + stream key</Text>
        </OutlinedTextField.Label>
        <OutlinedTextField.Placeholder>
          <Text>{PLACEHOLDER_URL}</Text>
        </OutlinedTextField.Placeholder>
        <OutlinedTextField.LeadingIcon>
          <Icon source={icons.link} size={20} />
        </OutlinedTextField.LeadingIcon>
      </OutlinedTextField>
      <Row horizontalArrangement={{ spacedBy: 8 }} verticalAlignment="center" modifiers={[fillMaxWidth()]}>
        <Spacer modifiers={[weight(1)]} />
        <TextButton onClick={onCancel}>
          <Text>Cancel</Text>
        </TextButton>
        <Button onClick={() => onSave(draft.current.trim())}>
          <Text>Save</Text>
        </Button>
      </Row>
    </Column>
  );
}

function EventsList({ logs, onClear }: { logs: LogEntry[]; onClear: () => void }) {
  return (
    <Column verticalArrangement={{ spacedBy: 8 }} modifiers={[fillMaxWidth(), padding(24, 0, 24, 16)]}>
      <Row verticalAlignment="center" modifiers={[fillMaxWidth()]}>
        <Text style={{ typography: 'titleLarge' }}>Events</Text>
        <Spacer modifiers={[size(8, 0)]} />
        <Text color={MUTED} style={{ typography: 'titleSmall' }}>
          {String(logs.length)}
        </Text>
        <Spacer modifiers={[weight(1)]} />
        <TextButton enabled={logs.length > 0} onClick={onClear}>
          <Icon source={icons.deleteSweep} size={18} />
          <Spacer modifiers={[size(6, 0)]} />
          <Text>Clear</Text>
        </TextButton>
      </Row>
      {logs.length === 0 ? (
        <Text color={MUTED} style={MONO}>
          No events yet
        </Text>
      ) : (
        <LazyColumn verticalArrangement={{ spacedBy: 4 }} modifiers={[fillMaxWidth(), height(440)]}>
          {logs.map((l) => (
            <Text key={l.id} style={MONO}>{`[${l.ts}] ${l.line}`}</Text>
          ))}
        </LazyColumn>
      )}
    </Column>
  );
}
