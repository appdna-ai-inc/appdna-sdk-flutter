package com.appdna.flutter

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import ai.appdna.sdk.AppDNA
import ai.appdna.sdk.AppDNABillingDelegate
import ai.appdna.sdk.AppDNAInAppMessageDelegate
import ai.appdna.sdk.AppDNAInitDelegate
import ai.appdna.sdk.AppDNAOptions
import ai.appdna.sdk.OnboardingContext
import ai.appdna.sdk.ForcedTheme
import ai.appdna.sdk.AppDNAPushDelegate
import ai.appdna.sdk.AppDNADeepLinkDelegate
import ai.appdna.sdk.AppDNASurveyDelegate
import ai.appdna.sdk.Environment
import ai.appdna.sdk.LogLevel
import ai.appdna.sdk.PurchaseCancelledException
import ai.appdna.sdk.PushPayload
import ai.appdna.sdk.SurveyResponse
import ai.appdna.sdk.TransactionInfo
import ai.appdna.sdk.billing.Entitlement
import ai.appdna.sdk.billing.PurchaseOptions
import ai.appdna.sdk.onboarding.AppDNAOnboardingDelegate
import ai.appdna.sdk.onboarding.ElementInteractionResult
import ai.appdna.sdk.onboarding.PermissionHandling
import ai.appdna.sdk.onboarding.StepAdvanceResult
import ai.appdna.sdk.onboarding.StepConfigOverride
import ai.appdna.sdk.paywalls.AppDNAPaywallDelegate
import ai.appdna.sdk.paywalls.PaywallAction
import ai.appdna.sdk.paywalls.PaywallContext
import ai.appdna.sdk.screens.AppDNAScreenDelegate
import ai.appdna.sdk.generated.AppDNALifecycleDelegate
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.*
import kotlin.coroutines.resume

class AppdnaPlugin internal constructor(
    /**
     * How a native → Dart sync callback reaches the Dart host. `null` (production, the public no-arg
     * constructor Flutter's plugin registrant uses) = the main-looper `MethodChannel` hop in
     * [invokeDart]. The JVM bridge tests inject a scripted Dart host here.
     */
    private val dartTransport: ((method: String, args: Map<String, Any?>, reply: (Any?) -> Unit) -> Unit)?,
) : FlutterPlugin, MethodCallHandler, ActivityAware, EventChannel.StreamHandler {
    constructor() : this(null)

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var billingChannel: MethodChannel
    private lateinit var entitlementEventChannel: EventChannel
    /** `internal` (test seam): the JVM fixture runner supplies the Robolectric application context. */
    internal var context: Context? = null
    /** `internal` (test seam): the JVM billing test supplies a Robolectric Activity. */
    internal var activity: Activity? = null
    private var eventSink: EventChannel.EventSink? = null
    internal var entitlementEventSink: EventChannel.EventSink? = null
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // SPEC-070-C Phase 2a — native -> Dart sync-callback plumbing. MethodChannel
    // invokes hop onto the main looper (Flutter platform-channel requirement);
    // the coroutine awaits the reply with a timeout-default so a slow/absent
    // Flutter host never deadlocks the native onboarding engine.
    private val mainHandler = Handler(Looper.getMainLooper())
    // SPEC-497 §4.2 — the host's `AppDNAOptions.vetoTimeout` (ms), written by the "configure" handler
    // (outside `context?.let`, so it applies even before the plugin has a context). Every hook reads it
    // at call time; `@Volatile` because the handler runs on the platform thread and the hooks on the
    // coroutine that awaits them.
    @Volatile
    private var syncCallbackTimeoutMs = 5000L

    // -------------------------------------------------------------------------
    // Native -> Dart delegate event channels (SDK delegate parity).
    //
    // Channel layout per Flutter SDK contract:
    //   com.appdna.sdk/events/<module>          (one-way, native -> Dart)
    //   com.appdna.sdk/sync_callbacks           (MethodChannel for veto hooks)
    //
    // Each event payload is { "type": "<delegateMethodName>", "args": { ... } }.
    // For Throwable args we serialize as { "message": String, "type": String }.
    // Complex DTOs (TransactionInfo, PushPayload, Entitlement) are converted
    // to Map<String, Any?> inline so Flutter's StandardMethodCodec can serialize.
    // -------------------------------------------------------------------------
    private lateinit var paywallEventChannel: EventChannel
    private lateinit var onboardingEventChannel: EventChannel
    private lateinit var surveyEventChannel: EventChannel
    private lateinit var inAppMessageEventChannel: EventChannel
    private lateinit var pushEventChannel: EventChannel
    private lateinit var billingEventChannel: EventChannel
    private lateinit var deepLinkEventChannel: EventChannel
    private lateinit var screenEventChannel: EventChannel
    private lateinit var initEventChannel: EventChannel
    private lateinit var lifecycleEventChannel: EventChannel
    private lateinit var remoteConfigChangeChannel: EventChannel
    private lateinit var featuresChangeChannel: EventChannel
    private lateinit var syncCallbackChannel: MethodChannel

    /** `internal` (SPEC-497 §3.4 test seam): the JVM test assigns a recording sink directly. */
    internal var paywallEventSink: EventChannel.EventSink? = null
    private var onboardingEventSink: EventChannel.EventSink? = null
    private var surveyEventSink: EventChannel.EventSink? = null
    private var inAppMessageEventSink: EventChannel.EventSink? = null
    private var pushEventSink: EventChannel.EventSink? = null
    private var billingDelegateEventSink: EventChannel.EventSink? = null

    /**
     * The `events/push` and `events/deep_link` stream handlers — properties (not anonymous objects inside
     * `onAttachedToEngine`) so the SPEC-497 §8.7 push fixture runner (`PushFixtureBridgeTest`) can listen
     * with a recording sink without a `FlutterPluginBinding`, exactly as a Dart listener does.
     */
    internal val pushStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            pushEventSink = events
            val fwd = PushDelegateForwarder()
            pushForwarder = fwd
            AppDNA.push.setDelegate(fwd)
        }
        override fun onCancel(arguments: Any?) {
            AppDNA.push.setDelegate(null)
            pushForwarder = null
            pushEventSink = null
        }
    }

    internal val deepLinkStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            deepLinkEventSink = events
            val fwd = DeepLinkDelegateForwarder()
            deepLinkForwarder = fwd
            AppDNA.deepLinks.setDelegate(fwd)
            // SPEC-070-C D10 — register the NET-NEW async shouldOpen veto.
            // The native handleURL() awaits this before dispatching the
            // deep link; null/timeout → allow (open).
            AppDNA.deepLinks.asyncShouldOpen = { url, params ->
                (invokeDart("shouldOpen", mapOf("url" to url, "params" to params)) as? Boolean) ?: true
            }
        }
        override fun onCancel(arguments: Any?) {
            AppDNA.deepLinks.setDelegate(null)
            AppDNA.deepLinks.asyncShouldOpen = null
            deepLinkForwarder = null
            deepLinkEventSink = null
        }
    }

    /**
     * The `events/billing` stream handler — a property (not an anonymous object inside
     * `onAttachedToEngine`) so the JVM test can drive it without a `FlutterPluginBinding`.
     *
     * SPEC-497 D-R40-1: Dart listening makes the forwarder a DELIVERING billing delegate — it drains
     * the late-purchase queue (Flutter cannot see whether the Dart delegate overrides
     * `onPurchaseCompleted`, so any listener counts). Order matters so a null sink is never counted as a
     * delivery: the sink is set BEFORE the forwarder is registered (registration drains at once), and
     * the delegate is cleared BEFORE the sink.
     */
    internal val billingStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            billingDelegateEventSink = events
            val fwd = BillingDelegateForwarder()
            billingForwarder = fwd
            AppDNA.billing.setDelegate(fwd, deliversPurchases = true)
        }
        override fun onCancel(arguments: Any?) {
            AppDNA.billing.setDelegate(null)
            billingForwarder = null
            billingDelegateEventSink = null
        }
    }
    private var deepLinkEventSink: EventChannel.EventSink? = null
    private var screenEventSink: EventChannel.EventSink? = null
    private var initEventSink: EventChannel.EventSink? = null
    private var lifecycleEventSink: EventChannel.EventSink? = null
    private var remoteConfigChangeSink: EventChannel.EventSink? = null
    private var featuresChangeSink: EventChannel.EventSink? = null
    // The remote-config / feature-flag change streams observe the core's process-global
    // `AppDNA.configUpdated` flow (as the React Native bridge does). They used `remoteConfig.onChanged`
    // / `features.onChanged`, which attach to the CURRENT manager only: a listen before the bootstrap
    // (manager not yet set) was never attached, `shutdown()` → `configure()` built a new manager
    // without it, and `features.onChanged` is a stub in the core — so on Android these streams could
    // stay silent for the whole session. The flow outlives `shutdown()`, so one collector is enough.
    private var configUpdatesJob: kotlinx.coroutines.Job? = null

    internal fun ensureConfigUpdatesCollector() {
        if (configUpdatesJob != null) return
        configUpdatesJob = scope.launch {
            AppDNA.configUpdated.collect {
                emit(remoteConfigChangeSink, "onRemoteConfigChanged", emptyMap())
                emit(featuresChangeSink, "onFeatureFlagsChanged", emptyMap())
            }
        }
    }
    // The two entitlement streams hold their native listener so it can be REMOVED-then-ADDED. A
    // `registered` latch used to stand here: native `shutdown()` nulls the billing and web-entitlement
    // managers (taking their listeners with them), the latch stayed set, and after `shutdown()` →
    // `configure()` both streams were silent for the rest of the process. A web listen before
    // `configure()` was dropped outright (no manager yet) and never retried.
    private var billingEntitlementListener: ((List<ai.appdna.sdk.billing.Entitlement>) -> Unit)? = null
    private var webEntitlementListener: ((ai.appdna.sdk.webentitlements.WebEntitlement?) -> Unit)? = null

    /** Remove-then-add: a re-attach never stacks a second listener. Internal for the plugin tests. */
    internal fun attachBillingEntitlementListener() {
        billingEntitlementListener?.let { AppDNA.billing.removeEntitlementsChangedListener(it) }
        val listener: (List<ai.appdna.sdk.billing.Entitlement>) -> Unit = { entitlements ->
            val maps = entitlements.map { it.toMap() }
            entitlementEventSink?.success(maps)
        }
        billingEntitlementListener = listener
        AppDNA.billing.onEntitlementsChanged(listener)
    }

    internal fun attachWebEntitlementListener() {
        webEntitlementListener?.let { AppDNA.removeWebEntitlementListener(it) }
        val listener: (ai.appdna.sdk.webentitlements.WebEntitlement?) -> Unit = { entitlement ->
            eventSink?.success(entitlement?.toMap())
        }
        webEntitlementListener = listener
        AppDNA.onWebEntitlementChanged(listener)
    }

    /** After every `configure`: re-register the entitlement streams Dart is still listening to. */
    internal fun reattachStreams() {
        if (entitlementEventSink != null) attachBillingEntitlementListener()
        if (eventSink != null) attachWebEntitlementListener()
    }

    // Forwarder instances we install on the native modules. Kept as properties
    // so onCancel() can call setDelegate(null) cleanly on stream tear-down.
    private var paywallForwarder: PaywallDelegateForwarder? = null
    private var onboardingForwarder: OnboardingDelegateForwarder? = null
    private var surveyForwarder: SurveyDelegateForwarder? = null
    private var inAppMessageForwarder: InAppMessageDelegateForwarder? = null
    private var pushForwarder: PushDelegateForwarder? = null
    private var billingForwarder: BillingDelegateForwarder? = null
    private var deepLinkForwarder: DeepLinkDelegateForwarder? = null
    private var screenForwarder: ScreenDelegateForwarder? = null
    private var initForwarder: InitDelegateForwarder? = null
    private var lifecycleForwarder: LifecycleDelegateForwarder? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.appdna.sdk/main")
        channel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "com.appdna.sdk/web_entitlement")
        eventChannel.setStreamHandler(this)

        // Billing channels
        billingChannel = MethodChannel(binding.binaryMessenger, "com.appdna.sdk/billing")
        billingChannel.setMethodCallHandler { call, result -> handleBilling(call, result) }
        entitlementEventChannel = EventChannel(binding.binaryMessenger, "com.appdna.sdk/entitlements")
        entitlementEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                entitlementEventSink = events
                attachBillingEntitlementListener()
            }
            override fun onCancel(arguments: Any?) {
                entitlementEventSink = null
                billingEntitlementListener?.let { AppDNA.billing.removeEntitlementsChangedListener(it) }
                billingEntitlementListener = null
            }
        })

        // -- Native -> Dart delegate event channels --
        // Eight observe-only streams. onListen wires a forwarder into the
        // native module's setDelegate(); onCancel removes it. The forwarders
        // marshal native callback args into the shared
        // { "type": ..., "args": {...} } envelope and push them through the
        // sink on the main thread.
        paywallEventChannel = EventChannel(binding.binaryMessenger, "com.appdna.sdk/events/paywall")
        paywallEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                paywallEventSink = events
                val fwd = PaywallDelegateForwarder()
                paywallForwarder = fwd
                AppDNA.paywall.setDelegate(fwd)
            }
            override fun onCancel(arguments: Any?) {
                AppDNA.paywall.setDelegate(null)
                paywallForwarder = null
                paywallEventSink = null
            }
        })

        onboardingEventChannel = EventChannel(binding.binaryMessenger, "com.appdna.sdk/events/onboarding")
        onboardingEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                onboardingEventSink = events
                val fwd = OnboardingDelegateForwarder()
                onboardingForwarder = fwd
                // Note: OnboardingModule.setDelegate stores the listener and
                // hands it to AppDNA.presentOnboarding(...) at present-time.
                // Dart code must subscribe to this stream BEFORE calling
                // presentOnboarding() for the callbacks to flow.
                AppDNA.onboarding.setDelegate(fwd)
            }
            override fun onCancel(arguments: Any?) {
                AppDNA.onboarding.setDelegate(null)
                onboardingForwarder = null
                onboardingEventSink = null
            }
        })

        surveyEventChannel = EventChannel(binding.binaryMessenger, "com.appdna.sdk/events/survey")
        surveyEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                surveyEventSink = events
                val fwd = SurveyDelegateForwarder()
                surveyForwarder = fwd
                AppDNA.surveys.setDelegate(fwd)
            }
            override fun onCancel(arguments: Any?) {
                AppDNA.surveys.setDelegate(null)
                surveyForwarder = null
                surveyEventSink = null
            }
        })

        inAppMessageEventChannel = EventChannel(binding.binaryMessenger, "com.appdna.sdk/events/in_app_message")
        inAppMessageEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                inAppMessageEventSink = events
                val fwd = InAppMessageDelegateForwarder()
                inAppMessageForwarder = fwd
                AppDNA.inAppMessages.setDelegate(fwd)
                // SPEC-070-C D10 — register the async shouldShowMessage veto.
                // The native SDK awaits this in ADDITION to the sync delegate
                // veto; invokeDart applies the timeout-default + logs, and a
                // null/timeout reply defaults to allow (true).
                AppDNA.inAppMessages.setAsyncShouldShowMessage { messageId ->
                    (invokeDart("shouldShowMessage", mapOf("messageId" to messageId)) as? Boolean) ?: true
                }
            }
            override fun onCancel(arguments: Any?) {
                AppDNA.inAppMessages.setDelegate(null)
                AppDNA.inAppMessages.setAsyncShouldShowMessage(null)
                inAppMessageForwarder = null
                inAppMessageEventSink = null
            }
        })

        pushEventChannel = EventChannel(binding.binaryMessenger, "com.appdna.sdk/events/push")
        pushEventChannel.setStreamHandler(pushStreamHandler)

        billingEventChannel = EventChannel(binding.binaryMessenger, "com.appdna.sdk/events/billing")
        billingEventChannel.setStreamHandler(billingStreamHandler)

        deepLinkEventChannel = EventChannel(binding.binaryMessenger, "com.appdna.sdk/events/deep_link")
        deepLinkEventChannel.setStreamHandler(deepLinkStreamHandler)

        screenEventChannel = EventChannel(binding.binaryMessenger, "com.appdna.sdk/events/screen")
        screenEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                screenEventSink = events
                val fwd = ScreenDelegateForwarder()
                screenForwarder = fwd
                AppDNA.screenDelegate = fwd
                // SPEC-070-C D10 — register the async onScreenAction veto. The
                // native SDK awaits this before performing the action (the sync
                // forwarder below always returns true); null/timeout → allow.
                AppDNA.asyncOnScreenAction = { screenId, action ->
                    (invokeDart("onScreenAction", mapOf("screenId" to screenId, "action" to action)) as? Boolean) ?: true
                }
            }
            override fun onCancel(arguments: Any?) {
                AppDNA.screenDelegate = null
                AppDNA.asyncOnScreenAction = null
                screenForwarder = null
                screenEventSink = null
            }
        })

        // SPEC-070-C §3.1 — Android-only init-degradation delegate stream.
        // onListen wires an AppDNAInitDelegate forwarder into the native SDK;
        // onCancel clears it. (iOS registers this channel as a no-op.)
        initEventChannel = EventChannel(binding.binaryMessenger, "com.appdna.sdk/events/init")
        initEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                initEventSink = events
                val fwd = InitDelegateForwarder()
                initForwarder = fwd
                AppDNA.setInitDelegate(fwd)
            }
            override fun onCancel(arguments: Any?) {
                AppDNA.setInitDelegate(null)
                initForwarder = null
                initEventSink = null
            }
        })

        // SPEC-404 — runtime-lock lifecycle delegate stream (BOTH platforms).
        // onListen wires an AppDNALifecycleDelegate forwarder into the native
        // SDK via setLifecycleDelegate(); onCancel clears it.
        lifecycleEventChannel = EventChannel(binding.binaryMessenger, "com.appdna.sdk/events/lifecycle")
        lifecycleEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                lifecycleEventSink = events
                val fwd = LifecycleDelegateForwarder()
                lifecycleForwarder = fwd
                AppDNA.setLifecycleDelegate(fwd)
            }
            override fun onCancel(arguments: Any?) {
                AppDNA.setLifecycleDelegate(null)
                lifecycleForwarder = null
                lifecycleEventSink = null
            }
        })

        // SPEC-070-C M1 — remote-config / feature-flag change streams. On
        // onListen each wires the native `onChanged` observer (once) and emits a
        // bare signal; the Dart side ignores the payload and fires its callback.
        remoteConfigChangeChannel = EventChannel(binding.binaryMessenger, "com.appdna.sdk/events/remote_config")
        remoteConfigChangeChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                remoteConfigChangeSink = events
                ensureConfigUpdatesCollector()
            }
            override fun onCancel(arguments: Any?) {
                remoteConfigChangeSink = null
            }
        })

        featuresChangeChannel = EventChannel(binding.binaryMessenger, "com.appdna.sdk/events/features")
        featuresChangeChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                featuresChangeSink = events
                ensureConfigUpdatesCollector()
            }
            override fun onCancel(arguments: Any?) {
                featuresChangeSink = null
            }
        })

        // Bidirectional sync-callback MethodChannel. Native -> Dart veto + async
        // onboarding hooks flow through `invokeDart()` (see below) and are fully
        // implemented. This inbound handler is for the (currently unused)
        // Dart -> native direction only.
        syncCallbackChannel = MethodChannel(binding.binaryMessenger, "com.appdna.sdk/sync_callbacks")
        syncCallbackChannel.setMethodCallHandler { _, result ->
            // No Dart -> native sync calls are defined today.
            result.notImplemented()
        }

        // SPEC-070-C Phase 2b — register the AppDNAScreenSlot PlatformView
        // factory. The Dart `AppDNAScreenSlot` widget embeds an `AndroidView`
        // with this same viewType; the factory hosts the `@Composable
        // AppDNAScreenSlot(name)` in a ComposeView with plugin-owned ViewTree
        // owners (bare FlutterActivity has none).
        binding.platformViewRegistry.registerViewFactory(
            "com.appdna.sdk/screen_slot",
            AppDNAScreenSlotViewFactory(),
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // The native listeners capture this engine-scoped plugin: detach them with it.
        configUpdatesJob?.cancel()
        configUpdatesJob = null
        billingEntitlementListener?.let { AppDNA.billing.removeEntitlementsChangedListener(it) }
        billingEntitlementListener = null
        webEntitlementListener?.let { AppDNA.removeWebEntitlementListener(it) }
        webEntitlementListener = null
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        billingChannel.setMethodCallHandler(null)
        entitlementEventChannel.setStreamHandler(null)
        // Tear down delegate streams and unregister forwarders so the native
        // modules don't keep callbacks alive past Flutter engine teardown.
        paywallEventChannel.setStreamHandler(null)
        onboardingEventChannel.setStreamHandler(null)
        surveyEventChannel.setStreamHandler(null)
        inAppMessageEventChannel.setStreamHandler(null)
        pushEventChannel.setStreamHandler(null)
        billingEventChannel.setStreamHandler(null)
        deepLinkEventChannel.setStreamHandler(null)
        screenEventChannel.setStreamHandler(null)
        initEventChannel.setStreamHandler(null)
        lifecycleEventChannel.setStreamHandler(null)
        remoteConfigChangeChannel.setStreamHandler(null)
        featuresChangeChannel.setStreamHandler(null)
        syncCallbackChannel.setMethodCallHandler(null)
        runCatching { AppDNA.paywall.setDelegate(null) }
        runCatching { AppDNA.onboarding.setDelegate(null) }
        runCatching { AppDNA.surveys.setDelegate(null) }
        runCatching { AppDNA.inAppMessages.setDelegate(null) }
        runCatching { AppDNA.push.setDelegate(null) }
        runCatching { AppDNA.billing.setDelegate(null) }
        runCatching { AppDNA.deepLinks.setDelegate(null) }
        runCatching { AppDNA.screenDelegate = null }
        runCatching { AppDNA.setInitDelegate(null) }
        // SPEC-070-C round-10 FIX-1 — also clear the 4 async registrations installed
        // by the stream onListen blocks. Flutter doesn't guarantee onCancel fires at
        // engine detach, so on a pure engine-destroy these closures (which capture the
        // plugin's invokeDart → strong `this`) would stay on the native AppDNA singleton
        // → leak + a 5s invokeMethod-on-dead-messenger stall per subsequent native-driven
        // action (add-to-app / engine-recreation hosts).
        runCatching { AppDNA.inAppMessages.setAsyncShouldShowMessage(null) }
        runCatching { AppDNA.deepLinks.asyncShouldOpen = null }
        runCatching { AppDNA.asyncOnScreenAction = null }
        runCatching { AppDNA.setLifecycleDelegate(null) }
        scope.cancel()
    }

    // Bind a delegate forwarder before presenting so host hooks/vetoes are live even
    // if the app never subscribed to that module's event stream. Critical for the
    // onboarding onBeforeStepAdvance hook that auth actions (email_login / login /
    // register / OTP) route through — the native SDK STAYS on an auth step when no
    // delegate is bound. Forwarders are inner classes whose sync hooks flow through
    // the plugin-level sync_callbacks channel, so one created here works without an
    // event sink (observe events are simply dropped). onCancel still clears them.
    private fun ensureOnboardingDelegate() {
        if (onboardingForwarder == null) onboardingForwarder = OnboardingDelegateForwarder()
        AppDNA.onboarding.setDelegate(onboardingForwarder)
    }
    private fun ensurePaywallDelegate() {
        if (paywallForwarder == null) paywallForwarder = PaywallDelegateForwarder()
        AppDNA.paywall.setDelegate(paywallForwarder)
    }
    private fun ensureSurveyDelegate() {
        if (surveyForwarder == null) surveyForwarder = SurveyDelegateForwarder()
        AppDNA.surveys.setDelegate(surveyForwarder)
    }
    private fun ensureScreenDelegate() {
        if (screenForwarder == null) screenForwarder = ScreenDelegateForwarder()
        AppDNA.screenDelegate = screenForwarder
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "configure" -> {
                val apiKey = call.argument<String>("apiKey")!!
                val envStr = call.argument<String>("env") ?: "production"
                val env = if (envStr == "staging") Environment.SANDBOX else Environment.PRODUCTION
                val options = parseOptions(call.argument<Map<String, Any>>("options"))
                // SPEC-497 §4.2 — every Flutter hook honours the configured vetoTimeout (it used to
                // reach only diagnose()). parseOptions has already mapped a non-positive value to the
                // native default.
                // Exact milliseconds from the host's (possibly fractional) seconds — `options.vetoTimeout`
                // is the core's whole-second field and would truncate 0.5 s to the default.
                syncCallbackTimeoutMs = parseVetoTimeoutMs(call.argument<Map<String, Any>>("options"))
                context?.let { AppDNA.configure(it, apiKey, env, options) }
                // Native `shutdown()` dropped the entitlement listeners with their managers.
                reattachStreams()
                result.success(null)
            }
            "identify" -> {
                val userId = call.argument<String>("userId")!!
                val traits = call.argument<Map<String, Any>>("traits")
                AppDNA.identify(userId, traits)
                result.success(null)
            }
            "reset" -> {
                AppDNA.reset()
                result.success(null)
            }
            "track" -> {
                val event = call.argument<String>("event")!!
                val properties = call.argument<Map<String, Any>>("properties")
                AppDNA.track(event, properties)
                result.success(null)
            }
            "flush" -> {
                AppDNA.flush()
                result.success(null)
            }
            "presentPaywall" -> {
                val id = call.argument<String>("id")!!
                val contextMap = call.argument<Map<String, Any>>("context")
                val paywallContext = contextMap?.let { map ->
                    val placement = map["placement"] as? String ?: return@let null
                    // SPEC-070-B PN row 11(e) / D-s: customData finally reaches native.
                    @Suppress("UNCHECKED_CAST")
                    val custom = map["customData"] as? Map<String, Any>
                    PaywallContext(
                        placement = placement,
                        experiment = map["experiment"] as? String,
                        variant = map["variant"] as? String,
                        customData = custom
                    )
                }
                // SPEC-070-C HIGH-1/2 — route through the MODULE present() so the
                // stored paywall listener (PaywallDelegateForwarder installed on
                // the events/paywall stream's onListen) is forwarded. The static
                // `AppDNA.presentPaywall(activity, id, context)` defaults
                // listener=null and would leave all host paywall callbacks dead.
                ensurePaywallDelegate()
                // 🔴 `result.success(null)` USED TO THROW THE ANSWER AWAY. Native returns false when the
                // id is not published / the SDK is unconfigured / it is runtime-locked, and Dart's
                // `Future<void>` resolved SUCCESSFULLY anyway — telling a Flutter host a paywall had been
                // shown when none had. Hand the Boolean across.
                result.success(activity?.let { AppDNA.paywall.present(it, id, paywallContext) } ?: false)
            }
            "presentOnboarding" -> {
                val flowId = call.argument<String>("flowId")!!
                // SPEC-070-C HIGH-1 — route through the MODULE present() so the
                // stored OnboardingDelegateForwarder is forwarded (the static
                // `presentOnboarding(activity, flowId)` defaults listener=null,
                // leaving all observe + sync_callbacks hooks dead).
                // MEDIUM-1 — forward the host's OnboardingContext. NOTE: the native
                // module present() currently drops it (pre-existing native gap
                // affecting native hosts equally); the bridge forwards it faithfully.
                @Suppress("UNCHECKED_CAST")
                val onbCtx = call.argument<Map<String, Any?>>("context")?.let { m ->
                    OnboardingContext(
                        source = m["source"] as? String,
                        campaign = m["campaign"] as? String,
                        referrer = m["referrer"] as? String,
                        userProperties = m["userProperties"] as? Map<String, Any>,
                        experimentOverrides = m["experimentOverrides"] as? Map<String, String>
                    )
                }
                ensureOnboardingDelegate()
                // 🔴 This used to `result.success(null)` and drop the module's Boolean on the
                // floor, so Dart could not tell "presented" from "that flow id is not in the
                // published config". `false` when there is no Activity to present from, for the
                // same reason — a silent no-op is how "the SDK does nothing" gets filed as a bug.
                result.success(activity?.let { AppDNA.onboarding.present(it, flowId, onbCtx) } ?: false)
            }
            "getRemoteConfig" -> {
                val key = call.argument<String>("key")!!
                result.success(AppDNA.getRemoteConfig(key))
            }
            "isFeatureEnabled" -> {
                val flag = call.argument<String>("flag")!!
                result.success(AppDNA.isFeatureEnabled(flag))
            }
            "getExperimentVariant" -> {
                val experimentId = call.argument<String>("experimentId")!!
                result.success(AppDNA.getExperimentVariant(experimentId))
            }
            "isInVariant" -> {
                val experimentId = call.argument<String>("experimentId")!!
                val variantId = call.argument<String>("variantId")!!
                result.success(AppDNA.isInVariant(experimentId, variantId))
            }
            "getExperimentConfig" -> {
                val experimentId = call.argument<String>("experimentId")!!
                val key = call.argument<String>("key")!!
                result.success(AppDNA.getExperimentConfig(experimentId, key))
            }
            "setPushToken" -> {
                val token = call.argument<String>("token")!!
                AppDNA.setPushToken(token)
                result.success(null)
            }
            "setPushPermission" -> {
                val granted = call.argument<Boolean>("granted") ?: false
                AppDNA.setPushPermission(granted)
                result.success(null)
            }
            "trackPushDelivered" -> {
                val pushId = call.argument<String>("pushId")!!
                AppDNA.trackPushDelivered(pushId)
                result.success(null)
            }
            "trackPushTapped" -> {
                val pushId = call.argument<String>("pushId")!!
                val action = call.argument<String>("action")
                AppDNA.trackPushTapped(pushId, action)
                result.success(null)
            }
            "setConsent" -> {
                val analytics = call.argument<Boolean>("analytics") ?: true
                AppDNA.setConsent(analytics)
                result.success(null)
            }
            "onReady" -> {
                AppDNA.onReady { result.success(true) }
            }
            "getWebEntitlement" -> {
                val entitlement = AppDNA.webEntitlement
                result.success(entitlement?.toMap())
            }
            "checkDeferredDeepLink" -> {
                AppDNA.checkDeferredDeepLink { deepLink ->
                    result.success(deepLink?.toMap())
                }
            }
            "shutdown" -> {
                AppDNA.shutdown()
                result.success(null)
            }
            "getSdkVersion" -> {
                result.success(AppDNA.sdkVersion)
            }

            // MARK: SPEC-070-C Phase 3 — remaining facade method wiring.
            // Each case delegates to the current native sdk-android 1.0.39
            // facade. Thin marshalling only (arg unpack -> native call -> reply).

            "setLogLevel" -> {
                // Native AppDNA.setLogLevel(String) resolves the level itself.
                AppDNA.setLogLevel(call.argument<String>("level") ?: "warning")
                result.success(null)
            }

            // Push module. requestPermission needs a foreground Activity to show
            // the OS dialog; with none we report not-granted (documented no-op)
            // rather than throwing (§3.14).
            "requestPushPermission" -> {
                val act = activity
                if (act == null) {
                    result.success(false)
                    return
                }
                scope.launch {
                    try {
                        result.success(AppDNA.push.requestPermission(act))
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
            }
            "getPushToken" -> {
                result.success(AppDNA.push.getToken())
            }

            // Remote config module.
            "refreshConfig" -> {
                AppDNA.remoteConfig.refresh()
                result.success(null)
            }
            "getAllRemoteConfig" -> {
                result.success(AppDNA.remoteConfig.getAll())
            }

            // Features module.
            "getFeatureVariant" -> {
                val flag = call.argument<String>("flag")!!
                result.success(AppDNA.features.getVariant(flag))
            }

            // Experiments module. Map ExposureEntry -> {experimentId, variant}
            // so the shape matches iOS + the Dart parser.
            "getExperimentExposures" -> {
                val exposures = AppDNA.experiments.getExposures()
                result.success(
                    exposures.map {
                        mapOf("experimentId" to it.experimentId, "variant" to it.variant)
                    },
                )
            }

            // In-app messages module.
            "suppressMessages" -> {
                AppDNA.inAppMessages.suppressDisplay(call.argument<Boolean>("suppress") ?: false)
                result.success(null)
            }

            // Surveys module.
            "presentSurvey" -> {
                val surveyId = call.argument<String>("surveyId")!!
                ensureSurveyDelegate()
                AppDNA.surveys.present(surveyId)
                result.success(null)
            }

            // Deep links module. Dart passes a raw URL string.
            "handleDeepLink" -> {
                val url = call.argument<String>("url")!!
                AppDNA.deepLinks.handleURL(url)
                result.success(null)
            }

            // Screen (server-driven UI) module. Presentation is fire-and-forget:
            // lifecycle callbacks arrive on events/screen via the forwarder, so
            // no completion is passed and the method resolves immediately.
            // `context` has no native counterpart on showScreen/showFlow and is
            // intentionally dropped (documented no-op).
            // `showScreen`/`showFlow` return Unit natively, so the only honest answer here is
            // whether there was an Activity to present from — exactly what the RN module resolves
            // (`AppdnaModule.kt`). The screen's real RESULT arrives on `onScreenDismissed`.
            "showScreen" -> {
                val screenId = call.argument<String>("screenId")!!
                val a = activity
                if (a == null) { result.success(false) } else {
                    ensureScreenDelegate()
                    AppDNA.showScreen(screenId)
                    result.success(true)
                }
            }
            "showScreenFlow" -> {
                val flowId = call.argument<String>("flowId")!!
                val a = activity
                if (a == null) { result.success(false) } else {
                    ensureScreenDelegate()
                    AppDNA.showFlow(flowId)
                    result.success(true)
                }
            }
            "dismissScreen" -> {
                AppDNA.dismissScreen()
                result.success(null)
            }
            "enableScreenNavigationInterception" -> {
                AppDNA.enableNavigationInterception()
                result.success(null)
            }
            "disableScreenNavigationInterception" -> {
                AppDNA.disableNavigationInterception()
                result.success(null)
            }
            // Dart sends the screen definition as a Map; native previewScreen
            // takes a JSON string, so serialize before forwarding. Android's
            // previewScreen returns a success Bool (iOS returns a ScreenResult),
            // surfaced to Dart as {success: <bool>} (SPEC-070-C §3.12 / M4).
            "previewScreen" -> {
                val jsonStr = when (val json = call.argument<Any>("json")) {
                    is String -> json
                    is Map<*, *> -> org.json.JSONObject(json).toString()
                    else -> null
                }
                if (jsonStr != null) {
                    val ok = AppDNA.previewScreen(jsonStr)
                    result.success(mapOf("success" to ok))
                } else {
                    result.success(null)
                }
            }

            // MARK: SPEC-070-C §3.1 lifecycle / core
            "registerBackgroundTasks" -> {
                AppDNA.registerBackgroundTasks()
                result.success(null)
            }
            "isConsentGranted" -> {
                result.success(AppDNA.isConsentGranted())
            }
            // Android `diagnose()` returns the report String (iOS returns Void).
            "diagnose" -> {
                result.success(AppDNA.diagnose())
            }
            "getUserTraits" -> {
                result.success(AppDNA.getUserTraits())
            }
            // SPEC-070-C §3.1 — app-defined session data (SPEC-088).
            "setSessionData" -> {
                val k = call.argument<String>("key")!!
                val v = call.argument<Any>("value")
                if (v != null) AppDNA.setSessionData(k, v)
                result.success(null)
            }
            "getSessionData" -> {
                result.success(AppDNA.getSessionData(call.argument<String>("key")!!))
            }
            "clearSessionData" -> {
                AppDNA.clearSessionData()
                result.success(null)
            }
            // Android-only forced-theme override. Dart passes 'light'/'dark'/
            // 'system'/null; map to the ForcedTheme enum (null = follow system).
            "setForcedTheme" -> {
                val theme = when (call.argument<String>("theme")?.lowercase()) {
                    "light" -> ForcedTheme.LIGHT
                    "dark" -> ForcedTheme.DARK
                    "system" -> ForcedTheme.SYSTEM
                    else -> null
                }
                AppDNA.setForcedTheme(theme)
                result.success(null)
            }
            "getForcedTheme" -> {
                result.success(AppDNA.getForcedTheme()?.name?.lowercase())
            }
            // Android-only last-init-error read → {message, type} or null.
            "getLastInitError" -> {
                val err = AppDNA.lastInitError
                result.success(err?.let { throwableToMap(it) })
            }
            // §3.1 brand accent hex — read-only public on BOTH platforms.
            "getBrandAccentHex" -> {
                result.success(AppDNA.brandAccentHex)
            }
            // §3.1 runtime lock — pollable read. Native `Pair<String,String>` is
            // `(reason, locked_at)` → the same `{reason, locked_at}` map iOS emits.
            "getRuntimeLock" -> {
                val lock = AppDNA.runtimeLock
                result.success(
                    lock?.let { mapOf("reason" to it.first, "locked_at" to it.second) },
                )
            }
            // §3.1 Android-only current bundle version read (iOS var is internal
            // → the iOS plugin returns null).
            "getCurrentBundleVersion" -> {
                result.success(AppDNA.currentBundleVersion)
            }
            // §3.1 Android-only notification-icon read (iOS has no such field
            // → the iOS plugin returns null). `0` means unset.
            "getNotificationIcon" -> {
                result.success(AppDNA.notificationIcon)
            }

            // MARK: SPEC-070-C §3.2 events
            "notifyScreenAppeared" -> {
                val screenName = call.argument<String>("screenName")!!
                AppDNA.notifyScreenAppeared(screenName)
                result.success(null)
            }

            // MARK: SPEC-070-C §3.3 config
            "forceRefreshConfig" -> {
                AppDNA.forceRefreshConfig()
                result.success(null)
            }
            "debugAppliedConfigVersion" -> {
                result.success(AppDNA.debugAppliedConfigVersion(call.argument<String>("flowId")))
            }

            // MARK: SPEC-070-C §3.7 paywall
            "presentPaywallByPlacement" -> {
                val placement = call.argument<String>("placement")!!
                val contextMap = call.argument<Map<String, Any>>("context")
                val paywallContext = contextMap?.let { map ->
                    val p = map["placement"] as? String ?: placement
                    // SPEC-070-B PN row 11(e) / D-s.
                    @Suppress("UNCHECKED_CAST")
                    val custom = map["customData"] as? Map<String, Any>
                    PaywallContext(
                        placement = p,
                        experiment = map["experiment"] as? String,
                        variant = map["variant"] as? String,
                        customData = custom,
                    )
                }
                // SPEC-070-C HIGH-2 — no module-level placement present() exists,
                // so pass the stored forwarder explicitly as the `listener` arg.
                // `paywallForwarder` is set to the live forwarder only while the
                // host is subscribed to the events/paywall stream (null otherwise),
                // so this exactly mirrors the module's stored-listener behavior.
                ensurePaywallDelegate()
                // Same as the id-based case above: a placement with no authored paywall now reports
                // false instead of a cheerful success.
                result.success(
                    activity?.let {
                        AppDNA.presentPaywallByPlacement(it, placement, paywallContext, paywallForwarder)
                    } ?: false,
                )
            }
            "showPaywall" -> {
                // SPEC-070-C HIGH-2 — route through the MODULE present() so the
                // stored paywall listener is forwarded. The static
                // `AppDNA.showPaywall(id)` routes through presentPaywall with
                // listener=null.
                ensurePaywallDelegate()
                result.success(
                    activity?.let { AppDNA.paywall.present(it, call.argument<String>("id")!!) } ?: false,
                )
            }
            "skipNextAutoDismissOnRestore" -> {
                AppDNA.paywall.skipNextAutoDismissOnRestore = call.argument<Boolean>("value") ?: false
                result.success(null)
            }

            // MARK: SPEC-070-C §3.9 surveys
            "showSurvey" -> {
                ensureSurveyDelegate()
                AppDNA.showSurvey(call.argument<String>("id")!!)
                result.success(null)
            }

            // MARK: SPEC-070-C §3.11 push
            // §3.14: Android has no dedicated registerForPush — route to
            // push.requestPermission (needs a foreground Activity).
            "registerForPush" -> {
                val act = activity
                if (act == null) {
                    result.success(false)
                    return
                }
                scope.launch {
                    try {
                        result.success(AppDNA.push.requestPermission(act))
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
            }
            // Android-only: hand the current activity's launch intent to the SDK
            // so it can attribute + route a notification tap.
            "handlePushTap" -> {
                result.success(AppDNA.handlePushTap(activity?.intent))
            }
            // SPEC-497 §9.2 — the forwarding API for a host that owns Firebase Messaging. The host's
            // map is converted natively (scalars → strings, nested maps / lists → JSON); every entry
            // point is marker-gated in the core (no `appdna: "1"` → false, nothing done).
            "push.isAppDNAMessage" -> {
                result.success(AppDNA.push.isAppDNAMessage(pushData(call)))
            }
            "push.handleMessageData" -> {
                // Never displays: the host that forwards owns display.
                result.success(AppDNA.push.handleMessageData(pushData(call)))
            }
            "push.handleTap" -> {
                result.success(AppDNA.push.handleTapData(pushData(call), call.argument<String>("actionId")))
            }
            // Android-only: feed a fresh FCM token into the SDK.
            "onNewPushToken" -> {
                AppDNA.onNewPushToken(call.argument<String>("token")!!)
                result.success(null)
            }

            // MARK: SPEC-070-C §3.13 location
            "getLocationData" -> {
                val fieldId = call.argument<String>("fieldId")!!
                val loc = AppDNA.getLocationData(fieldId)
                result.success(loc?.let { locationDataToMap(it) })
            }

            else -> result.notImplemented()
        }
    }

    private fun pushData(call: MethodCall): Map<String, String> =
        PushDataMapper.toStringMap(call.argument<Map<*, *>>("data"))

    // SPEC-070-C §3.13 — LocationData -> channel map (snake_case keys matching
    // the Dart `LocationData.fromMap` contract).
    private fun locationDataToMap(l: ai.appdna.sdk.onboarding.LocationData): Map<String, Any?> = mapOf(
        "formatted_address" to l.formatted_address,
        "city" to l.city,
        "state" to l.state,
        "state_code" to l.state_code,
        "country" to l.country,
        "country_code" to l.country_code,
        "latitude" to l.latitude,
        "longitude" to l.longitude,
        "timezone" to l.timezone,
        "timezone_offset" to l.timezone_offset,
        "postal_code" to l.postal_code,
        "raw_query" to l.raw_query,
    )

    /**
     * SPEC-497 §3.4 / §13b.2 — the `details` of a `PURCHASE_ERROR` / `RESTORE_ERROR`: the failure's
     * `billingErrorType` (so `verificationFailed`, `providerNotAvailable`, …). A Dart host reads
     * `(e as PlatformException).details?['errorType']`.
     */
    internal fun purchaseErrorDetails(e: Throwable): Map<String, Any?> =
        mapOf("errorType" to ai.appdna.sdk.billing.billingErrorType(e))

    /** The `com.appdna.sdk/billing` channel. `internal` so the JVM billing test drives it directly. */
    internal fun handleBilling(call: MethodCall, result: Result) {
        when (call.method) {
            "purchase" -> {
                val productId = call.argument<String>("productId")!!
                val offerToken = call.argument<String>("offerToken")
                // sdk-android 1.0.39: purchase(activity, productId, options) now
                // requires an Activity (Play Billing launchBillingFlow) and returns
                // a TransactionInfo on success, throwing on cancel/pending/failure.
                val act = activity
                if (act == null) {
                    result.error(
                        "NO_ACTIVITY",
                        "No foreground Activity available to launch the purchase flow",
                        null,
                    )
                    return
                }
                scope.launch {
                    try {
                        val txn = AppDNA.billing.purchase(
                            act,
                            productId,
                            PurchaseOptions(offerToken = offerToken),
                        )
                        // Map TransactionInfo -> Dart PurchaseResult shape
                        // (lib/billing.dart PurchaseResult.fromMap / Entitlement.fromMap).
                        result.success(
                            mapOf(
                                "status" to "purchased",
                                "entitlement" to mapOf(
                                    "productId" to txn.productId,
                                    // round-15 — match the real getEntitlements() store token
                                    // (native Entitlement.store defaults to "google_play") so a
                                    // host reading entitlement.store sees a consistent value from
                                    // the purchase result and getEntitlements().
                                    "store" to "google_play",
                                    "status" to "active",
                                    // SPEC-070-C round-14 F-1 — native TransactionInfo carries
                                    // NO expiry, so the synthesized purchase-success entitlement
                                    // must emit null (was stuffing the purchaseDate string into
                                    // the expiry slot — semantically wrong + diverged from iOS
                                    // which emits null). Real expiry comes from getEntitlements().
                                    "expiresAt" to null,
                                    "isTrial" to false,
                                    "offerType" to null,
                                ),
                            ),
                        )
                    } catch (e: PurchaseCancelledException) {
                        result.success(mapOf("status" to "cancelled"))
                    } catch (e: Exception) {
                        // Covers PurchasePending/PurchaseFailed + any billing error. SPEC-497 §3.4 —
                        // the code stays PURCHASE_ERROR; `details` carries the stable errorType.
                        result.error("PURCHASE_ERROR", e.message, purchaseErrorDetails(e))
                    }
                }
            }
            "restorePurchases" -> {
                // sdk-android 1.0.39: restorePurchases() now returns List<String>
                // (restored product ids). The Dart channel contract still expects
                // List<Entitlement> maps, so trigger the restore then read the
                // refreshed entitlements from the cache.
                scope.launch {
                    try {
                        AppDNA.billing.restorePurchases()
                        val entitlements = AppDNA.billing.getEntitlements()
                        result.success(entitlements.map { it.toMap() })
                    } catch (e: Exception) {
                        // SPEC-497 §13b.2 restore error contract — `details.errorType`
                        // (`providerNotAvailable`, `networkError`, `serverError`, …).
                        result.error("RESTORE_ERROR", e.message, purchaseErrorDetails(e))
                    }
                }
            }
            "getProducts" -> {
                val productIds = call.argument<List<String>>("productIds") ?: emptyList()
                scope.launch {
                    try {
                        val products = AppDNA.billing.getProducts(productIds)
                        result.success(products.map { it.toMap() })
                    } catch (e: Exception) {
                        result.error("PRODUCTS_ERROR", e.message, null)
                    }
                }
            }
            "hasActiveSubscription" -> {
                scope.launch {
                    try {
                        val hasActive = AppDNA.billing.hasActiveSubscription()
                        result.success(hasActive)
                    } catch (e: Exception) {
                        result.error("SUBSCRIPTION_ERROR", e.message, null)
                    }
                }
            }
            "getEntitlements" -> {
                // Native getEntitlements() (suspend) -> List<Entitlement>.
                // Map via BillingMappers.toMap() so keys match the Dart
                // Entitlement.fromMap contract (productId/store/status/…).
                scope.launch {
                    try {
                        val entitlements = AppDNA.billing.getEntitlements()
                        result.success(entitlements.map { it.toMap() })
                    } catch (e: Exception) {
                        result.error("ENTITLEMENTS_ERROR", e.message, null)
                    }
                }
            }
            // SPEC-070-C §3.8 — force-refresh the native entitlement cache
            // (suspend on sdk-android).
            "refreshEntitlementCache" -> {
                scope.launch {
                    try {
                        AppDNA.billing.refreshEntitlementCache()
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("REFRESH_CACHE_ERROR", e.message, null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        /**
         * SPEC-070-B §7 rule 1 — the wrapper's attribution tag, INJECTED by the bridge.
         *
         * A constant, not a map lookup: a host must not be able to set, spoof, or omit its own
         * attribution. Mirrors the RN wrapper's `FRAMEWORK_TAG`.
         */
        private const val FRAMEWORK_TAG = "flutter"
    }

    /**
     * ⚠ `internal`, not `private` — SPEC-070-B AC-11's own testability prerequisite.
     *
     * A Dart test cannot see a Kotlin `?: 3600`, and the fixture runners never reach the bridge. The
     * only thing that can observe the `framework` tag, the `configTTL` default and the
     * `billingProvider` mapping is a native unit test, and while this was private there could not be
     * one. `AppdnaParseOptionsTest` calls it (Kotlin `internal` is visible to the module's own test
     * compilation).
     */
    private fun vetoTimeoutSeconds(map: Map<String, Any>?): Double? =
        (map?.get("vetoTimeout") as? Number)?.toDouble()?.takeIf { it > 0 && it.isFinite() }

    /** The bridge's hook wait in milliseconds, without truncating fractional seconds (0.5 s → 500 ms). */
    internal fun parseVetoTimeoutMs(map: Map<String, Any>?): Long {
        val seconds = vetoTimeoutSeconds(map) ?: AppDNAOptions().vetoTimeout.toDouble()
        return kotlin.math.round((seconds * 1000.0).coerceIn(1.0, Long.MAX_VALUE / 2.0)).toLong()
    }

    internal fun parseOptions(map: Map<String, Any>?): AppDNAOptions {
        // 🔴 This was `return AppDNAOptions()` — the bare native defaults, `framework = "native"`
        // among them. The tag was injected on every OTHER path and dropped on this one, so the
        // no-options path re-created the exact bug §7 rule 1 exists to prevent: a Flutter app whose
        // `options` map never arrives (a caller that does not go through Dart's `toMap()`, an
        // absent `options` key on the MethodCall) reports itself as a NATIVE app for the life of the
        // process. `event-envelope.schema.ts` is `.catch('native')` — a wrong tag does not error, is
        // not logged and is not metered. It just quietly lies in BigQuery.
        if (map == null) return AppDNAOptions(framework = FRAMEWORK_TAG)
        val logLevel = when (map["logLevel"] as? String) {
            "none" -> LogLevel.NONE
            "error" -> LogLevel.ERROR
            "warning" -> LogLevel.WARNING
            "info" -> LogLevel.INFO
            "debug" -> LogLevel.DEBUG
            else -> LogLevel.WARNING
        }
        return AppDNAOptions(
            flushInterval = (map["flushInterval"] as? Number)?.toLong() ?: 30L,
            batchSize = (map["batchSize"] as? Number)?.toInt() ?: 20,
            // Never a literal: mirror the native default so this cannot drift again.
            configTTL = (map["configTTL"] as? Number)?.toLong() ?: AppDNAOptions().configTTL,
            logLevel = logLevel,
            // SPEC-070-C §3.1 — Android-only notification small-icon drawable id
            // (0 = unset → SDK falls back to manifest meta-data then app icon).
            notificationIcon = (map["notificationIcon"] as? Number)?.toInt() ?: 0,
            // SPEC-070-B §7 rule 1 — INJECTED, never read from the host's map. This used to be
            // `map["framework"] as? String ?: "native"`: a host could SPOOF its attribution, and any
            // path reaching configure without Dart's `toMap()` fell back to "native" and tagged every
            // Flutter event as native. The envelope schema is `.catch('native')`, so a wrong tag does
            // not error, is not logged, and is not metered — it just quietly lies in BigQuery.
            framework = FRAMEWORK_TAG,
            // SPEC-070-C: wrapper's own version so diagnose() reports per-platform.
            frameworkVersion = map["frameworkVersion"] as? String,
            // SPEC-070-B PN row 11(a): Android gained `billingProvider` in 1.0.42, so the Dart
            // `AppDNABillingProvider` a host has been able to set since 070-C finally reaches native
            // on this platform. `fromWire` handles both the bare string and the adapty tagged map;
            // an unrecognized value falls back to the native default rather than guessing.
            billingProvider = ai.appdna.sdk.BillingProvider.fromWire(map["billingProvider"])
                ?: AppDNAOptions().billingProvider,
            requireConsent = map["requireConsent"] as? Boolean ?: AppDNAOptions().requireConsent,
            // SPEC-497 §4.2 (R72) — a non-numeric, zero or negative value is the native default, mapped
            // HERE so diagnose() reports the value the bridge actually applies.
            // Whole seconds for the core (diagnose only), rounded UP so 0.5 s is 1, not the default.
            vetoTimeout = vetoTimeoutSeconds(map)?.let { kotlin.math.ceil(it).toLong() }
                ?: AppDNAOptions().vetoTimeout
        )
    }

    // ActivityAware
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { activity = null }

    // EventChannel.StreamHandler
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        attachWebEntitlementListener()
    }
    override fun onCancel(arguments: Any?) {
        eventSink = null
        webEntitlementListener?.let { AppDNA.removeWebEntitlementListener(it) }
        webEntitlementListener = null
    }

    // =========================================================================
    // Native -> Dart delegate forwarders.
    //
    // Each forwarder implements the native delegate interface and pushes a
    // shared { "type": <method>, "args": { ... } } envelope into the matching
    // EventChannel sink. Event sinks are not thread-safe off the main thread,
    // so every send hops onto the main dispatcher via `scope.launch` (the
    // CoroutineScope is built with Dispatchers.Main + SupervisorJob above).
    //
    // For complex DTOs we serialize inline to Map<String, Any?> rather than
    // depending on an extension method `toMap()` that may not exist for every
    // type. Throwables collapse to { "message": String, "type": String }.
    // =========================================================================

    private fun emit(sink: EventChannel.EventSink?, type: String, args: Map<String, Any?>) {
        val target = sink ?: return
        // Coroutine launched on main dispatcher so we can safely call
        // EventChannel.EventSink#success regardless of which thread the
        // native callback fired from.
        scope.launch {
            try {
                target.success(mapOf("type" to type, "args" to args))
            } catch (e: Throwable) {
                // Sink may be closed mid-flight if Dart cancels the stream.
                // Swallow so a stale callback doesn't crash the host app.
            }
        }
    }

    /** [emit] without the hop — for a caller already on Main that needs the sink read now. */
    private fun emitNow(sink: EventChannel.EventSink?, type: String, args: Map<String, Any?>) {
        val target = sink ?: return
        try {
            target.success(mapOf("type" to type, "args" to args))
        } catch (e: Throwable) {
            // Sink closed mid-flight — same policy as emit().
        }
    }

    private fun throwableToMap(t: Throwable): Map<String, Any?> = mapOf(
        "message" to (t.message ?: ""),
        "type" to (t::class.java.simpleName ?: "Throwable"),
    )

    private fun transactionToMap(tx: TransactionInfo): Map<String, Any?> = mapOf(
        "transactionId" to tx.transactionId,
        "productId" to tx.productId,
        "purchaseDate" to tx.purchaseDate,
        "environment" to tx.environment,
    )

    private fun entitlementToMap(e: Entitlement): Map<String, Any?> = mapOf(
        "productId" to e.productId,
        "store" to e.store,
        "status" to e.status,
        "expiresAt" to e.expiresAt,
        "isTrial" to e.isTrial,
        "offerType" to e.offerType,
    )

    private fun pushPayloadToMap(p: PushPayload): Map<String, Any?> = mapOf(
        "pushId" to p.pushId,
        "title" to p.title,
        "body" to p.body,
        "imageUrl" to p.imageUrl,
        "data" to p.data,
        "action" to p.action?.let { mapOf("type" to it.type, "value" to it.value) },
    )

    private fun surveyResponseToMap(r: SurveyResponse): Map<String, Any?> = mapOf(
        "questionId" to r.questionId,
        "answer" to r.answer,
        "metadata" to r.metadata,
    )

    // =========================================================================
    // SPEC-070-C Phase 2a — native -> Dart sync-callback invoker + reply decode.
    //
    // invokeDart() posts the MethodChannel invoke onto the main looper, awaits
    // the reply via suspendCancellableCoroutine, and wraps the whole thing in a
    // timeout. On timeout it logs a §5 diagnostic and returns null so the caller
    // substitutes the native default. A channel error / notImplemented also maps
    // to null (default). The Dart handler builds the reply maps whose shapes the
    // to*() decoders below match.
    // =========================================================================

    /**
     * [timeoutMs] defaults to the configured sync-callback timeout; SPEC-496 §5b C5.5 — the
     * `onElementInteraction` bridge passes `max(configured, core minimumBridgeTimeoutMs(action))`, so a
     * `refresh` is never cut short of the SDK's own 8 s deadline. No other call site changes.
     */
    private suspend fun invokeDart(method: String, args: Map<String, Any?>, timeoutMs: Long = syncCallbackTimeoutMs): Any? {
        return try {
            withTimeout(timeoutMs) {
                suspendCancellableCoroutine<Any?> { cont ->
                    dartTransport?.let { transport ->
                        transport(method, args) { r -> if (cont.isActive) cont.resume(r) }
                        return@suspendCancellableCoroutine
                    }
                    mainHandler.post {
                        try {
                            syncCallbackChannel.invokeMethod(
                                method,
                                args,
                                object : MethodChannel.Result {
                                    override fun success(result: Any?) {
                                        if (cont.isActive) cont.resume(result)
                                    }
                                    override fun error(
                                        code: String,
                                        message: String?,
                                        details: Any?,
                                    ) {
                                        if (cont.isActive) cont.resume(null)
                                    }
                                    override fun notImplemented() {
                                        if (cont.isActive) cont.resume(null)
                                    }
                                },
                            )
                        } catch (t: Throwable) {
                            // Channel torn down mid-flight (engine detach) etc.
                            if (cont.isActive) cont.resume(null)
                        }
                    }
                }
            }
        } catch (e: TimeoutCancellationException) {
            Log.w("AppDNA", "sync_callbacks timeout: $method")
            // SPEC-497 §4.2 — count it, as RN's invoker does, so diagnose() reports it.
            AppDNA.recordVetoTimeout()
            null
        }
    }

    /** Coerce a decoded reply value into a `Map<String, Any>` (non-null values). */
    private fun asStringMap(v: Any?): Map<String, Any> {
        val m = v as? Map<*, *> ?: return emptyMap()
        val out = HashMap<String, Any>()
        for ((k, value) in m) {
            if (k is String && value != null) out[k] = value
        }
        return out
    }

    /**
     * `{type:"proceed"}` | `{type:"proceedWithData",data:{…}}` |
     * `{type:"block",message}` | `{type:"skipTo",stepId,data?}` |
     * `{type:"stay",message?}`  →  [StepAdvanceResult] (default Proceed).
     */
    /**
     * Actions that collect or act on a credential and MUST be handled by the host before the flow
     * advances. Kept in sync with React Native (`AppdnaDelegates.kt`) and the iOS core
     * (`AuthActionPolicy.delegateRequiredActions`).
     */
    private val AUTH_ACTIONS = setOf(
        "social_login", "login", "register", "reset_password", "magic_link", "verify_email",
        "resend_verification", "enable_biometric", "email_login", "request_otp", "verify_otp",
        "logout", "change_password", "set_new_password", "delete_account", "update_profile",
    )

    private val AUTH_UNAVAILABLE_MESSAGE = "Sign-in isn't available right now. Please try again later."

    private fun isAuthAction(stepData: Map<String, Any>?): Boolean =
        (stepData?.get("action") as? String) in AUTH_ACTIONS

    /** The decision types [toStepAdvanceResult] actually understands. */
    private val KNOWN_DECISIONS = setOf(
        "proceed", "proceedWithData", "block", "skipTo", "skipToWithData", "stay",
    )

    /**
     * Did the host make an EXPLICIT, RECOGNISED decision? A map with no `type` (`{}`), the unhandled
     * sentinel, `null`, a timeout, a channel error, or a `type` the decoder does not know are all "the
     * host did not answer" — and on an auth action that is never "let them in". See the caller.
     */
    private fun isExplicitDecision(reply: Any?): Boolean {
        val map = reply as? Map<*, *> ?: return false
        if (map["__appdna_unhandled"] == true) return false
        val type = map["type"] as? String ?: return false
        return type in KNOWN_DECISIONS
    }

    private fun toStepAdvanceResult(reply: Any?): StepAdvanceResult {
        val map = reply as? Map<*, *> ?: return StepAdvanceResult.Proceed
        return when (map["type"] as? String ?: "proceed") {
            "proceedWithData" -> StepAdvanceResult.ProceedWithData(asStringMap(map["data"]))
            "block" -> StepAdvanceResult.Block(map["message"] as? String ?: "")
            // `skipToWithData` is an ACCEPTED ALIAS of `skipTo`, not a second encoding — the canonical
            // wire shape is `{type:"skipTo", stepId, data?}` and `data` promotes it. It is in
            // KNOWN_DECISIONS (so the auth gate treats it as an explicit answer), but without a case
            // here it fell to `else -> Proceed` and ADVANCED an auth step instead of skipping it.
            // Mirrors React Native (`AppdnaDelegates.kt` `"skipTo", "skipToWithData"`).
            "skipTo", "skipToWithData" -> StepAdvanceResult.SkipTo(
                map["stepId"] as? String ?: "",
                (map["data"] as? Map<*, *>)?.let { asStringMap(it) },
            )
            "stay" -> StepAdvanceResult.Stay(map["message"] as? String)
            else -> StepAdvanceResult.Proceed
        }
    }

    /** map-or-null → [StepConfigOverride]? (field-by-field; default null). */
    private fun toStepConfigOverride(reply: Any?): StepConfigOverride? {
        val map = reply as? Map<*, *> ?: return null
        return StepConfigOverride(
            fieldDefaults = (map["fieldDefaults"] as? Map<*, *>)?.let { asStringMap(it) },
            title = map["title"] as? String,
            subtitle = map["subtitle"] as? String,
            ctaText = map["ctaText"] as? String,
            // SPEC-448 §B — replaces the removed `layoutOverrides`, which nothing ever read.
            fieldOptions = decodeFieldOptions(map["fieldOptions"]),
            // SPEC-452 — the `{{hook_data.…}}` payload. `asStringMap` for the same reason
            // `fieldDefaults` uses it: the codec hands back `Map<*, *>`, and the SDK wants
            // `Map<String, Any>`.
            dataContext = (map["dataContext"] as? Map<*, *>)?.let { asStringMap(it) },
            // SPEC-451 — a one-line forward into the core decoder, which is all a wrapper may be.
            mapRoutes = ai.appdna.sdk.onboarding.StepConfigOverride.decodeMapRoutes(map["mapRoutes"]),
        )
    }

    /** map-or-null → [ElementInteractionResult]? (default null). `internal` for the JVM bridge test. */
    internal fun toElementInteractionResult(reply: Any?): ElementInteractionResult? {
        val map = reply as? Map<*, *> ?: return null
        val patches = (map["fieldConfigPatches"] as? Map<*, *>)?.let { raw ->
            val out = HashMap<String, Map<String, Any>>()
            for ((k, v) in raw) {
                if (k is String) out[k] = asStringMap(v)
            }
            out
        }
        return ElementInteractionResult(
            fieldConfigPatches = patches,
            inputValuePatches = (map["inputValuePatches"] as? Map<*, *>)?.let { asStringMap(it) },
            // #657 — replacement options for a refresh. Same decoder the render-time override uses,
            // because they are the same shape and must not drift apart.
            fieldOptions = decodeFieldOptions(map["fieldOptions"]),
            advance = map["advance"] as? Boolean ?: false,
            // SPEC-496 §5b C2 — a one-line forward into the core decoder. NOT `asStringMap`: it drops
            // null members, and a null member is how a host removes a `hook_data` key.
            dataContext = ElementInteractionResult.decodeDataContext(map["dataContext"]),
        )
    }

    /**
     * map-or-null → [PermissionHandling]?. `{type:"handledByHost",granted}`
     * short-circuits the OS prompt; anything else → Proceed; null → null
     * (run the native flow).
     */
    private fun toPermissionHandling(reply: Any?): PermissionHandling? {
        val map = reply as? Map<*, *> ?: return null
        return when (map["type"] as? String ?: "proceed") {
            "handledByHost" -> PermissionHandling.HandledByHost(map["granted"] as? Boolean ?: false)
            else -> PermissionHandling.Proceed
        }
    }

    /**
     * All 9 standard paywall lifecycle methods + post-purchase hooks. `internal` (SPEC-497 §3.4 test
     * seam, as [OnboardingDelegateForwarder] already is).
     */
    internal inner class PaywallDelegateForwarder : AppDNAPaywallDelegate {
        override fun onPaywallPresented(paywallId: String) {
            emit(paywallEventSink, "onPaywallPresented", mapOf("paywallId" to paywallId))
        }

        override fun onPaywallAction(paywallId: String, action: PaywallAction) {
            emit(
                paywallEventSink,
                "onPaywallAction",
                mapOf("paywallId" to paywallId, "action" to action.value),
            )
        }

        override fun onPaywallPurchaseStarted(paywallId: String, productId: String) {
            emit(
                paywallEventSink,
                "onPaywallPurchaseStarted",
                mapOf("paywallId" to paywallId, "productId" to productId),
            )
        }

        override fun onPaywallPurchaseCompleted(
            paywallId: String,
            productId: String,
            transaction: TransactionInfo,
        ) {
            emit(
                paywallEventSink,
                "onPaywallPurchaseCompleted",
                mapOf(
                    "paywallId" to paywallId,
                    "productId" to productId,
                    "transaction" to transactionToMap(transaction),
                ),
            )
        }

        // SPEC-497 §3.4 (R8-S1) — every native caller uses the 4-arg overload, whose default chains
        // 4 → 3 → 2 and drops `errorType` / `productId`; overriding only the 2-arg one handed Dart
        // `errorType: 'unknown'` and `productId: null`, so a host on `revenueCat` could not tell "start
        // the purchase with RevenueCat" from a failure. The 4-arg override emits the ONE event; the
        // 2- and 3-arg ones delegate to it (never the reverse).
        override fun onPaywallPurchaseFailed(
            paywallId: String,
            error: Throwable,
            errorType: String,
            productId: String?,
        ) {
            emit(
                paywallEventSink,
                "onPaywallPurchaseFailed",
                mapOf(
                    "paywallId" to paywallId,
                    "error" to throwableToMap(error),
                    "errorType" to errorType,
                    "productId" to productId,
                ),
            )
        }

        override fun onPaywallPurchaseFailed(paywallId: String, error: Throwable, errorType: String) {
            onPaywallPurchaseFailed(paywallId, error, errorType, null)
        }

        override fun onPaywallPurchaseFailed(paywallId: String, error: Throwable) {
            onPaywallPurchaseFailed(paywallId, error, ai.appdna.sdk.billing.billingErrorType(error), null)
        }

        override fun onPaywallRestoreStarted(paywallId: String) {
            emit(paywallEventSink, "onPaywallRestoreStarted", mapOf("paywallId" to paywallId))
        }

        override fun onPaywallRestoreCompleted(paywallId: String, productIds: List<String>) {
            emit(
                paywallEventSink,
                "onPaywallRestoreCompleted",
                mapOf("paywallId" to paywallId, "restoredProductIds" to productIds),
            )
        }

        override fun onPaywallRestoreFailed(paywallId: String, error: Throwable) {
            emit(
                paywallEventSink,
                "onPaywallRestoreFailed",
                mapOf("paywallId" to paywallId, "error" to throwableToMap(error)),
            )
        }

        override fun onPaywallDismissed(paywallId: String) {
            emit(paywallEventSink, "onPaywallDismissed", mapOf("paywallId" to paywallId))
        }

        override fun onPostPurchaseDeepLink(paywallId: String, url: String) {
            emit(
                paywallEventSink,
                "onPostPurchaseDeepLink",
                mapOf("paywallId" to paywallId, "url" to url),
            )
        }

        override fun onPostPurchaseNextStep(paywallId: String) {
            emit(paywallEventSink, "onPostPurchaseNextStep", mapOf("paywallId" to paywallId))
        }

        // SPEC-070-C H3 — route promo-code validation through the sync_callbacks
        // channel and feed the host's Boolean decision back into the native
        // completion. Default REJECT (false) on no host reply / timeout, so an
        // absent host never accepts an unvalidated code.
        override fun onPromoCodeSubmit(paywallId: String, code: String, completion: (Boolean) -> Unit) {
            scope.launch {
                val reply = invokeDart(
                    "onPromoCodeSubmit",
                    mapOf("paywallId" to paywallId, "code" to code),
                )
                completion((reply as? Boolean) ?: false)
            }
        }
    }

    /** Onboarding observe-only callbacks (4 methods). */
    /** `internal` so the JVM bridge test can drive the real forwarder. */
    internal inner class OnboardingDelegateForwarder : AppDNAOnboardingDelegate {
        override fun onOnboardingStarted(flowId: String) {
            emit(onboardingEventSink, "onOnboardingStarted", mapOf("flowId" to flowId))
        }

        override fun onOnboardingStepChanged(
            flowId: String,
            stepId: String,
            stepIndex: Int,
            totalSteps: Int,
        ) {
            emit(
                onboardingEventSink,
                "onOnboardingStepChanged",
                mapOf(
                    "flowId" to flowId,
                    "stepId" to stepId,
                    "stepIndex" to stepIndex,
                    "totalSteps" to totalSteps,
                ),
            )
        }

        override fun onOnboardingCompleted(flowId: String, responses: Map<String, Any>) {
            emit(
                onboardingEventSink,
                "onOnboardingCompleted",
                mapOf("flowId" to flowId, "responses" to responses),
            )
        }

        override fun onOnboardingDismissed(flowId: String, atStep: Int) {
            emit(
                onboardingEventSink,
                "onOnboardingDismissed",
                mapOf("flowId" to flowId, "atStep" to atStep),
            )
        }

        // SPEC-070-C §3.6 — observe-only permission-result callback (native
        // fires this on the onboarding listener after a runtime permission
        // resolves). Emitted on the observe channel; NOT a sync_callbacks veto.
        override fun onPermissionResult(
            flowId: String,
            stepId: String,
            permissionType: String,
            granted: Boolean,
        ) {
            emit(
                onboardingEventSink,
                "onPermissionResult",
                mapOf(
                    "flowId" to flowId,
                    "stepId" to stepId,
                    "permissionType" to permissionType,
                    "granted" to granted,
                ),
            )
        }

        // SPEC-070-C Phase 2a — async return-value hooks. Each invokes the Dart
        // host over the sync_callbacks channel, awaits the reply map, converts
        // it to the native return DTO, and falls back to the SDK default on
        // null/timeout. The invoker + to*() decoders live on the outer plugin.

        override suspend fun onBeforeStepAdvance(
            flowId: String,
            fromStepId: String,
            stepIndex: Int,
            stepType: String,
            responses: Map<String, Any>,
            stepData: Map<String, Any>?,
        ): StepAdvanceResult {
            val args = mutableMapOf<String, Any?>(
                "flowId" to flowId,
                "fromStepId" to fromStepId,
                "stepIndex" to stepIndex,
                "stepType" to stepType,
                "responses" to responses,
            )
            if (stepData != null) args["stepData"] = stepData
            // SPEC-497 §4.2 — a sign-in action spans OS UI the host cannot shorten, so the bridge waits
            // at least the core floor (120 s) for it; every other step keeps the configured vetoTimeout.
            val reply = invokeDart(
                "onBeforeStepAdvance",
                args,
                timeoutMs = maxOf(syncCallbackTimeoutMs, StepAdvanceResult.minimumBridgeTimeoutMs(stepData) ?: 0L),
            )
            // 🔴 AN AUTH ACTION MAY ONLY ADVANCE ON AN EXPLICIT, RECOGNISED HOST DECISION.
            //
            // The Flutter plugin ALWAYS binds this forwarder before presenting, so the core renderer's
            // own gate (`delegate == nil`) never fires — exactly as on React Native. And Flutter had
            // THREE ways to advance a credential step with nobody authenticating: a `null` reply, a `{}`
            // reply (`map["type"] ?: "proceed"`), and the Dart base class's default `onBeforeStepAdvance`
            // which literally RETURNS `{}`. So a published `login` / `verify_otp` / `social_login` step
            // advanced the user into the app on the SDK's own default. This is the same fix RN got in
            // `AppdnaDelegates`; it was missing on the SDK that actually ships on pub.dev.
            if (isAuthAction(stepData) && !isExplicitDecision(reply)) {
                return StepAdvanceResult.Block(AUTH_UNAVAILABLE_MESSAGE)
            }
            return toStepAdvanceResult(reply)
        }

        override suspend fun onBeforeStepRender(
            flowId: String,
            stepId: String,
            stepIndex: Int,
            stepType: String,
            responses: Map<String, Any>,
        ): StepConfigOverride? {
            return toStepConfigOverride(
                invokeDart(
                    "onBeforeStepRender",
                    mapOf(
                        "flowId" to flowId,
                        "stepId" to stepId,
                        "stepIndex" to stepIndex,
                        "stepType" to stepType,
                        "responses" to responses,
                    ),
                ),
            )
        }

        override suspend fun onElementInteraction(
            flowId: String,
            stepId: String,
            blockId: String,
            action: String,
            value: String?,
            inputValues: Map<String, Any>,
        ): ElementInteractionResult? {
            val args = mutableMapOf<String, Any?>(
                "flowId" to flowId,
                "stepId" to stepId,
                "blockId" to blockId,
                "action" to action,
                "inputValues" to inputValues,
            )
            if (value != null) args["value"] = value
            // SPEC-496 §5b C5.5 — wait at least as long as the SDK's own deadline for this action.
            return toElementInteractionResult(
                invokeDart(
                    "onElementInteraction",
                    args,
                    timeoutMs = maxOf(syncCallbackTimeoutMs, ElementInteractionResult.minimumBridgeTimeoutMs(action) ?: 0L),
                ),
            )
        }

        override suspend fun onPermissionRequest(permissionType: String): PermissionHandling? {
            return toPermissionHandling(
                invokeDart("onPermissionRequest", mapOf("permissionType" to permissionType)),
            )
        }
    }

    /** Survey lifecycle (3 methods). */
    private inner class SurveyDelegateForwarder : AppDNASurveyDelegate {
        override fun onSurveyPresented(surveyId: String) {
            emit(surveyEventSink, "onSurveyPresented", mapOf("surveyId" to surveyId))
        }

        override fun onSurveyCompleted(surveyId: String, responses: List<SurveyResponse>) {
            emit(
                surveyEventSink,
                "onSurveyCompleted",
                mapOf("surveyId" to surveyId, "responses" to responses.map { surveyResponseToMap(it) }),
            )
        }

        override fun onSurveyDismissed(surveyId: String) {
            emit(surveyEventSink, "onSurveyDismissed", mapOf("surveyId" to surveyId))
        }
    }

    /** In-app message lifecycle (3 observe + 1 veto). */
    private inner class InAppMessageDelegateForwarder : AppDNAInAppMessageDelegate {
        override fun onMessageShown(messageId: String, trigger: String) {
            emit(
                inAppMessageEventSink,
                "onMessageShown",
                mapOf("messageId" to messageId, "trigger" to trigger),
            )
        }

        override fun onMessageAction(messageId: String, action: String, data: Map<String, Any>?) {
            emit(
                inAppMessageEventSink,
                "onMessageAction",
                mapOf("messageId" to messageId, "action" to action, "data" to data),
            )
        }

        override fun onMessageDismissed(messageId: String) {
            emit(inAppMessageEventSink, "onMessageDismissed", mapOf("messageId" to messageId))
        }

        /**
         * Veto hook. The real host veto runs through the async wrapper
         * (`setAsyncShouldShowMessage`, registered in onListen) over the
         * sync_callbacks channel — the native SDK awaits it in ADDITION to this
         * synchronous method. This sync path can't await a Dart roundtrip, so it
         * returns `true` (allow) and defers the decision to the async wrapper.
         */
        override fun shouldShowMessage(messageId: String): Boolean {
            return true
        }
    }

    /** Push notification lifecycle (3 methods). */
    private inner class PushDelegateForwarder : AppDNAPushDelegate {
        override fun onPushTokenRegistered(token: String) {
            emit(pushEventSink, "onPushTokenRegistered", mapOf("token" to token))
        }

        override fun onPushReceived(notification: PushPayload, inForeground: Boolean) {
            emit(
                pushEventSink,
                "onPushReceived",
                mapOf(
                    "notification" to pushPayloadToMap(notification),
                    "inForeground" to inForeground,
                ),
            )
        }

        override fun onPushTapped(notification: PushPayload, actionId: String?) {
            emit(
                pushEventSink,
                "onPushTapped",
                mapOf(
                    "notification" to pushPayloadToMap(notification),
                    "actionId" to actionId,
                ),
            )
        }
    }

    /** Billing observer (5 methods incl. onBillingUnavailable). */
    private inner class BillingDelegateForwarder : AppDNABillingDelegate {
        override fun onPurchaseCompleted(productId: String, transaction: TransactionInfo) {
            // SPEC-497 D-R40-1 — the delivery-queue drain calls this synchronously on Main and counts
            // the entry delivered when it returns, so on Main the event goes to the sink read NOW (not a
            // later coroutine that could find the stream cancelled). Off Main, the usual hop.
            val args = mapOf("productId" to productId, "transaction" to transactionToMap(transaction))
            // No Dart listener any more (the stream was cancelled after the drain read this forwarder):
            // THROW, so the drain keeps the entry queued for the next listener instead of counting a
            // delivery nobody received. The live purchase path catches and logs it.
            val sink = billingDelegateEventSink
                ?: throw IllegalStateException("no Dart billing listener — the purchase stays queued")
            if (Looper.myLooper() == Looper.getMainLooper()) {
                emitNow(sink, "onPurchaseCompleted", args)
            } else {
                emit(sink, "onPurchaseCompleted", args)
            }
        }

        override fun onPurchaseFailed(productId: String, error: Throwable) {
            emit(
                billingDelegateEventSink,
                "onPurchaseFailed",
                mapOf("productId" to productId, "error" to throwableToMap(error)),
            )
        }

        override fun onEntitlementsChanged(entitlements: List<Entitlement>) {
            emit(
                billingDelegateEventSink,
                "onEntitlementsChanged",
                mapOf("entitlements" to entitlements.map { entitlementToMap(it) }),
            )
        }

        override fun onRestoreCompleted(restoredProducts: List<String>) {
            emit(
                billingDelegateEventSink,
                "onRestoreCompleted",
                mapOf("restoredProductIds" to restoredProducts),
            )
        }

        override fun onBillingUnavailable() {
            emit(billingDelegateEventSink, "onBillingUnavailable", emptyMap())
        }
    }

    /** Deep link receiver (1 method on the native interface). */
    private inner class DeepLinkDelegateForwarder : AppDNADeepLinkDelegate {
        override fun onDeepLinkReceived(url: String, params: Map<String, String>) {
            emit(
                deepLinkEventSink,
                "onDeepLinkReceived",
                mapOf("url" to url, "params" to params),
            )
        }
    }

    /** Server-driven screen lifecycle (3 observe + 1 veto). */
    private inner class ScreenDelegateForwarder : AppDNAScreenDelegate {
        override fun onScreenPresented(screenId: String) {
            emit(screenEventSink, "onScreenPresented", mapOf("screenId" to screenId))
        }

        override fun onScreenDismissed(screenId: String, result: Map<String, Any?>) {
            // SPEC-070-C — the native SDK emits snake_case result keys; iOS's
            // forwarder emits camelCase. Canonicalize on camelCase (the rest of
            // the Flutter bridge) so cross-platform host code reads one shape.
            emit(
                screenEventSink,
                "onScreenDismissed",
                mapOf("screenId" to screenId, "result" to camelCaseResultKeys(result)),
            )
        }

        override fun onFlowCompleted(flowId: String, result: Map<String, Any?>) {
            // SPEC-070-C — see onScreenDismissed: normalize native snake_case
            // result keys to iOS's camelCase.
            emit(
                screenEventSink,
                "onFlowCompleted",
                mapOf("flowId" to flowId, "result" to camelCaseResultKeys(result)),
            )
        }

        /**
         * Veto hook. The real host veto runs through the async wrapper
         * (`asyncOnScreenAction`, registered in onListen) over the sync_callbacks
         * channel — the native SDK awaits it before performing the action. This
         * synchronous path can't await a Dart roundtrip, so it returns `true`
         * (allow) and defers the decision to the async wrapper.
         */
        override fun onScreenAction(screenId: String, action: Map<String, Any?>): Boolean {
            return true
        }

        /**
         * Remap the native ScreenResult/FlowResult top-level snake_case keys to
         * the camelCase keys iOS emits (matching `screenResultToMap` /
         * `flowResultToMap` in AppdnaPlugin.swift). Only the known top-level
         * keys are renamed; values (incl. the arbitrary `responses` map) pass
         * through untouched so user data keys are never mangled.
         */
        private fun camelCaseResultKeys(result: Map<String, Any?>): Map<String, Any?> {
            val out = LinkedHashMap<String, Any?>(result.size)
            for ((key, value) in result) {
                val camel = when (key) {
                    "screen_id" -> "screenId"
                    "last_action" -> "lastAction"
                    "flow_id" -> "flowId"
                    "last_screen_id" -> "lastScreenId"
                    "screens_viewed" -> "screensViewed"
                    else -> key
                }
                // SPEC-070-C LOW-1 — the native Android SDK emits the ScreenError
                // as its SCREAMING_SNAKE `enum.name` (e.g. SCREEN_NOT_FOUND); iOS
                // emits the Codable camelCase rawValue (screenNotFound). Round-3
                // normalized result KEYS but not this VALUE — convert it too so
                // cross-platform hosts compare one string.
                out[camel] = if (camel == "error" && value is String) iosScreenErrorValue(value) else value
            }
            return out
        }

        /**
         * SPEC-070-C LOW-1 — map the Android `ScreenError.name` (SCREAMING_SNAKE)
         * to the iOS `ScreenError` Codable camelCase rawValue. The two enums are
         * defined in the same order with matching cases; unknown values pass
         * through untouched.
         */
        private fun iosScreenErrorValue(name: String): String = when (name) {
            "CONFIG_FETCH_FAILED" -> "configFetchFailed"
            "CONFIG_FETCH_TIMEOUT" -> "configFetchTimeout"
            "SCREEN_NOT_FOUND" -> "screenNotFound"
            "CONFIG_PARSE_ERROR" -> "configParseError"
            "CONFIG_INVALID" -> "configInvalid"
            "NESTING_DEPTH_EXCEEDED" -> "nestingDepthExceeded"
            else -> name
        }
    }

    /**
     * SPEC-070-C §3.1 — Android-only init-degradation delegate. Forwards
     * `onInitDegraded(reason)` as an observe-only `{ message, type }` map on
     * the init event channel.
     */
    private inner class InitDelegateForwarder : AppDNAInitDelegate {
        override fun onInitDegraded(reason: Throwable) {
            emit(initEventSink, "onInitDegraded", mapOf("error" to throwableToMap(reason)))
        }
    }

    /**
     * SPEC-404 — runtime-lock lifecycle delegate. Forwards
     * `onSdkRuntimeLocked(reason, lockedAt)` / `onSdkRuntimeUnlocked()` as
     * observe-only envelopes on the lifecycle event channel. `lockedAt` is the
     * native ISO-8601 String verbatim (same type iOS emits).
     */
    private inner class LifecycleDelegateForwarder : AppDNALifecycleDelegate {
        override fun onSdkRuntimeLocked(reason: String, lockedAt: String) {
            emit(
                lifecycleEventSink,
                "onSdkRuntimeLocked",
                mapOf("reason" to reason, "lockedAt" to lockedAt),
            )
        }

        override fun onSdkRuntimeUnlocked() {
            emit(lifecycleEventSink, "onSdkRuntimeUnlocked", emptyMap())
        }
    }
}

/**
 * SPEC-448 §B — `[blockId: [option maps]]` from the channel into typed options.
 *
 * Routed through the SAME `parseInputOptionList` the config parser uses, rather than hand-mapped
 * here: a hand-mapped copy would drift from the DTO the first time a field was added, and the
 * host's options would quietly lose it.
 */
/**
 * SPEC-448 §B — `[blockId: [option maps]]` from the channel into typed options.
 *
 * A one-line forward into the core, which is all a wrapper is allowed to be. The previous version
 * reached into `OnboardingConfigParser`, which is `internal` — so from this separate Gradle module
 * it did not compile AT ALL. Nothing caught it: the Flutter CI job runs `flutter analyze` and
 * `flutter test`, which are Dart-only and never build this plugin's Kotlin, so the break would
 * have surfaced first in a customer's Android build.
 */
private fun decodeFieldOptions(raw: Any?): Map<String, List<ai.appdna.sdk.onboarding.InputOption>>? =
    ai.appdna.sdk.onboarding.StepConfigOverride.decodeFieldOptions(raw)
