import { PermissionsAndroid, Platform } from 'react-native'

/**
 * Result of {@link requestRtmpPermissions}. `granted` is `true` only when both
 * camera AND microphone access are available. `notifications` is reported
 * separately — it isn't required for the capture pipeline itself, but on
 * Android 13+ the foreground-service notification (set via
 * `foregroundServiceTitle`) silently won't appear if denied, and some OEMs
 * (Pixel, OnePlus, Xiaomi) then kill the service mid-stream.
 */
export type RtmpPermissionResult = {
  granted: boolean
  /** Per-permission breakdown. `'granted'` / `'denied'` / `'unknown'`. */
  camera: 'granted' | 'denied' | 'unknown'
  microphone: 'granted' | 'denied' | 'unknown'
  /** Android 13+ only. `'unknown'` on iOS and on Android ≤ 12 (no runtime grant). */
  notifications: 'granted' | 'denied' | 'unknown'
}

/**
 * Request the camera + microphone permissions the publisher needs, plus
 * `POST_NOTIFICATIONS` on Android 13+ so the FG-service notification can
 * actually appear when streaming is started with a non-empty
 * `foregroundServiceTitle`. Platform-agnostic so JS callers can use a single
 * code path.
 *
 * - **Android**: shows the standard runtime permission dialogs via
 *   `PermissionsAndroid.requestMultiple`. Returns the user's choices.
 *   `POST_NOTIFICATIONS` is only requested on API 33+; on older Android it's
 *   implicitly granted and reported as `'unknown'`.
 * - **iOS**: returns `granted: true` immediately without prompting — iOS shows
 *   the system permission dialog automatically the first time the publisher
 *   actually accesses `AVCaptureDevice`. The capture pipeline stays idle until
 *   the user accepts, so it's safe to mount the publisher view first.
 *
 * Call this once on app launch (before mounting `<RtmpPublisherView>` on
 * Android) so audio capture is fully wired by the time `prepareAudio` runs
 * and so the FG notification is visible the moment `startStream` posts it.
 *
 * @example
 * ```tsx
 * useEffect(() => {
 *   requestRtmpPermissions().then(({ granted, notifications }) => {
 *     if (!granted) Alert.alert('Camera + microphone permissions required')
 *     if (notifications === 'denied') {
 *       // Optional: warn the user that the live-stream notification
 *       // won't appear and OEM may suspend the background stream.
 *     }
 *     setPermissionsReady(granted)
 *   })
 * }, [])
 * ```
 */
export async function requestRtmpPermissions(): Promise<RtmpPermissionResult> {
  if (Platform.OS === 'android') {
    // POST_NOTIFICATIONS was added in API 33 (Android 13). Including it in
    // requestMultiple on older versions throws "Unable to determine if the
    // permission is granted". Gate by Platform.Version.
    const apiLevel =
      typeof Platform.Version === 'number'
        ? Platform.Version
        : parseInt(String(Platform.Version), 10)
    const requestedNotifications = apiLevel >= 33
    const perms: string[] = [
      PermissionsAndroid.PERMISSIONS.CAMERA,
      PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
    ]
    if (requestedNotifications) {
      // The constant key was added to PermissionsAndroid.PERMISSIONS in
      // React Native 0.71+. Guard the access so older RN versions still
      // build (the string literal is the stable Android permission name).
      const postNotif =
        (PermissionsAndroid.PERMISSIONS as Record<string, string>)
          .POST_NOTIFICATIONS ?? 'android.permission.POST_NOTIFICATIONS'
      perms.push(postNotif)
    }
    const res = await PermissionsAndroid.requestMultiple(perms as never)
    const toState = (v: string | undefined) =>
      v === PermissionsAndroid.RESULTS.GRANTED ? 'granted' : 'denied'
    const camera = toState(res[PermissionsAndroid.PERMISSIONS.CAMERA])
    const microphone = toState(res[PermissionsAndroid.PERMISSIONS.RECORD_AUDIO])
    const notifications: 'granted' | 'denied' | 'unknown' = requestedNotifications
      ? toState(res['android.permission.POST_NOTIFICATIONS' as never])
      : 'unknown'
    return {
      granted: camera === 'granted' && microphone === 'granted',
      camera: camera as 'granted' | 'denied',
      microphone: microphone as 'granted' | 'denied',
      notifications,
    }
  }
  // iOS, web, anything else: the native side handles prompts itself.
  return {
    granted: true,
    camera: 'unknown',
    microphone: 'unknown',
    notifications: 'unknown',
  }
}
