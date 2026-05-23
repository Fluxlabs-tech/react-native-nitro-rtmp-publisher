require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "NitroRtmpPublisher"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "13.0" }
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

  # HaishinKit — RTMP publisher engine.
  # Pinned to the 1.9.x line: stable, sync-style API that matches RootEncoder on Android.
  # https://github.com/HaishinKit/HaishinKit.swift
  s.dependency "HaishinKit", "~> 1.9"

  load "nitrogen/generated/ios/NitroRtmpPublisher+autolinking.rb"
  add_nitrogen_files(s)
end
