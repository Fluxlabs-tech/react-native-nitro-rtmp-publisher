import { PermissionsAndroid, Platform } from 'react-native'

/**
 * Result of {@link requestRtmpPermissions}. `granted` is `true` only when both
 * camera AND microphone access are available.
 */
export type RtmpPermissionResult = {
  granted: boolean
  /** Per-permission breakdown. `'granted'` / `'denied'` / `'unknown'`. */
  camera: 'granted' | 'denied' | 'unknown'
  microphone: 'granted' | 'denied' | 'unknown'
}

/**
 * Request the camera + microphone permissions the publisher needs, in a
 * platform-agnostic way so that the JS caller can use a single code path.
 *
 * - **Android**: shows the standard runtime permission dialog via
 *   `PermissionsAndroid.requestMultiple`. Returns the user's choices.
 * - **iOS**: returns `granted: true` immediately without prompting — iOS shows
 *   the system permission dialog automatically the first time the publisher
 *   actually accesses `AVCaptureDevice`. The capture pipeline stays idle until
 *   the user accepts, so it's safe to mount the publisher view first.
 *
 * Call this once on app launch (before mounting `<RtmpPublisherView>` on
 * Android) so audio capture is fully wired by the time `prepareAudio` runs.
 *
 * @example
 * ```tsx
 * useEffect(() => {
 *   requestRtmpPermissions().then(({ granted }) => {
 *     if (!granted) Alert.alert('Camera + microphone permissions required')
 *     setPermissionsReady(granted)
 *   })
 * }, [])
 * ```
 */
export async function requestRtmpPermissions(): Promise<RtmpPermissionResult> {
  if (Platform.OS === 'android') {
    const res = await PermissionsAndroid.requestMultiple([
      PermissionsAndroid.PERMISSIONS.CAMERA,
      PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
    ])
    const toState = (v: string) =>
      v === PermissionsAndroid.RESULTS.GRANTED ? 'granted' : 'denied'
    const camera = toState(res[PermissionsAndroid.PERMISSIONS.CAMERA])
    const microphone = toState(res[PermissionsAndroid.PERMISSIONS.RECORD_AUDIO])
    return {
      granted: camera === 'granted' && microphone === 'granted',
      camera: camera as 'granted' | 'denied',
      microphone: microphone as 'granted' | 'denied',
    }
  }
  // iOS, web, anything else: the native side handles prompts itself.
  return { granted: true, camera: 'unknown', microphone: 'unknown' }
}
