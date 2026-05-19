import { getHostComponent } from 'react-native-nitro-modules'
import RtmpPublisherViewConfig from '../nitrogen/generated/shared/json/RtmpPublisherViewConfig.json'
import type {
  RtmpPublisherViewProps,
  RtmpPublisherViewMethods,
} from './specs/RtmpPublisher.nitro'

export const RtmpPublisherView = getHostComponent<
  RtmpPublisherViewProps,
  RtmpPublisherViewMethods
>('RtmpPublisherView', () => RtmpPublisherViewConfig)

export type {
  RtmpPublisherView as RtmpPublisherViewSpec,
  RtmpPublisherViewProps,
  RtmpPublisherViewMethods,
  RtmpConnectionEvent,
  CameraFacing,
  VideoCodec,
  AudioCodec,
  AspectRatioMode,
  RecordStatus,
  ThermalStatus,
  AudioSource,
  StreamMode,
} from './specs/RtmpPublisher.nitro'
