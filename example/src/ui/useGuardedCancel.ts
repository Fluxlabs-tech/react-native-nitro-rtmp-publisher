import { useCallback, useEffect, useRef } from 'react';

/** Longer than a double-tap, shorter than a deliberate second tap. */
const GUARD_MS = 800;

/**
 * While a connect is in flight the primary button turns into Cancel, right
 * under the finger that just pressed "Go live". Ignore taps for a moment after
 * the switch, so a double-tap on "Go live" can't abort the connect it started.
 */
export function useGuardedCancel(connecting: boolean, onStop: () => void) {
  const since = useRef(0);
  useEffect(() => {
    if (connecting) since.current = Date.now();
  }, [connecting]);
  return useCallback(() => {
    if (Date.now() - since.current >= GUARD_MS) onStop();
  }, [onStop]);
}
