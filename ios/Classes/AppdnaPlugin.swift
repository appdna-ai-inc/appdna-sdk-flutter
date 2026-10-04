import Flutter
import UIKit
import AppDNASDK

public class AppdnaPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private var billingChannel: FlutterMethodChannel?
    // Internal (not public) so BillingEntitlementStreamHandler can route the entitlement stream
    // through it and RunnerTests can drive it.
    var entitlementEventSink: FlutterEventSink?
    // Held so `configure` can re-attach it: native `shutdown()` drops every entitlement handler.
    var entitlementStreamHandler: BillingEntitlementStreamHandler?

    // MARK: - Delegate forwarders (strong references so they are NOT
    // deallocated — the iOS SDK holds delegates with `weak` semantics on
    // most surfaces and `static weak` on push/billing/screen).
    private var onboardingForwarder: OnboardingDelegateForwarder?
    // Native -> Dart invoker for the sync_callbacks
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
    // Held strongly here; `AppDNA.lifecycleDelegate` is `weak`.
    private var lifecycleForwarder: LifecycleDelegateForwarder?
    private var initForwarder: InitDelegateForwarder?

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
        let entitlementStreamHandler = BillingEntitlementStreamHandler(plugin: instance)
        instance.entitlementStreamHandler = entitlementStreamHandler
        entitlementEventChannel.setStreamHandler(entitlementStreamHandler)

        // MARK: - Delegate event channels (native -> Dart)
        // Each forwarder implements the corresponding native delegate
        // protocol AND FlutterStreamHandler. On stream onListen the
        // forwarder is wired to the native module via setDelegate(...);
        // on onCancel the delegate is cleared.
        let messenger = registrar.messenger()

        // sync_callbacks MethodChannel (native -> Dart).
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

        // Runtime-lock lifecycle delegate stream (BOTH platforms).
        // onListen assigns the forwarder to the native `weak` lifecycleDelegate;
        // the plugin holds the only strong ref so it isn't deallocated.
        let lifecycleChannel = FlutterEventChannel(
            name: "com.appdna.sdk/events/lifecycle", binaryMessenger: messenger
        )
        let lifecycleForwarder = LifecycleDelegateForwarder()
        instance.lifecycleForwarder = lifecycleForwarder
        lifecycleChannel.setStreamHandler(lifecycleForwarder)

        // Register the AppDNAScreenSlot PlatformView
        // factory. The Dart `AppDNAScreenSlot` widget embeds a `UiKitView` with
        // this same viewType; the factory wraps the SwiftUI `AppDNAScreenSlot`
        // in a retained UIHostingController.
        registrar.register(
            AppDNAScreenSlotFactory(),
            withId: "com.appdna.sdk/screen_slot"
        )

        // The init-degradation delegate stream (BOTH platforms). onListen makes the
        // forwarder the native `AppDNA.initDelegate` — which replays a degradation
        // that already happened — and each `onInitDegraded` goes to Dart as
        // `{error: {message, type}}`, the shape Android sends. The plugin holds
        // the forwarder; the channel retains it too.
        let initChannel = FlutterEventChannel(
            name: "com.appdna.sdk/events/init", binaryMessenger: messenger
        )
        let initForwarder = makeInitStreamHandler()
        instance.initForwarder = initForwarder
        initChannel.setStreamHandler(initForwarder)

        // Remote-config / feature-flag change streams. On
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

    /// The init event channel's stream handler (`register` installs it; RunnerTests drives it).
    static func makeInitStreamHandler() -> InitDelegateForwarder { InitDelegateForwarder() }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "configure":
            let apiKey = args["apiKey"] as! String
            let envStr = args["env"] as? String ?? "production"
            let env: Environment = envStr == "staging" ? .sandbox : .production
            let options = parseOptions(args["options"] as? [String: Any])
            // Every Flutter hook honours the host's vetoTimeout (it used to reach only
            // diagnose()). The forwarders share this invoker, so one write covers them all; parseOptions
            // has already mapped a non-positive value to the native default.
            syncInvoker?.timeout = options.vetoTimeout
            AppDNA.configure(apiKey: apiKey, environment: env, options: options)
            // Native `shutdown()` drops every entitlement and web-entitlement handler, so a stream that
            // is still listening after `shutdown()` → `configure()` must register again, or it goes
            // silent for the rest of the process (it used to: a `didRegister` latch never re-opened).
            reattachStreams()
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
            // Route through the MODULE present() so the
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
            // Route through the MODULE present() so the
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
            // 🔴 This used to `result(nil)` and drop the module's Bool, so Dart could not tell
            // "presented" from "that flow id is not in the published config" (or "no view
            // controller to present from"). Report it rather than discarding it.
            result(AppDNA.onboarding.present(flowId: flowId, context: onbCtx))

        // A thin forward; the identity and the no-op-before-configure rule live in the
        // native SDK, the only place they can be enforced for all four wrappers.
        case "reportPayingUser":
            AppDNA.reportPayingUser(
                productId: args["productId"] as? String,
                priceCents: args["priceCents"] as? Int,
                currency: args["currency"] as? String
            )
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
            // The Dart facade sends the raw APNs token as a String — hex
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

        // MARK: - remaining facade method wiring
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
        // `showScreen`/`showFlow` return Void natively, so the only honest answer here is whether
        // there was a view controller to present from — exactly what the RN module resolves
        // (`AppdnaModuleImpl.swift`). The screen's real RESULT arrives on `onScreenDismissed`.
        case "showScreen":
            let screenId = args["screenId"] as! String
            guard AppDNA.topViewController() != nil else { result(false); return }
            // Bind the forwarder so host hooks/vetoes are live even if the app never subscribed to this stream (same fix as onboarding + presentPaywallByPlacement).
            if let fwd = screenForwarder { AppDNA.screenDelegate = fwd }
            AppDNA.showScreen(screenId)
            result(true)

        case "showScreenFlow":
            let flowId = args["flowId"] as! String
            guard AppDNA.topViewController() != nil else { result(false); return }
            // Bind the forwarder so host hooks/vetoes are live even if the app never subscribed to this stream (same fix as onboarding + presentPaywallByPlacement).
            if let fwd = screenForwarder { AppDNA.screenDelegate = fwd }
            AppDNA.showFlow(flowId)
            result(true)

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
        // ScreenResult back as a map.
        case "previewScreen":
            if let jsonStr = jsonString(from: args["json"]) {
                AppDNA.previewScreen(json: jsonStr) { screenResult in
                    let map = AppdnaPlugin.screenResultToMap(screenResult)
                    DispatchQueue.main.async { result(map) }
                }
            } else {
                result(nil)
            }

        // MARK: - lifecycle / core
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

        // App-defined session data.
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

        // iOS no-ops (Android-only forced-theme / init delegate).
        // iOS has no ForcedTheme (verified: 0 hits in the iOS SDK), so these two stay
        // no-ops rather than pretending. `getLastInitError` is no longer among them — see below.
        case "setForcedTheme", "getForcedTheme":
            result(nil)

        // iOS gained the init-degraded seam in 1.0.70, so this stops being
        // a shim that reports "healthy" for a degraded SDK. Shape matches Android's throwableToMap.
        case "getLastInitError":
            if let err = AppDNA.lastInitError {
                result([
                    "type": initErrorTypeName(err),
                    "message": err.localizedDescription,
                ])
            } else {
                result(nil)
            }

        // Brand accent hex — read-only public on BOTH platforms.
        case "getBrandAccentHex":
            result(AppDNA.brandAccentHex)

        // Runtime lock — pollable read. `BootstrapRuntimeLock {reason,
        // locked_at}` → the same `{reason, locked_at}` map Android emits.
        case "getRuntimeLock":
            if let lock = AppDNA.runtimeLock {
                result(["reason": lock.reason, "locked_at": lock.locked_at])
            } else {
                result(nil)
            }

        // iOS no-ops: `currentBundleVersion` is `internal` on iOS (not
        // accessible cross-module from the plugin) and `notificationIcon` is an
        // Android-only option/read → both return nil.
        case "getCurrentBundleVersion", "getNotificationIcon":
            result(nil)

        // iOS no-op (Android-only zero-code screen attribution).
        case "notifyScreenAppeared":
            result(nil)

        // MARK: - config
        case "forceRefreshConfig":
            AppDNA.forceRefreshConfig()
            result(nil)

        case "debugAppliedConfigVersion":
            result(AppDNA.debugAppliedConfigVersion(flowId: args["flowId"] as? String))

        // MARK: - paywall
        // iOS has no `presentPaywallByPlacement` — route to the native
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
            // No module-level placement present() exists,
            // so pass the stored forwarder explicitly as the `delegate:` arg
            // to make the host paywall delegate surface live (the static
            // overload otherwise defaults delegate:nil). `paywallForwarder`
            // is created in register() and held strongly; its sink no-ops
            // until the host subscribes to the events/paywall stream.
            result(AppDNA.presentPaywall(placement: placement, from: vc, context: ctx, delegate: paywallForwarder))

        case "showPaywall":
            // Route through the MODULE present() (which
            // resolves the top view controller + forwards the stored delegate).
            // The static `AppDNA.showPaywall(_:)` presents with delegate:nil.
            // Bind the forwarder so host hooks/vetoes are live even if the app never subscribed to this stream (same fix as onboarding + presentPaywallByPlacement).
            if let fwd = paywallForwarder { AppDNA.paywall.setDelegate(fwd) }
            // The module present() returns whether it presented — hand it across instead of nil.
            result(AppDNA.paywall.present(args["id"] as! String))

        case "skipNextAutoDismissOnRestore":
            AppDNA.paywall.skipNextAutoDismissOnRestore = args["value"] as? Bool ?? false
            result(nil)

        // MARK: - surveys
        case "showSurvey":
            // Bind the forwarder so host hooks/vetoes are live even if the app never subscribed to this stream (same fix as onboarding + presentPaywallByPlacement).
            if let fwd = surveyForwarder { AppDNA.surveys.setDelegate(fwd) }
            AppDNA.showSurvey(args["id"] as! String)
            result(nil)

        // MARK: - push
        case "registerForPush":
            Task {
                let granted = await AppDNA.registerForPush()
                DispatchQueue.main.async { result(granted) }
            }

        // iOS no-ops (Android-only intent-tap / FCM new-token feed). On iOS the SDK's notification
        // proxy tracks and routes taps itself, and a host that owns its notification handling
        // forwards through `push.handleTap` below.
        case "handlePushTap":
            result(false)
        case "onNewPushToken":
            result(nil)

        // The forwarding API for a host that owns its push handling. Classification
        // and handling are native; on iOS the data passes through UNTOUCHED (nested `action` /
        // `actions` stay dictionaries / arrays). Every call is marker-gated in the core: a push without
        // `appdna: "1"` returns false and does nothing.
        case "push.isAppDNAMessage":
            result(AppDNA.pushModule.isAppDNAMessage(Self.pushData(args)))
        case "push.handleMessageData":
            // iOS has no display path: `handleMessage` IS `handleMessageData` here.
            result(AppDNA.pushModule.handleMessageData(Self.pushData(args)))
        case "push.handleTap":
            result(AppDNA.pushModule.handleNotificationTap(
                Self.pushData(args), actionIdentifier: args["actionId"] as? String
            ))

        // MARK: - location
        case "getLocationData":
            guard let fieldId = args["fieldId"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "getLocationData needs a String fieldId", details: nil))
                return
            }
            if let loc = AppDNA.getLocationData(fieldId: fieldId) {
                result(Self.locationDataToMap(loc))
            } else {
                result(nil)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// The push payload of a `push.*` call, as the channel delivered it (no conversion on iOS).
    private static func pushData(_ args: [String: Any]) -> [AnyHashable: Any] {
        return (args["data"] as? [String: Any]) ?? [:]
    }

    // MARK: - ScreenResult -> channel map for previewScreen
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

    // MARK: - LocationData -> channel map (snake_case keys
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

    /// ⚠ `internal`, not `private` — its own testability prerequisite. While it was
    /// private, the `framework` tag, the `configTTL` default and the `billingProvider` mapping could
    /// not be reached by any test on this platform: a Dart test mocks the MethodChannel away and sees
    /// neither a Swift `??` nor an injected tag. `RunnerTests.swift` calls it.
    internal func parseOptions(_ dict: [String: Any]?) -> AppDNAOptions {
        // 🔴 This was `return AppDNAOptions()` — the bare native defaults, `framework: "native"`
        // among them. The tag was injected on every OTHER path and dropped on this one, so the
        // no-options path re-created the exact bug the framework tag exists to prevent: a Flutter app whose
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
        // (BillingProvider.adapty(apiKey:)).
        let billingProvider = Self.parseBillingProvider(dict["billingProvider"])

        // A non-numeric, zero or negative vetoTimeout is the native default, here,
        // so diagnose() and the bridge's invoker agree on the value actually applied.
        let vetoTimeout: TimeInterval = {
            if let t = (dict["vetoTimeout"] as? NSNumber)?.doubleValue, t > 0 { return t }
            return AppDNAOptions().vetoTimeout
        }()

        return AppDNAOptions(
            // Passed only when the host set them: a value filled in here would read as the host's own
            // choice and beat the bootstrap's `settings` (native resolves host > bootstrap > default).
            flushInterval: dict["flushInterval"] as? TimeInterval,
            batchSize: dict["batchSize"] as? Int,
            configTTL: dict["configTTL"] as? TimeInterval,
            logLevel: logLevel,
            billingProvider: billingProvider,
            // INJECTED, never read from the host's map.
            //
            // This used to be `dict["framework"] as? String ?? "native"`, which had two failure
            // modes and no way to notice either: a host could SPOOF its attribution by passing
            // `framework: 'ios'`, and any path that reached configure without Dart's `toMap()`
            // (which is the only thing that supplies the key) silently fell back to "native" —
            // tagging every Flutter event as a native one. The envelope schema is `.catch('native')`,
            // so a wrong tag does not error, is not logged, and is not metered. It just quietly lies
            // in BigQuery. RN already injects unconditionally; now Flutter does too.
            framework: Self.frameworkTag,
            // Wrapper's own version so diagnose() reports per-platform.
            frameworkVersion: dict["frameworkVersion"] as? String,
            // PN rows 14 + 16. Never a literal: mirror the native default.
            requireConsent: dict["requireConsent"] as? Bool ?? AppDNAOptions().requireConsent,
            vetoTimeout: vetoTimeout
        )
    }

    /// The provider through the core's `BillingProvider.fromWire`, like every other
    /// bridge. It used to be parsed here by hand, and a bare `"adapty"` or a key-less map became
    /// `.adapty(apiKey: "")`. A value `fromWire` refuses (key-less Adapty, an unknown string) falls back
    /// to the default `.storeKit2`, with a warning; an absent value is the default silently.
    internal static func parseBillingProvider(_ value: Any?) -> BillingProvider {
        guard let value = value, !(value is NSNull) else { return .storeKit2 }
        if let provider = BillingProvider.fromWire(value) { return provider }
        NSLog("[AppDNA] billingProvider \(value) is not usable (Adapty needs a non-empty apiKey) — falling back to storeKit2")
        return .storeKit2
    }

    private func parsePaywallContext(_ dict: [String: Any]?) -> PaywallContext? {
        guard let dict = dict, let placement = dict["placement"] as? String else { return nil }
        return PaywallContext(
            placement: placement,
            experiment: dict["experiment"] as? String,
            variant: dict["variant"] as? String,
            // customData was declared on the Dart side and dropped
            // here. It now reaches native, where it is merged into the `paywall_view` properties.
            customData: dict["customData"] as? [String: Any]
        )
    }

    /// Build a native OnboardingContext from the Dart map
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
                    // `getEntitlements()` reads the device's StoreKit set (no network): the purchased product's
                    // entry and its real expiry are there as soon as `purchase` returns. It never depended on
                    // the post-purchase refresh, which `purchase` now queues instead of awaiting (it reads
                    // `/billing/entitlements`); server-only rows arriving later reach `onEntitlementsChanged`,
                    // never this result.
                    let entitlements = await AppDNA.billing.getEntitlements()
                    DispatchQueue.main.async {
                        result(transaction.toPurchaseResultMap(entitlements: entitlements))
                    }
                } catch {
                    DispatchQueue.main.async {
                        if BillingMappers.isUserCancellation(error) {
                            result(["status": "cancelled"])
                        } else {
                            // The code stays PURCHASE_ERROR (hosts match it); `details`
                            // carries the stable `errorType` (was nil).
                            result(FlutterError(code: "PURCHASE_ERROR", message: error.localizedDescription,
                                                details: BillingMappers.errorDetails(error)))
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
                        // Restore error contract — `details.errorType`, as on Android.
                        result(FlutterError(code: "RESTORE_ERROR", message: error.localizedDescription,
                                            details: BillingMappers.errorDetails(error)))
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

        // Force-refresh the native entitlement cache.
        case "refreshEntitlementCache":
            Task {
                await AppDNA.billing.refreshEntitlementCache()
                DispatchQueue.main.async { result(nil) }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Re-register the entitlement streams that are listening. Called after every `configure`.
    /// Internal (not private) so RunnerTests can drive the shutdown → configure sequence.
    func reattachStreams() {
        if eventSink != nil { attachWebEntitlement() }
        entitlementStreamHandler?.reattachIfListening()
    }

    // MARK: - FlutterStreamHandler (web entitlement events)

    /// The native handler token. REMOVE-then-ADD on every attach: the native registry appends, so a
    /// plain re-add would stack a second handler (duplicate emissions); a latch that never re-registers
    /// went silent after `shutdown()` → `configure()`, because native `shutdown()` drops the handlers.
    /// Removing a token native already dropped is a no-op.
    private var webEntitlementToken: UUID?

    private func attachWebEntitlement() {
        if let token = webEntitlementToken { AppDNA.removeWebEntitlementChangedHandler(token) }
        webEntitlementToken = AppDNA.onWebEntitlementChanged { [weak self] entitlement in
            self?.eventSink?(entitlement?.toMap())
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        attachWebEntitlement()
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        if let token = webEntitlementToken { AppDNA.removeWebEntitlementChangedHandler(token) }
        webEntitlementToken = nil
        return nil
    }
}

// MARK: - remote-config / feature-flag change stream handlers
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

/// The ONE source of the Dart `billing.onEntitlementsChanged` stream: the native closure API
/// (`AppDNA.billing.onEntitlementsChanged`). The billing delegate's `onEntitlementsChanged` goes to
/// the delegate channel only (`BillingDelegateForwarder`), never to this stream, so a native change
/// that fires both the closure and the delegate emits once on each surface — never twice here.
class BillingEntitlementStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: AppdnaPlugin?
    /// The native handler token. REMOVE-then-ADD on every attach (see `attachWebEntitlement`): a
    /// `didRegister` latch here used to stay set after `shutdown()` — which drops every native
    /// handler — so the stream went silent after `shutdown()` → `configure()`.
    private(set) var token: UUID?

    init(plugin: AppdnaPlugin) {
        self.plugin = plugin
    }

    func attach() {
        if let token = token { AppDNA.billing.removeEntitlementsChangedHandler(token) }
        token = AppDNA.billing.onEntitlementsChanged { [weak self] entitlements in
            let maps = entitlements.map { $0.toFlutterMap() }
            self?.plugin?.entitlementEventSink?(maps)
        }
    }

    /// After `configure`: re-register only while Dart is listening.
    func reattachIfListening() {
        if plugin?.entitlementEventSink != nil { attach() }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.entitlementEventSink = events
        attach()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.entitlementEventSink = nil
        if let token = token { AppDNA.billing.removeEntitlementsChangedHandler(token) }
        token = nil
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

/// Internal (not `private`) so `RunnerTests` can reach the step-advance decoder and auth gate.
class OnboardingDelegateForwarder: NSObject, AppDNAOnboardingDelegate, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    /// Native -> Dart invoker for the async return-value
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

    // Observe-only permission-result callback (native fires
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

    // Async return-value hooks. Each invokes the Dart
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
        // No invoker means nobody can answer — and silence never lets a sign-in action through (the
        // same rule as the reply gate below). Every other step keeps the native default.
        guard let invoker = invoker else {
            return Self.isAuthAction(stepData) ? .block(message: Self.authUnavailableMessage) : .proceed
        }
        var args: [String: Any] = [
            "flowId": flowId,
            "fromStepId": fromStepId,
            "stepIndex": stepIndex,
            "stepType": stepType,
            "responses": responses
        ]
        if let stepData = stepData { args["stepData"] = stepData }
        // A sign-in action spans OS UI the host cannot shorten, so the bridge waits at
        // least the core floor (120 s) for it; every other step keeps the configured vetoTimeout.
        let timeout = max(invoker.timeout, StepAdvanceResult.minimumBridgeTimeout(stepData: stepData) ?? 0)
        let reply = await invoker.invokeDart("onBeforeStepAdvance", args, timeout: timeout)
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
    static let authActions: Set<String> = [
        "social_login", "login", "register", "reset_password", "magic_link", "verify_email",
        "resend_verification", "enable_biometric", "email_login", "request_otp", "verify_otp",
        "logout", "change_password", "set_new_password", "delete_account", "update_profile",
    ]

    static let authUnavailableMessage = "Sign-in isn't available right now. Please try again later."

    static func isAuthAction(_ stepData: [String: Any]?) -> Bool {
        authActions.contains((stepData?["action"] as? String) ?? "")
    }

    /// A map with a RECOGNISED `type`. A `{}`, the unhandled sentinel, `nil`, a timeout, or an unknown
    /// `type` are all "the host did not answer" — and on an auth action that is never "let them in".
    /// A `skipTo` without a usable `stepId` is not a decision either. One rule, in the core.
    static func isExplicitDecision(_ reply: Any?) -> Bool {
        StepAdvanceResult.isExplicitBridgeDecision(reply)
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
        // Wait at least as long as core's deadline for this action (8 s for a
        // `refresh`), so the bridge never cuts a slow "Show more" short. One line; the rule is core's.
        let timeout = max(invoker.timeout, ElementInteractionResult.minimumBridgeTimeout(action: action) ?? 0)
        let reply = await invoker.invokeDart("onElementInteraction", args, timeout: timeout)
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
    static func stepAdvanceResult(from reply: Any?) -> StepAdvanceResult {
        guard let map = reply as? [String: Any] else { return .proceed }
        switch (map["type"] as? String) ?? "proceed" {
        case "proceedWithData":
            return .proceedWithData(map["data"] as? [String: Any] ?? [:])
        case "block":
            return .block(message: (map["message"] as? String) ?? "")
        // `skipToWithData` is an ACCEPTED ALIAS of `skipTo`, not a second encoding — the canonical wire
        // shape is `{type:"skipTo", stepId, data?}` and `data` promotes it. It is in `isExplicitDecision`'s
        // list (so the auth gate treats it as an explicit answer), but without a case here it fell to
        // `default: .proceed` and ADVANCED the step instead of skipping. Mirrors Flutter Android and RN.
        case "skipTo", "skipToWithData":
            let data = map["data"] as? [String: Any]
            // A missing / blank `stepId` names no step: not a skip (it used to decode to `skipTo("")`).
            guard let stepId = StepAdvanceResult.bridgeSkipTarget(reply: map) else {
                if let data, !data.isEmpty { return .proceedWithData(data) }
                return .proceed
            }
            if let data, !data.isEmpty {
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
            // `layoutOverrides` was removed from the SDK (declared and bridged
            // everywhere, read by nothing). `fieldOptions` replaces it with a typed home for the
            // one real use case: the host supplying a Select's options.
            fieldOptions: decodeFieldOptions(map["fieldOptions"]),
            // The `{{hook_data.…}}` payload. Flutter's standard message codec already
            // yields nested `[String: Any]`/`[Any]`, so a direct cast is enough here (unlike the RN
            // bridge, whose nested maps need element-wise decoding).
            dataContext: map["dataContext"] as? [String: Any],
            // A one-line forward into the core decoder, which is all a wrapper may be.
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
        // 🔴 ARGUMENT ORDER IS PART OF THE CALL IN SWIFT. This read
        // `fieldOptions:` first, and `ElementInteractionResult.init` declares
        // `(fieldConfigPatches:, inputValuePatches:, fieldOptions:, advance:)` —
        // so this file DID NOT COMPILE ("Argument 'fieldConfigPatches' must
        // precede argument 'fieldOptions'") from the moment the call was
        // written. Nothing caught it because nothing compiled the plugin's iOS
        // side: `flutter analyze`/`flutter test` are Dart and the CI step
        // compiles only the Kotlin half. A wrapper host building for iOS would
        // have been the first to find out.
        return ElementInteractionResult(
            fieldConfigPatches: patches,
            inputValuePatches: map["inputValuePatches"] as? [String: Any],
            // #657 — replacement options for a refresh; same decoder as the render-time override.
            fieldOptions: decodeFieldOptions(map["fieldOptions"]),
            advance: (map["advance"] as? Bool) ?? false,
            // A one-line forward into the CORE decoder (last: Swift argument order
            // is part of the call). It keeps null members as removal markers; a plain cast would not
            // survive a bridged nested map.
            dataContext: ElementInteractionResult.decodeDataContext(map["dataContext"])
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
    /// Native -> Dart invoker for the completion-based
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

    // Every native caller uses the 4-arg overload; the protocol's default chains
    // 4 → 3 → 2 and drops `errorType` / `productId` on the way, so overriding only the 2-arg one handed
    // Dart `errorType: 'unknown'` and `productId: null` — a host on `revenueCat` could not tell "start the
    // purchase with RevenueCat" from a failure. The 4-arg implementation emits the ONE event; the 2- and
    // 3-arg ones delegate to it (never the reverse), so whichever overload a path calls, one event carries
    // a real errorType.
    func onPaywallPurchaseFailed(paywallId: String, error: Error, errorType: String, productId: String?) {
        sendEvent(sink, type: "onPaywallPurchaseFailed", args: [
            "paywallId": paywallId,
            "error": errorMap(error),
            "errorType": errorType,
            "productId": productId
        ])
    }

    func onPaywallPurchaseFailed(paywallId: String, error: Error, errorType: String) {
        onPaywallPurchaseFailed(paywallId: paywallId, error: error, errorType: errorType, productId: nil)
    }

    func onPaywallPurchaseFailed(paywallId: String, error: Error) {
        onPaywallPurchaseFailed(
            paywallId: paywallId, error: error, errorType: billingErrorType(error), productId: nil
        )
    }

    func onPaywallDismissed(paywallId: String) {
        sendEvent(sink, type: "onPaywallDismissed", args: ["paywallId": paywallId])
    }

    func onPromoCodeSubmit(paywallId: String, code: String, completion: @escaping (Bool) -> Void) {
        // Route the promo-code validation through the
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
            // Key must match the generated delegate param + Android emit.
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
            // Cross-platform-consistent type: emit epoch-millis
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
    /// Native -> Dart invoker for the async `shouldShowMessage`
    /// wrapper-veto. Injected in `register(...)`.
    weak var invoker: SyncCallbackInvoker?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        AppDNA.inAppMessages.setDelegate(self)
        // Register the async wrapper-veto. The native SDK
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
        var out: [String: Any?] = [
            "pushId": p.pushId,
            "title": p.title,
            "body": p.body,
            "imageUrl": p.imageUrl,
            "data": p.data,
            "action": actionMap,
        ]
        // The action BUTTONS, exactly as the RN wrapper sends them (`AppdnaMappers.map`): the key only
        // when there are buttons, a missing id / label as "", `action_value` only when non-empty.
        // `onPushTapped`'s actionId is one of these ids.
        if !p.actions.isEmpty {
            out["actions"] = p.actions.map { btn -> [String: Any] in
                var entry: [String: Any] = ["id": btn.id ?? "", "label": btn.label ?? "", "action_type": btn.type]
                if !btn.value.isEmpty { entry["action_value"] = btn.value }
                return entry
            }
        }
        return out
    }
}

// MARK: Billing (lifecycle delegate)

private class BillingDelegateForwarder: NSObject, AppDNABillingDelegate, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    // This forwarder is a DELIVERING delegate (`setDelegate(self)` defaults
    // `deliversPurchases: true`): Dart listening is what drains the late-purchase queue. Order matters
    // for "a null sink is never counted as a delivery": the sink is set BEFORE the forwarder becomes the
    // delegate (the registration drains at once), and the delegate is cleared BEFORE the sink. The
    // native drain re-reads the delegate per entry inside `MainActor.run` and calls
    // `onPurchaseCompleted` in that same main-thread turn, where `sendEvent` emits synchronously — so
    // an entry counted delivered was handed to a live sink.
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        AppDNA.billing.setDelegate(self, deliversPurchases: true)
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
                // Epoch-millis String, matching Android's
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
        // Delegate channel ONLY. The Dart `billing.onEntitlementsChanged` stream has one source, the
        // native closure (`BillingEntitlementStreamHandler`); forwarding this into it too would emit
        // every change twice once native fires both the delegate and the closure.
        // Emit the Dart `Entitlement.fromMap` contract shape
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

// MARK: Lifecycle (runtime lock)

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

// MARK: Init degradation

/// The `type` an init error carries to Dart — the strings Android sends (an explicit one per init error class):
/// `BootstrapFailed`, `SubsystemFailed`, `FirebaseConfigMissing`, and `UnsupportedBlockType` (iOS only). Any other
/// error keeps its Swift type name. (It used to send "AppDNAInitError" for every case, so a Dart host could not
/// branch on the cause the way it can on Android.)
func initErrorTypeName(_ error: Error) -> String {
    if let e = error as? AppDNAInitError {
        if case .bootstrapFailed = e { return "BootstrapFailed" }
        if case .subsystemFailed = e { return "SubsystemFailed" }
        if case .firebaseConfigMissing = e { return "FirebaseConfigMissing" }
        if case .unsupportedBlockType = e { return "UnsupportedBlockType" }
    }
    return String(describing: type(of: error))
}

/// The ONE native `AppDNA.initDelegate` while any Dart listener is attached, fanning each `onInitDegraded` out to
/// every listening `InitDelegateForwarder` (one per Flutter engine / init stream). `AppDNA.initDelegate` is
/// process-wide: when each forwarder installed itself, the last engine to listen won and the others stopped
/// receiving, and any engine's cancel cleared the delegate for all of them.
///
/// Rules: the fan-out is installed when the first forwarder joins and cleared (only if it is still the delegate)
/// when the last one leaves; listeners are held weakly; a forwarder that joins while the SDK is already degraded
/// gets that error replayed to itself alone — the replay the native setter makes on install is swallowed so the
/// others never see it twice. Main thread delivery, like the native delegate.
final class InitDelegateFanOut: NSObject, AppDNAInitDelegate {
    static let shared = InitDelegateFanOut()

    private let lock = NSLock()
    private let listeners = NSHashTable<InitDelegateForwarder>.weakObjects()
    /// Install-time replays still to swallow (the native setter replays a pending error asynchronously on main).
    private var replaysToSwallow = 0

    func join(_ forwarder: InitDelegateForwarder) {
        lock.lock()
        listeners.add(forwarder)
        let install = AppDNA.initDelegate !== self
        if install && AppDNA.lastInitError != nil { replaysToSwallow += 1 }
        let pending = (pendingErrorForTesting ?? { AppDNA.lastInitError })()
        lock.unlock()
        if install { AppDNA.initDelegate = self }
        if let pending {
            DispatchQueue.main.async { forwarder.deliver(pending) }
        }
    }

    func leave(_ forwarder: InitDelegateForwarder) {
        lock.lock()
        listeners.remove(forwarder)
        let empty = listeners.allObjects.isEmpty
        lock.unlock()
        if empty, AppDNA.initDelegate === self { AppDNA.initDelegate = nil }
    }

    func onInitDegraded(reason: Error) {
        lock.lock()
        if replaysToSwallow > 0 {
            replaysToSwallow -= 1
            lock.unlock()
            return
        }
        let targets = listeners.allObjects
        lock.unlock()
        for target in targets { target.deliver(reason) }
    }

    /// Test seam: the degradation a joining forwarder is replayed (nil: `AppDNA.lastInitError`, which RunnerTests
    /// cannot set — the SDK's reporter is internal).
    var pendingErrorForTesting: (() -> Error?)?

    /// Test reader: the forwarders listening now.
    var listenerCountForTesting: Int { lock.lock(); defer { lock.unlock() }; return listeners.allObjects.count }
}

/// Forwards the native `AppDNAInitDelegate.onInitDegraded` to Dart's `setInitDelegate` stream — Android's
/// `InitDelegateForwarder`, same envelope. Internal (not private) so RunnerTests can drive it. Listens through
/// `InitDelegateFanOut`, so several engines can listen at once.
class InitDelegateForwarder: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        InitDelegateFanOut.shared.join(self)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        InitDelegateFanOut.shared.leave(self)
        self.sink = nil
        return nil
    }

    func deliver(_ reason: Error) {
        sendEvent(sink, type: "onInitDegraded", args: [
            "error": [
                "message": reason.localizedDescription,
                "type": initErrorTypeName(reason),
            ],
        ])
    }
}

// MARK: Deep Link

private class DeepLinkDelegateForwarder: NSObject, AppDNADeepLinkDelegate, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    /// Native -> Dart invoker for the async `shouldOpen`
    /// wrapper-veto. Injected in `register(...)`.
    weak var invoker: SyncCallbackInvoker?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        AppDNA.deepLinks.setDelegate(self)
        // Register the NET-NEW async `shouldOpen` veto. The
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
    /// Native -> Dart invoker for the async `onScreenAction`
    /// wrapper-veto. Injected in `register(...)`.
    weak var invoker: SyncCallbackInvoker?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        AppDNA.screenDelegate = self
        // Register the async `onScreenAction` veto. The native
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

/// `[blockId: [option maps]]` from the channel into typed options.
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
