require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "NitroRtmpPublisher"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  # Minimum iOS bumped to 15 to match HaishinKit 2.2.x's deployment target.
  # If you need iOS 13/14 support, pin to v0.3.x of this package.
  s.platforms    = { :ios => "15.0" }
  s.source       = { :git => "https://github.com/Fluxlabs-tech/react-native-nitro-rtmp-publisher.git", :tag => "#{s.version}" }

  s.source_files = [
    "ios/**/*.{swift,h,hpp,m,mm,c,cpp}",
  ]

  s.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES",
    "SWIFT_VERSION" => "5.0",
    # The Nitro-generated Fabric view component (HybridRtmpPublisherViewComponent.mm)
    # transitively includes React-Fabric headers that reference Yoga C++ headers
    # (yoga/style/Style.h, yoga/node/Node.h, …). The Yoga podspec only exposes
    # YG*.h publicly, so the C++ headers live under Pods/Headers/Private/Yoga.
    # Pull that into our search path so the Fabric chain compiles.
    "HEADER_SEARCH_PATHS" => "$(inherited) \"${PODS_ROOT}/Headers/Private/Yoga\"",
  }

  s.dependency "React-Core"

  # HaishinKit 2.2.5 — RTMP publisher engine.
  #
  # ⚠️  HaishinKit stopped publishing podspecs to CocoaPods trunk after 2.0.9.
  # We ship our own vendored HaishinKit.podspec + RTMPHaishinKit.podspec under
  # the `podspecs/` directory of this package (kept out of the package root so
  # they don't shadow this podspec during RN autolinking). Consumers must add
  # these two lines to their Podfile (typically `ios/Podfile`):
  #
  #   pod 'HaishinKit',     :podspec => '../node_modules/react-native-nitro-rtmp-publisher/podspecs/HaishinKit.podspec'
  #   pod 'RTMPHaishinKit', :podspec => '../node_modules/react-native-nitro-rtmp-publisher/podspecs/RTMPHaishinKit.podspec'
  #
  # See README.md "Install → iOS" for the full setup.
  s.dependency "HaishinKit", "2.2.5"
  s.dependency "RTMPHaishinKit", "2.2.5"

  load "nitrogen/generated/ios/NitroRtmpPublisher+autolinking.rb"
  add_nitrogen_files(s)
end
