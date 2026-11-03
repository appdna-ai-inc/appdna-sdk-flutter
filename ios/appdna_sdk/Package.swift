// swift-tools-version: 5.9
//
// Swift Package Manager support for the AppDNA Flutter plugin's iOS side (SPEC-515).
//
// Flutter uses this when the app has Swift Package Manager turned on (the default from Flutter 3.44, or
// `flutter config --enable-swift-package-manager` before that) and every plugin in the app supports it.
// Otherwise it uses `ios/appdna_sdk.podspec` (CocoaPods), which builds the same sources.
//
// The native SDK comes from its public Swift package, so this path does not depend on CocoaPods Trunk.
// Keep the version range in step with the podspec's `AppDNASDK` pin (`check:native-pins`).

import PackageDescription

let package = Package(
  name: "appdna_sdk",
  platforms: [
    .iOS("16.0")
  ],
  products: [
    .library(name: "appdna-sdk", targets: ["appdna_sdk"])
  ],
  dependencies: [
    .package(url: "https://github.com/appdna-ai-inc/appdna-sdk-ios.git", "1.0.84"..<"1.1.0")
  ],
  targets: [
    .target(
      name: "appdna_sdk",
      dependencies: [
        .product(name: "AppDNASDK", package: "appdna-sdk-ios")
      ],
      resources: [
        .process("PrivacyInfo.xcprivacy")
      ]
    )
  ]
)
