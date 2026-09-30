library appdna_sdk;

import 'dart:async';
import 'package:flutter/services.dart';
import 'generated/delegates.dart';
import 'models/web_entitlement.dart';
import 'models/deferred_deep_link.dart';
import 'models/paywall_context.dart';
import 'models/appdna_options.dart';
import 'models/location_data.dart';
import 'billing.dart';

export 'models/web_entitlement.dart';
export 'models/deferred_deep_link.dart';
export 'models/paywall_context.dart';
export 'models/survey_result.dart';
export 'models/appdna_options.dart';
export 'models/location_data.dart';
// SPEC-451 — the route a `map` block draws, supplied by the host at runtime.
export 'models/map_route.dart';
export 'billing.dart';
export 'push.dart';

// SPEC-070-C Phase 2b — inline server-driven screen slot widget. Hosts the
// native AppDNAScreenSlot (SwiftUI / Compose) as a Flutter platform view.
export 'screen_slot.dart';

// Generated delegate interfaces are the canonical public API (SPEC-070-0).
// These supersede the previously hand-written abstract classes that lived
// at the bottom of this file. Customer code that implemented the old
// classes continues to work because the generated ones are supersets.
export 'generated/delegates.dart';

// Generated DTOs. The `AppDNAEnvironment` DTO class collides with the
// legacy `AppDNAEnvironment` enum below (kept for `AppDNA.configure(env:)`
// backwards-compatibility), so we hide it from the public surface here.
// Once consumers migrate off the enum, the hide clause can be dropped and
// the enum renamed.
//
// SPEC-070-C — `AppDNAPushPayload` / `AppDNAPushAction` are the CONFIG-wire
// push shape (snake_case: push_id/image_url + an `actions` ARRAY) modelled on
// the `push_payload/*` behavioral fixtures. They are NOT the runtime push
// object: the live `AppDNA.push.setDelegate` path delivers a raw camelCase
// `Map<String, dynamic>` (`pushId`/`imageUrl`/`data`/single `action:{type,value}`
// — see push.dart). A host that fed the runtime notification map into
// `AppDNAPushPayload.fromMap` would get a TypeError, so these config DTOs are
// hidden from the public surface to remove that trap.
export 'generated/dtos.dart'
    hide AppDNAEnvironment, AppDNAPushPayload, AppDNAPushAction;

enum AppDNAEnvironment { production, staging }

/// Main entry point for the AppDNA Flutter SDK.
/// Thin wrapper around native iOS/Android SDKs via platform channels.
class AppDNA {
  static const MethodChannel _channel = MethodChannel('com.appdna.sdk/main');
  static const EventChannel _webEntitlementChannel =
      EventChannel('com.appdna.sdk/web_entitlement');

  /// Initialize the SDK. Call once at app startup.
  /// SPEC-070-C §5 — bidirectional sync-callback channel. Native invokes Dart on
  /// this channel for async return-value hooks + host-veto decisions and awaits the
  /// reply (the MethodChannel reply IS the correlation; native applies a
  /// timeout-default so a slow/absent host never deadlocks).
  static const MethodChannel _syncChannel =
      MethodChannel('com.appdna.sdk/sync_callbacks');
  static bool _syncCallbacksWired = false;

  /// SPEC-070-C §3.1 — Android-only init-degradation delegate stream. Native
  /// emits `onInitDegraded` here when `configure()` completes in a degraded
  /// state. iOS has no equivalent (documented no-op: the stream never emits).
  static const EventChannel _initChannel =
      EventChannel('com.appdna.sdk/events/init');
  static AppDNAInitDelegate? _initDelegate;
  static StreamSubscription? _initSub;

  /// SPEC-404 — backend-driven runtime-lock lifecycle stream. Native (iOS +
  /// Android) emits `onSdkRuntimeLocked` / `onSdkRuntimeUnlocked` here once per
  /// lock-state transition. Supported on BOTH platforms (unlike the init
  /// stream). Register via [AppDNA.setLifecycleDelegate].
  static const EventChannel _lifecycleChannel =
      EventChannel('com.appdna.sdk/events/lifecycle');
  static AppDNALifecycleDelegate? _lifecycleDelegate;
  static StreamSubscription? _lifecycleSub;

  static void _ensureSyncCallbacks() {
    if (_syncCallbacksWired) return;
    _syncCallbacksWired = true;
    _syncChannel.setMethodCallHandler(_handleSyncCallback);
  }

  /// Dispatches a native sync-callback to the registered host delegate and returns
  /// its result (Future for the async onboarding hooks; bool for the vetos). Returns
  /// the SDK's default when no delegate is registered so native proceeds normally.
  static Future<dynamic> _handleSyncCallback(MethodCall call) async {
    final args =
        (call.arguments as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    String s(String k) => args[k] as String? ?? '';
    int i(String k) => (args[k] as num?)?.toInt() ?? 0;
    Map<String, dynamic> m(String k) =>
        (args[k] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};

    switch (call.method) {
      // ── Onboarding async return-value hooks (Phase 2a) ───────────────────
      case 'onBeforeStepAdvance':
        return await onboarding._delegate?.onBeforeStepAdvance(
          s('flowId'), s('fromStepId'), i('stepIndex'), s('stepType'),
          m('responses'), (args['stepData'] as Map?)?.cast<String, dynamic>(),
        );
      case 'onBeforeStepRender':
        return await onboarding._delegate?.onBeforeStepRender(
          s('flowId'), s('stepId'), i('stepIndex'), s('stepType'), m('responses'),
        );
      case 'onElementInteraction':
        return await onboarding._delegate?.onElementInteraction(
          s('flowId'), s('stepId'), s('blockId'), s('action'),
          args['value'] as String?, m('inputValues'),
        );
      case 'onPermissionRequest':
        return await onboarding._delegate?.onPermissionRequest(s('permissionType'));
      // ── Host-veto decisions (D10; native seams land in Phase 2b) ─────────
      case 'shouldShowMessage':
        return inAppMessages._delegate?.shouldShowMessage(s('messageId')) ?? true;
      case 'onScreenAction':
        return screen._delegate?.onScreenAction(s('screenId'), m('action')) ?? true;
      case 'shouldOpen':
        return deepLinks._delegate?.shouldOpen(s('url'), m('params')) ?? true;
      // §3.7 promo-code veto — completion-based natively. Default REJECT (false)
      // when no delegate is registered (native also rejects on timeout).
      case 'onPromoCodeSubmit':
        return await paywall._delegate?.onPromoCodeSubmit(s('paywallId'), s('code')) ??
            false;
      default:
        return null;
    }
  }

  static Future<void> configure({
    required String apiKey,
    AppDNAEnvironment env = AppDNAEnvironment.production,
    AppDNAOptions? options,
  }) async {
    _ensureSyncCallbacks();
    // Always send an options map — even when the caller passes none — so `frameworkVersion`
    // reaches native on the common `configure(apiKey:)` path. The `framework` TAG is not in this
    // map at all: native injects it (§7 rule 1). It used to travel through here, which is exactly
    // what made it spoofable and what let a bare map mean "native".
    await _channel.invokeMethod('configure', {
      'apiKey': apiKey,
      'env': env.name,
      'options': (options ?? const AppDNAOptions()).toMap(),
    });
  }

  /// Set log verbosity level at runtime.
  /// Valid levels: 'none', 'error', 'warning', 'info', 'debug'.
  static void setLogLevel(String level) {
    _channel.invokeMethod('setLogLevel', {'level': level});
  }

  /// Identify a user.
  static Future<void> identify(String userId,
      {Map<String, dynamic>? traits}) async {
    await _channel.invokeMethod('identify', {
      'userId': userId,
      'traits': traits,
    });
  }

  /// Clear user identity.
  static Future<void> reset() async {
    await _channel.invokeMethod('reset');
  }

  /// Track a custom event.
  static Future<void> track(String event,
      {Map<String, dynamic>? properties}) async {
    await _channel.invokeMethod('track', {
      'event': event,
      'properties': properties,
    });
  }

  /// Force flush all queued events.
  static Future<void> flush() async {
    await _channel.invokeMethod('flush');
  }

  /// Present a paywall.
  ///
  /// 🔴 THIS RETURNED `Future<void>` AND THREW THE NATIVE ANSWER AWAY.
  ///
  /// Both natives return a Bool — false when the id is not in the published config, when the SDK is
  /// not configured yet, or when it is runtime-locked. This facade discarded it, so `await
  /// AppDNA.presentPaywall('typo_id')` completed SUCCESSFULLY and told a Flutter host the paywall had
  /// been shown. No paywall ever appeared. That is exactly the defect the Bool was added to fix, still
  /// live on Flutter — on the surface that takes the money.
  ///
  /// Returns false if nothing was presented.
  static Future<bool> presentPaywall(String id,
      {PaywallContext? context}) async {
    final shown = await _channel.invokeMethod<bool>('presentPaywall', {
      'id': id,
      'context': context?.toMap(),
    });
    return shown ?? false;
  }

  /// Present an onboarding flow.
  ///
  /// 🔴 THIS RETURNED `Future<void>` AND THREW THE NATIVE ANSWER AWAY — the same defect
  /// [presentPaywall] was fixed for, left live on onboarding.
  ///
  /// Both natives return a Bool (`AppDNA+Modules.swift` / `AppDNAModules.kt` `present(...)`), false
  /// when the flow id is not in the published config, when the SDK is not configured yet, or when
  /// there is no view controller / Activity to present from. Discarding it meant
  /// `await AppDNA.presentOnboarding('typo_id')` completed SUCCESSFULLY with no onboarding on
  /// screen, and a Flutter host had no way to tell that from a flow that ran. Found while building
  /// the SPEC-495 device harness, where exactly that cost a debugging cycle: the only way to learn
  /// nothing had been presented was to read logcat.
  ///
  /// Returns false if nothing was presented.
  static Future<bool> presentOnboarding(String flowId) async {
    final shown =
        await _channel.invokeMethod<bool>('presentOnboarding', {'flowId': flowId});
    return shown ?? false;
  }

  /// Get a remote config value by key.
  static Future<dynamic> getRemoteConfig(String key) async {
    return await _channel.invokeMethod('getRemoteConfig', {'key': key});
  }

  /// Check if a feature flag is enabled.
  static Future<bool> isFeatureEnabled(String flag) async {
    final result =
        await _channel.invokeMethod<bool>('isFeatureEnabled', {'flag': flag});
    return result ?? false;
  }

  /// Get the variant assignment for an experiment.
  static Future<String?> getExperimentVariant(String experimentId) async {
    return await _channel.invokeMethod<String>(
        'getExperimentVariant', {'experimentId': experimentId});
  }

  /// Check if the user is in a specific variant.
  static Future<bool> isInVariant(
      String experimentId, String variantId) async {
    final result = await _channel.invokeMethod<bool>('isInVariant', {
      'experimentId': experimentId,
      'variantId': variantId,
    });
    return result ?? false;
  }

  /// Get experiment config value.
  static Future<dynamic> getExperimentConfig(
      String experimentId, String key) async {
    return await _channel.invokeMethod('getExperimentConfig', {
      'experimentId': experimentId,
      'key': key,
    });
  }

  /// Set push token. Registers with backend for direct push delivery.
  static Future<void> setPushToken(String token) async {
    await _channel.invokeMethod('setPushToken', {'token': token});
  }

  /// Report push permission status.
  static Future<void> setPushPermission(bool granted) async {
    await _channel.invokeMethod('setPushPermission', {'granted': granted});
  }

  /// Track push notification delivered (SPEC-030).
  static Future<void> trackPushDelivered(String pushId) async {
    await _channel.invokeMethod('trackPushDelivered', {'pushId': pushId});
  }

  /// Track push notification tapped (SPEC-030).
  static Future<void> trackPushTapped(String pushId, {String? action}) async {
    await _channel.invokeMethod('trackPushTapped', {
      'pushId': pushId,
      if (action != null) 'action': action,
    });
  }

  /// Set analytics consent.
  static Future<void> setConsent({required bool analytics}) async {
    await _channel.invokeMethod('setConsent', {'analytics': analytics});
  }

  /// Register a ready callback.
  static Future<void> onReady(void Function() callback) async {
    final result = await _channel.invokeMethod<bool>('onReady');
    if (result == true) callback();
  }

  // MARK: - v0.3: Web Entitlements

  /// Get the current web subscription entitlement.
  static Future<WebEntitlement?> get webEntitlement async {
    final data = await _channel.invokeMethod<Map>('getWebEntitlement');
    if (data == null) return null;
    return WebEntitlement.fromMap(Map<String, dynamic>.from(data));
  }

  /// Listen for web entitlement changes.
  static Stream<WebEntitlement?> get onWebEntitlementChanged {
    return _webEntitlementChannel.receiveBroadcastStream().map((data) {
      if (data == null) return null;
      return WebEntitlement.fromMap(Map<String, dynamic>.from(data as Map));
    });
  }

  // MARK: - v0.3: Deferred Deep Links

  /// Check for a deferred deep link on first launch.
  static Future<DeferredDeepLink?> checkDeferredDeepLink() async {
    final data = await _channel.invokeMethod<Map>('checkDeferredDeepLink');
    if (data == null) return null;
    return DeferredDeepLink.fromMap(Map<String, dynamic>.from(data));
  }

  // MARK: - v1.0 Module Namespaces

  /// Push notification module.
  static final push = AppDNAPushModule._(_channel);

  /// Onboarding module.
  static final onboarding = AppDNAOnboardingModule._(_channel);

  /// Paywall module.
  static final paywall = AppDNAPaywallModule._(_channel);

  /// Remote config module.
  static final remoteConfig = AppDNARemoteConfigModule._(_channel);

  /// Feature flags module.
  static final features = AppDNAFeaturesModule._(_channel);

  /// Experiments module.
  static final experiments = AppDNAExperimentsModule._(_channel);

  /// In-app messages module.
  static final inAppMessages = AppDNAInAppMessagesModule._(_channel);

  /// Surveys module.
  static final surveys = AppDNASurveysModule._(_channel);

  /// Deep links module.
  static final deepLinks = AppDNADeepLinksModule._(_channel);

  /// Screen (server-driven UI) module.
  static final screen = AppDNAScreenModule._(_channel);

  /// Billing module.
  static AppDNABilling billing = AppDNABilling();

  // MARK: - Lifecycle

  /// Shut down the SDK and release resources.
  /// On Android this delegates to AppDNA.shutdown(); on iOS this is a no-op.
  static Future<void> shutdown() async {
    await _channel.invokeMethod('shutdown');
  }

  /// Get the native SDK version string (e.g. iOS "1.0.61" or Android "1.0.33").
  static Future<String> getSdkVersion() async {
    final version = await _channel.invokeMethod<String>('getSdkVersion');
    return version ?? 'unknown';
  }

  // MARK: - SPEC-070-C §3.1 lifecycle / core (full native parity)

  /// Register background tasks (iOS `BGTaskScheduler` event-upload / Android
  /// WorkManager). Call once at startup after `configure`. Real on both.
  static Future<void> registerBackgroundTasks() async {
    await _channel.invokeMethod('registerBackgroundTasks');
  }

  /// Whether analytics consent is currently granted.
  static Future<bool> isConsentGranted() async {
    final granted = await _channel.invokeMethod<bool>('isConsentGranted');
    return granted ?? false;
  }

  /// Emit a comprehensive SDK health report and return it as a string. Both
  /// platforms return the report (and also print it to the console) — iOS
  /// `diagnose()` was made `-> String` for parity with Android.
  static Future<String?> diagnose() async {
    return await _channel.invokeMethod<String>('diagnose');
  }

  /// Get the identified user's traits (empty map if none / not identified).
  static Future<Map<String, dynamic>> getUserTraits() async {
    final data = await _channel.invokeMethod<Map>('getUserTraits');
    return data == null ? {} : Map<String, dynamic>.from(data);
  }

  /// SPEC-070-C §3.1 — app-defined session data (a key/value store scoped to the
  /// SDK session). Values must be StandardMessageCodec-serializable.
  static Future<void> setSessionData(String key, Object value) async {
    await _channel.invokeMethod('setSessionData', {'key': key, 'value': value});
  }

  /// Retrieve a session-data value by key (null if unset).
  static Future<dynamic> getSessionData(String key) async {
    return await _channel.invokeMethod('getSessionData', {'key': key});
  }

  /// Clear all app-defined session data.
  static Future<void> clearSessionData() async {
    await _channel.invokeMethod('clearSessionData');
  }

  /// Force a forced-theme override. Valid values: `'light'`, `'dark'`,
  /// `'system'`, or `null` to follow the system. **Android-only** — a
  /// documented no-op on iOS (§3.14).
  static Future<void> setForcedTheme(String? theme) async {
    await _channel.invokeMethod('setForcedTheme', {'theme': theme});
  }

  /// Read the current forced-theme override (`'light'`/`'dark'`/`'system'`),
  /// or `null` when following the system. **Android-only** — always returns
  /// `null` on iOS (§3.14).
  static Future<String?> getForcedTheme() async {
    return await _channel.invokeMethod<String>('getForcedTheme');
  }

  /// Register a delegate notified when `configure()` completes in a degraded
  /// state (`onInitDegraded`). **Android-only** — on iOS the underlying stream
  /// never emits (§3.14). Pass `null` to clear.
  static void setInitDelegate(AppDNAInitDelegate? delegate) {
    _initDelegate = delegate;
    _initSub?.cancel();
    _initSub = null;
    if (delegate == null) return;
    _initSub = _initChannel.receiveBroadcastStream().listen((raw) {
      if (raw is! Map) return;
      final type = raw['type'] as String?;
      final args =
          (raw['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      if (type == 'onInitDegraded') {
        _initDelegate?.onInitDegraded(
          (args['error'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{},
        );
      }
    });
  }

  /// The last init error captured during `configure()` as a `{message, type}`
  /// map, or `null` if init succeeded. **Android-only** — returns `null` on
  /// iOS (§3.14).
  static Future<Map<String, dynamic>?> lastInitError() async {
    final data = await _channel.invokeMethod<Map>('getLastInitError');
    return data == null ? null : Map<String, dynamic>.from(data);
  }

  /// The app's brand accent colour as a hex string (e.g. `#6366F1`), or `null`
  /// until the brand config has loaded. Read-only value on BOTH platforms
  /// (iOS `AppDNA.brandAccentHex` / Android `AppDNA.brandAccentHex`) — §3.1.
  static Future<String?> brandAccentHex() async {
    return await _channel.invokeMethod<String>('getBrandAccentHex');
  }

  /// The current backend-driven SDK runtime lock as a `{reason, locked_at}`
  /// map, or `null` when the SDK is active (not locked). Pollable read on BOTH
  /// platforms (iOS `BootstrapRuntimeLock {reason, locked_at}` / Android
  /// `Pair<String,String>` = `(reason, locked_at)`) — §3.1. This is the
  /// synchronous pollable read; the transition-callback equivalent is
  /// [setLifecycleDelegate]'s `onSdkRuntimeLocked` — both exist by design.
  static Future<Map<String, dynamic>?> runtimeLock() async {
    final data = await _channel.invokeMethod<Map>('getRuntimeLock');
    return data == null ? null : Map<String, dynamic>.from(data);
  }

  /// The current config bundle version reported on events, or `null` if unknown.
  /// **Android-only** — returns `null` on iOS, whose `currentBundleVersion` is
  /// declared `internal` and is therefore not accessible cross-module from the
  /// plugin (§3.1 / §3.14).
  static Future<int?> currentBundleVersion() async {
    return await _channel.invokeMethod<int>('getCurrentBundleVersion');
  }

  /// The host-supplied notification small-icon drawable resource id (`0` means
  /// unset → the SDK falls back to manifest meta-data then the app icon), or
  /// `null` on iOS. **Android-only** — returns `null` on iOS (§3.14).
  ///
  /// Practical caveat: the paired [AppDNAOptions.notificationIcon] setter takes
  /// an Android drawable resource id (an `int` from `R.drawable.*`), which a
  /// pure-Dart host generally cannot produce — it is only meaningful when a
  /// native Android layer supplies the id. The option pass-through and this
  /// read are bridged regardless, to keep the full §3.1 surface (not dropped).
  static Future<int?> notificationIcon() async {
    return await _channel.invokeMethod<int>('getNotificationIcon');
  }

  /// SPEC-404 — register a delegate notified when the backend locks or unlocks
  /// the SDK runtime (e.g. billing overdue, org cancelled). Fires once per
  /// state transition on BOTH platforms. Pass `null` to clear the current
  /// delegate and stop listening.
  static void setLifecycleDelegate(AppDNALifecycleDelegate? delegate) {
    _lifecycleDelegate = delegate;
    _lifecycleSub?.cancel();
    _lifecycleSub = null;
    if (delegate == null) return;
    _lifecycleSub = _lifecycleChannel.receiveBroadcastStream().listen((raw) {
      if (raw is! Map) return;
      final type = raw['type'] as String?;
      final args =
          (raw['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      final d = _lifecycleDelegate;
      if (d == null || type == null) return;
      switch (type) {
        case 'onSdkRuntimeLocked':
          // lockedAt is an ISO-8601 string (raw for cross-platform parity —
          // matches the native Android/iOS emit type; host parses if needed).
          d.onSdkRuntimeLocked(
            args['reason'] as String? ?? '',
            args['lockedAt'] as String? ?? '',
          );
          break;
        case 'onSdkRuntimeUnlocked':
          d.onSdkRuntimeUnlocked();
          break;
        default:
          break;
      }
    });
  }

  // MARK: - SPEC-070-C §3.2 events

  /// Feed the current screen name so subsequent events carry `context.screen`
  /// (zero-code screen attribution). **Android-only** — a no-op on iOS (§3.14).
  static Future<void> notifyScreenAppeared(String screenName) async {
    await _channel.invokeMethod('notifyScreenAppeared', {'screenName': screenName});
  }

  // MARK: - SPEC-070-C §3.3 config

  /// Force an immediate remote-config refresh from the backend.
  static Future<void> forceRefreshConfig() async {
    await _channel.invokeMethod('forceRefreshConfig');
  }

  /// The applied config version for debugging. Pass a [flowId] to scope to a
  /// specific onboarding flow. Returns `null` when no config is applied yet.
  static Future<int?> debugAppliedConfigVersion({String? flowId}) async {
    final v = await _channel.invokeMethod<int>(
        'debugAppliedConfigVersion', {'flowId': flowId});
    return v;
  }

  // MARK: - SPEC-070-C §3.7 paywall

  /// Present a paywall by placement — the SDK auto-selects the best audience
  /// match. Real on Android; on iOS this routes to the placement-based
  /// `presentPaywall` overload (§3.14).
  /// Returns false if no paywall matched the placement (or the SDK could not present one) — see
  /// [presentPaywall] for why discarding this answer was a bug.
  static Future<bool> presentPaywallByPlacement(String placement,
      {PaywallContext? context}) async {
    final shown = await _channel.invokeMethod<bool>('presentPaywallByPlacement', {
      'placement': placement,
      'context': context?.toMap(),
    });
    return shown ?? false;
  }

  /// Shorthand to present a paywall by ID over the current top screen.
  /// Returns false if nothing was presented — see [presentPaywall].
  static Future<bool> showPaywall(String id) async {
    final shown = await _channel.invokeMethod<bool>('showPaywall', {'id': id});
    return shown ?? false;
  }

  /// Suppress the next auto-dismiss that would otherwise fire after a restore
  /// completes (so the host can present its own post-restore UX).
  static Future<void> skipNextAutoDismissOnRestore(bool value) async {
    await _channel
        .invokeMethod('skipNextAutoDismissOnRestore', {'value': value});
  }

  // MARK: - SPEC-070-C §3.9 surveys

  /// Shorthand to present a survey by ID.
  static Future<void> showSurvey(String id) async {
    await _channel.invokeMethod('showSurvey', {'id': id});
  }
}

/// SPEC-070-C §3.1 — delegate notified when the SDK finishes `configure()` in
/// a degraded state (e.g. Firebase unavailable). **Android-only**; on iOS the
/// backing stream never emits. Register via [AppDNA.setInitDelegate].
abstract class AppDNAInitDelegate {
  /// Called with a `{message, type}` map describing the degraded-init reason.
  void onInitDegraded(Map<String, dynamic> error);
}

// MARK: - Module Namespace Classes (v1.0)
//
// Each module that owns a delegate listens on a dedicated EventChannel under
// `com.appdna.sdk/events/<name>`. Native (iOS Swift + Android Kotlin) sinks
// emit a `{ type: <delegateMethodName>, args: { ... } }` envelope. Dart
// dispatches each envelope to the typed delegate method on the
// customer-set delegate. Unknown `type` values are ignored silently so new
// native events ship without forcing a Flutter package bump.

/// Push notification module namespace.
class AppDNAPushModule {
  final MethodChannel _channel;
  AppDNAPushDelegate? _delegate;
  StreamSubscription? _eventSub;
  static const _events = EventChannel('com.appdna.sdk/events/push');

  AppDNAPushModule._(this._channel);

  Future<void> setToken(String token) =>
      _channel.invokeMethod('setPushToken', {'token': token});
  Future<void> setPermission(bool granted) =>
      _channel.invokeMethod('setPushPermission', {'granted': granted});
  Future<void> trackDelivered(String pushId) =>
      _channel.invokeMethod('trackPushDelivered', {'pushId': pushId});
  Future<void> trackTapped(String pushId, {String? action}) =>
      _channel.invokeMethod('trackPushTapped',
          {'pushId': pushId, if (action != null) 'action': action});

  /// Request push notification permission from the OS.
  Future<bool> requestPermission() async {
    final result = await _channel.invokeMethod<bool>('requestPushPermission');
    return result ?? false;
  }

  /// Get the current push token.
  Future<String?> getToken() => _channel.invokeMethod<String>('getPushToken');

  /// Whether [data] is an AppDNA push — it carries the `appdna: "1"` marker the
  /// server adds. Use it in your own push handling (e.g. `firebase_messaging`)
  /// to leave AppDNA pushes to AppDNA. The check runs in the native SDK.
  Future<bool> isAppDNAMessage(Map<String, dynamic> data) async {
    final result = await _channel
        .invokeMethod<bool>('push.isAppDNAMessage', {'data': data});
    return result ?? false;
  }

  /// Forward a received push (e.g. `FirebaseMessaging.onMessage`'s
  /// `message.data`). For an AppDNA push the SDK tracks delivery once and
  /// fires `onPushReceived`; it never displays anything — your app owns
  /// display. Returns `false`, doing nothing, for any other push.
  Future<bool> handleMessage(Map<String, dynamic> data) async {
    final result = await _channel
        .invokeMethod<bool>('push.handleMessageData', {'data': data});
    return result ?? false;
  }

  /// Forward a notification tap (e.g. `FirebaseMessaging.onMessageOpenedApp`'s
  /// `message.data`, and [actionId] when an action button was tapped). For an
  /// AppDNA push the SDK tracks the tap once, fires `onPushTapped` and routes
  /// the push's action. Returns `false`, doing nothing, for any other push.
  Future<bool> handleTap(Map<String, dynamic> data, {String? actionId}) async {
    final result = await _channel.invokeMethod<bool>('push.handleTap', {
      'data': data,
      if (actionId != null) 'actionId': actionId,
    });
    return result ?? false;
  }

  /// Set a delegate to receive push notification callbacks.
  /// Pass `null` to clear the current delegate and stop listening.
  void setDelegate(AppDNAPushDelegate? delegate) {
    _delegate = delegate;
    _eventSub?.cancel();
    _eventSub = null;
    if (delegate == null) return;
    _eventSub = _events.receiveBroadcastStream().listen(_dispatch);
  }

  void _dispatch(dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type'] as String?;
    final args =
        (raw['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final d = _delegate;
    if (d == null || type == null) return;
    switch (type) {
      case 'onPushTokenRegistered':
        d.onPushTokenRegistered(args['token'] as String? ?? '');
        break;
      case 'onPushReceived':
        d.onPushReceived(
          (args['notification'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{},
          args['inForeground'] as bool? ?? false,
        );
        break;
      case 'onPushTapped':
        d.onPushTapped(
          (args['notification'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{},
          args['actionId'] as String?,
        );
        break;
      default:
        // Unknown event — forward-compat with future native methods.
        break;
    }
  }
}

/// Onboarding module namespace.
class AppDNAOnboardingModule {
  final MethodChannel _channel;
  AppDNAOnboardingDelegate? _delegate;
  StreamSubscription? _eventSub;
  static const _events = EventChannel('com.appdna.sdk/events/onboarding');

  AppDNAOnboardingModule._(this._channel);

  /// Present an onboarding flow. Returns false if nothing was presented — see
  /// [AppDNA.presentOnboarding] for why discarding this answer was a bug.
  Future<bool> present(String flowId, {OnboardingContext? context}) async {
    final shown = await _channel.invokeMethod<bool>('presentOnboarding', {
      'flowId': flowId,
      if (context != null) 'context': context.toMap(),
    });
    return shown ?? false;
  }

  /// Set a delegate to receive onboarding lifecycle callbacks.
  /// Pass `null` to clear the current delegate and stop listening.
  void setDelegate(AppDNAOnboardingDelegate? delegate) {
    _delegate = delegate;
    _eventSub?.cancel();
    _eventSub = null;
    if (delegate == null) return;
    _eventSub = _events.receiveBroadcastStream().listen(_dispatch);
  }

  void _dispatch(dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type'] as String?;
    final args =
        (raw['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final d = _delegate;
    if (d == null || type == null) return;
    switch (type) {
      case 'onOnboardingStarted':
        d.onOnboardingStarted(args['flowId'] as String? ?? '');
        break;
      case 'onOnboardingStepChanged':
        d.onOnboardingStepChanged(
          args['flowId'] as String? ?? '',
          args['stepId'] as String? ?? '',
          (args['stepIndex'] as num?)?.toInt() ?? 0,
          (args['totalSteps'] as num?)?.toInt() ?? 0,
        );
        break;
      case 'onOnboardingCompleted':
        d.onOnboardingCompleted(
          args['flowId'] as String? ?? '',
          (args['responses'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{},
        );
        break;
      case 'onOnboardingDismissed':
        d.onOnboardingDismissed(
          args['flowId'] as String? ?? '',
          (args['atStep'] as num?)?.toInt() ?? 0,
        );
        break;
      case 'onPermissionResult':
        d.onPermissionResult(
          args['flowId'] as String? ?? '',
          args['stepId'] as String? ?? '',
          args['permissionType'] as String? ?? '',
          args['granted'] as bool? ?? false,
        );
        break;
      default:
        break;
    }
  }
}

/// Paywall module namespace.
class AppDNAPaywallModule {
  final MethodChannel _channel;
  AppDNAPaywallDelegate? _delegate;
  StreamSubscription? _eventSub;
  static const _events = EventChannel('com.appdna.sdk/events/paywall');

  AppDNAPaywallModule._(this._channel);

  /// Present a paywall by id. Returns false if nothing was presented (the id is
  /// not in the published config, the SDK is unconfigured, or it is runtime-locked).
  ///
  /// 🔴 This is the facade the docs point hosts to, and it USED TO RETURN `Future<void>` —
  /// discarding the Bool the plugin already returns. `await AppDNA.paywall.present('typo_id')`
  /// completed cheerfully with no paywall shown. The top-level `AppDNA.presentPaywall` was fixed
  /// and this module facade was missed.
  Future<bool> present(String id, {PaywallContext? context}) async {
    final shown = await _channel.invokeMethod<bool>(
        'presentPaywall', {'id': id, 'context': context?.toMap()});
    return shown ?? false;
  }

  /// Set a delegate to receive paywall lifecycle callbacks.
  /// Pass `null` to clear the current delegate and stop listening.
  void setDelegate(AppDNAPaywallDelegate? delegate) {
    _delegate = delegate;
    _eventSub?.cancel();
    _eventSub = null;
    if (delegate == null) return;
    _eventSub = _events.receiveBroadcastStream().listen(_dispatch);
  }

  void _dispatch(dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type'] as String?;
    final args =
        (raw['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final d = _delegate;
    if (d == null || type == null) return;
    switch (type) {
      case 'onPaywallPresented':
        d.onPaywallPresented(args['paywallId'] as String? ?? '');
        break;
      case 'onPaywallAction':
        d.onPaywallAction(
          args['paywallId'] as String? ?? '',
          args['action'] as String? ?? '',
        );
        break;
      case 'onPaywallPurchaseStarted':
        d.onPaywallPurchaseStarted(
          args['paywallId'] as String? ?? '',
          args['productId'] as String? ?? '',
        );
        break;
      case 'onPaywallPurchaseCompleted':
        d.onPaywallPurchaseCompleted(
          args['paywallId'] as String? ?? '',
          args['productId'] as String? ?? '',
          (args['transaction'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{},
        );
        break;
      case 'onPaywallPurchaseFailed':
        // 🔴 FLUTTER DID NOT COMPILE. This passed TWO arguments to a FOUR-parameter delegate.
        //
        // `onPaywallPurchaseFailed` gained `errorType` + `productId` when the RN wrapper was found to
        // be ERASING them (it overrode the narrower overload, so the callback still fired while the
        // two values vanished). The delegate is CODEGEN'D from the IR, so it grew the two parameters
        // immediately — and RN's dispatcher was updated to pass them. This one, hand-written, was not.
        //
        // Dart is not TypeScript: `Too few positional arguments: 4 required, 2 given` is a COMPILE
        // ERROR, so `flutter analyze` and `flutter test` were both red — on a branch where nothing
        // said so, because the Flutter CI job only triggers on `packages/appdna-sdk-flutter/**` and
        // the change that broke it lived in `src/lib/sdk-delegates/`. A codegen source outside a
        // package's path filter can break that package with nothing to notice.
        d.onPaywallPurchaseFailed(
          args['paywallId'] as String? ?? '',
          // Generated delegate types this as `Object`; native sends either a
          // map ({ message, type }) or a raw string. Pass through verbatim.
          args['error'] ?? const <String, dynamic>{},
          // The stable discriminator — a host cannot introspect `error` across the bridge, so without
          // this it cannot tell a user cancel from a declined card from a dead network.
          args['errorType'] as String? ?? 'unknown',
          // Null only when no product was ever selected. A paywall selling two plans must say WHICH.
          args['productId'] as String?,
        );
        break;
      case 'onPaywallRestoreStarted':
        d.onPaywallRestoreStarted(args['paywallId'] as String? ?? '');
        break;
      case 'onPaywallRestoreCompleted':
        d.onPaywallRestoreCompleted(
          args['paywallId'] as String? ?? '',
          (args['restoredProductIds'] as List?)
                  ?.map((e) => e.toString())
                  .toList() ??
              const <String>[],
        );
        break;
      case 'onPaywallRestoreFailed':
        d.onPaywallRestoreFailed(
          args['paywallId'] as String? ?? '',
          args['error'] ?? const <String, dynamic>{},
        );
        break;
      case 'onPaywallDismissed':
        d.onPaywallDismissed(args['paywallId'] as String? ?? '');
        break;
      // SPEC-070-C §3.7 — post-purchase observe hooks.
      case 'onPostPurchaseDeepLink':
        d.onPostPurchaseDeepLink(
          args['paywallId'] as String? ?? '',
          args['url'] as String? ?? '',
        );
        break;
      case 'onPostPurchaseNextStep':
        d.onPostPurchaseNextStep(args['paywallId'] as String? ?? '');
        break;
      // NOTE: onPromoCodeSubmit is a veto — it flows through the sync_callbacks
      // channel (see AppDNA._handleSyncCallback), NOT this observe channel.
      default:
        break;
    }
  }
}

/// Remote config module namespace.
class AppDNARemoteConfigModule {
  final MethodChannel _channel;
  // SPEC-070-C M1 — a dedicated observe-only EventChannel. Native emits on it
  // when remote config changes (iOS `remoteConfig.onChanged` /
  // Android `remoteConfig.onChanged`). The old wiring set a handler on the MAIN
  // channel — which native never invoked AND which clobbered any other main
  // handler (incl. features.onChanged). Neither fired.
  static const _events = EventChannel('com.appdna.sdk/events/remote_config');
  StreamSubscription? _onChangedSub;
  AppDNARemoteConfigModule._(this._channel);

  Future<dynamic> get(String key) =>
      _channel.invokeMethod('getRemoteConfig', {'key': key});
  Future<void> refresh() => _channel.invokeMethod('refreshConfig');

  /// Get all remote config values as a map.
  Future<Map<String, dynamic>> getAll() async {
    final data = await _channel.invokeMethod<Map>('getAllRemoteConfig');
    if (data != null) {
      return Map<String, dynamic>.from(data);
    }
    return {};
  }

  /// Register a callback to be notified when remote config values change.
  /// Replaces any previously-registered callback.
  void onChanged(void Function() callback) {
    _onChangedSub?.cancel();
    _onChangedSub =
        _events.receiveBroadcastStream().listen((_) => callback());
  }
}

/// Feature flags module namespace.
class AppDNAFeaturesModule {
  final MethodChannel _channel;
  // SPEC-070-C M1 — dedicated observe-only EventChannel (see remote-config note).
  static const _events = EventChannel('com.appdna.sdk/events/features');
  StreamSubscription? _onChangedSub;
  AppDNAFeaturesModule._(this._channel);

  Future<bool> isEnabled(String flag) async {
    final result =
        await _channel.invokeMethod<bool>('isFeatureEnabled', {'flag': flag});
    return result ?? false;
  }

  /// Get the variant value for a feature flag (for multi-variate flags).
  Future<dynamic> getVariant(String flag) async {
    return await _channel.invokeMethod('getFeatureVariant', {'flag': flag});
  }

  /// Register a callback to be notified when feature flags change.
  /// Replaces any previously-registered callback.
  void onChanged(void Function() callback) {
    _onChangedSub?.cancel();
    _onChangedSub =
        _events.receiveBroadcastStream().listen((_) => callback());
  }
}

/// Experiments module namespace.
class AppDNAExperimentsModule {
  final MethodChannel _channel;
  AppDNAExperimentsModule._(this._channel);

  Future<String?> getVariant(String experimentId) =>
      _channel.invokeMethod<String>(
          'getExperimentVariant', {'experimentId': experimentId});
  Future<bool> isInVariant(String experimentId, String variantId) async {
    final result = await _channel.invokeMethod<bool>('isInVariant',
        {'experimentId': experimentId, 'variantId': variantId});
    return result ?? false;
  }

  /// Get all experiment exposures for the current user.
  Future<List<Map<String, dynamic>>> getExposures() async {
    final data = await _channel.invokeMethod<List>('getExperimentExposures');
    if (data != null) {
      return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return [];
  }
}

/// In-app messages module namespace.
class AppDNAInAppMessagesModule {
  final MethodChannel _channel;
  AppDNAInAppMessageDelegate? _delegate;
  StreamSubscription? _eventSub;
  static const _events = EventChannel('com.appdna.sdk/events/in_app_message');

  AppDNAInAppMessagesModule._(this._channel);

  Future<void> suppressDisplay(bool suppress) =>
      _channel.invokeMethod('suppressMessages', {'suppress': suppress});

  /// Set a delegate to receive in-app message lifecycle callbacks.
  /// Pass `null` to clear the current delegate and stop listening.
  void setDelegate(AppDNAInAppMessageDelegate? delegate) {
    _delegate = delegate;
    _eventSub?.cancel();
    _eventSub = null;
    if (delegate == null) return;
    _eventSub = _events.receiveBroadcastStream().listen(_dispatch);
  }

  void _dispatch(dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type'] as String?;
    final args =
        (raw['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final d = _delegate;
    if (d == null || type == null) return;
    switch (type) {
      case 'onMessageShown':
        final messageId = args['messageId'] as String? ?? '';
        final trigger = args['trigger'] as String? ?? '';
        d.onMessageShown(messageId, trigger);
        // Non-breaking shim: 1.0.5 hosts that overrode onMessagePresented still fire.
        // ignore: deprecated_member_use_from_same_package
        d.onMessagePresented(messageId);
        break;
      case 'onMessageAction':
        d.onMessageAction(
          args['messageId'] as String? ?? '',
          args['action'] as String? ?? '',
          (args['data'] as Map?)?.cast<String, dynamic>(),
        );
        break;
      case 'onMessageDismissed':
        d.onMessageDismissed(args['messageId'] as String? ?? '');
        break;
      // NOTE: shouldShowMessage is a veto — it flows through the sync_callbacks
      // channel (AppDNA._handleSyncCallback), NOT this observe channel. Invoking
      // it here too would run a side-effecting host predicate twice (SPEC-070-C L1).
      default:
        break;
    }
  }
}

/// Surveys module namespace.
class AppDNASurveysModule {
  final MethodChannel _channel;
  AppDNASurveyDelegate? _delegate;
  StreamSubscription? _eventSub;
  static const _events = EventChannel('com.appdna.sdk/events/survey');

  AppDNASurveysModule._(this._channel);

  Future<void> present(String surveyId) =>
      _channel.invokeMethod('presentSurvey', {'surveyId': surveyId});

  /// Set a delegate to receive survey lifecycle callbacks.
  /// Pass `null` to clear the current delegate and stop listening.
  void setDelegate(AppDNASurveyDelegate? delegate) {
    _delegate = delegate;
    _eventSub?.cancel();
    _eventSub = null;
    if (delegate == null) return;
    _eventSub = _events.receiveBroadcastStream().listen(_dispatch);
  }

  void _dispatch(dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type'] as String?;
    final args =
        (raw['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final d = _delegate;
    if (d == null || type == null) return;
    switch (type) {
      case 'onSurveyPresented':
        d.onSurveyPresented(args['surveyId'] as String? ?? '');
        break;
      case 'onSurveyCompleted':
        final surveyId = args['surveyId'] as String? ?? '';
        final responses = (args['responses'] as List?)
                ?.map((e) => (e as Map).cast<String, dynamic>())
                .toList() ??
            <Map<String, dynamic>>[];
        d.onSurveyCompleted(surveyId, responses);
        // Non-breaking shim: 1.0.5 hosts that overrode onSurveySubmitted still fire
        // (with the first response, matching the old single-response shape).
        // ignore: deprecated_member_use_from_same_package
        d.onSurveySubmitted(
          surveyId,
          responses.isNotEmpty ? responses.first : <String, dynamic>{},
        );
        break;
      case 'onSurveyDismissed':
        d.onSurveyDismissed(args['surveyId'] as String? ?? '');
        break;
      default:
        break;
    }
  }
}

/// Deep links module namespace.
class AppDNADeepLinksModule {
  final MethodChannel _channel;
  AppDNADeepLinkDelegate? _delegate;
  StreamSubscription? _eventSub;
  static const _events = EventChannel('com.appdna.sdk/events/deep_link');

  AppDNADeepLinksModule._(this._channel);

  Future<void> handleURL(String url) =>
      _channel.invokeMethod('handleDeepLink', {'url': url});

  /// SPEC-070-C §3.13 — resolve a location the user picked for an onboarding
  /// location field. Returns `null` when the field has no captured location.
  Future<LocationData?> getLocationData(String fieldId) async {
    final data = await _channel
        .invokeMethod<Map>('getLocationData', {'fieldId': fieldId});
    if (data == null) return null;
    return LocationData.fromMap(data);
  }

  /// Set a delegate to receive deep link callbacks.
  /// Pass `null` to clear the current delegate and stop listening.
  void setDelegate(AppDNADeepLinkDelegate? delegate) {
    _delegate = delegate;
    _eventSub?.cancel();
    _eventSub = null;
    if (delegate == null) return;
    _eventSub = _events.receiveBroadcastStream().listen(_dispatch);
  }

  void _dispatch(dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type'] as String?;
    final args =
        (raw['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final d = _delegate;
    if (d == null || type == null) return;
    switch (type) {
      case 'onDeepLinkReceived':
        d.onDeepLinkReceived(
          args['url'] as String? ?? '',
          (args['params'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{},
        );
        break;
      // NOTE: shouldOpen is a veto — it flows through the sync_callbacks channel
      // (AppDNA._handleSyncCallback), NOT this observe channel (SPEC-070-C L1).
      default:
        break;
    }
  }
}

/// Server-driven screen module namespace.
/// Forwards `com.appdna.sdk/events/screen` envelopes to an
/// `AppDNAScreenDelegate`.
class AppDNAScreenModule {
  final MethodChannel _channel;
  AppDNAScreenDelegate? _delegate;
  StreamSubscription? _eventSub;
  static const _events = EventChannel('com.appdna.sdk/events/screen');

  AppDNAScreenModule._(this._channel);

  /// Present a server-driven screen by ID. The screen is rendered natively;
  /// lifecycle callbacks fire on the registered [AppDNAScreenDelegate].
  ///
  /// Returns false when there was no host surface to present from (no view controller on iOS, no
  /// foreground Activity on Android) — the SAME contract React Native has had since SPEC-070-B, and
  /// the narrow thing it can honestly promise: the two natives' `showScreen` return Void, so this
  /// is not "the screen was shown". The screen's own RESULT arrives on `onScreenDismissed`, which
  /// can be long after this call. Before this it returned `Future<void>`, so a Flutter host calling
  /// it with the app backgrounded got a cheerful completion and no screen.
  Future<bool> show(String screenId, {Map<String, dynamic>? context}) async {
    final shown = await _channel.invokeMethod<bool>('showScreen', {
      'screenId': screenId,
      if (context != null) 'context': context,
    });
    return shown ?? false;
  }

  /// Present a multi-screen flow by ID. The flow runs through its configured
  /// screens; the delegate's `onFlowCompleted` fires when finished or abandoned.
  ///
  /// Returns false when there was no host surface to present from — same contract as [show].
  Future<bool> showFlow(String flowId, {Map<String, dynamic>? context}) async {
    final shown = await _channel.invokeMethod<bool>('showScreenFlow', {
      'flowId': flowId,
      if (context != null) 'context': context,
    });
    return shown ?? false;
  }

  /// Dismiss the currently-presented screen, if any.
  Future<void> dismiss() {
    return _channel.invokeMethod('dismissScreen');
  }

  /// Enable navigation interception so the delegate's `onScreenAction` is
  /// consulted before the SDK applies its default routing for nav actions.
  Future<void> enableNavigationInterception() {
    return _channel.invokeMethod('enableScreenNavigationInterception');
  }

  /// Disable navigation interception. The SDK resumes applying default
  /// routing for all nav actions.
  Future<void> disableNavigationInterception() {
    return _channel.invokeMethod('disableScreenNavigationInterception');
  }

  /// Render a screen from raw JSON for debugging or design preview.
  /// Use during development only.
  ///
  /// SPEC-070-C §3.12 / M4 — returns the preview result map, or `null` when the
  /// preview produced nothing. The two natives differ (reconciled here): iOS's
  /// `previewScreen(json:completion:)` yields a full `ScreenResult` (returned as
  /// a map: `screenId`/`dismissed`/`responses`/`lastAction`/`duration_ms`/`error`);
  /// Android's `previewScreen(json)` yields only a success `Bool`, surfaced as
  /// `{'success': <bool>}`.
  Future<Map<String, dynamic>?> preview(Map<String, dynamic> json) async {
    final data =
        await _channel.invokeMethod<Map>('previewScreen', {'json': json});
    if (data == null) return null;
    return Map<String, dynamic>.from(data);
  }

  /// Set a delegate to receive server-driven screen lifecycle callbacks.
  /// Pass `null` to clear the current delegate and stop listening.
  void setDelegate(AppDNAScreenDelegate? delegate) {
    _delegate = delegate;
    _eventSub?.cancel();
    _eventSub = null;
    if (delegate == null) return;
    _eventSub = _events.receiveBroadcastStream().listen(_dispatch);
  }

  void _dispatch(dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type'] as String?;
    final args =
        (raw['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final d = _delegate;
    if (d == null || type == null) return;
    switch (type) {
      case 'onScreenPresented':
        d.onScreenPresented(args['screenId'] as String? ?? '');
        break;
      case 'onScreenDismissed':
        d.onScreenDismissed(
          args['screenId'] as String? ?? '',
          (args['result'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{},
        );
        break;
      case 'onFlowCompleted':
        d.onFlowCompleted(
          args['flowId'] as String? ?? '',
          (args['result'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{},
        );
        break;
      // NOTE: onScreenAction is a veto — it flows through the sync_callbacks
      // channel (AppDNA._handleSyncCallback), NOT this observe channel. Invoking
      // it here too would run a side-effecting host predicate twice (SPEC-070-C L1).
      default:
        break;
    }
  }
}

/// Context passed to onboarding flows.
class OnboardingContext {
  final String? source;
  final String? campaign;
  final String? referrer;
  final Map<String, dynamic>? userProperties;
  final Map<String, String>? experimentOverrides;

  const OnboardingContext({this.source, this.campaign, this.referrer, this.userProperties, this.experimentOverrides});

  Map<String, dynamic> toMap() => {
    if (source != null) 'source': source,
    if (campaign != null) 'campaign': campaign,
    if (referrer != null) 'referrer': referrer,
    if (userProperties != null) 'userProperties': userProperties,
    if (experimentOverrides != null) 'experimentOverrides': experimentOverrides,
  };
}
