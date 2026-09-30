import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // Opt-in launch values for test harnesses (see `_readLaunchValues` in lib/main.dart): launch
    // arguments such as `-appdnaApiKey <key>` land in the NSUserDefaults argument domain. Only these
    // keys below are exposed; with no arguments the map is empty and nothing changes.
    if let controller = window?.rootViewController as? FlutterViewController {
      FlutterMethodChannel(name: "appdna_example/launch", binaryMessenger: controller.binaryMessenger)
        .setMethodCallHandler { call, result in
          guard call.method == "launchValues" else { return result(FlutterMethodNotImplemented) }
          var values: [String: String] = [:]
          for key in ["appdnaApiKey", "appdnaOnboardingId", "appdnaHostDataDemo",
                      // SPEC-497 §4.10 — the sign-in timeout floor device rows.
                      "appdnaSignInDelaySeconds", "appdnaVetoTimeout", "appdnaStepAdvanceDelaySeconds",
                      "appdnaStepAdvanceReply"] {
            if let v = UserDefaults.standard.string(forKey: key) { values[key] = v }
          }
          result(values)
        }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
