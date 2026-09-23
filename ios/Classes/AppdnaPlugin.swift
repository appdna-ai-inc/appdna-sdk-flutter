import Flutter
import UIKit
import AppDNASDK

public class AppdnaPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private var billingChannel: FlutterMethodChannel?
    // fileprivate so BillingEntitlementStreamHandler (same file) can route the
    // entitlement stream through it. Not public — stays internal to this file.
    fileprivate var entitlementEventSink: FlutterEventSink?

    // MARK: - Delegate forwarders (strong references so they are NOT
    // deallocated — the iOS SDK holds delegates with `weak` semantics on
    // most surfaces and `static weak` on push/billing/screen).
    private var onboardingForwarder: OnboardingDelegateForwarder?
    // SPEC-070-C Phase 2a — native -> Dart invoker for the sync_callbacks
    // channel. Held strongly so it (and its FlutterMethodChannel) outlive
    // register(); shared with the onboarding forwarder for its async hooks.
    private var syncInvoker: SyncCallbackInvoker?
    private var paywallForwarder: PaywallDelegateForwarder?
    private var surveyForwarder: SurveyDelegateForwarder?
    private var inAppMessageForwarder: InAppMessageDelegateForwarder?
    private var pushForwarder: PushDelegateForwarder?
    private var billingDelegateForwarder: BillingDelegateForwarder?
    private var deepLinkForwarder: DeepLinkDelegateForwarder?
    private var screenForwarder: ScreenDelegateForwarder?
    // SPEC-404 — held strongly here; `AppDNA.lifecycleDelegate` is `weak`.
    private var lifecycleForwarder: LifecycleDelegateForwarder?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.appdna.sdk/main",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "com.appdna.sdk/web_entitlement",
            binaryMessenger: registrar.messenger()
        )

        // Billing channels
        let billingChannel = FlutterMethodChannel(
            name: "com.appdna.sdk/billing",
            binaryMessenger: registrar.messenger()
        )
        let entitlementEventChannel = FlutterEventChannel(
            name: "com.appdna.sdk/entitlements",
            binaryMessenger: registrar.messenger()
        )

        let instance = AppdnaPlugin()
        instance.billingChannel = billingChannel
        registrar.addMethodCallDelegate(instance, channel: channel)
        billingChannel.setMethodCallHandler(instance.handleBilling)
        eventChannel.setStreamHandler(instance)
        entitlementEventChannel.setStreamHandler(BillingEntitlementStreamHandler(plugin: instance))

        // MARK: - Delegate event channels (native -> Dart)
        // Each forwarder implements the corresponding native delegate
        // protocol AND FlutterStreamHandler. On stream onListen the
        // forwarder is wired to the native module via setDelegate(...);
        // on onCancel the delegate is cleared.
        let messenger = registrar.messenger()

        // SPEC-070-C Phase 2a — sync_callbacks MethodChannel (native -> Dart).
        // The Dart side sets the method-call handler on this same channel name;
        // native uses it to invokeMethod async hooks + veto decisions and await
        // the reply. One shared invoker instance carries the timeout-default.
        let syncChannel = FlutterMethodChannel(
            name: "com.appdna.sdk/sync_callbacks", binaryMessenger: messenger
        )
        let syncInvoker = SyncCallbackInvoker(channel: syncChannel)
        instance.syncInvoker = syncInvoker

        let onboardingChannel = FlutterEventChannel(
            name: "com.appdna.sdk/events/onboarding", binaryMessenger: messenger
        )
        let onboardingForwarder = OnboardingDelegateForwarder()
        onboardingForwarder.invoker = syncInvoker
        instance.onboardingForwarder = onboardingForwarder
        onboardingChannel.setStreamHandler(onboardingForwarder)

        let paywallChannel = FlutterEventChannel(
            name: "com.appdna.sdk/events/paywall", binaryMessenger: messenger
        )
        let paywallForwarder = PaywallDelegateForwarder()
        paywallForwarder.invoker = syncInvoker
        instance.paywallForwarder = paywallForwarder
        paywallChannel.setStreamHandler(paywallForwarder)

        let surveyChannel = FlutterEventChannel(
            name: "com.appdna.sdk/events/survey", binaryMessenger: messenger
        )
        let surveyForwarder = SurveyDelegateForwarder()
        instance.surveyForwarder = surveyForwarder
        surveyChannel.setStreamHandler(surveyForwarder)

        let inAppMessageChannel = FlutterEventChannel(
            name: "com.appdna.sdk/events/in_app_message", binaryMessenger: messenger
        )
        let inAppMessageForwarder = InAppMessageDelegateForwarder()
        inAppMessageForwarder.invoker = syncInvoker
        instance.inAppMessageForwarder = inAppMessageForwarder
        inAppMessageChannel.setStreamHandler(inAppMessageForwarder)

        let pushChannel = FlutterEventChannel(
            name: "com.appdna.sdk/events/push", binaryMessenger: messenger
        )
        let pushForwarder = PushDelegateForwarder()
        instance.pushForwarder = pushForwarder
        pushChannel.setStreamHandler(pushForwarder)

        let billingEventChannel = FlutterEventChannel(
            name: "com.appdna.sdk/events/billing", binaryMessenger: messenger
        )
        let billingDelegateForwarder = BillingDelegateForwarder()
        instance.billingDelegateForwarder = billingDelegateForwarder
        billingEventChannel.setStreamHandler(billingDelegateForwarder)

        let deepLinkChannel = FlutterEventChannel(
            name: "com.appdna.sdk/events/deep_link", binaryMessenger: messenger
        )
        let deepLinkForwarder = DeepLinkDelegateForwarder()
        deepLinkForwarder.invoker = syncInvoker
        instance.deepLinkForwarder = deepLinkForwarder
        deepLinkChannel.setStreamHandler(deepLinkForwarder)

        let screenChannel = FlutterEventChannel(
            name: "com.appdna.sdk/events/screen", binaryMessenger: messenger
        )
        let screenForwarder = ScreenDelegateForwarder()
        screenForwarder.invoker = syncInvoker
        instance.screenForwarder = screenForwarder
        screenChannel.setStreamHandler(screenForwarder)

        // SPEC-404 — runtime-lock lifecycle delegate stream (BOTH platforms).
        // onListen assigns the forwarder to the native `weak` lifecycleDelegate;
        // the plugin holds the only strong ref so it isn't deallocated.
        let lifecycleChannel = FlutterEventChannel(
            name: "com.appdna.sdk/events/lifecycle", binaryMessenger: messenger
        )
        let lifecycleForwarder = LifecycleDelegateForwarder()
        instance.lifecycleForwarder = lifecycleForwarder
        lifecycleChannel.setStreamHandler(lifecycleForwarder)

        // SPEC-070-C Phase 2b — register the AppDNAScreenSlot PlatformView
        // factory. The Dart `AppDNAScreenSlot` widget embeds a `UiKitView` with
        // this same viewType; the factory wraps the SwiftUI `AppDNAScreenSlot`
        // in a retained UIHostingController.
        registrar.register(
            AppDNAScreenSlotFactory(),
            withId: "com.appdna.sdk/screen_slot"
        )

        // SPEC-070-C §3.1/§3.14 — the Android-only init-degradation delegate
        // stream. iOS has no `setInitDelegate`; register the channel so the
        // Dart `setInitDelegate` stream subscribe succeeds, but it never emits
        // (documented no-op).
        let initChannel = FlutterEventChannel(
            name: "com.appdna.sdk/events/init", binaryMessenger: messenger
        )
        initChannel.setStreamHandler(NoopStreamHandler())

        // SPEC-070-C M1 — remote-config / feature-flag change streams. On
        // onListen each wires the native `onChanged` observer and emits a bare
        // signal (Dart fires its `onChanged` callback; payload is ignored).
        // FlutterEventChannel retains its stream handler, so no stored ref.
        let remoteConfigChangeChannel = FlutterEventChannel(
            name: "com.appdna.sdk/events/remote_config", binaryMessenger: messenger
        )
        remoteConfigChangeChannel.setStreamHandler(RemoteConfigChangeStreamHandler())

        let featuresChangeChannel = FlutterEventChannel(
            name: "com.appdna.sdk/events/features", binaryMessenger: messenger
        )
        featuresChangeChannel.setStreamHandler(FeaturesChangeStreamHandler())
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "configure":
            let apiKey = args["apiKey"] as! String
            let envStr = args["env"] as? String ?? "production"
            let env: Environment = envStr == "staging" ? .sandbox : .production
            let options = parseOptions(args["options"] as? [String: Any])
            AppDNA.configure(apiKey: apiKey, environment: env, options: options)
            result(nil)

        case "identify":
            let userId = args["userId"] as! String
            let traits = args["traits"] as? [String: Any]
            AppDNA.identify(userId: userId, traits: traits)
            result(nil)

        case "reset":
            AppDNA.reset()
            result(nil)

        case "track":
            let event = args["event"] as! String
            let properties = args["properties"] as? [String: Any]
            AppDNA.track(event: event, properties: properties)
            result(nil)

        case "flush":
            AppDNA.flush()
            result(nil)

        case "presentPaywall":
            let id = args["id"] as! String
            let context = parsePaywallContext(args["context"] as? [String: Any])
            // SPEC-070-C HIGH-1/2 — route through the MODULE present() so the
            // stored paywall delegate (the PaywallDelegateForwarder installed on
            // the events/paywall stream's onListen) is the active delegate. The
            // static `AppDNA.presentPaywall(id:from:context:)` takes its own
            // `delegate:` param (default nil) and would NOT fall back to the
            // module delegate, leaving all 12 host paywall callbacks dead.
            // The module present() resolves the top view controller itself.
            // Bind the forwarder so host hooks/vetoes are live even if the app never subscribed to this stream (same fix as onboarding + presentPaywallByPlacement).
            if let fwd = paywallForwarder { AppDNA.paywall.setDelegate(fwd) }
            // 🔴 `result(nil)` USED TO THROW THE ANSWER AWAY. Native returns false when the id is not
            // published / the SDK is unconfigured / it is runtime-locked, and Dart's `Future<void>`
            // resolved SUCCESSFULLY anyway — telling a Flutter host a paywall had been shown when none
            // had. Hand the Bool across.
            result(AppDNA.paywall.present(id, context: context))

        case "presentOnboarding":
            let flowId = args["flowId"] as? String
            // SPEC-070-C HIGH-1 — route through the MODULE present() so the
            // stored OnboardingDelegateForwarder is the active delegate (the
            // static top-level `presentOnboarding(flowId:)` defaults delegate:nil
            // and would leave all observe + sync_callbacks hooks dead).
            // MEDIUM-1 — forward the host's OnboardingContext (attribution +
            // experimentOverrides). The native module present() currently drops
            // this param (the static presentOnboarding has no context arg), so
            // onboarding experiment-override APPLICATION is a pending native-SDK
            // follow-up affecting native hosts equally; the bridge forwards it
            // faithfully so it flows the moment native threads it.
            let onbCtx = parseOnboardingContext(args["context"] as? [String: Any])
            // Bind the delegate forwarder for the whole flow even if the Dart host
            // never subscribed to the onboarding event stream. The sync_callbacks
            // hooks (esp. onBeforeStepAdvance) must be live whenever onboarding is
            // presented — auth actions (email_login / login / register / OTP …) route
            // through that hook, and the native SDK deliberately STAYS on an auth step
            // when no delegate is bound (handleStepCompleted → requiresDelegate). Before
            // this, an email/social-login step never advanced on Flutter (delegate only
            // got bound in onListen) while it advanced on native. onListen re-sets the
            // same forwarder if the host subscribes; onCancel clears it on unsubscribe.
            if let fwd = onboardingForwarder {
                AppDNA.onboarding.setDelegate(fwd)
            }
            AppDNA.onboarding.present(flowId: flowId, context: onbCtx)
            result(nil)

        case "getRemoteConfig":
            let key = args["key"] as! String
            result(AppDNA.getRemoteConfig(key: key))

        case "isFeatureEnabled":
            let flag = args["flag"] as! String
            result(AppDNA.isFeatureEnabled(flag: flag))

        case "getExperimentVariant":
            let experimentId = args["experimentId"] as! String
            result(AppDNA.getExperimentVariant(experimentId: experimentId))

        case "isInVariant":
            let experimentId = args["experimentId"] as! String
            let variantId = args["variantId"] as! String
            result(AppDNA.isInVariant(experimentId: experimentId, variantId: variantId))

        case "getExperimentConfig":
            let experimentId = args["experimentId"] as! String
            let key = args["key"] as! String
            result(AppDNA.getExperimentConfig(experimentId: experimentId, key: key))

        case "setPushToken":
            // §3.11: the Dart facade sends the raw APNs token as a String — hex
            // or base64. Try hex first, then fall back to base64 (L3).
            if let tokenStr = args["token"] as? String,
               let tokenData = hexStringToData(tokenStr) ?? Data(base64Encoded: tokenStr) {
                AppDNA.setPushToken(tokenData)
            }
            result(nil)

        case "setPushPermission":
            let granted = args["granted"] as? Bool ?? false
            AppDNA.setPushPermission(granted: granted)
            result(nil)

        case "trackPushDelivered":
            let pushId = args["pushId"] as! String
            AppDNA.trackPushDelivered(pushId: pushId)
            result(nil)

        case "trackPushTapped":
            let pushId = args["pushId"] as! String
            let action = args["action"] as? String
            AppDNA.trackPushTapped(pushId: pushId, action: action)
            result(nil)

        case "setConsent":
            let analytics = args["analytics"] as? Bool ?? true
            AppDNA.setConsent(analytics: analytics)
            result(nil)

        case "onReady":
            AppDNA.onReady {
                result(true)
            }

        case "getWebEntitlement":
            if let entitlement = AppDNA.webEntitlement {
                result(entitlement.toMap())
            } else {
                result(nil)
            }

        case "checkDeferredDeepLink":
            AppDNA.checkDeferredDeepLink { deepLink in
                if let deepLink = deepLink {
                    result(deepLink.toMap())
                } else {
                    result(nil)
                }
            }

        case "shutdown":
            // `AppDNA.shutdown()` exists (AppDNA.swift) and flushes the event queue
            // before tearing down. The old comment claiming otherwise was wrong, and
            // this handler silently resolved without shutting anything down.
            AppDNA.shutdown()
            result(nil)

        case "getSdkVersion":
            result(AppDNA.sdkVersion)

        // MARK: - SPEC-070-C Phase 3 — remaining facade method wiring
        // Each case delegates to the current native AppDNASDK 1.0.67 facade.
        // Thin marshalling only (arg unpack -> native call -> map reply).

        case "setLogLevel":
            AppDNA.setLogLevel(parseLogLevel(args["level"] as? String))
            result(nil)

        // Push module.
        case "requestPushPermission":
            Task {
                let granted = await AppDNA.pushModule.requestPermission()
                DispatchQueue.main.async { result(granted) }
            }

        case "getPushToken":
            result(AppDNA.pushModule.getToken())

        // Remote config module.
        case "refreshConfig":
            AppDNA.remoteConfig.refresh()
            result(nil)

        case "getAllRemoteConfig":
            result(AppDNA.remoteConfig.getAll())

        // Features module.
        case "getFeatureVariant":
            let flag = args["flag"] as! String
            result(AppDNA.features.getVariant(flag))

        // Experiments module. Native returns [(experimentId, variant)] tuples;
        // map to the `[{experimentId, variant}]` shape the Dart parser expects.
        case "getExperimentExposures":
            let exposures = AppDNA.experiments.getExposures()
            result(exposures.map { ["experimentId": $0.experimentId, "variant": $0.variant] })

        // In-app messages module.
        case "suppressMessages":
            AppDNA.inAppMessages.suppressDisplay(args["suppress"] as? Bool ?? false)
            result(nil)

        // Surveys module.
        case "presentSurvey":
            let surveyId = args["surveyId"] as! String
            // Bind the forwarder so host hooks/vetoes are live even if the app never subscribed to this stream (same fix as onboarding + presentPaywallByPlacement).
            if let fwd = surveyForwarder { AppDNA.surveys.setDelegate(fwd) }
            AppDNA.surveys.present(surveyId)
            result(nil)

        // Deep links module. Dart passes a raw URL string.
        case "handleDeepLink":
            if let urlStr = args["url"] as? String, let url = URL(string: urlStr) {
                AppDNA.deepLinks.handleURL(url)
            }
            result(nil)

        // Screen (server-driven UI) module. Presentation is fire-and-forget:
        // lifecycle callbacks arrive on the `events/screen` channel via the
        // ScreenDelegateForwarder, so the completion handler is left nil and the
        // method resolves immediately. `context` has no native counterpart on
        // showScreen/showFlow and is intentionally dropped (documented no-op).
        case "showScreen":
            let screenId = args["screenId"] as! String
            // Bind the forwarder so host hooks/vetoes are live even if the app never subscribed to this stream (same fix as onboarding + presentPaywallByPlacement).
            if let fwd = screenForwarder { AppDNA.screenDelegate = fwd }
            AppDNA.showScreen(screenId)
            result(nil)

        case "showScreenFlow":
            let flowId = args["flowId"] as! String
            // Bind the forwarder so host hooks/vetoes are live even if the app never subscribed to this stream (same fix as onboarding + presentPaywallByPlacement).
            if let fwd = screenForwarder { AppDNA.screenDelegate = fwd }
            AppDNA.showFlow(flowId)
            result(nil)

        case "dismissScreen":
            AppDNA.dismissScreen()
            result(nil)

        case "enableScreenNavigationInterception":
            AppDNA.enableNavigationInterception()
            result(nil)

        case "disableScreenNavigationInterception":
            AppDNA.disableNavigationInterception()
            result(nil)

        // Dart sends the screen definition as a Map; native previewScreen takes
        // a JSON string, so serialize before forwarding. iOS returns a
        // ScreenResult via completion (Android returns a Bool) → marshal the
        // ScreenResult back as a map (SPEC-070-C §3.12 / M4).
        case "previewScreen":
            if let jsonStr = jsonString(from: args["json"]) {
                AppDNA.previewScreen(json: jsonStr) { screenResult in
                    let map = AppdnaPlugin.screenResultToMap(screenResult)
                    DispatchQueue.main.async { result(map) }
                }
            } else {
                result(nil)
            }

        // MARK: - SPEC-070-C §3.1 lifecycle / core
        case "registerBackgroundTasks":
            AppDNA.registerBackgroundTasks()
            result(nil)

        case "isConsentGranted":
            result(AppDNA.isConsentGranted())

        // Both natives return the diagnostic report String (iOS diagnose() was
        // made -> String for parity with Android) → Dart facade yields it on both.
        case "diagnose":
            result(AppDNA.diagnose())

        case "getUserTraits":
            result(AppDNA.getUserTraits())

        // SPEC-070-C §3.1 — app-defined session data (SPEC-088).
        case "setSessionData":
            let sdKey = args["key"] as! String
            if let sdValue = args["value"], !(sdValue is NSNull) {
                AppDNA.setSessionData(key: sdKey, value: sdValue)
            }
            result(nil)
        case "getSessionData":
            result(AppDNA.getSessionData(key: args["key"] as! String))
        case "clearSessionData":
            AppDNA.clearSessionData()
            result(nil)

        // §3.14 iOS no-ops (Android-only forced-theme / init delegate).
        // SPEC-070-C: iOS has no ForcedTheme (verified: 0 hits in the iOS SDK), so these two stay
        // no-ops rather than pretending. `getLastInitError` is no longer among them — see below.
        case "setForcedTheme", "getForcedTheme":
            result(nil)

        // SPEC-070-B PN row 11(b): iOS gained the init-degraded seam in 1.0.70, so this stops being
        // a shim that reports "healthy" for a degraded SDK. Shape matches Android's throwableToMap.
        case "getLastInitError":
            if let err = AppDNA.lastInitError {
                result([
                    "type": String(describing: type(of: err)),
                    "message": err.localizedDescription,
                ])
            } else {
                result(nil)
            }

        // §3.1 brand accent hex — read-only public on BOTH platforms.
        case "getBrandAccentHex":
            result(AppDNA.brandAccentHex)

        // §3.1 runtime lock — pollable read. `BootstrapRuntimeLock {reason,
        // locked_at}` → the same `{reason, locked_at}` map Android emits.
        case "getRuntimeLock":
            if let lock = AppDNA.runtimeLock {
                result(["reason": lock.reason, "locked_at": lock.locked_at])
            } else {
                result(nil)
            }

        // §3.1 iOS no-ops: `currentBundleVersion` is `internal` on iOS (not
        // accessible cross-module from the plugin) and `notificationIcon` is an
        // Android-only option/read → both return nil (§3.1 / §3.14).
        case "getCurrentBundleVersion", "getNotificationIcon":
            result(nil)

        // §3.14 iOS no-op (Android-only zero-code screen attribution).
        case "notifyScreenAppeared":
            result(nil)

        // MARK: - SPEC-070-C §3.3 config
        case "forceRefreshConfig":
            AppDNA.forceRefreshConfig()
            result(nil)

        case "debugAppliedConfigVersion":
            result(AppDNA.debugAppliedConfigVersion(flowId: args["flowId"] as? String))

        // MARK: - SPEC-070-C §3.7 paywall
        // §3.14: iOS has no `presentPaywallByPlacement` — route to the native
        // placement-based `presentPaywall(placement:from:context:)` overload.
        case "presentPaywallByPlacement":
            let placement = args["placement"] as! String
            let ctx = parsePaywallContext(args["context"] as? [String: Any])
            // 🔴 `result(nil)` threw the answer away — see the `presentPaywall` case above. A placement
            // with no authored paywall now reports false instead of a cheerful success.
            guard let vc = UIApplication.shared.topViewController else {
                result(false)
                return
            }
            // SPEC-070-C HIGH-2 — no module-level placement present() exists,
            // so pass the stored forwarder explicitly as the `delegate:` arg
            // to make the host paywall delegate surface live (the static
            // overload otherwise defaults delegate:nil). `paywallForwarder`
            // is created in register() and held strongly; its sink no-ops
            // until the host subscribes to the events/paywall stream.
            result(AppDNA.presentPaywall(placement: placement, from: vc, context: ctx, delegate: paywallForwarder))

        case "showPaywall":
            // SPEC-070-C HIGH-2 — route through the MODULE present() (which
            // resolves the top view controller + forwards the stored delegate).
            // The static `AppDNA.showPaywall(_:)` presents with delegate:nil.
            // Bind the forwarder so host hooks/vetoes are live even if the app never subscribed to this stream (same fix as onboarding + presentPaywallByPlacement).
            if let fwd = paywallForwarder { AppDNA.paywall.setDelegate(fwd) }
            // The module present() returns whether it presented — hand it across instead of nil.
            result(AppDNA.paywall.present(args["id"] as! String))

        case "skipNextAutoDismissOnRestore":
            AppDNA.paywall.skipNextAutoDismissOnRestore = args["value"] as? Bool ?? false
            result(nil)

        // MARK: - SPEC-070-C §3.9 surveys
        case "showSurvey":
            // Bind the forwarder so host hooks/vetoes are live even if the app never subscribed to this stream (same fix as onboarding + presentPaywallByPlacement).
            if let fwd = surveyForwarder { AppDNA.surveys.setDelegate(fwd) }
            AppDNA.showSurvey(args["id"] as! String)
            result(nil)

        // MARK: - SPEC-070-C §3.11 push
        case "registerForPush":
            Task {
                let granted = await AppDNA.registerForPush()
                DispatchQueue.main.async { result(granted) }
            }

        // §3.14 iOS no-ops (Android-only intent-tap / FCM new-token feed).
        case "handlePushTap":
            result(false)
        case "onNewPushToken":
            result(nil)

        // MARK: - SPEC-070-C §3.13 location
        case "getLocationData":
            let fieldId = args["fieldId"] as! String
            if let loc = AppDNA.getLocationData(fieldId: fieldId) {
                result(Self.locationDataToMap(loc))
            } else {
                result(nil)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - SPEC-070-C §3.12 — ScreenResult -> channel map for previewScreen
    // (M4). Same shape the ScreenDelegateForwarder emits on `events/screen`.
    fileprivate static func screenResultToMap(_ r: ScreenResult) -> [String: Any] {
        return ([
            "screenId": r.screenId,
            "dismissed": r.dismissed,
            "responses": r.responses,
            "lastAction": r.lastAction,
            "duration_ms": r.duration_ms,
            "error": r.error?.rawValue
        ] as [String: Any?]).mapValues { $0 ?? NSNull() }
    }

    // MARK: - SPEC-070-C §3.13 — LocationData -> channel map (snake_case keys
    // matching the Dart `LocationData.fromMap` contract).
    private static func locationDataToMap(_ l: LocationData) -> [String: Any] {
        return ([
            "formatted_address": l.formatted_address,
            "city": l.city,
            "state": l.state,
            "state_code": l.state_code,
            "country": l.country,
            "country_code": l.country_code,
            "latitude": l.latitude,
            "longitude": l.longitude,
            "timezone": l.timezone,
            "timezone_offset": l.timezone_offset,
            "postal_code": l.postal_code,
            "raw_query": l.raw_query
        ] as [String: Any?]).mapValues { $0 ?? NSNull() }
    }

    // MARK: - Helpers

    /// Map a Dart log-level string to the native `LogLevel` (default `.warning`).
    private func parseLogLevel(_ level: String?) -> LogLevel {
        switch level {
        case "none": return .none
        case "error": return .error
        case "warning": return .warning
        case "info": return .info
        case "debug": return .debug
        default: return .warning
        }
    }

    /// Serialize a bridged `json` argument (String passthrough, or Map/Array ->
    /// JSON string) for `previewScreen(json:)`. Returns nil if not serializable.
    private func jsonString(from value: Any?) -> String? {
        if let s = value as? String { return s }
        guard let obj = value,
              JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private func hexStringToData(_ hex: String) -> Data? {
        let len = hex.count
        guard len % 2 == 0 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                data.append(byte)
            } else {
                return nil
            }
            index = nextIndex
        }
        return data
    }

    /// The wrapper's attribution tag. A constant, not a parameter — see `parseOptions`.
    static let frameworkTag = "flutter"

    /// ⚠ `internal`, not `private` — SPEC-070-B AC-11's own testability prerequisite. While it was
    /// private, the `framework` tag, the `configTTL` default and the `billingProvider` mapping could
    /// not be reached by any test on this platform: a Dart test mocks the MethodChannel away and sees
    /// neither a Swift `??` nor an injected tag. `RunnerTests.swift` calls it.
    internal func parseOptions(_ dict: [String: Any]?) -> AppDNAOptions {
        // 🔴 This was `return AppDNAOptions()` — the bare native defaults, `framework: "native"`
        // among them. The tag was injected on every OTHER path and dropped on this one, so the
        // no-options path re-created the exact bug §7 rule 1 exists to prevent: a Flutter app whose
        // `options` map never arrives reports itself as a NATIVE app for the life of the process.
        // The envelope schema is `.catch('native')` — a wrong tag does not error, is not logged and
        // is not metered. It just quietly lies in BigQuery.
        guard let dict = dict else { return AppDNAOptions(framework: Self.frameworkTag) }
        let logLevelStr = dict["logLevel"] as? String ?? "warning"
        let logLevel: LogLevel
        switch logLevelStr {
        case "none": logLevel = .none
        case "error": logLevel = .error
        case "warning": logLevel = .warning
        case "info": logLevel = .info
        case "debug": logLevel = .debug
        default: logLevel = .warning
        }

        // billingProvider crosses as a bare string for value-less cases, or a tagged
        // map {"type":"adapty","apiKey":"…"} for the associated-value adapty case
        // (SPEC-070-C §3.1 — BillingProvider.adapty(apiKey:)).
        let billingProvider: BillingProvider
        if let map = dict["billingProvider"] as? [String: Any],
           map["type"] as? String == "adapty" {
            billingProvider = .adapty(apiKey: map["apiKey"] as? String ?? "")
        } else {
            switch dict["billingProvider"] as? String {
            case "revenueCat": billingProvider = .revenueCat
            case "storeKit2": billingProvider = .storeKit2
            case "none": billingProvider = .none
            case "adapty": billingProvider = .adapty(apiKey: "")
            default: billingProvider = .storeKit2
            }
        }

        return AppDNAOptions(
            flushInterval: dict["flushInterval"] as? TimeInterval ?? 30,
            batchSize: dict["batchSize"] as? Int ?? 20,
            // Never a literal: mirror the native default so this cannot drift again.
            configTTL: dict["configTTL"] as? TimeInterval ?? AppDNAOptions().configTTL,
            logLevel: logLevel,
            billingProvider: billingProvider,
            // SPEC-070-B §7 rule 1 — INJECTED, never read from the host's map.
            //
            // This used to be `dict["framework"] as? String ?? "native"`, which had two failure
            // modes and no way to notice either: a host could SPOOF its attribution by passing
            // `framework: 'ios'`, and any path that reached configure without Dart's `toMap()`
            // (which is the only thing that supplies the key) silently fell back to "native" —
            // tagging every Flutter event as a native one. The envelope schema is `.catch('native')`,
            // so a wrong tag does not error, is not logged, and is not metered. It just quietly lies
            // in BigQuery. RN already injects unconditionally; now Flutter does too.
            framework: Self.frameworkTag,
            // SPEC-070-C: wrapper's own version so diagnose() reports per-platform.
            frameworkVersion: dict["frameworkVersion"] as? String,
            // SPEC-070-B PN rows 14 + 16. Never a literal: mirror the native default.
            requireConsent: dict["requireConsent"] as? Bool ?? AppDNAOptions().requireConsent,
            vetoTimeout: dict["vetoTimeout"] as? TimeInterval ?? AppDNAOptions().vetoTimeout
        )
    }

    private func parsePaywallContext(_ dict: [String: Any]?) -> PaywallContext? {
        guard let dict = dict, let placement = dict["placement"] as? String else { return nil }
        return PaywallContext(
            placement: placement,
            experiment: dict["experiment"] as? String,
            variant: dict["variant"] as? String,
            // SPEC-070-B PN row 11(e) / D-s: customData was declared on the Dart side and dropped
            // here. It now reaches native, where it is merged into the `paywall_view` properties.
            customData: dict["customData"] as? [String: Any]
        )
    }

    /// SPEC-070-C §3.6 — build a native OnboardingContext from the Dart map
    /// (source/campaign/referrer/userProperties/experimentOverrides). Keys match
    /// `OnboardingContext.toMap()` on the Dart side.
    private func parseOnboardingContext(_ dict: [String: Any]?) -> OnboardingContext? {
        guard let dict = dict else { return nil }
        return OnboardingContext(
            source: dict["source"] as? String,
            campaign: dict["campaign"] as? String,
            referrer: dict["referrer"] as? String,
            userProperties: dict["userProperties"] as? [String: Any],
            experimentOverrides: dict["experimentOverrides"] as? [String: String]
        )
    }

    // MARK: - Billing method channel handler

    private func handleBilling(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "purchase":
            let productId = args["productId"] as! String
            // `offerToken` is an Android (Play Billing base-plan/offer) concept.
            // iOS StoreKit has no equivalent, so it is accepted from the channel
            // for API symmetry but not forwarded to the native call.
            Task {
                do {
                    // Native signature (AppDNASDK 1.0.67):
                    //   purchase(_ productId: String, options: PurchaseOptions?) -> TransactionInfo
                    // Throws on user-cancel / pending. Mirror the Android
                    // semantics: success -> {status:"purchased", entitlement},
                    // cancel -> {status:"cancelled"}.
                    let transaction = try await AppDNA.billing.purchase(productId)
                    DispatchQueue.main.async {
                        result(transaction.toPurchaseResultMap())
                    }
                } catch {
                    DispatchQueue.main.async {
                        if BillingMappers.isUserCancellation(error) {
                            result(["status": "cancelled"])
                        } else {
                            result(FlutterError(code: "PURCHASE_ERROR", message: error.localizedDescription, details: nil))
                        }
                    }
                }
            }

        case "restorePurchases":
            Task {
                do {
                    // Native `restorePurchases()` now returns restored product IDs
                    // ([String]). To preserve the Dart `List<Entitlement>` contract
                    // we trigger the restore, then return the current entitlements.
                    _ = try await AppDNA.billing.restorePurchases()
                    let entitlements = await AppDNA.billing.getEntitlements()
                    let maps = entitlements.map { $0.toFlutterMap() }
                    DispatchQueue.main.async {
                        result(maps)
                    }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "RESTORE_ERROR", message: error.localizedDescription, details: nil))
                    }
                }
            }

        case "getProducts":
            let productIds = args["productIds"] as? [String] ?? []
            Task {
                do {
                    // Native signature: getProducts(_ ids: [String]) -> [ProductInfo]
                    let products = try await AppDNA.billing.getProducts(productIds)
                    let maps = products.map { $0.toFlutterMap() }
                    DispatchQueue.main.async {
                        result(maps)
                    }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "PRODUCTS_ERROR", message: error.localizedDescription, details: nil))
                    }
                }
            }

        case "hasActiveSubscription":
            Task {
                let hasActive = await AppDNA.billing.hasActiveSubscription()
                DispatchQueue.main.async {
                    result(hasActive)
                }
            }

        case "getEntitlements":
            // Native signature: getEntitlements() async -> [Entitlement].
            // Map via BillingMappers.toFlutterMap() so the keys match the Dart
            // `Entitlement.fromMap` contract (productId/store/status/…).
            Task {
                let entitlements = await AppDNA.billing.getEntitlements()
                let maps = entitlements.map { $0.toFlutterMap() }
                DispatchQueue.main.async {
                    result(maps)
                }
            }

        // SPEC-070-C §3.8 — force-refresh the native entitlement cache.
        case "refreshEntitlementCache":
            Task {
                await AppDNA.billing.refreshEntitlementCache()
                DispatchQueue.main.async { result(nil) }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler (web entitlement events)

    private var didRegisterWebEntitlement = false
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        // SPEC-070-C round-12 — onWebEntitlementChanged APPENDS (no removal API), so
        // register ONCE and only swap the sink on re-listen; else each listen→cancel→
        // listen stacks an observer → duplicate emissions + unbounded growth.
        if !didRegisterWebEntitlement {
            didRegisterWebEntitlement = true
            AppDNA.onWebEntitlementChanged { [weak self] entitlement in
                self?.eventSink?(entitlement?.toMap())
            }
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}

// MARK: - No-op stream handler (§3.14 iOS-side stubs, e.g. init-degradation)

private class NoopStreamHandler: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        return nil
    }
}

// MARK: - SPEC-070-C M1 remote-config / feature-flag change stream handlers
//
// Bridge the native `onChanged` observers to a Flutter EventChannel. iOS's
// `onChanged` APPENDS observers (no removal API), so a `didRegister` guard
// avoids stacking a second observer if the stream re-listens. The emitted
// value is a bare `true` — the Dart side ignores the payload and just fires
// the host callback.

private class RemoteConfigChangeStreamHandler: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    private var didRegister = false
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        if !didRegister {
            didRegister = true
            AppDNA.remoteConfig.onChanged { [weak self] in
                guard let sink = self?.sink else { return }
                if Thread.isMainThread { sink(true) } else { DispatchQueue.main.async { sink(true) } }
            }
        }
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}

private class FeaturesChangeStreamHandler: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    private var didRegister = false
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        if !didRegister {
            didRegister = true
            AppDNA.features.onChanged { [weak self] in
                guard let sink = self?.sink else { return }
                if Thread.isMainThread { sink(true) } else { DispatchQueue.main.async { sink(true) } }
            }
        }
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}

// MARK: - Billing entitlement stream handler

private class BillingEntitlementStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: AppdnaPlugin?
    private var didRegister = false

    init(plugin: AppdnaPlugin) {
        self.plugin = plugin
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.entitlementEventSink = events
        // SPEC-070-C round-12 — onEntitlementsChanged APPENDS (no removal API): register
        // ONCE, swap the sink on re-listen (else duplicate emissions + unbounded growth).
        if !didRegister {
            didRegister = true
            AppDNA.billing.onEntitlementsChanged { [weak self] entitlements in
                let maps = entitlements.map { $0.toFlutterMap() }
                self?.plugin?.entitlementEventSink?(maps)
            }
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.entitlementEventSink = nil
        return nil
    }
}

// MARK: - UIApplication helper

private extension UIApplication {
    var topViewController: UIViewController? {
        guard let scene = connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return nil
        }
        var vc = root
        while let presented = vc.presentedViewController {
            vc = presented
        }
        return vc
    }
}

// MARK: - Delegate Event Forwarders
//
// Each forwarder implements one of the eight native delegate protocols
// AND FlutterStreamHandler. On stream `onListen` it wires itself into
// the native module via `setDelegate(...)`; on `onCancel` it clears the
// delegate. Every callback marshals its arguments into the canonical
// shared payload:
//
//   { "type": "<delegateMethodName>", "args": { "<argName>": <value>, ... } }
//
// and dispatches `eventSink(...)` on the main thread (required by Flutter).
//
// All forwarders are held strongly by `AppdnaPlugin` so they survive the
// iOS SDK's `weak` delegate references.

/// Convenience: serialize a Swift `Error` for Dart consumers.
@inline(__always)
private func errorMap(_ error: Error) -> [String: Any] {
    return [
        "message": error.localizedDescription,
        "type": "\(type(of: error))"
    ]
}

/// Convenience: dispatch a `{type,args}` payload to a sink on main thread.
@inline(__always)
private func sendEvent(_ sink: FlutterEventSink?, type: String, args: [String: Any?]) {
    guard let sink = sink else { return }
    let payload: [String: Any] = [
        "type": type,
        "args": args.mapValues { $0 ?? NSNull() }
    ]
    if Thread.isMainThread {
        sink(payload)
    } else {
        DispatchQueue.main.async {
            sink(payload)
        }
    }
}

// MARK: Onboarding

private class OnboardingDelegateForwarder: NSObject, AppDNAOnboardingDelegate, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    /// SPEC-070-C Phase 2a — native -> Dart invoker for the async return-value
    /// hooks. Injected in `register(...)`. When nil (should not happen once
    /// registered), the hooks fall back to their native SDK defaults.
    weak var invoker: SyncCallbackInvoker?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        AppDNA.onboarding.setDelegate(self)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        AppDNA.onboarding.setDelegate(nil)
        self.sink = nil
        return nil
    }

    func onOnboardingStarted(flowId: String) {
        sendEvent(sink, type: "onOnboardingStarted", args: ["flowId": flowId])
    }

    func onOnboardingStepChanged(flowId: String, stepId: String, stepIndex: Int, totalSteps: Int) {
        sendEvent(sink, type: "onOnboardingStepChanged", args: [
            "flowId": flowId,
            "stepId": stepId,
            "stepIndex": stepIndex,
            "totalSteps": totalSteps
        ])
    }

    func onOnboardingCompleted(flowId: String, responses: [String: Any]) {
        sendEvent(sink, type: "onOnboardingCompleted", args: [
            "flowId": flowId,
            "responses": responses
        ])
    }

    func onOnboardingDismissed(flowId: String, atStep: Int) {
        sendEvent(sink, type: "onOnboardingDismissed", args: [
            "flowId": flowId,
            "atStep": atStep
        ])
    }

    // SPEC-070-C §3.6 — observe-only permission-result callback (native fires
    // this on the onboarding delegate after a runtime permission resolves).
    // Emitted on the observe channel; NOT a sync_callbacks veto.
    func onPermissionResult(flowId: String, stepId: String, permissionType: String, granted: Bool) {
        sendEvent(sink, type: "onPermissionResult", args: [
            "flowId": flowId,
            "stepId": stepId,
            "permissionType": permissionType,
            "granted": granted
        ])
    }

    // SPEC-070-C Phase 2a — async return-value hooks. Each invokes the Dart
    // host over the sync_callbacks channel, awaits the reply (a `[String: Any]?`
    // built by the host from its return DTO), converts it into the concrete
    // native return type, and falls back to the SDK default on nil/timeout.
    func onBeforeStepAdvance(
        flowId: String,
        fromStepId: String,
        stepIndex: Int,
        stepType: String,
        responses: [String: Any],
        stepData: [String: Any]?
    ) async -> StepAdvanceResult {
        guard let invoker = invoker else { return .proceed }
        var args: [String: Any] = [
            "flowId": flowId,
            "fromStepId": fromStepId,
            "stepIndex": stepIndex,
            "stepType": stepType,
            "responses": responses
        ]
        if let stepData = stepData { args["stepData"] = stepData }
        let reply = await invoker.invokeDart("onBeforeStepAdvance", args)
        // 🔴 AN AUTH ACTION MAY ONLY ADVANCE ON AN EXPLICIT, RECOGNISED HOST DECISION.
        //
        // The Flutter plugin ALWAYS binds this forwarder before presenting, so the core renderer's own
        // gate (`delegate == nil`) never fires. Flutter had three ways to advance a credential step
        // unauthenticated: a `nil` reply, a `{}` reply (`map["type"] ?? "proceed"`), and the Dart base
        // class's default `onBeforeStepAdvance` which RETURNS `{}`. Same fix RN got; missing on the SDK
        // that ships on pub.dev.
        if Self.isAuthAction(stepData), !Self.isExplicitDecision(reply) {
            return .block(message: Self.authUnavailableMessage)
        }
        return Self.stepAdvanceResult(from: reply)
    }

    /// Actions that collect/act on a credential and MUST be host-handled before the flow advances.
    /// Kept in sync with React Native + the iOS core `AuthActionPolicy.delegateRequiredActions`.
    private static let authActions: Set<String> = [
        "social_login", "login", "register", "reset_password", "magic_link", "verify_email",
        "resend_verification", "enable_biometric", "email_login", "request_otp", "verify_otp",
        "logout", "change_password", "set_new_password", "delete_account", "update_profile",
    ]

    private static let authUnavailableMessage = "Sign-in isn't available right now. Please try again later."

    private static func isAuthAction(_ stepData: [String: Any]?) -> Bool {
        authActions.contains((stepData?["action"] as? String) ?? "")
    }

    /// A map with a RECOGNISED `type`. A `{}`, the unhandled sentinel, `nil`, a timeout, or an unknown
    /// `type` are all "the host did not answer" — and on an auth action that is never "let them in".
    private static func isExplicitDecision(_ reply: Any?) -> Bool {
        guard let map = reply as? [String: Any] else { return false }
        if map["__appdna_unhandled"] as? Bool == true { return false }
        guard let type = map["type"] as? String else { return false }
        return ["proceed", "proceedWithData", "block", "skipTo", "skipToWithData", "stay"].contains(type)
    }

    func onBeforeStepRender(
        flowId: String,
        stepId: String,
        stepIndex: Int,
        stepType: String,
        responses: [String: Any]
    ) async -> StepConfigOverride? {
        guard let invoker = invoker else { return nil }
        let reply = await invoker.invokeDart("onBeforeStepRender", [
            "flowId": flowId,
            "stepId": stepId,
            "stepIndex": stepIndex,
            "stepType": stepType,
            "responses": responses
        ])
        return Self.stepConfigOverride(from: reply)
    }

    func onElementInteraction(
        flowId: String,
        stepId: String,
        blockId: String,
        action: String,
        value: String?,
        inputValues: [String: Any]
    ) async -> ElementInteractionResult? {
        guard let invoker = invoker else { return nil }
        var args: [String: Any] = [
            "flowId": flowId,
            "stepId": stepId,
            "blockId": blockId,
            "action": action,
            "inputValues": inputValues
        ]
        if let value = value { args["value"] = value }
        let reply = await invoker.invokeDart("onElementInteraction", args)
        return Self.elementInteractionResult(from: reply)
    }

    func onPermissionRequest(_ permissionType: String) async -> PermissionHandling? {
        guard let invoker = invoker else { return nil }
        let reply = await invoker.invokeDart("onPermissionRequest", [
            "permissionType": permissionType
        ])
        return Self.permissionHandling(from: reply)
    }

    // MARK: Dart reply map -> native return DTO conversions
    //
    // Canonical reply shapes (host builds these; native decodes them). Enum
    // return types carry a `type` discriminator; struct return types map
    // field-by-field. Any missing/unknown shape falls back to the SDK default.

    /// `{type:"proceed"}` | `{type:"proceedWithData",data:{…}}` |
    /// `{type:"block",message:String}` | `{type:"skipTo",stepId:String,data:{…}?}` |
    /// `{type:"stay",message:String?}`  →  `StepAdvanceResult` (default `.proceed`).
    private static func stepAdvanceResult(from reply: Any?) -> StepAdvanceResult {
        guard let map = reply as? [String: Any] else { return .proceed }
        switch (map["type"] as? String) ?? "proceed" {
        case "proceedWithData":
            return .proceedWithData(map["data"] as? [String: Any] ?? [:])
        case "block":
            return .block(message: (map["message"] as? String) ?? "")
        case "skipTo":
            let stepId = (map["stepId"] as? String) ?? ""
            if let data = map["data"] as? [String: Any], !data.isEmpty {
                return .skipToWithData(stepId: stepId, data: data)
            }
            return .skipTo(stepId: stepId)
        case "stay":
            return .stay(message: map["message"] as? String)
        default:
            return .proceed
        }
    }

    /// map-or-null → `StepConfigOverride?` (field-by-field; default nil).
    private static func stepConfigOverride(from reply: Any?) -> StepConfigOverride? {
        guard let map = reply as? [String: Any] else { return nil }
        return StepConfigOverride(
            fieldDefaults: map["fieldDefaults"] as? [String: Any],
            title: map["title"] as? String,
            subtitle: map["subtitle"] as? String,
            ctaText: map["ctaText"] as? String,
            // SPEC-448 §B — `layoutOverrides` was removed from the SDK (declared and bridged
            // everywhere, read by nothing). `fieldOptions` replaces it with a typed home for the
            // one real use case: the host supplying a Select's options.
            fieldOptions: decodeFieldOptions(map["fieldOptions"]),
            // SPEC-452 — the `{{hook_data.…}}` payload. Flutter's standard message codec already
            // yields nested `[String: Any]`/`[Any]`, so a direct cast is enough here (unlike the RN
            // bridge, whose nested maps need element-wise decoding).
            dataContext: map["dataContext"] as? [String: Any],
            // SPEC-451 — a one-line forward into the core decoder, which is all a wrapper may be.
            mapRoutes: StepConfigOverride.decodeMapRoutes(map["mapRoutes"])
        )
    }

    /// map-or-null → `ElementInteractionResult?` (default nil). `fieldConfigPatches`
    /// is decoded element-by-element to avoid a brittle nested bridged-dictionary cast.
    private static func elementInteractionResult(from reply: Any?) -> ElementInteractionResult? {
        guard let map = reply as? [String: Any] else { return nil }
        var patches: [String: [String: Any]]? = nil
        if let raw = map["fieldConfigPatches"] as? [String: Any] {
            var out: [String: [String: Any]] = [:]
            for (k, v) in raw {
                if let inner = v as? [String: Any] { out[k] = inner }
            }
            patches = out
        }
        return ElementInteractionResult(
            // #657 — replacement options for a refresh; same decoder as the render-time override.
            fieldOptions: decodeFieldOptions(map["fieldOptions"]),
            fieldConfigPatches: patches,
            inputValuePatches: map["inputValuePatches"] as? [String: Any],
            advance: (map["advance"] as? Bool) ?? false
        )
    }

    /// map-or-null → `PermissionHandling?`. `{type:"handledByHost",granted:Bool}`
    /// short-circuits the OS prompt; anything else → `.proceed`; null → nil
    /// (run the native flow).
    private static func permissionHandling(from reply: Any?) -> PermissionHandling? {
        guard let map = reply as? [String: Any] else { return nil }
        switch (map["type"] as? String) ?? "proceed" {
        case "handledByHost":
            return .handledByHost(granted: (map["granted"] as? Bool) ?? false)
        default:
            return .proceed
        }
    }
}

// MARK: Paywall

private class PaywallDelegateForwarder: NSObject, AppDNAPaywallDelegate, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    /// SPEC-070-C H3 — native -> Dart invoker for the completion-based
    /// `onPromoCodeSubmit` veto. Injected in `register(...)`.
    weak var invoker: SyncCallbackInvoker?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        AppDNA.paywall.setDelegate(self)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        AppDNA.paywall.setDelegate(nil)
        self.sink = nil
        return nil
    }

    func onPaywallPresented(paywallId: String) {
        sendEvent(sink, type: "onPaywallPresented", args: ["paywallId": paywallId])
    }

    func onPaywallAction(paywallId: String, action: PaywallAction) {
        sendEvent(sink, type: "onPaywallAction", args: [
            "paywallId": paywallId,
            "action": action.rawValue
        ])
    }

    func onPaywallPurchaseStarted(paywallId: String, productId: String) {
        sendEvent(sink, type: "onPaywallPurchaseStarted", args: [
            "paywallId": paywallId,
            "productId": productId
        ])
    }

    func onPaywallPurchaseCompleted(paywallId: String, productId: String, transaction: TransactionInfo) {
        sendEvent(sink, type: "onPaywallPurchaseCompleted", args: [
            "paywallId": paywallId,
            "productId": productId,
            "transaction": transactionInfoToMap(transaction)
        ])
    }

    func onPaywallPurchaseFailed(paywallId: String, error: Error) {
        sendEvent(sink, type: "onPaywallPurchaseFailed", args: [
            "paywallId": paywallId,
            "error": errorMap(error)
        ])
    }

    func onPaywallDismissed(paywallId: String) {
        sendEvent(sink, type: "onPaywallDismissed", args: ["paywallId": paywallId])
    }

    func onPromoCodeSubmit(paywallId: String, code: String, completion: @escaping (Bool) -> Void) {
        // SPEC-070-C H3 — route the promo-code validation through the
        // sync_callbacks channel and feed the host's Bool decision back into the
        // native completion. Default REJECT (false) when no invoker / timeout /
        // no host reply, so an absent host never accepts an unvalidated code.
        guard let invoker = invoker else { completion(false); return }
        Task {
            let reply = await invoker.invokeDart("onPromoCodeSubmit", [
                "paywallId": paywallId,
                "code": code
            ])
            let accepted = (reply as? Bool) ?? false
            DispatchQueue.main.async { completion(accepted) }
        }
    }

    func onPostPurchaseDeepLink(paywallId: String, url: String) {
        sendEvent(sink, type: "onPostPurchaseDeepLink", args: [
            "paywallId": paywallId,
            "url": url
        ])
    }

    func onPostPurchaseNextStep(paywallId: String) {
        sendEvent(sink, type: "onPostPurchaseNextStep", args: ["paywallId": paywallId])
    }

    func onPaywallRestoreStarted(paywallId: String) {
        sendEvent(sink, type: "onPaywallRestoreStarted", args: ["paywallId": paywallId])
    }

    func onPaywallRestoreCompleted(paywallId: String, productIds: [String]) {
        sendEvent(sink, type: "onPaywallRestoreCompleted", args: [
            "paywallId": paywallId,
            // Key must match the generated delegate param + Android emit (SPEC-070-C MED-1).
            "restoredProductIds": productIds
        ])
    }

    func onPaywallRestoreFailed(paywallId: String, error: Error) {
        sendEvent(sink, type: "onPaywallRestoreFailed", args: [
            "paywallId": paywallId,
            "error": errorMap(error)
        ])
    }

    private func transactionInfoToMap(_ t: TransactionInfo) -> [String: Any] {
        return [
            "transactionId": t.transactionId,
            "productId": t.productId,
            // SPEC-070-C MED-2 — cross-platform-consistent type: emit epoch-millis
            // as a String (native iOS purchaseDate is a Date; Android's
            // TransactionInfo.purchaseDate is already an epoch-millis String).
            "purchaseDate": String(Int64((t.purchaseDate.timeIntervalSince1970 * 1000).rounded())),
            "environment": t.environment
        ]
    }
}

// MARK: Survey

private class SurveyDelegateForwarder: NSObject, AppDNASurveyDelegate, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        AppDNA.surveys.setDelegate(self)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        AppDNA.surveys.setDelegate(nil)
        self.sink = nil
        return nil
    }

    func onSurveyPresented(surveyId: String) {
        sendEvent(sink, type: "onSurveyPresented", args: ["surveyId": surveyId])
    }

    func onSurveyCompleted(surveyId: String, responses: [SurveyResponse]) {
        let mapped: [[String: Any]] = responses.map { r in
            ["questionId": r.questionId, "answer": r.answer]
        }
        sendEvent(sink, type: "onSurveyCompleted", args: [
            "surveyId": surveyId,
            "responses": mapped
        ])
    }

    func onSurveyDismissed(surveyId: String) {
        sendEvent(sink, type: "onSurveyDismissed", args: ["surveyId": surveyId])
    }
}

// MARK: In-App Message

private class InAppMessageDelegateForwarder: NSObject, AppDNAInAppMessageDelegate, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    /// SPEC-070-C D10 — native -> Dart invoker for the async `shouldShowMessage`
    /// wrapper-veto. Injected in `register(...)`.
    weak var invoker: SyncCallbackInvoker?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        AppDNA.inAppMessages.setDelegate(self)
        // SPEC-070-C D10 — register the async wrapper-veto. The native SDK
        // awaits this in ADDITION to the sync `shouldShowMessage` below. The
        // invoker applies the timeout-default + logs; nil/timeout → allow.
        AppDNA.inAppMessages.asyncShouldShowMessage = { [weak self] messageId in
            guard let invoker = self?.invoker else { return true }
            let reply = await invoker.invokeDart("shouldShowMessage", ["messageId": messageId])
            return (reply as? Bool) ?? true
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        AppDNA.inAppMessages.setDelegate(nil)
        AppDNA.inAppMessages.asyncShouldShowMessage = nil
        self.sink = nil
        return nil
    }

    func onMessageShown(messageId: String, trigger: String) {
        sendEvent(sink, type: "onMessageShown", args: [
            "messageId": messageId,
            "trigger": trigger
        ])
    }

    func onMessageAction(messageId: String, action: String, data: [String: Any]?) {
        sendEvent(sink, type: "onMessageAction", args: [
            "messageId": messageId,
            "action": action,
            "data": data
        ])
    }

    func onMessageDismissed(messageId: String) {
        sendEvent(sink, type: "onMessageDismissed", args: ["messageId": messageId])
    }

    /// VETO method. The real host veto runs through the async wrapper
    /// (`asyncShouldShowMessage`, registered in `onListen`) over the
    /// sync_callbacks channel — the native SDK awaits it in ADDITION to this
    /// synchronous method. This sync path can't await a Dart roundtrip, so it
    /// returns `true` (allow) and defers the decision to the async wrapper.
    func shouldShowMessage(messageId: String) -> Bool {
        return true
    }
}

// MARK: Push

private class PushDelegateForwarder: NSObject, AppDNAPushDelegate, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        AppDNA.pushModule.setDelegate(self)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        AppDNA.pushModule.setDelegate(nil)
        self.sink = nil
        return nil
    }

    func onPushTokenRegistered(token: String) {
        sendEvent(sink, type: "onPushTokenRegistered", args: ["token": token])
    }

    func onPushReceived(notification: PushPayload, inForeground: Bool) {
        sendEvent(sink, type: "onPushReceived", args: [
            "notification": pushPayloadToMap(notification),
            "inForeground": inForeground
        ])
    }

    func onPushTapped(notification: PushPayload, actionId: String?) {
        sendEvent(sink, type: "onPushTapped", args: [
            "notification": pushPayloadToMap(notification),
            "actionId": actionId
        ])
    }

    private func pushPayloadToMap(_ p: PushPayload) -> [String: Any?] {
        var actionMap: [String: Any]? = nil
        if let a = p.action {
            actionMap = ["type": a.type, "value": a.value]
        }
        return [
            "pushId": p.pushId,
            "title": p.title,
            "body": p.body,
            "imageUrl": p.imageUrl,
            "data": p.data,
            "action": actionMap
        ]
    }
}

// MARK: Billing (lifecycle delegate)

private class BillingDelegateForwarder: NSObject, AppDNABillingDelegate, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        AppDNA.billing.setDelegate(self)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        AppDNA.billing.setDelegate(nil)
        self.sink = nil
        return nil
    }

    func onPurchaseCompleted(productId: String, transaction: TransactionInfo) {
        sendEvent(sink, type: "onPurchaseCompleted", args: [
            "productId": productId,
            "transaction": [
                "transactionId": transaction.transactionId,
                "productId": transaction.productId,
                // SPEC-070-C MED-2 — epoch-millis String, matching Android's
                // String-typed TransactionInfo.purchaseDate (see transactionInfoToMap).
                "purchaseDate": String(Int64((transaction.purchaseDate.timeIntervalSince1970 * 1000).rounded())),
                "environment": transaction.environment
            ]
        ])
    }

    func onPurchaseFailed(productId: String, error: Error) {
        sendEvent(sink, type: "onPurchaseFailed", args: [
            "productId": productId,
            "error": errorMap(error)
        ])
    }

    func onEntitlementsChanged(entitlements: [Entitlement]) {
        // SPEC-070-C H2 — emit the Dart `Entitlement.fromMap` contract shape
        // (productId/store/status/expiresAt/isTrial/offerType) via the shared
        // BillingMappers.toFlutterMap(), NOT the raw native field names.
        let mapped: [[String: Any?]] = entitlements.map { $0.toFlutterMap() }
        sendEvent(sink, type: "onEntitlementsChanged", args: [
            "entitlements": mapped
        ])
    }

    func onRestoreCompleted(restoredProducts: [String]) {
        // Key aligned with the Dart delegate param + Android forwarder.
        sendEvent(sink, type: "onRestoreCompleted", args: [
            "restoredProductIds": restoredProducts
        ])
    }
}

// MARK: Lifecycle (SPEC-404 runtime lock)

private class LifecycleDelegateForwarder: NSObject, AppDNALifecycleDelegate, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        AppDNA.lifecycleDelegate = self
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        AppDNA.lifecycleDelegate = nil
        self.sink = nil
        return nil
    }

    // lockedAt is the native ISO-8601 String verbatim — same type Android emits.
    func onSdkRuntimeLocked(reason: String, lockedAt: String) {
        sendEvent(sink, type: "onSdkRuntimeLocked", args: [
            "reason": reason,
            "lockedAt": lockedAt
        ])
    }

    func onSdkRuntimeUnlocked() {
        sendEvent(sink, type: "onSdkRuntimeUnlocked", args: [:])
    }
}

// MARK: Deep Link

private class DeepLinkDelegateForwarder: NSObject, AppDNADeepLinkDelegate, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    /// SPEC-070-C D10 — native -> Dart invoker for the async `shouldOpen`
    /// wrapper-veto. Injected in `register(...)`.
    weak var invoker: SyncCallbackInvoker?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        AppDNA.deepLinks.setDelegate(self)
        // SPEC-070-C D10 — register the NET-NEW async `shouldOpen` veto. The
        // native `handleURL(_:)` awaits this before dispatching the deep link;
        // nil/timeout → allow (open).
        AppDNA.deepLinks.asyncShouldOpen = { [weak self] url, params in
            guard let invoker = self?.invoker else { return true }
            let reply = await invoker.invokeDart("shouldOpen", [
                "url": url.absoluteString,
                "params": params
            ])
            return (reply as? Bool) ?? true
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        AppDNA.deepLinks.setDelegate(nil)
        AppDNA.deepLinks.asyncShouldOpen = nil
        self.sink = nil
        return nil
    }

    func onDeepLinkReceived(url: URL, params: [String: String]) {
        sendEvent(sink, type: "onDeepLinkReceived", args: [
            "url": url.absoluteString,
            "params": params
        ])
    }
}

// MARK: Screen
//
// The Screen delegate is held on `AppDNA.screenDelegate` (static weak),
// not via a module-level `setDelegate(...)`. The forwarder is kept alive
// by `AppdnaPlugin` and assigned/cleared on stream lifecycle.

private class ScreenDelegateForwarder: NSObject, AppDNAScreenDelegate, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    /// SPEC-070-C D10 — native -> Dart invoker for the async `onScreenAction`
    /// wrapper-veto. Injected in `register(...)`.
    weak var invoker: SyncCallbackInvoker?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        AppDNA.screenDelegate = self
        // SPEC-070-C D10 — register the async `onScreenAction` veto. The native
        // SDK awaits this before performing the action (its synchronous
        // `onScreenAction` below always returns true); nil/timeout → allow.
        AppDNA.asyncOnScreenAction = { [weak self] screenId, action in
            guard let invoker = self?.invoker else { return true }
            let actionMap: [String: Any?] = self?.sectionActionToMap(action) ?? [:]
            let reply = await invoker.invokeDart("onScreenAction", [
                "screenId": screenId,
                "action": actionMap
            ])
            return (reply as? Bool) ?? true
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        AppDNA.screenDelegate = nil
        AppDNA.asyncOnScreenAction = nil
        self.sink = nil
        return nil
    }

    func onScreenPresented(screenId: String) {
        sendEvent(sink, type: "onScreenPresented", args: ["screenId": screenId])
    }

    func onScreenDismissed(screenId: String, result: ScreenResult) {
        sendEvent(sink, type: "onScreenDismissed", args: [
            "screenId": screenId,
            "result": screenResultToMap(result)
        ])
    }

    func onFlowCompleted(flowId: String, result: FlowResult) {
        sendEvent(sink, type: "onFlowCompleted", args: [
            "flowId": flowId,
            "result": flowResultToMap(result)
        ])
    }

    /// VETO method. The real host veto runs through the async wrapper
    /// (`asyncOnScreenAction`, registered in `onListen`) over the sync_callbacks
    /// channel — the native SDK awaits it before performing the action. This
    /// synchronous path can't await a Dart roundtrip, so it returns `true`
    /// (allow) and defers the decision to the async wrapper.
    func onScreenAction(screenId: String, action: SectionAction) -> Bool {
        return true
    }

    private func screenResultToMap(_ r: ScreenResult) -> [String: Any] {
        return ([
            "screenId": r.screenId,
            "dismissed": r.dismissed,
            "responses": r.responses,
            "lastAction": r.lastAction,
            "duration_ms": r.duration_ms,
            "error": r.error?.rawValue
        ] as [String: Any?]).mapValues { $0 ?? NSNull() }
    }

    private func flowResultToMap(_ r: FlowResult) -> [String: Any] {
        return ([
            "flowId": r.flowId,
            "completed": r.completed,
            "lastScreenId": r.lastScreenId,
            "responses": r.responses,
            "screensViewed": r.screensViewed,
            "duration_ms": r.duration_ms,
            "error": r.error?.rawValue
        ] as [String: Any?]).mapValues { $0 ?? NSNull() }
    }

    /// Encode a `SectionAction` as `{type, value?}` matching the shared
    /// payload contract (Android forwarder encodes the same shape).
    private func sectionActionToMap(_ action: SectionAction) -> [String: Any?] {
        switch action {
        case .next:
            return ["type": "next"]
        case .back:
            return ["type": "back"]
        case .dismiss:
            return ["type": "dismiss"]
        case .navigate(let screenId):
            return ["type": "navigate", "screenId": screenId]
        case .openURL(let url):
            return ["type": "openURL", "url": url]
        case .openWebview(let url):
            return ["type": "openWebview", "url": url]
        case .openAppSettings:
            return ["type": "openAppSettings"]
        case .share(let text):
            return ["type": "share", "text": text]
        case .deepLink(let url):
            return ["type": "deepLink", "url": url]
        case .showPaywall(let id):
            return ["type": "showPaywall", "id": id]
        case .showSurvey(let id):
            return ["type": "showSurvey", "id": id]
        case .showScreen(let id):
            return ["type": "showScreen", "id": id]
        case .submitForm(let data):
            return ["type": "submitForm", "data": data]
        case .track(let event, let properties):
            return ["type": "track", "event": event, "properties": properties]
        case .haptic(let type):
            return ["type": "haptic", "hapticType": type]
        case .custom(let type, let value):
            return ["type": "custom", "customType": type, "value": value]
        // Flow-level verbs. Discriminators + field names are Android's `toActionMap`
        // (`screens/SectionContext.kt:94-103`) verbatim, so the veto payload stays byte-identical.
        case .restart:
            return ["type": "restart"]
        case .complete:
            return ["type": "complete"]
        case .setResponse(let key, let value):
            return ["type": "setResponse", "key": key, "value": value]
        case .presentPaywall(let id):
            return ["type": "presentPaywall", "id": id]
        case .dismissPaywall:
            return ["type": "dismissPaywall"]
        case .showMessage(let id):
            return ["type": "showMessage", "id": id]
        case .setUserProperty(let key, let value):
            return ["type": "setUserProperty", "key": key, "value": value]
        case .purchase(let productId):
            return ["type": "purchase", "productId": productId]
        case .restore:
            return ["type": "restore"]
        }
    }
}

/// SPEC-448 §B — `[blockId: [option maps]]` from the channel into typed options.
///
/// Decoded through `JSONDecoder` against the SAME `InputOption` the config parser uses, rather
/// than hand-mapped fields: a hand-mapped copy here would drift from the DTO the first time a
/// field was added, and the host's options would quietly lose it.
private func decodeFieldOptions(_ raw: Any?) -> [String: [InputOption]]? {
    guard let byBlock = raw as? [String: Any] else { return nil }
    var out: [String: [InputOption]] = [:]
    for (blockId, list) in byBlock {
        guard let arr = list as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: arr),
              let options = try? JSONDecoder().decode([InputOption].self, from: data)
        else { continue }
        out[blockId] = options
    }
    return out.isEmpty ? nil : out
}
