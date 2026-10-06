import { Button, Host, Image, Text, VStack } from '@expo/ui/swift-ui';
import {
  controlSize,
  font,
  foregroundStyle,
  multilineTextAlignment,
  padding,
  tint,
} from '@expo/ui/swift-ui/modifiers';

import { glassButton } from './glass';
import { BLUE, MUTED } from './palette';
import type { SecondScreenProps } from './types';

export function SecondScreen({ onBack }: SecondScreenProps) {
  return (
    <Host style={{ flex: 1 }} colorScheme="dark">
      <VStack spacing={16} modifiers={[padding({ all: 28 })]}>
        <Image systemName="rectangle.stack" size={40} color={MUTED} />
        <Text modifiers={[font({ textStyle: 'title2', weight: 'bold' })]}>Second screen</Text>
        <Text
          modifiers={[
            multilineTextAlignment('center'),
            foregroundStyle({ type: 'hierarchical', style: 'secondary' }),
          ]}
        >
          No publisher here; the stream screen stays mounted underneath. Picture-in-Picture is
          Android-only, so on iOS this just checks that leaving and coming back keeps the stream
          healthy.
        </Text>
        <Button
          label="Back to stream"
          systemImage="chevron.left"
          onPress={onBack}
          modifiers={[...glassButton(true), tint(BLUE), controlSize('large')]}
        />
      </VStack>
    </Host>
  );
}
