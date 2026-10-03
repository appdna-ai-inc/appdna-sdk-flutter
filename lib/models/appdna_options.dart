/// The Flutter AppDNA SDK's own published package version. Reported to the
/// native SDK so `diagnose()` shows the Flutter version per platform (instead of
/// the native core version). MUST be kept in sync with `pubspec.yaml` `version:`
/// (bump both together — see D14 version-bump checklist).
const String kAppDNAFlutterSdkVersion = '1.0.20';

/// Log verbosity levels.
enum AppDNALogLevel { none, error, warning, info, debug }

/// Who owns store transactions — applies on iOS and Android.
///
/// Only [storeKit2] (the default: AppDNA's own billing — StoreKit 2 on iOS,
/// Google Play Billing on Android) lets the SDK buy, finish (iOS) and
/// acknowledge (Android) purchases. Under [revenueCat], `adapty` or [none] the
/// SDK never finishes, acknowledges or consumes a transaction: a paywall plan
/// tap reports `onPaywallPurchaseFailed` with `errorType: 'providerNotAvailable'`
/// and the tapped `productId`, so your app starts the purchase with its own
/// provider; `billing.restorePurchases()` throws `RESTORE_ERROR` with
/// `details['errorType'] == 'providerNotAvailable'`.
///
/// Value-less providers cross the channel as a bare string; `adapty` carries an
/// API key and crosses as a tagged map `{"type":"adapty","apiKey":"…"}` — mirroring
/// the native `BillingProvider.adapty(apiKey:)` associated-value case.
/// An `adapty` provider with an empty key is refused (logged) and the SDK uses
/// the default [storeKit2], on both platforms.
class AppDNABillingProvider {
  /// Provider discriminator: `storeKit2` | `revenueCat` | `adapty` | `none`.
  final String type;

  /// Adapty public SDK key (only set for the `adapty` provider).
  final String? apiKey;

  const AppDNABillingProvider._(this.type, {this.apiKey});

  static const AppDNABillingProvider storeKit2 =
      AppDNABillingProvider._('storeKit2');
  static const AppDNABillingProvider revenueCat =
      AppDNABillingProvider._('revenueCat');
  static const AppDNABillingProvider none = AppDNABillingProvider._('none');

  /// Adapty billing, keyed by your Adapty public SDK key.
  factory AppDNABillingProvider.adapty(String apiKey) =>
      AppDNABillingProvider._('adapty', apiKey: apiKey);

  /// Channel encoding: a bare string for value-less cases, a tagged map for adapty.
  Object toJson() => apiKey == null
      ? type
      : <String, dynamic>{'type': type, 'apiKey': apiKey};
}

/// Configuration options for the AppDNA SDK.
class AppDNAOptions {
  /// Automatic flush interval in seconds. When null, the server's value from the SDK's bootstrap request
  /// (if positive), else 30. Sent to native only when set.
  final int? flushInterval;

  /// A cap on the events one upload sends and the queue length that triggers a flush; the batch is sized
  /// by the network (100 on Wi-Fi or wired, 50 on cellular, 20 on an expensive / metered connection) and
  /// never exceeds this. When null, the server's value from the bootstrap request (if positive) is the
  /// cap, else there is none. Below 1 is ignored (as if not set). Sent to native only when set.
  final int? batchSize;

  /// Remote config cache TTL in seconds. When null, the server's value from the bootstrap request (if
  /// positive), else 3600 (1 hour). Sent to native only when set.
  final int? configTTL;

  /// Log verbosity. Default: warning.
  final AppDNALogLevel? logLevel;

  /// Billing provider for paywall purchases. Default: storeKit2 (Google Play Billing on Android).
  ///
  /// Reaches native on **both** platforms from Android 1.0.42. Before
  /// that the Android plugin silently ignored it — the "(iOS only)" this doc used to claim.
  final AppDNABillingProvider? billingProvider;

  /// Notification small-icon drawable resource id used for AppDNA push
  /// notifications (**Android only**; iOS ignores it). `0`/unset falls
  /// back to manifest meta-data then the app icon.
  ///
  /// Caveat: this is an Android `R.drawable.*` resource id (an `int`) — a
  /// pure-Dart host has no such id, so it is only useful when a native Android
  /// layer supplies it. Bridged for full surface parity.
  final int? notificationIcon;

  /// **ignored. The bridge injects `flutter` unconditionally.**
  ///
  /// This used to be sent to native, which read it back out of the options map. That let a host
  /// SPOOF its own attribution, and it meant any path that reached `configure` without going
  /// through [toMap] fell back to native's `"native"` default — tagging every Flutter event as a
  /// native one. The envelope schema is `.catch('native')`, so a wrong tag does not error, is not
  /// logged, and is not metered: it just quietly lies in BigQuery.
  ///
  /// The field is kept (rather than removed) so existing hosts still compile; setting it now has no
  /// effect.
  @Deprecated(
    'Ignored since 1.0.8 — the native bridge injects the framework tag itself. '
    'A host must not be able to set, spoof, or omit its own attribution. Remove this argument.',
  )
  final String? framework;

  /// When true, analytics stay OFF until `setConsent(true)`, and no
  /// event (including `sdk_initialized`) is emitted before that decision. Default false: analytics
  /// are opt-out. Either way the decision now **persists** across a cold start.
  final bool? requireConsent;

  /// Seconds any host hook on this bridge (`onBeforeStepAdvance`,
  /// `onBeforeStepRender`, `onElementInteraction`, the vetoes, …) may take
  /// before the SDK applies the hook's default. Default 5; a value of 0 or
  /// less means the default. Sign-in actions in `onBeforeStepAdvance` wait at
  /// least 120 s whatever this is (`max(vetoTimeout, 120)`), and an
  /// `onElementInteraction` refresh at least 8 s. Timeouts are counted in
  /// `diagnose()`.
  final int? vetoTimeout;

  const AppDNAOptions({
    this.flushInterval,
    this.batchSize,
    this.configTTL,
    this.logLevel,
    this.billingProvider,
    this.notificationIcon,
    this.framework,
    this.requireConsent,
    this.vetoTimeout,
  });

  Map<String, dynamic> toMap() => {
        if (flushInterval != null) 'flushInterval': flushInterval,
        if (batchSize != null) 'batchSize': batchSize,
        if (configTTL != null) 'configTTL': configTTL,
        if (logLevel != null) 'logLevel': logLevel!.name,
        if (billingProvider != null) 'billingProvider': billingProvider!.toJson(),
        if (notificationIcon != null) 'notificationIcon': notificationIcon,
        if (requireConsent != null) 'requireConsent': requireConsent,
        if (vetoTimeout != null) 'vetoTimeout': vetoTimeout,
        // `framework` is deliberately NOT sent: the native bridge injects it. Sending
        // it is what made it spoofable, and what let a missing key mean "native".
        // The wrapper's OWN version so native diagnose() reports it per platform.
        'frameworkVersion': kAppDNAFlutterSdkVersion,
      };
}
