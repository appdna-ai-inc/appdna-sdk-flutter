Pod::Spec.new do |s|
  s.name             = 'appdna_sdk'
  s.version          = '1.0.23'
  s.summary          = 'AppDNA SDK Flutter plugin - iOS platform support.'
  s.description      = <<-DESC
Flutter plugin that bridges the AppDNA iOS SDK for analytics, experiments,
paywalls, surveys, web entitlements, and deferred deep links.
                       DESC
  s.homepage         = 'https://appdna.ai'
  s.license          = { :type => 'Proprietary', :file => '../LICENSE' }
  s.author           = { 'AppDNA' => 'hello@appdna.ai' }
  s.source           = { :path => '.' }
  # The sources live in Swift Package Manager's layout; CocoaPods builds the same files.
  s.source_files     = 'appdna_sdk/Sources/appdna_sdk/**/*.swift'
  s.resource_bundles = { 'appdna_sdk' => ['appdna_sdk/Sources/appdna_sdk/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  # How the iOS SDK reaches an app that uses CocoaPods. Trunk accepts no new pod versions after 2026-12-02,
  # so this plugin cannot depend on the AppDNASDK pod for a new version. The publish copies the iOS SDK (its
  # podspec and the sources it lists) into `ios-core/` of the pub package, and this pod compiles them
  # itself. The SDK's dependencies are read from that podspec, so they cannot drift, and are older versions
  # that stay on Trunk. Apps on Swift Package Manager do not use this file: Package.swift depends on the
  # public package. The plugin's Swift imports `AppDNASDK` only when it is a separate module.
  #
  # The separate pod is still used when `ios-core/` is absent (a checkout of this repo) or when
  # APPDNA_IOS_SDK_PATH names a local SDK (this repo's example app and CI): then the Podfile names it.
  appdna_core_podspec = File.join(__dir__, 'ios-core', 'AppDNASDK.podspec')
  appdna_core_bundled = File.exist?(appdna_core_podspec) && ENV['APPDNA_IOS_SDK_PATH'].to_s.empty?
  appdna_core_xcconfig = {}
  if appdna_core_bundled
    core = Pod::Specification.from_file(appdna_core_podspec)
    core_ios = core.consumer(:ios)
    s.source_files = ['appdna_sdk/Sources/appdna_sdk/**/*.swift'] + core_ios.source_files.map { |g| "ios-core/#{g}" }
    core_ios.resource_bundles.each do |name, files|
      s.resource_bundles = s.attributes_hash['resource_bundles'].merge(name => Array(files).map { |f| "ios-core/#{f}" })
    end
    core.all_dependencies.each { |d| s.dependency d.name, *d.requirement.as_list }
    s.frameworks = core_ios.frameworks
    s.swift_version = core.swift_version.to_s
    appdna_core_xcconfig = { 'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) APPDNA_CORE_BUNDLED' }
  else
    s.dependency 'AppDNASDK', '~> 1.0.85'
  end

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
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }.merge(appdna_core_xcconfig)
  s.swift_version    = '5.0' unless appdna_core_bundled
end
