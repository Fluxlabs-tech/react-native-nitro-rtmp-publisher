import { useEffect, useState } from 'react';
import { Alert } from 'react-native';
import { requestRtmpPermissions } from 'react-native-nitro-rtmp-publisher';

/**
 * Requests the camera + microphone permissions the publisher needs.
 *
 * - Android: shows the runtime permission dialog
 * - iOS: resolves immediately (native side prompts on AVCaptureDevice access)
 *
 * Returns `permissionsReady` — only `true` once the user has accepted on
 * Android. The publisher view should not mount until this is true.
 */
export function usePermissions(onLog: (line: string) => void) {
  const [permissionsReady, setPermissionsReady] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { granted } = await requestRtmpPermissions();
      if (cancelled) return;
      if (!granted) {
        Alert.alert(
          'Permissions denied',
          'CAMERA and RECORD_AUDIO are required'
        );
        return;
      }
      onLog('permissions granted');
      setPermissionsReady(true);
    })();
    return () => {
      cancelled = true;
    };
  }, [onLog]);

  return permissionsReady;
}
