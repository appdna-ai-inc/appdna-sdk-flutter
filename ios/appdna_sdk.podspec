Pod::Spec.new do |s|
  s.name             = 'appdna_sdk'
  s.version          = '1.0.6'
  s.summary          = 'AppDNA SDK Flutter plugin - iOS platform support.'
  s.description      = <<-DESC
Flutter plugin that bridges the AppDNA iOS SDK for analytics, experiments,
paywalls, surveys, web entitlements, and deferred deep links.
                       DESC
  s.homepage         = 'https://appdna.ai'
  s.license          = { :type => 'Proprietary', :file => '../LICENSE' }
  s.author           = { 'AppDNA' => 'hello@appdna.ai' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.resource_bundles = { 'appdna_sdk' => ['PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.dependency 'AppDNASDK', '~> 1.0.83'

  # 🔴 STATIC, because this pod links the static AppDNASDK and inherits its map symbols.
  #
  # AppDNASDK is `static_framework` (GoogleMaps ships as a static xcframework). A DYNAMIC framework
  # that links a static library must resolve that library's external symbols at its own link step,
  # so this wrapper failed exactly where the SDK used to:
  #
  #     Undefined symbols for architecture arm64:
  #       "_OBJC_CLASS_$_GMSMapView", referenced from:
  #            in AppDNASDK[arm64](MapInteractive.o)
  #     (in target 'appdna_sdk' from project 'Pods')
  #
  # Declaring this pod static too removes that link step: the objects flow into the app, which links
  # GoogleMaps alongside them. Every pod in the chain from the map code to the app has to be static
  # or link GoogleMaps itself; static is the one that does not multiply.
  s.static_framework = true
  s.platform         = :ios, '16.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version    = '5.0'
end
