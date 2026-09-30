import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:appdna_sdk/appdna_sdk.dart';

/// Opt-in launch values for test harnesses (absent → the example behaves as before):
///   appdnaApiKey       — configure with this key instead of the APPDNA_API_KEY dart-define
///   appdnaOnboardingId — adds a "Present onboarding: <id>" button
///   appdnaHostDataDemo — `items` | `empty`: SPEC-496 sample host data via onBeforeStepRender;
///                        `showmore`: SPEC-496 §5b paging host — "Show more" (`refresh_step`)
///   SPEC-497 §4.10 — the sign-in timeout floor device rows:
///   appdnaSignInDelaySeconds      — `onBeforeStepAdvance` waits n s for the FIRST sign-in action of
///                                   each presentation, then answers `proceed`; later attempts in the
///                                   same presentation proceed at once
///   appdnaVetoTimeout             — passed to `AppDNAOptions.vetoTimeout`
///   appdnaStepAdvanceDelaySeconds — for a NON-sign-in step, `onBeforeStepAdvance` waits n s …
///   appdnaStepAdvanceReply        — … then answers `proceed` (default) or `stay`
///   SPEC-497 §3.11 / §13h — the billing, local-server and location device rows:
///   appdnaBillingProvider — `storeKit2` (default) | `revenueCat` | `none` | `adapty:<publicKey>`
///   appdnaEnv             — `sandbox` when the native base-URL override is set (read natively from
///                           the `ai.appdna.sdk.BASE_URL_OVERRIDE` meta-data / `AppDNABaseURLOverride`
///                           plist entry, never passed by hand); configures `AppDNAEnvironment.staging`
///   appdnaHostProductId   — the product the iOS "Host buy (no finish)" button buys
///                           (default `ai.appdna.test.monthly`)
///   appdnaLocationFlowId  — the "Location flow" button's flow id (also the
///                           `APPDNA_E2E_LOCATION_FLOW_ID` dart-define)
///   appdnaPermissionsFlowId — the "Permissions flow" button's flow id (also the
///                           `APPDNA_E2E_PERMISSIONS_FLOW_ID` dart-define)
/// Android: `adb shell am start ... --es appdnaApiKey <key>`; iOS: launch arguments
/// (`-appdnaApiKey <key>`). Read by the example's own MainActivity / AppDelegate.
const _launchChannel = MethodChannel('appdna_example/launch');

Future<Map<String, String>> _readLaunchValues() async {
  try {
    final m = await _launchChannel.invokeMapMethod<String, String>('launchValues');
    return m ?? const {};
  } on MissingPluginException {
    return const {};
  } on PlatformException {
    return const {};
  }
}

/// SPEC-496 — sample host data for `appdnaHostDataDemo`. Public placeholder images only.
const _hostDataDemoItems = [
  {'id': 'w1', 'name': 'Maple Farm', 'subtitle': 'Toronto', 'imageUrl': 'https://picsum.photos/seed/w1/400/300'},
  {'id': 'w2', 'name': 'Oak Hall', 'subtitle': 'Nashville', 'imageUrl': 'https://picsum.photos/seed/w2/400/300'},
  {'id': 'w3', 'name': 'Birch Mill', 'subtitle': 'Dublin', 'imageUrl': 'https://picsum.photos/seed/w3/400/300'},
];

/// SPEC-496 §5b — the `showmore` paging host's list: item i is `a`, `b`, … with the page it arrived on
/// as its subtitle. Public placeholder images only.
List<Map<String, String>> _showMoreItems(int count) => [
      for (var i = 0; i < count; i++)
        {
          'id': String.fromCharCode(97 + i),
          'name': 'Venue ${String.fromCharCode(65 + i)}',
          'subtitle': 'page ${i ~/ 4 + 1}',
          'imageUrl': 'https://picsum.photos/seed/p1b-${String.fromCharCode(97 + i)}/400/300',
        },
    ];

/// The sign-in actions a host must answer — the SDK's own bridge-floor set (SPEC-497 §4.2), held equal
/// to the core by `check:auth-action-parity`. The example only uses it to decide which delay applies.
const _signInActions = {
  'social_login', 'login', 'register', 'reset_password', 'magic_link', 'verify_email',
  'resend_verification', 'enable_biometric', 'email_login', 'request_otp', 'verify_otp',
  'logout', 'change_password', 'set_new_password', 'delete_account', 'update_profile',
};

/// Hands every step a `dataContext` (`hook_data.recommendations`) — what a
/// `{{hook_data.recommendations}}` repeat reads — and logs the lifecycle. [mode] is null when no host
/// data demo is on (the delegate may be registered only for the SPEC-497 step-advance delays).
class _HostDataDemoDelegate extends AppDNAOnboardingDelegate {
  _HostDataDemoDelegate(
    this.mode,
    this.log, {
    this.signInDelaySeconds,
    this.stepAdvanceDelaySeconds,
    this.stepAdvanceReply = 'proceed',
    this.locationFieldStep = false,
  });
  final String? mode;
  /// SPEC-497 §13h D2-1 — log `AppDNA-E2E location <json|null>` in `onBeforeStepRender` for
  /// `step_after`.
  final bool locationFieldStep;
  final void Function(String) log;
  final int? signInDelaySeconds;
  final int? stepAdvanceDelaySeconds;
  final String stepAdvanceReply;

  /// Whether this presentation's first sign-in action has already been delayed.
  bool _signInDelayed = false;

  /// `showmore`: pages shown so far, per step — page 1 is a–d, every `refresh` adds four (accumulate,
  /// at most 20). A revisit answers with the list the user last saw.
  final _pages = <String, int>{};

  @override
  void onOnboardingStarted(String flowId) {
    _signInDelayed = false;
    log('onboarding started $flowId');
  }

  @override
  Future<Map<String, dynamic>> onBeforeStepAdvance(String flowId, String fromStepId, int stepIndex,
      String stepType, Map<String, dynamic> responses, Map<String, dynamic>? stepData) async {
    final action = stepData?['action'] as String?;
    // No SPEC-497 step-advance launch value set → the delegate's default answer, exactly as before
    // (the SPEC-496 host-data demo registered this delegate without overriding this hook).
    if (signInDelaySeconds == null && stepAdvanceDelaySeconds == null) {
      return super.onBeforeStepAdvance(flowId, fromStepId, stepIndex, stepType, responses, stepData);
    }
    if (action != null && _signInActions.contains(action)) {
      final delay = signInDelaySeconds;
      if (delay == null) {
        return super.onBeforeStepAdvance(flowId, fromStepId, stepIndex, stepType, responses, stepData);
      }
      if (!_signInDelayed) {
        _signInDelayed = true;
        log('onBeforeStepAdvance($fromStepId, $action) — signing in for ${delay}s');
        await Future<void>.delayed(Duration(seconds: delay));
      }
      log('onBeforeStepAdvance($fromStepId, $action) → proceed');
      return {'type': 'proceed'};
    }
    final delay = stepAdvanceDelaySeconds;
    if (delay != null) {
      log('onBeforeStepAdvance($fromStepId) — waiting ${delay}s');
      await Future<void>.delayed(Duration(seconds: delay));
      log('onBeforeStepAdvance($fromStepId) → $stepAdvanceReply');
      return {'type': stepAdvanceReply};
    }
    return super.onBeforeStepAdvance(flowId, fromStepId, stepIndex, stepType, responses, stepData);
  }

  @override
  void onOnboardingStepChanged(String flowId, String stepId, int stepIndex, int totalSteps) =>
      log('step changed $stepId ($stepIndex/$totalSteps)');

  @override
  void onOnboardingCompleted(String flowId, Map<String, dynamic> responses) =>
      log('onboarding completed $flowId responses=$responses');

  @override
  Future<Map<String, dynamic>?> onBeforeStepRender(
      String flowId, String stepId, int stepIndex, String stepType, Map<String, dynamic> responses) async {
    if (locationFieldStep && stepId == 'step_after') {
      final loc = await AppDNA.deepLinks.getLocationData('e2e_location');
      log('AppDNA-E2E location ${loc == null ? 'null' : jsonEncode(_locationJson(loc))}');
    }
    if (mode == null) return null;
    final recommendations = mode == 'showmore'
        ? _showMoreItems(4 * (_pages[stepId] ?? 1))
        : mode == 'items'
            ? _hostDataDemoItems
            : const <Map<String, String>>[];
    log('onBeforeStepRender($stepId) → dataContext: ${recommendations.length} recommendation(s)');
    return {'dataContext': {'recommendations': recommendations}};
  }

  @override
  Future<Map<String, dynamic>?> onElementInteraction(String flowId, String stepId, String blockId,
      String action, String? value, Map<String, dynamic> inputValues) async {
    log('onElementInteraction($stepId/$blockId, $action, value=${value ?? '<none>'})');
    if (mode != 'showmore' || action != 'refresh') return null;
    // Slow enough that the tapped button's spinner is visible.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final next = (_pages[stepId] ?? 1) + 1;
    final pages = next > 5 ? 5 : next;
    _pages[stepId] = pages;
    final recommendations = _showMoreItems(4 * pages);
    log('onElementInteraction($stepId/$blockId) → dataContext: ${recommendations.length} recommendation(s)');
    // The WHOLE list so far (accumulate), under the key the Select repeats over.
    return {'dataContext': {'recommendations': recommendations}, 'advance': false};
  }
}

/// The snake_case shape the device row greps (every key, null for a missing field).
Map<String, Object?> _locationJson(LocationData l) => {
      'formatted_address': l.formattedAddress,
      'raw_query': l.rawQuery,
      'city': l.city,
      'state': l.state,
      'state_code': l.stateCode,
      'country': l.country,
      'country_code': l.countryCode,
      'postal_code': l.postalCode,
      'latitude': l.latitude,
      'longitude': l.longitude,
      'timezone': l.timezone,
      'timezone_offset': l.timezoneOffset,
    };

/// SPEC-497 §3.11 — logs the paywall purchase outcome lines the device rows assert.
class _E2EPaywallDelegate extends AppDNAPaywallDelegate {
  _E2EPaywallDelegate(this.log);
  final void Function(String) log;

  @override
  void onPaywallPurchaseStarted(String paywallId, String productId) =>
      log('AppDNA-E2E onPaywallPurchaseStarted $productId');

  @override
  void onPaywallPurchaseCompleted(String paywallId, String productId, Map<String, dynamic> transaction) =>
      log('AppDNA-E2E onPaywallPurchaseCompleted $productId ${transaction['transactionId']}');

  @override
  void onPaywallPurchaseFailed(String paywallId, Object error, String errorType, String? productId) =>
      log('AppDNA-E2E onPaywallPurchaseFailed $errorType $productId');
}

/// `appdnaBillingProvider` → the Dart provider. Unknown → null (the SDK default, storeKit2).
AppDNABillingProvider? _billingProvider(String? raw) {
  switch (raw) {
    case 'storeKit2':
      return AppDNABillingProvider.storeKit2;
    case 'revenueCat':
      return AppDNABillingProvider.revenueCat;
    case 'none':
      return AppDNABillingProvider.none;
  }
  if (raw != null && raw.startsWith('adapty:')) return AppDNABillingProvider.adapty(raw.substring(7));
  return null;
}

/// SPEC-497 §3.11 — the iOS host's own StoreKit calls (`AppDelegate.swift`): a purchase the host does
/// NOT finish, and the `AppDNA-E2E unfinished=<ids>` / `all=<ids>` lines. Android has no equivalent here
/// (its E2E host is the native sample), so the call reports unsupported.
const _hostChannel = MethodChannel('appdna_example/host');

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AppDNA SDK Example',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF6366f1), useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Surface targets injected at build time via --dart-define (no customer IDs
  // committed). Fall back to placeholders for source readers.
  static const _onboardingId =
      String.fromEnvironment('APPDNA_ONBOARDING_ID', defaultValue: 'default');
  static const _paywallId =
      String.fromEnvironment('APPDNA_PAYWALL_ID', defaultValue: 'default');
  static const _paywallId2 =
      String.fromEnvironment('APPDNA_PAYWALL_ID_2', defaultValue: 'default');
  static const _surveyId =
      String.fromEnvironment('APPDNA_SURVEY_ID', defaultValue: 'default');
  static const _messageEvent =
      String.fromEnvironment('APPDNA_MESSAGE_EVENT', defaultValue: 'session_start');

  /// SPEC-497 D2-1 — the location device row's flow (a DEV flow, never committed).
  static const _definedLocationFlowId = String.fromEnvironment('APPDNA_E2E_LOCATION_FLOW_ID');
  /// SPEC-497 D3 — the permissions device row's flow (a DEV flow, never committed).
  static const _definedPermissionsFlowId = String.fromEnvironment('APPDNA_E2E_PERMISSIONS_FLOW_ID');
  String? _permissionsFlowId;

  String _status = 'Not configured';
  String? _launchOnboardingId;
  String? _locationFlowId;
  String _hostProductId = 'ai.appdna.test.monthly';
  final List<String> _log = [];

  void _append(String line) {
    // ignore: avoid_print
    print('[AppDNAExample] $line');
    if (mounted) setState(() => _log.add(line));
  }
  String? _webEntitlement;
  String? _deepLink;

  @override
  void initState() {
    super.initState();
    _initSdk();
  }

  Future<void> _initSdk() async {
    // 1. Configure SDK. The API key is injected at build time via
    //    --dart-define=APPDNA_API_KEY=... (D12: no key committed to the example);
    //    falls back to a placeholder for source readers.
    const definedKey =
        String.fromEnvironment('APPDNA_API_KEY', defaultValue: 'YOUR_API_KEY');
    final launch = await _readLaunchValues();
    final apiKey = launch['appdnaApiKey'] ?? definedKey;
    _launchOnboardingId = launch['appdnaOnboardingId'];
    final demoValue = launch['appdnaHostDataDemo'];
    final demo = (demoValue == 'items' || demoValue == 'empty' || demoValue == 'showmore') ? demoValue : null;
    final signInDelay = int.tryParse(launch['appdnaSignInDelaySeconds'] ?? '');
    final stepDelay = int.tryParse(launch['appdnaStepAdvanceDelaySeconds'] ?? '');
    final vetoTimeout = int.tryParse(launch['appdnaVetoTimeout'] ?? '');
    final locationFlow = launch['appdnaLocationFlowId'] ??
        (_definedLocationFlowId.isEmpty ? null : _definedLocationFlowId);
    _locationFlowId = locationFlow;
    _permissionsFlowId = launch['appdnaPermissionsFlowId'] ??
        (_definedPermissionsFlowId.isEmpty ? null : _definedPermissionsFlowId);
    _hostProductId = launch['appdnaHostProductId'] ?? _hostProductId;
    if (demo != null || signInDelay != null || stepDelay != null || locationFlow != null) {
      AppDNA.onboarding.setDelegate(_HostDataDemoDelegate(
        demo,
        _append,
        signInDelaySeconds: signInDelay,
        stepAdvanceDelaySeconds: stepDelay,
        stepAdvanceReply: launch['appdnaStepAdvanceReply'] == 'stay' ? 'stay' : 'proceed',
        locationFieldStep: locationFlow != null,
      ));
    }
    // SPEC-497 §3.11 — the paywall outcome lines, always on (they only log).
    AppDNA.paywall.setDelegate(_E2EPaywallDelegate(_append));
    final provider = _billingProvider(launch['appdnaBillingProvider']);
    // `appdnaEnv=sandbox` is set natively only when the base-URL override is configured for this
    // build (local-server runs); every other run is production.
    final env = launch['appdnaEnv'] == 'sandbox' ? AppDNAEnvironment.staging : AppDNAEnvironment.production;
    await AppDNA.configure(
      apiKey: apiKey,
      env: env,
      options: (vetoTimeout == null && provider == null)
          ? null
          : AppDNAOptions(vetoTimeout: vetoTimeout, billingProvider: provider),
    );
    setState(() => _status = 'Configured');
    // SPEC-497 §3.11 — the local-server precheck line: the base URL the SDK resolved, read from
    // diagnose() (`base_url: <v>`), and the environment this host configured.
    final report = await AppDNA.diagnose() ?? '';
    final baseUrl = RegExp(r'base_url: (\S+)').firstMatch(report)?.group(1) ?? 'unknown';
    _append('AppDNA-E2E base_url=$baseUrl env=${env == AppDNAEnvironment.staging ? 'sandbox' : 'production'}');
    if (launch.isNotEmpty) {
      _append('wrapper sdkVersion=${await AppDNA.getSdkVersion()} hostDataDemo=${demo ?? 'off'} '
          'signInDelay=${signInDelay ?? 'off'} stepAdvanceDelay=${stepDelay ?? 'off'} vetoTimeout=${vetoTimeout ?? 'default'} '
          'billingProvider=${launch['appdnaBillingProvider'] ?? 'default'} env=${env.name}');
    }

    // 2. Identify user. The user id can be overridden at build time via
    //    --dart-define=APPDNA_USER_ID=... (used to exercise per-user-frequency
    //    surfaces like in-app messages with a fresh identity).
    const userId =
        String.fromEnvironment('APPDNA_USER_ID', defaultValue: 'user_123');
    await AppDNA.identify(userId, traits: {'email': 'demo@example.com'});
    setState(() => _status = 'Identified');

    // 3. Check for deferred deep link (first launch)
    final link = await AppDNA.checkDeferredDeepLink();
    if (link != null) {
      setState(() => _deepLink = '${link.screen} (${link.params})');
    }

    // 4. Listen for web entitlement changes
    AppDNA.onWebEntitlementChanged.listen((entitlement) {
      setState(() {
        _webEntitlement = entitlement != null
            ? '${entitlement.planName} (${entitlement.status})'
            : 'None';
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AppDNA SDK Example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _infoCard('SDK Status', _status),
          _infoCard('Web Entitlement', _webEntitlement ?? 'Not loaded'),
          _infoCard('Deferred Deep Link', _deepLink ?? 'None'),
          const SizedBox(height: 24),

          if (_launchOnboardingId != null) ...[
            FilledButton(
              onPressed: () async =>
                  _append('presentOnboarding → ${await AppDNA.presentOnboarding(_launchOnboardingId!)}'),
              child: Text('Present onboarding: $_launchOnboardingId'),
            ),
            const SizedBox(height: 12),
          ],
          if (_locationFlowId != null) ...[
            FilledButton(
              onPressed: () async =>
                  _append('presentOnboarding(location) → ${await AppDNA.presentOnboarding(_locationFlowId!)}'),
              child: const Text('Location flow'),
            ),
            const SizedBox(height: 12),
          ],
          if (_permissionsFlowId != null) ...[
            FilledButton(
              onPressed: () async =>
                  _append('presentOnboarding(permissions) → ${await AppDNA.presentOnboarding(_permissionsFlowId!)}'),
              child: const Text('Permissions flow'),
            ),
            const SizedBox(height: 12),
          ],
          // SPEC-497 §3.11 / §13b.2 — restore, with the lines the restore rows assert.
          OutlinedButton(
            onPressed: _restore,
            child: const Text('Restore'),
          ),
          // SPEC-497 §3.11 — the host's OWN StoreKit purchase, deliberately never finished (iOS), and
          // the transaction listing the device rows assert on.
          OutlinedButton(
            onPressed: () => _host('hostBuy', {'productId': _hostProductId}),
            child: Text('Host buy (no finish): $_hostProductId'),
          ),
          OutlinedButton(
            onPressed: () => _host('logTransactions', const {}),
            child: const Text('Log unfinished transactions'),
          ),
          const SizedBox(height: 12),
          for (final line in _log) Text(line, style: const TextStyle(fontSize: 11)),
          if (_log.isNotEmpty) const SizedBox(height: 12),

          // Track Event
          FilledButton.icon(
            onPressed: () => AppDNA.track('button_tapped', properties: {'button': 'demo'}),
            icon: const Icon(Icons.analytics),
            label: const Text('Track Event'),
          ),
          const SizedBox(height: 12),

          // Present Paywall
          FilledButton.icon(
            onPressed: () => AppDNA.presentPaywall(_paywallId),
            icon: const Icon(Icons.shopping_cart),
            label: const Text('Present Paywall'),
          ),
          const SizedBox(height: 12),

          // Present a second paywall (e.g. a winback variant).
          FilledButton.icon(
            onPressed: () => AppDNA.presentPaywall(_paywallId2),
            icon: const Icon(Icons.card_giftcard),
            label: const Text('Present Paywall 2'),
          ),
          const SizedBox(height: 12),

          // Present Onboarding
          FilledButton.icon(
            onPressed: () => AppDNA.presentOnboarding(_onboardingId),
            icon: const Icon(Icons.rocket_launch),
            label: const Text('Present Onboarding'),
          ),
          const SizedBox(height: 12),

          // Present Survey
          FilledButton.icon(
            onPressed: () => AppDNA.showSurvey(_surveyId),
            icon: const Icon(Icons.assignment),
            label: const Text('Present Survey'),
          ),
          const SizedBox(height: 12),

          // Trigger In-App Message (fires the native trigger evaluation)
          FilledButton.icon(
            onPressed: () => AppDNA.track(_messageEvent),
            icon: const Icon(Icons.campaign),
            label: const Text('Trigger In-App Message'),
          ),
          const SizedBox(height: 12),

          // Remote Config
          FilledButton.icon(
            onPressed: () async {
              final value = await AppDNA.getRemoteConfig('welcome_message');
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Remote config: $value')),
                );
              }
            },
            icon: const Icon(Icons.settings_remote),
            label: const Text('Get Remote Config'),
          ),
          const SizedBox(height: 12),

          // Experiment Variant
          FilledButton.icon(
            onPressed: () async {
              final variant = await AppDNA.getExperimentVariant('onboarding_test');
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Variant: $variant')),
                );
              }
            },
            icon: const Icon(Icons.science),
            label: const Text('Get Experiment Variant'),
          ),
          const SizedBox(height: 12),

          // Feature Flag
          FilledButton.icon(
            onPressed: () async {
              final enabled = await AppDNA.isFeatureEnabled('dark_mode');
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Feature enabled: $enabled')),
                );
              }
            },
            icon: const Icon(Icons.flag),
            label: const Text('Check Feature Flag'),
          ),
          const SizedBox(height: 12),

          // Run Diagnose — returns the SDK health report String on BOTH platforms.
          FilledButton.icon(
            onPressed: () async {
              final report = await AppDNA.diagnose();
              if (context.mounted) {
                showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('SDK Diagnose'),
                    content: SingleChildScrollView(
                      child: Text(report ?? '(null)',
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                );
              }
            },
            icon: const Icon(Icons.health_and_safety),
            label: const Text('Run Diagnose'),
          ),
        ],
      ),
    );
  }

  Future<void> _restore() async {
    try {
      final restored = await AppDNA.billing.restorePurchases();
      _append('AppDNA-E2E onRestoreCompleted ${restored.map((e) => e.productId).join(',')}');
    } on PlatformException catch (e) {
      final details = e.details;
      final errorType = details is Map ? details['errorType'] : null;
      _append('AppDNA-E2E restoreFailed ${e.code} ${errorType ?? 'unknown'}');
    }
  }

  Future<void> _host(String method, Map<String, Object?> args) async {
    try {
      _append('$method → ${await _hostChannel.invokeMethod<Object?>(method, args)}');
    } on PlatformException catch (e) {
      _append('$method ✗ ${e.code} ${e.message}');
    } on MissingPluginException {
      _append('$method ✗ not available on this platform');
    }
  }

  Widget _infoCard(String title, String value) {
    return Card(
      child: ListTile(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(value),
      ),
    );
  }
}
