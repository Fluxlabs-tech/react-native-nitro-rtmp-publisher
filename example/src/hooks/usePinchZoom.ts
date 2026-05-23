import { useMemo, useRef, type RefObject } from 'react';
import { PanResponder } from 'react-native';
import type { RtmpPublisherViewMethods } from 'react-native-nitro-rtmp-publisher';

type PinchState = {
  startDistance: number;
  startZoom: number;
  min: number;
  max: number;
};

/**
 * Two-finger pinch gesture → `setZoom(...)` calls. Uses RN's built-in
 * PanResponder so we don't pull in `react-native-gesture-handler`.
 *
 * Pass the returned `panHandlers` onto a transparent overlay View that sits
 * above the preview. Single-finger touches are ignored.
 */
export function usePinchZoom(
  publisherRef: RefObject<RtmpPublisherViewMethods | null>,
  onSettle?: (info: { zoom: number; min: number; max: number }) => void
) {
  const stateRef = useRef<PinchState | null>(null);

  const responder = useMemo(
    () =>
      PanResponder.create({
        onStartShouldSetPanResponder: (e) => e.nativeEvent.touches.length >= 2,
        onMoveShouldSetPanResponder: (e) => e.nativeEvent.touches.length >= 2,
        onPanResponderGrant: (e) => {
          const ref = publisherRef.current;
          const touches = e.nativeEvent.touches;
          if (!ref || touches.length < 2) return;
          stateRef.current = {
            startDistance: distanceBetween(touches[0]!, touches[1]!),
            startZoom: ref.getZoom(),
            min: ref.getMinZoom(),
            max: ref.getMaxZoom(),
          };
        },
        onPanResponderMove: (e) => {
          const ref = publisherRef.current;
          const state = stateRef.current;
          const touches = e.nativeEvent.touches;
          if (!ref || !state || touches.length < 2) return;
          const distance = distanceBetween(touches[0]!, touches[1]!);
          if (state.startDistance < 1) return;
          const next = clamp(
            state.startZoom * (distance / state.startDistance),
            state.min,
            state.max
          );
          try {
            ref.setZoom(next);
          } catch {
            // setZoom may throw briefly during device-switch races. Safe to drop.
          }
        },
        onPanResponderRelease: () => {
          const ref = publisherRef.current;
          const state = stateRef.current;
          if (ref && state && onSettle) {
            onSettle({ zoom: ref.getZoom(), min: state.min, max: state.max });
          }
          stateRef.current = null;
        },
        onPanResponderTerminate: () => {
          stateRef.current = null;
        },
      }),
    [publisherRef, onSettle]
  );

  return responder.panHandlers;
}

type Touch = { pageX: number; pageY: number };

function distanceBetween(a: Touch, b: Touch): number {
  return Math.hypot(a.pageX - b.pageX, a.pageY - b.pageY);
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}
