import Flutter
import UIKit
import XCTest
import AppDNASDK
@testable import appdna_sdk

/**
 SPEC-070-B AC-11 — the native `parseOptions` mapping, on Flutter/iOS.

 ## Why this file exists

 It was the stock Flutter template — one empty `testExample()` — for the whole life of the plugin.
 AC-11 asks for native `parseOptions` unit tests, Swift AND Kotlin, for **RN *and* Flutter**, because
 both wrappers once hardcoded `?? 300` for `configTTL` and both once read the `framework` tag out of
 the host's own map. RN got its two suites. Flutter got the CODE FIX and nothing else. A guarantee
 that is only tested on one platform is a guarantee on one platform — and the two `parseOptions`
 implementations are separate hand-written functions, so "the Kotlin one is right" is not evidence
 about Swift. E7's `?? 300` — the wrapper literal that sat 12× below the native `configTTL` and made
 every wrapped app re-fetch its config twelve times as often as a native one — lived in a SWIFT file.

 A `flutter test` cannot reach any of this: it mocks the MethodChannel away, so it observes neither a
 Swift `??` default nor the tag the bridge injects. Only a native test does. `parseOptions` is
 `internal` (it was `private`) precisely so this file can call it — the AC's own testability
 prerequisite, which had never been applied on this platform.

 ## The oracle

 Every default is compared against `AppDNAOptions()`'s own value, never a literal. Asserting
 `configTTL == 3600` against a number written here would re-create the exact defect: a constant in
 the wrapper that agrees with nothing. If native moves, this test moves with it, and the wrapper is
 forced to move too.

 The one deliberate literal is the wire value `"flutter"`, because that string IS the contract (the
 `framework` column in BigQuery); mirroring it from the constant under test would assert nothing.

 ## Running it

     cd example/ios && xcodebuild test -workspace Runner.xcworkspace -scheme Runner \
       -destination 'platform=iOS Simulator,name=iPhone 15'

 The Podfile already declares `target 'RunnerTests' { inherit! :search_paths }`, which is what makes
 `@testable import appdna_sdk` (the pod's module name — `s.name` in the podspec) resolve.
 */
class RunnerTests: XCTestCase {

    private let plugin = AppdnaPlugin()

    /// The native defaults. The oracle — never a literal.
    private let defaults = AppDNAOptions()

    // MARK: - AC-11 leg 1: the `framework` tag

    func testFrameworkTagIsAlwaysFlutter() {
        // 🔴 The nil case. This returned a bare `AppDNAOptions()` — `framework: "native"` — so the tag
        // was injected on every other path and DROPPED on this one. A Flutter app whose options map
        // never arrives reported itself as a NATIVE app for the life of the process, and
        // `event-envelope.schema.ts` is `.catch('native')`: a wrong tag does not error, is not logged,
        // and is not metered. It just quietly lies in BigQuery.
        XCTAssertEqual(plugin.parseOptions(nil).framework, "flutter")
        XCTAssertEqual(plugin.parseOptions([:]).framework, "flutter")

        // §7 rule 1 — the tag is INJECTED, never read from the host's map. A host must not be able to
        // set, spoof or omit its own attribution.
        XCTAssertEqual(plugin.parseOptions(["framework": "native"]).framework, "flutter")
        XCTAssertEqual(plugin.parseOptions(["framework": "react_native"]).framework, "flutter")

        // …and it is never the native default, which is what a dropped tag silently produces.
        XCTAssertNotEqual(plugin.parseOptions([:]).framework, defaults.framework)
    }

    func testFrameworkVersionIsCarriedThroughFromDart() {
        // ⚠ NOT the same rule as the tag. The Flutter wrapper's version lives in Dart
        // (`AppDNAOptions.toMap()` supplies it even on the bare `configure(apiKey:)` path), so native
        // passes it through rather than injecting it. What matters here is that the plumbing does not
        // DROP it: a nil `frameworkVersion` is what `diagnose()` and every event envelope reported for
        // two releases while the Dart constant was stale, and nothing noticed.
        // `check:wrapper-version-selfreport` owns the VALUE.
        XCTAssertEqual(plugin.parseOptions(["frameworkVersion": "1.2.3"]).frameworkVersion, "1.2.3")
        XCTAssertNil(plugin.parseOptions([:]).frameworkVersion)
    }

    // MARK: - AC-11 leg 2: `configTTL` (E7 — the 12× drift)

    func testConfigTTLDefaultsToTheNativeValueNotAWrapperLiteral() {
        XCTAssertEqual(plugin.parseOptions(nil).configTTL, defaults.configTTL)
        XCTAssertEqual(plugin.parseOptions([:]).configTTL, defaults.configTTL)

        // A host value is honored. A Dart `int` crosses the MethodChannel as an **NSNumber**, and
        // `as? TimeInterval` must still accept it — writing this as `["configTTL": 120]` would be a
        // Swift `Int`, which does NOT bridge to `TimeInterval`, and the test would prove the opposite
        // of what it appears to prove. The real dictionary comes from ObjC; model that.
        XCTAssertEqual(plugin.parseOptions(["configTTL": NSNumber(value: 120)]).configTTL, 120)
        XCTAssertEqual(plugin.parseOptions(["configTTL": 120.0]).configTTL, 120)
    }

    func testTheOtherScalarsAlsoDefaultToNative() {
        let d = plugin.parseOptions([:])
        XCTAssertEqual(d.flushInterval, defaults.flushInterval)
        XCTAssertEqual(d.batchSize, defaults.batchSize)
        XCTAssertEqual(d.vetoTimeout, defaults.vetoTimeout)
        XCTAssertEqual(d.requireConsent, defaults.requireConsent)

        let set = plugin.parseOptions([
            "flushInterval": NSNumber(value: 5),
            "batchSize": NSNumber(value: 7),
            "vetoTimeout": NSNumber(value: 11),
            "requireConsent": true,
        ])
        XCTAssertEqual(set.flushInterval, 5)
        XCTAssertEqual(set.batchSize, 7)
        XCTAssertEqual(set.vetoTimeout, 11)
        XCTAssertTrue(set.requireConsent)
    }

    // MARK: - AC-11 leg 3: `billingProvider`

    func testBillingProviderBareStrings() {
        XCTAssertEqual(plugin.parseOptions(["billingProvider": "revenueCat"]).billingProvider, BillingProvider.revenueCat)
        XCTAssertEqual(plugin.parseOptions(["billingProvider": "storeKit2"]).billingProvider, BillingProvider.storeKit2)
        // `BillingProvider.none`, spelled out: a bare `.none` inside XCTAssertEqual's generic overloads
        // binds to `Optional.none` and the assertion silently changes meaning.
        XCTAssertEqual(plugin.parseOptions(["billingProvider": "none"]).billingProvider, BillingProvider.none)
    }

    func testBillingProviderAdaptyCarriesItsKey() {
        XCTAssertEqual(
            plugin.parseOptions(["billingProvider": ["type": "adapty", "apiKey": "public_live_abc"]]).billingProvider,
            BillingProvider.adapty(apiKey: "public_live_abc")
        )
    }

    func testBillingProviderFallsBackToTheNativeDefaultWhenAbsentOrUnknown() {
        XCTAssertEqual(plugin.parseOptions([:]).billingProvider, defaults.billingProvider)
        XCTAssertEqual(plugin.parseOptions(["billingProvider": "paddle"]).billingProvider, defaults.billingProvider)
    }

    /// SPEC-497 §3.2 rule 6 — the provider goes through the core's `BillingProvider.fromWire`, like every
    /// other bridge. A bare `"adapty"` or a key-less map used to become `.adapty(apiKey: "")`, which every
    /// other bridge refuses; it is now refused here too, and falls back to the native default.
    func testKeylessAdaptyIsRefusedAndFallsBackToTheDefault() {
        XCTAssertEqual(plugin.parseOptions(["billingProvider": "adapty"]).billingProvider, defaults.billingProvider)
        XCTAssertEqual(plugin.parseOptions(["billingProvider": ["type": "adapty"]]).billingProvider, defaults.billingProvider)
        XCTAssertEqual(
            plugin.parseOptions(["billingProvider": ["type": "adapty", "apiKey": ""]]).billingProvider,
            defaults.billingProvider
        )
        XCTAssertEqual(defaults.billingProvider, BillingProvider.storeKit2)
    }

    /// SPEC-497 §4.2 (R82) — a zero, negative or non-numeric vetoTimeout is the native default, mapped in
    /// `parseOptions` so `diagnose()` and the bridge's invoker (written from this value in `configure`)
    /// agree.
    func testNonPositiveVetoTimeoutIsTheNativeDefault() {
        XCTAssertEqual(plugin.parseOptions(["vetoTimeout": NSNumber(value: 0)]).vetoTimeout, defaults.vetoTimeout)
        XCTAssertEqual(plugin.parseOptions(["vetoTimeout": NSNumber(value: -3)]).vetoTimeout, defaults.vetoTimeout)
        XCTAssertEqual(plugin.parseOptions(["vetoTimeout": "ten"]).vetoTimeout, defaults.vetoTimeout)
        XCTAssertEqual(plugin.parseOptions(["vetoTimeout": NSNumber(value: 150)]).vetoTimeout, 150)
    }

    /// SPEC-497 §4.2 — the sign-in floor the onBeforeStepAdvance call site takes `max` with.
    func testSignInFloorAppliesOnlyToAuthActions() {
        let configured = plugin.parseOptions(["vetoTimeout": NSNumber(value: 5)]).vetoTimeout
        let wait: ([String: Any]?) -> TimeInterval = {
            max(configured, StepAdvanceResult.minimumBridgeTimeout(stepData: $0) ?? 0)
        }
        XCTAssertEqual(wait(["action": "social_login"]), 120)
        XCTAssertEqual(wait(["action": "email_login"]), 120)
        XCTAssertEqual(wait(["action": "next"]), 5)
        XCTAssertEqual(wait(nil), 5)
    }

    /// SPEC-497 §3.4 / §13b.2 — PURCHASE_ERROR / RESTORE_ERROR carry `details.errorType` (was nil).
    func testBillingErrorDetailsCarryTheErrorType() {
        let refused = BillingError.providerNotAvailable("RevenueCat: purchases are made by RevenueCat in your app")
        XCTAssertEqual(BillingMappers.errorDetails(refused)["errorType"] as? String, "providerNotAvailable")
        XCTAssertEqual(BillingMappers.errorDetails(refused)["errorType"] as? String, billingErrorType(refused))
        let other = NSError(domain: "AppDNA", code: 1, userInfo: [NSLocalizedDescriptionKey: "x"])
        XCTAssertEqual(BillingMappers.errorDetails(other)["errorType"] as? String, "unknown")
    }

    // MARK: - `logLevel`

    func testLogLevelMapsEveryWireValueAndDefaultsToNative() {
        XCTAssertEqual(plugin.parseOptions(["logLevel": "none"]).logLevel, LogLevel.none)
        XCTAssertEqual(plugin.parseOptions(["logLevel": "error"]).logLevel, LogLevel.error)
        XCTAssertEqual(plugin.parseOptions(["logLevel": "warning"]).logLevel, LogLevel.warning)
        XCTAssertEqual(plugin.parseOptions(["logLevel": "info"]).logLevel, LogLevel.info)
        XCTAssertEqual(plugin.parseOptions(["logLevel": "debug"]).logLevel, LogLevel.debug)
        XCTAssertEqual(plugin.parseOptions(["logLevel": "verbose"]).logLevel, defaults.logLevel)
        XCTAssertEqual(plugin.parseOptions([:]).logLevel, defaults.logLevel)
    }
}
