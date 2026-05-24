#
# HaishinKit core podspec — VENDORED by react-native-nitro-rtmp-publisher.
#
# Upstream (https://github.com/HaishinKit/HaishinKit.swift) stopped shipping
# a .podspec at the 2.1.0 tag in favor of Swift Package Manager. This file
# replicates what their last published podspec (2.0.9) looked like, pointed
# at the latest 2.x tag — so React Native consumers using CocoaPods can
# still get the newest HaishinKit without forking the upstream repo.
#
# Source path / dependency list / Swift version match
# https://github.com/HaishinKit/HaishinKit.swift/blob/2.2.5/Package.swift
# Kept in sync manually on every HaishinKit release we want to support.
#
Pod::Spec.new do |s|
  s.name          = "HaishinKit"
  s.version       = "2.2.5"
  s.summary       = "Camera and Microphone streaming library via RTMP for iOS, macOS, tvOS, and visionOS."
  s.swift_version = "6.0"

  s.homepage     = "https://github.com/HaishinKit/HaishinKit.swift"
  s.license      = { :type => "New BSD", :file => "LICENSE.md" }
  s.authors      = { "shogo4405" => "shogo4405@gmail.com" }
  s.source       = { :git => "https://github.com/HaishinKit/HaishinKit.swift.git", :tag => "#{s.version}" }

  s.ios.deployment_target      = "15.0"
  s.osx.deployment_target      = "12.0"
  s.tvos.deployment_target     = "15.0"
  s.visionos.deployment_target = "1.0"

  s.source_files = "HaishinKit/Sources/**/*.swift"

  # HaishinKit 2.x uses Swift 5.9+ `package` access modifiers internally
  # (so the core HaishinKit and RTMPHaishinKit modules can share package-level
  # symbols without making them public). When built via SPM the package name
  # is derived from Package.swift; when built via CocoaPods we have to set it
  # manually with -package-name. The name must match across both pods so
  # cross-module `package` access works.
  s.pod_target_xcconfig = {
    "OTHER_SWIFT_FLAGS" => "$(inherited) -package-name HaishinKit",
  }

  # Loosen Logboard pin: upstream Package.swift declares `2.6.0..<2.7.0`
  # but CocoaPods trunk only has Logboard 2.5.0. The 2.5→2.6 changes
  # are minor (Sendable conformance) and don't change the API surface
  # HaishinKit actually uses. Bump to ~> 2.6 if/when Logboard 2.6 ships
  # to trunk or we vendor a Logboard.podspec ourselves.
  s.dependency 'Logboard', '~> 2.5.0'
end
