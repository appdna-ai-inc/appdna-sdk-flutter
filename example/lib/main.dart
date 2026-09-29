import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:appdna_sdk/appdna_sdk.dart';

/// Opt-in launch values for test harnesses (absent → the example behaves as before):
///   appdnaApiKey       — configure with this key instead of the APPDNA_API_KEY dart-define
///   appdnaOnboardingId — adds a "Present onboarding: <id>" button
///   appdnaHostDataDemo — `items` | `empty`: SPEC-496 sample host data via onBeforeStepRender;
///                        `showmore`: SPEC-496 §5b paging host — "Show more" (`refresh_step`)
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

/// Hands every step a `dataContext` (`hook_data.recommendations`) — what a
/// `{{hook_data.recommendations}}` repeat reads — and logs the lifecycle.
class _HostDataDemoDelegate extends AppDNAOnboardingDelegate {
  _HostDataDemoDelegate(this.mode, this.log);
  final String mode;
  final void Function(String) log;

  /// `showmore`: pages shown so far, per step — page 1 is a–d, every `refresh` adds four (accumulate,
  /// at most 20). A revisit answers with the list the user last saw.
  final _pages = <String, int>{};

  @override
  void onOnboardingStarted(String flowId) => log('onboarding started $flowId');

  @override
  void onOnboardingStepChanged(String flowId, String stepId, int stepIndex, int totalSteps) =>
      log('step changed $stepId ($stepIndex/$totalSteps)');

  @override
  void onOnboardingCompleted(String flowId, Map<String, dynamic> responses) =>
      log('onboarding completed $flowId responses=$responses');

  @override
  Future<Map<String, dynamic>?> onBeforeStepRender(
      String flowId, String stepId, int stepIndex, String stepType, Map<String, dynamic> responses) async {
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

  String _status = 'Not configured';
  String? _launchOnboardingId;
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
    final demo = launch['appdnaHostDataDemo'];
    if (demo == 'items' || demo == 'empty' || demo == 'showmore') {
      AppDNA.onboarding.setDelegate(_HostDataDemoDelegate(demo!, _append));
    }
    await AppDNA.configure(apiKey: apiKey);
    setState(() => _status = 'Configured');
    if (launch.isNotEmpty) {
      _append('wrapper sdkVersion=${await AppDNA.getSdkVersion()} hostDataDemo=${demo ?? 'off'}');
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

  Widget _infoCard(String title, String value) {
    return Card(
      child: ListTile(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(value),
      ),
    );
  }
}
