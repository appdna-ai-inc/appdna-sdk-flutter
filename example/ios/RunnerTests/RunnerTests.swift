import Flutter
import UIKit
import XCTest
import StoreKit
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

    /// SPEC-497 round 12 — `skipToWithData` is an accepted alias of `skipTo`. It is in the auth gate's
    /// list of explicit decisions, so without its own decoder case it fell to `default: .proceed` and
    /// ADVANCED the step instead of skipping. Android and React Native already map both names.
    func testSkipToWithDataDecodesAsASkipNotAProceed() {
        switch OnboardingDelegateForwarder.stepAdvanceResult(
            from: ["type": "skipToWithData", "stepId": "plan", "data": ["k": "v"]]
        ) {
        case .skipToWithData(let stepId, let data):
            XCTAssertEqual(stepId, "plan")
            XCTAssertEqual(data["k"] as? String, "v")
        default:
            XCTFail("skipToWithData with data must decode as .skipToWithData")
        }
        switch OnboardingDelegateForwarder.stepAdvanceResult(from: ["type": "skipToWithData", "stepId": "plan"]) {
        case .skipTo(let stepId):
            XCTAssertEqual(stepId, "plan")
        default:
            XCTFail("skipToWithData without data must decode as .skipTo")
        }
        XCTAssertTrue(OnboardingDelegateForwarder.isExplicitDecision(["type": "skipToWithData", "stepId": "plan"]))
    }

    /// SPEC-497 — a `skipTo` whose `stepId` is missing or blank names no step: not a skip, and not an
    /// explicit decision, so the auth gate blocks it on a sign-in step (it used to decode to
    /// `.skipTo("")`, which advanced). Mirrors `delegate_contracts/skip_to_without_step_id_is_not_a_decision`.
    func testSkipToWithoutAStepIdIsNeitherASkipNorADecision() {
        for reply in [["type": "skipTo"], ["type": "skipTo", "stepId": ""], ["type": "skipTo", "stepId": 42],
                      ["type": "skipToWithData", "data": ["plan": "pro"]]] as [[String: Any]] {
            XCTAssertFalse(OnboardingDelegateForwarder.isExplicitDecision(reply), "\(reply)")
        }
        guard case .proceed = OnboardingDelegateForwarder.stepAdvanceResult(from: ["type": "skipTo", "stepId": "  "]) else {
            return XCTFail("a blank stepId off a sign-in step proceeds")
        }
        guard case .proceedWithData(let data) = OnboardingDelegateForwarder.stepAdvanceResult(
            from: ["type": "skipToWithData", "data": ["plan": "pro"]]
        ) else { return XCTFail("no stepId + data → proceedWithData") }
        XCTAssertEqual(data["plan"] as? String, "pro")
        XCTAssertTrue(OnboardingDelegateForwarder.isExplicitDecision(["type": "skipTo", "stepId": "plan_step"]))
    }

    /// SPEC-497 round 12 — with no invoker nobody can answer, and silence never lets a sign-in action
    /// through. It used to return `.proceed` for every step.
    func testNoInvokerBlocksASignInActionAndProceedsAnOrdinaryStep() async {
        let forwarder = OnboardingDelegateForwarder()
        XCTAssertNil(forwarder.invoker)
        let signIn = await forwarder.onBeforeStepAdvance(
            flowId: "f", fromStepId: "s", stepIndex: 0, stepType: "form",
            responses: [:], stepData: ["action": "login"]
        )
        guard case .block(let message) = signIn else {
            return XCTFail("a sign-in action with no invoker must block, got \(signIn)")
        }
        XCTAssertFalse(message.isEmpty)
        let ordinary = await forwarder.onBeforeStepAdvance(
            flowId: "f", fromStepId: "s", stepIndex: 0, stepType: "form",
            responses: [:], stepData: nil
        )
        guard case .proceed = ordinary else {
            return XCTFail("an ordinary step with no invoker keeps the native default, got \(ordinary)")
        }
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

    // MARK: - Fix wave: entitlement streams survive shutdown() → configure()

    private func postEntitlementsChanged() throws {
        let json = #"[{"productId":"pro","store":"app_store","status":"active","isTrial":false}]"#
        let entitlements = try JSONDecoder().decode([ServerEntitlement].self, from: Data(json.utf8))
        NotificationCenter.default.post(name: Notification.Name("com.appdna.entitlementsChanged"),
                                        object: nil, userInfo: ["entitlements": entitlements])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    private func postWebEntitlementChanged() {
        NotificationCenter.default.post(name: Notification.Name("AppDNA.webEntitlementChanged"), object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// OWNER-NAMED. The Dart `billing.onEntitlementsChanged` stream used a `didRegister` latch: native
    /// `shutdown()` drops every entitlement handler, the latch stayed set, and the stream never emitted
    /// again after `shutdown()` → `configure()`. The "configure" case now calls `reattachStreams()`.
    /// Exactly ONE emission per change (remove-then-add: no second handler stacks up).
    func testEntitlementStreamEmitsOnceAfterShutdownThenConfigure() throws {
        let plugin = AppdnaPlugin()
        let handler = BillingEntitlementStreamHandler(plugin: plugin)
        plugin.entitlementStreamHandler = handler
        var emissions = 0
        _ = handler.onListen(withArguments: nil) { _ in emissions += 1 }
        defer { _ = handler.onCancel(withArguments: nil) }

        try postEntitlementsChanged()
        XCTAssertEqual(emissions, 1, "a listening stream receives the change")

        AppDNA.shutdown()
        plugin.reattachStreams()   // what the "configure" method-call case does after AppDNA.configure
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))  // let the async teardown land

        try postEntitlementsChanged()
        XCTAssertEqual(emissions, 2, "after shutdown() → configure() the stream must still emit, exactly once per change")

        plugin.reattachStreams()   // a second configure without a shutdown must not stack a handler
        try postEntitlementsChanged()
        XCTAssertEqual(emissions, 3, "re-attaching twice must not deliver a change twice")
    }

    /// Same latch on the web-entitlement stream (the plugin's own FlutterStreamHandler).
    func testWebEntitlementStreamEmitsAfterShutdownThenConfigure() {
        let plugin = AppdnaPlugin()
        var emissions = 0
        _ = plugin.onListen(withArguments: nil) { _ in emissions += 1 }
        defer { _ = plugin.onCancel(withArguments: nil) }

        postWebEntitlementChanged()
        XCTAssertEqual(emissions, 1)

        AppDNA.shutdown()
        plugin.reattachStreams()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        postWebEntitlementChanged()
        XCTAssertEqual(emissions, 2, "the web-entitlement stream must survive shutdown() → configure(), once per change")
    }

    /// Cancellation is decided by the typed error, never by the message text.
    func testUserCancellationIsTypedNotStringMatched() {
        XCTAssertTrue(BillingMappers.isUserCancellation(BillingError.userCancelled))
        XCTAssertTrue(BillingMappers.isUserCancellation(SKError(.paymentCancelled)))
        // RevenueCat's `ErrorCode.purchaseCancelledError` (an NSError in the "RevenueCat.ErrorCode" domain,
        // code 1) is a user cancel → `{status: "cancelled"}`; another RevenueCat error is not.
        XCTAssertTrue(BillingMappers.isUserCancellation(NSError(domain: "RevenueCat.ErrorCode", code: 1)))
        XCTAssertFalse(BillingMappers.isUserCancellation(NSError(domain: "RevenueCat.ErrorCode", code: 2)))
        let prose = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Request was cancelled by the server"])
        XCTAssertFalse(BillingMappers.isUserCancellation(prose), "an untyped error whose text says 'cancel' is not a user cancel")
        XCTAssertFalse(BillingMappers.isUserCancellation(CancellationError()), "a Task cancellation (shutdown) is not a user cancel")
        XCTAssertFalse(BillingMappers.isUserCancellation(BillingError.serverError("purchase cancelled upstream")))
    }

    /// `PurchaseResult.entitlement` carries the product's real expiry and status. NEGATIVE CONTROL: it was
    /// a placeholder — `expiresAt` nil, `status` "active" — whatever the store held.
    func testPurchaseResultEntitlementCarriesTheRealExpiry() {
        let tx = TransactionInfo(transactionId: "1", productId: "monthly", purchaseDate: Date())
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let map = tx.toPurchaseResultMap(entitlements: [
            Entitlement(identifier: "other", isActive: true, expiresAt: nil, productId: "other"),
            Entitlement(identifier: "monthly", isActive: true, expiresAt: expiry, productId: "monthly"),
        ])
        let entitlement = map["entitlement"] as? [String: Any?]
        XCTAssertEqual(entitlement?["expiresAt"] as? String, "2030-03-17T17:46:40Z")
        XCTAssertEqual(entitlement?["status"] as? String, "active")
        // No entry for the product (a consumable): the fallback.
        let fallback = tx.toPurchaseResultMap(entitlements: [])["entitlement"] as? [String: Any?]
        XCTAssertEqual(fallback?["status"] as? String, "active")
        XCTAssertNil(fallback?["expiresAt"] ?? nil)
    }

    /// The init event channel forwards the native `onInitDegraded` (it was a handler that never emitted, so
    /// `setInitDelegate` worked on Android only). NEGATIVE CONTROL: `makeInitStreamHandler()` returning a
    /// handler that does not register `AppDNA.initDelegate` → this fails (no delegate, no event).
    func testTheInitStreamForwardsOnInitDegraded() throws {
        let saved = AppDNA.initDelegate
        defer { AppDNA.initDelegate = saved }
        let handler: FlutterStreamHandler = AppdnaPlugin.makeInitStreamHandler()
        var events: [Any] = []
        XCTAssertNil(handler.onListen(withArguments: nil, eventSink: { events.append($0 as Any) }))
        let delegate = try XCTUnwrap(AppDNA.initDelegate, "listening did not register the native init delegate")

        struct Offline: LocalizedError { var errorDescription: String? { "Bootstrap failed: offline" } }
        delegate.onInitDegraded(reason: Offline())
        let deadline = Date().addingTimeInterval(2)
        while events.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

        let envelope = try XCTUnwrap(events.first as? [String: Any], "no event reached the Dart stream")
        XCTAssertEqual(envelope["type"] as? String, "onInitDegraded")
        let error = (envelope["args"] as? [String: Any])?["error"] as? [String: Any]
        XCTAssertEqual(error?["message"] as? String, "Bootstrap failed: offline")
        XCTAssertEqual(error?["type"] as? String, "Offline")

        _ = handler.onCancel(withArguments: nil)
        XCTAssertNil(AppDNA.initDelegate, "cancelling the stream left the native delegate registered")
    }
}
