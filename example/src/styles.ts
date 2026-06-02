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
    backgroundColor: 'rgba(0,0,0,0.45)',
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
    flexDirection: 'row',
  },
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
});
