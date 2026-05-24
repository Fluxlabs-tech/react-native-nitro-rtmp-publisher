#
# RTMPHaishinKit podspec — VENDORED by react-native-nitro-rtmp-publisher.
#
# In HaishinKit 2.1+ the RTMP transport (RTMPStream, RTMPConnection) was
# split out of the core HaishinKit module into its own RTMPHaishinKit
# target. Both must be installed for an RTMP publisher to work.
#
# See HaishinKit.podspec in this repo for context on why we ship our own
# .podspec files for HaishinKit 2.x.
#
Pod::Spec.new do |s|
  s.name          = "RTMPHaishinKit"
  s.version       = "2.2.5"
  s.summary       = "RTMP transport layer for HaishinKit."
  s.swift_version = "6.0"

  s.homepage     = "https://github.com/HaishinKit/HaishinKit.swift"
  s.license      = { :type => "New BSD", :file => "LICENSE.md" }
  s.authors      = { "shogo4405" => "shogo4405@gmail.com" }
  s.source       = { :git => "https://github.com/HaishinKit/HaishinKit.swift.git", :tag => "#{s.version}" }

  s.ios.deployment_target      = "15.0"
  s.osx.deployment_target      = "12.0"
  s.tvos.deployment_target     = "15.0"
  s.visionos.deployment_target = "1.0"

  s.source_files = "RTMPHaishinKit/Sources/**/*.swift"

  # Must share the same -package-name as HaishinKit.podspec so package-level
  # symbols (AsyncStreamedFlow, AsyncStreamed, NetworkTransportReporter, etc.)
  # are visible across the module boundary. See HaishinKit.podspec for context.
  s.pod_target_xcconfig = {
    "OTHER_SWIFT_FLAGS" => "$(inherited) -package-name HaishinKit",
  }

  s.dependency 'HaishinKit', '2.2.5'
end
