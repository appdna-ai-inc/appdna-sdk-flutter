/// The Flutter AppDNA SDK's own published package version. Reported to the
/// native SDK so `diagnose()` shows the Flutter version per platform (instead of
/// the native core version). MUST be kept in sync with `pubspec.yaml` `version:`
/// (bump both together — see D14 version-bump checklist).
const String kAppDNAFlutterSdkVersion = '1.0.15';

/// Log verbosity levels.
enum AppDNALogLevel { none, error, warning, info, debug }

/// Billing provider for paywall purchases (iOS only).
///
/// Value-less providers cross the channel as a bare string; `adapty` carries an
/// API key and crosses as a tagged map `{"type":"adapty","apiKey":"…"}` — mirroring
/// the native `BillingProvider.adapty(apiKey:)` associated-value case (SPEC-070-C §3.1).
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
  /// Automatic flush interval in seconds. Default: 30.
  final int? flushInterval;

  /// Number of events per flush batch. Default: 20.
  final int? batchSize;

  /// Remote config cache TTL in seconds. Default: 3600 (1 hour), set natively.
  final int? configTTL;

  /// Log verbosity. Default: warning.
  final AppDNALogLevel? logLevel;

  /// Billing provider for paywall purchases. Default: storeKit2 (Google Play Billing on Android).
  ///
  /// SPEC-070-B PN row 11(a): reaches native on **both** platforms from Android 1.0.42. Before
  /// that the Android plugin silently ignored it — the "(iOS only)" this doc used to claim.
  final AppDNABillingProvider? billingProvider;

  /// Notification small-icon drawable resource id used for AppDNA push
  /// notifications (**Android only**; iOS ignores it — §3.14). `0`/unset falls
  /// back to manifest meta-data then the app icon.
  ///
  /// Caveat: this is an Android `R.drawable.*` resource id (an `int`) — a
  /// pure-Dart host has no such id, so it is only useful when a native Android
  /// layer supplies it. Bridged for full §3.1 surface parity.
  final int? notificationIcon;

  /// SPEC-070-B §7 rule 1 — **ignored. The bridge injects `flutter` unconditionally.**
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

  /// SPEC-070-B PN row 14 (AC-36) — when true, analytics stay OFF until `setConsent(true)`, and no
  /// event (including `sdk_initialized`) is emitted before that decision. Default false: analytics
  /// are opt-out. Either way the decision now **persists** across a cold start.
  final bool? requireConsent;

  /// SPEC-070-B PN row 16 (W12) — seconds a host veto may take before the SDK applies the hook's
  /// default. Default 5. Surfaced through `diagnose()`.
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
        // `framework` is deliberately NOT sent: the native bridge injects it (§7 rule 1). Sending
        // it is what made it spoofable, and what let a missing key mean "native".
        // The wrapper's OWN version so native diagnose() reports it per platform.
        'frameworkVersion': kAppDNAFlutterSdkVersion,
      };
}
