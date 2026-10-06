import {
  background,
  buttonBorderShape,
  buttonStyle,
  glassEffect,
  shapes,
  tint,
  type ModifierConfig,
} from '@expo/ui/swift-ui/modifiers';
import { Platform } from 'react-native';

const IOS_MAJOR = Platform.OS === 'ios' ? parseInt(String(Platform.Version), 10) : 0;

/**
 * Liquid Glass needs iOS 26. Below that, `@expo/ui` silently drops
 * `glassEffect` and maps the glass button styles to `.automatic`, which would
 * leave bare labels floating over the camera — so every helper here falls back
 * to a blurred material / bordered style on older iOS.
 */
export const LIQUID_GLASS = IOS_MAJOR >= 26;

/** `.circle` button borders need iOS 17; a capsule is the closest shape before that. */
export function circleBorder(): ModifierConfig {
  return buttonBorderShape(IOS_MAJOR >= 17 ? 'circle' : 'capsule');
}

const MATERIAL = { type: 'material', material: 'ultraThin' } as const;

/** Glass capsule behind a non-interactive view (status pills), optionally tinted. */
export function glassCapsule(tint?: string): ModifierConfig[] {
  return LIQUID_GLASS
    ? [glassEffect({ glass: { variant: 'regular', tint }, shape: 'capsule' })]
    : [background(tint ?? MATERIAL, shapes.capsule())];
}

/** Interactive glass circle, for icon-only triggers such as a `Menu`. */
export function glassCircle(): ModifierConfig[] {
  return LIQUID_GLASS
    ? [glassEffect({ glass: { variant: 'regular', interactive: true }, shape: 'circle' })]
    : [background(MATERIAL, shapes.circle())];
}

/** Black at 50% (`#RRGGBBAA`). */
const SCRIM_FILL = '#00000080';

/** `.glass` / `.glassProminent` on iOS 26, `.borderedProminent` before. */
export function glassButton(prominent = false): ModifierConfig[] {
  if (LIQUID_GLASS) return [buttonStyle(prominent ? 'glassProminent' : 'glass')];
  // Before iOS 26, prominent buttons take the caller's tint; the rest get a dark
  // translucent fill with a white label, which stays legible over bright video
  // (`.bordered` would paint a light fill behind white text).
  if (prominent) return [buttonStyle('borderedProminent')];
  return [buttonStyle('borderedProminent'), tint(SCRIM_FILL)];
}
