import { Button, Column, Host, Icon, Spacer, Text } from '@expo/ui/jetpack-compose';
import { fillMaxSize, height, paddingAll, size } from '@expo/ui/jetpack-compose/modifiers';

import { icons } from './icons';
import { MUTED, SEED_COLOR } from './palette';
import type { SecondScreenProps } from './types';

/**
 * The stream screen stays mounted (native-stack keeps it in the tree) while
 * this one is on top — exactly the case that must NOT auto-enter PiP. If the
 * app shrinks into a floating window on Home here, PiP is leaking app-wide.
 */
export function SecondScreen({ onBack }: SecondScreenProps) {
  return (
    <Host style={{ flex: 1 }} colorScheme="dark" seedColor={SEED_COLOR}>
      <Column
        verticalArrangement="center"
        horizontalAlignment="center"
        modifiers={[fillMaxSize(), paddingAll(28)]}
      >
        <Text style={{ typography: 'headlineSmall', fontWeight: '700' }}>Second screen</Text>
        <Spacer modifiers={[height(12)]} />
        <Text color={MUTED} style={{ typography: 'bodyLarge', textAlign: 'center' }}>
          No publisher here. Press Home now: the app should stay normal (NO Picture-in-Picture
          window). If it shrinks into a floating PiP window, PiP is leaking to non-stream screens.
        </Text>
        <Spacer modifiers={[height(28)]} />
        <Button onClick={onBack}>
          <Icon source={icons.arrowBack} size={18} />
          <Spacer modifiers={[size(8, 0)]} />
          <Text>Back to stream</Text>
        </Button>
      </Column>
    </Host>
  );
}
