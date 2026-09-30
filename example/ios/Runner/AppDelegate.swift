import Flutter
import StoreKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// Opt-in launch values for test harnesses (see `_readLaunchValues` in lib/main.dart): launch
  /// arguments such as `-appdnaApiKey <key>` land in the NSUserDefaults argument domain. Only the keys
  /// below are exposed; with no arguments the map is empty and nothing changes.
  private static let launchKeys = [
    "appdnaApiKey", "appdnaOnboardingId", "appdnaHostDataDemo",
    // SPEC-497 §4.10 — the sign-in timeout floor device rows.
    "appdnaSignInDelaySeconds", "appdnaVetoTimeout", "appdnaStepAdvanceDelaySeconds",
    "appdnaStepAdvanceReply",
    // SPEC-497 §3.11 / §13h — billing provider, the host-buy product, the location flow.
    "appdnaBillingProvider", "appdnaHostProductId", "appdnaLocationFlowId", "appdnaPermissionsFlowId",
  ]

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      FlutterMethodChannel(name: "appdna_example/launch", binaryMessenger: controller.binaryMessenger)
        .setMethodCallHandler { call, result in
          guard call.method == "launchValues" else { return result(FlutterMethodNotImplemented) }
          var values: [String: String] = [:]
          for key in Self.launchKeys {
            if let v = UserDefaults.standard.string(forKey: key) { values[key] = v }
          }
          // SPEC-497 §3.11 — `appdnaEnv=sandbox` exactly when this build carries a base-URL override
          // (Info.plist `AppDNABaseURLOverride` ← `$(APPDNA_BASE_URL_OVERRIDE)` from the uncommitted
          // Local.xcconfig). Emitted even with no launch arguments.
          if let override = Bundle.main.object(forInfoDictionaryKey: "AppDNABaseURLOverride") as? String,
             !override.trimmingCharacters(in: .whitespaces).isEmpty {
            values["appdnaEnv"] = "sandbox"
          }
          result(values)
        }
      // SPEC-497 §3.11 — the host's OWN StoreKit calls, for the ownership device rows.
      FlutterMethodChannel(name: "appdna_example/host", binaryMessenger: controller.binaryMessenger)
        .setMethodCallHandler { call, result in
          switch call.method {
          case "hostBuy":
            let productId = (call.arguments as? [String: Any])?["productId"] as? String ?? "ai.appdna.test.monthly"
            Task {
              let outcome = await Self.hostBuyWithoutFinishing(productId)
              await Self.logTransactions()
              DispatchQueue.main.async { result(outcome) }
            }
          case "logTransactions":
            Task {
              await Self.logTransactions()
              DispatchQueue.main.async { result(nil) }
            }
          default:
            result(FlutterMethodNotImplemented)
          }
        }
    }
    // After every foreground (the rows background/foreground the app, then read the log).
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in Task { await Self.logTransactions() } }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }


  /// A purchase the HOST makes and deliberately does not finish — the shape of an app whose own
  /// billing SDK owns transactions. The SDK must leave it unfinished under a non-owning provider.
  private static func hostBuyWithoutFinishing(_ productId: String) async -> String {
    do {
      guard let product = try await Product.products(for: [productId]).first else {
        return "no such product"
      }
      let purchase = try await product.purchase()
      guard case .success(.verified(let transaction)) = purchase else { return "\(purchase)" }
      NSLog("AppDNA-E2E hostBuy %@ %@", productId, String(transaction.id))
      return String(transaction.id)
    } catch {
      NSLog("AppDNA-E2E hostBuy %@ failed %@", productId, "\(error)")
      return "failed: \(error)"
    }
  }

  /// `AppDNA-E2E unfinished=<ids>` and `AppDNA-E2E all=<ids>` (comma-separated `productId:transactionId`).
  private static func logTransactions() async {
    var unfinished: [String] = []
    for await result in Transaction.unfinished {
      if case .verified(let t) = result { unfinished.append("\(t.productID):\(t.id)") }
    }
    var all: [String] = []
    for await result in Transaction.all {
      if case .verified(let t) = result { all.append("\(t.productID):\(t.id)") }
    }
    NSLog("AppDNA-E2E unfinished=%@", unfinished.joined(separator: ","))
    NSLog("AppDNA-E2E all=%@", all.joined(separator: ","))
  }
}
