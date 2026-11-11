require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "NitroRtmpPublisher"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  # Minimum iOS bumped to 15 to match HaishinKit 2.x's deployment target.
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

  # React Native's own libraries (Fabric, JSI, folly, glog) that the Nitro view
  # component uses. `install_modules_dependencies` declares them all, so the pod
  # also links when it is built as a dynamic framework.
  s.dependency "React-jsi"
  s.dependency "React-callinvoker"
  install_modules_dependencies(s)

  # HaishinKit 2.3.0 — RTMP publisher engine, as a Swift package.
  #
  # HaishinKit is distributed through Swift Package Manager only (no podspecs
  # since 2.0.9). React Native's `spm_dependency` (react_native_pods.rb, which
  # every React Native Podfile loads) adds the package to the Pods project and
  # links its products into this pod, so apps need no Podfile lines for it.
  unless respond_to?(:spm_dependency, true)
    raise "NitroRtmpPublisher needs React Native's spm_dependency (React Native 0.75 or later)"
  end
  spm_dependency(s,
    url: "https://github.com/HaishinKit/HaishinKit.swift.git",
    requirement: { kind: "exactVersion", version: "2.3.0" },
    products: ["HaishinKit", "RTMPHaishinKit"]
  )

  load "nitrogen/generated/ios/NitroRtmpPublisher+autolinking.rb"
  add_nitrogen_files(s)
end
