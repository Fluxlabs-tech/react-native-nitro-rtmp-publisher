import { StyleSheet } from 'react-native';

export const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#000' },
  preview: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
  pinchLayer: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: 'transparent',
  },
  secondScreen: { flex: 1, backgroundColor: '#101114' },
});
