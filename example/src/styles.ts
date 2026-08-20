import { StyleSheet } from 'react-native';

export const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#000' },
  preview: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
  // Controls float over the bottom of the (full-window) preview instead of
  // sitting below it in a flex column. Showing/hiding them — e.g. on the PIP
  // transition — then never resizes the preview, so there's no jitter.
  controlsOverlay: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    // Opaque enough to read log text over a bright preview. The preview area
    // that matters is above the panel, so darkening behind it costs nothing.
    backgroundColor: 'rgba(0,0,0,0.82)',
  },
  pinchLayer: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: 'transparent',
  },
  previewOverlay: {
    position: 'absolute',
    top: 48,
    left: 16,
    flexDirection: 'row',
  },
  // Top-right corner. Diagnostic chips that aren't tied to stream state —
  // sample rate, mic config, etc. Same vertical band as `previewOverlay`
  // (top: 48) so the two rows align visually.
  previewOverlayRight: {
    position: 'absolute',
    top: 48,
    right: 16,
    alignItems: 'flex-end',
    gap: 10,
  },
  statsOverlay: {
    position: 'absolute',
    top: 92,
    left: 16,
    flexDirection: 'row',
  },
  flipBtn: {
    width: 46,
    height: 46,
    borderRadius: 23,
    backgroundColor: 'rgba(0,0,0,0.55)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  flipIcon: { color: '#fff', fontSize: 22, fontWeight: '700' },
  badge: {
    color: '#fff',
    backgroundColor: '#444',
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 6,
    fontWeight: '700',
    fontSize: 12,
  },
  badgeOn: { backgroundColor: '#dc2626' },
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.55)',
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 999,
    marginLeft: 8,
  },
  chipDot: { width: 8, height: 8, borderRadius: 4, marginRight: 6 },
  chipText: { color: '#fff', fontWeight: '600', fontSize: 11, letterSpacing: 0.5 },
  // `paddingBottom` clears Android gesture/button nav and the iOS home
  // indicator — without this, the secondary controls row (NS / AUD) gets
  // tucked under the system bar on phones with no safe-area-context.
  controls: { paddingTop: 16, paddingHorizontal: 16, paddingBottom: 36 },
  label: { color: '#aaa', marginTop: 8, marginBottom: 4 },
  input: {
    backgroundColor: '#222',
    color: '#fff',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
  },
  row: { flexDirection: 'row', gap: 8, marginTop: 12 },
  btn: {
    flex: 1,
    backgroundColor: '#2563eb',
    borderRadius: 8,
    paddingVertical: 12,
    alignItems: 'center',
  },
  btnStop: { backgroundColor: '#dc2626' },
  btnAlt: { backgroundColor: '#4b5563' },
  btnDisabled: { opacity: 0.4 },
  btnText: { color: '#fff', fontWeight: '600' },
  logLine: { color: '#9ca3af', fontFamily: 'monospace', fontSize: 11 },
  logLineMuted: {
    color: '#6b7280',
    fontFamily: 'monospace',
    fontSize: 11,
    fontStyle: 'italic',
  },
  modalBackdrop: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.55)',
    justifyContent: 'flex-end',
  },
  modalSheet: {
    height: '70%',
    backgroundColor: 'rgba(20,20,20,0.96)',
    borderTopLeftRadius: 16,
    borderTopRightRadius: 16,
    paddingHorizontal: 16,
    paddingTop: 12,
    paddingBottom: 24,
  },
  // Bottom sheet for the URL editor. Its TextInput (and therefore the keyboard)
  // lives in the Modal's own window, so it can never resize the main preview /
  // PIP layout the way an inline input under KeyboardAvoidingView did.
  urlSheet: {
    backgroundColor: 'rgba(20,20,20,0.98)',
    borderTopLeftRadius: 16,
    borderTopRightRadius: 16,
    paddingHorizontal: 16,
    paddingTop: 16,
    paddingBottom: 28,
  },
  modalHeader: { flexDirection: 'row', alignItems: 'center', marginBottom: 8 },
  modalTitle: { flex: 1, color: '#fff', fontSize: 16, fontWeight: '700' },
  modalHeaderBtn: {
    paddingHorizontal: 10,
    paddingVertical: 6,
    marginLeft: 8,
    borderRadius: 6,
    backgroundColor: '#374151',
  },
  modalHeaderBtnText: { color: '#fff', fontSize: 12, fontWeight: '600' },
  modalLogs: {
    flex: 1,
    backgroundColor: '#0f0f0f',
    borderRadius: 8,
    padding: 8,
  },
  // Full-frame mode: the only affordance left on screen.
  hidePill: {
    alignSelf: 'center',
    backgroundColor: 'rgba(0,0,0,0.55)',
    paddingHorizontal: 18,
    paddingVertical: 10,
    borderRadius: 20,
    marginBottom: 12,
  },
  lookTrack: {
    flex: 1,
    height: 34,
    borderRadius: 17,
    backgroundColor: '#3a4150',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  lookFill: {
    position: 'absolute',
    left: 0,
    top: 0,
    bottom: 0,
    backgroundColor: '#2f6bff',
  },
  lookValue: {
    color: '#fff',
    fontWeight: '600',
    textAlign: 'center',
  },
  panel: {
    paddingTop: 6,
    paddingHorizontal: 12,
    // Clears the Android navigation bar; without it the last row is unreachable.
    paddingBottom: 52,
  },
  tabBar: {
    flexDirection: 'row',
    gap: 6,
    marginTop: 10,
  },
  tab: {
    flex: 1,
    paddingVertical: 9,
    borderRadius: 10,
    backgroundColor: '#2b303a',
    alignItems: 'center',
  },
  tabOn: { backgroundColor: '#2f6bff' },
  tabText: { color: '#b9c0cc', fontWeight: '600', fontSize: 13 },
  tabTextOn: { color: '#fff' },
  panelBody: { maxHeight: 300 },
  btnWide: { marginTop: 8 },
  hint: {
    color: '#8f97a3',
    fontSize: 12,
    lineHeight: 17,
    marginTop: 8,
    marginBottom: 4,
  },
  filterChip: {
    paddingHorizontal: 12,
    paddingVertical: 7,
    borderRadius: 999,
    marginRight: 6,
  },
  filterChipOn: { backgroundColor: '#2f6bff' },
  filterChipOff: { backgroundColor: '#3a4150' },
  filterChipText: { color: '#fff', fontSize: 12, fontWeight: '600' },
  tagRow: { marginTop: 6, marginBottom: 2 },
  logMeta: { color: '#7d8492', fontSize: 11, marginTop: 8, marginBottom: 4 },
  logScroll: { maxHeight: 220 },
  logTag: { color: '#79c0ff' },
  logInfo: { color: '#c9d1d9' },
  logWarn: { color: '#e3b341' },
  logError: { color: '#ff7b72' },
  kvRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 5,
    borderBottomWidth: 1,
    borderBottomColor: 'rgba(255,255,255,0.07)',
  },
  kvKey: { color: '#8f97a3', fontSize: 12 },
  kvVal: { color: '#fff', fontSize: 12, fontWeight: '600' },
});
