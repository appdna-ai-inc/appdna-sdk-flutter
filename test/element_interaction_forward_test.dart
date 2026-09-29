// element_interaction_forward_test.dart
//
// SPEC-496 §5b C10 — the Dart half of the `element_interaction_data_context_decode` shared fixture.
//
// A thin wrapper FORWARDS (ADR-001): the decode of `dataContext` — null members kept as removal
// markers, 0/1 kept as numbers — happens in the native bridge, into the core
// `ElementInteractionResult.decodeDataContext`. What this side must prove is that the map the host's
// `onElementInteraction` returns reaches the channel UNCHANGED, `null` members included: a wrapper
// that dropped a null here would silently make "null removes a key" impossible for every Flutter host.
//
// The reply is READ FROM THE FIXTURE the iOS and Android runners decode, not restated here.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appdna_sdk/appdna_sdk.dart';

class _Host extends AppDNAOnboardingDelegate {
  _Host(this.reply);
  final Map<String, dynamic> reply;
  final calls = <List<Object?>>[];

  @override
  Future<Map<String, dynamic>?> onElementInteraction(String flowId, String stepId, String blockId,
      String action, String? value, Map<String, dynamic> inputValues) async {
    calls.add([flowId, stepId, blockId, action, value]);
    return reply;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory resolveFixturesRoot() {
    final env = Platform.environment['APPDNA_SDK_FIXTURES_DIR'];
    if (env != null && Directory(env).existsSync()) return Directory(env);
    Directory here = Directory.current;
    for (var i = 0; i < 10; i++) {
      final candidate = Directory(
        '${here.path}${Platform.pathSeparator}packages${Platform.pathSeparator}sdk-shared-fixtures',
      );
      if (candidate.existsSync()) return candidate;
      final parent = here.parent;
      if (parent.path == here.path) break;
      here = parent;
    }
    final synced = Directory('${Directory.current.path}/test/fixtures/sdk-shared-fixtures');
    if (synced.existsSync()) return synced;
    final codespace = Directory('/workspaces/appdna-ai/packages/sdk-shared-fixtures');
    if (codespace.existsSync()) return codespace;
    throw StateError('Could not locate packages/sdk-shared-fixtures. Set APPDNA_SDK_FIXTURES_DIR.');
  }

  const mainChannel = MethodChannel('com.appdna.sdk/main');
  const onboardingEvents = MethodChannel('com.appdna.sdk/events/onboarding');
  const syncChannel = 'com.appdna.sdk/sync_callbacks';
  const codec = StandardMethodCodec();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(mainChannel, (MethodCall call) async => null);
    // `setDelegate` subscribes to the onboarding event stream (listen / cancel).
    messenger.setMockMethodCallHandler(onboardingEvents, (MethodCall call) async => null);
  });

  tearDown(() {
    AppDNA.onboarding.setDelegate(null);
    messenger.setMockMethodCallHandler(mainChannel, null);
    messenger.setMockMethodCallHandler(onboardingEvents, null);
  });

  /// Deliver a native sync-callback and return the Dart side's decoded answer.
  Future<Object?> fire(String method, Map<String, Object?> args) async {
    final done = Completer<ByteData?>();
    await messenger.handlePlatformMessage(
      syncChannel,
      codec.encodeMethodCall(MethodCall(method, args)),
      (ByteData? data) => done.complete(data),
    );
    final data = await done.future;
    return data == null ? null : codec.decodeEnvelope(data);
  }

  test('onElementInteraction forwards the host map unchanged, null members included', () async {
    final file = File(
      '${resolveFixturesRoot().path}/config_overrides/element_interaction_data_context_decode.fixture.json',
    );
    expect(file.existsSync(), isTrue,
        reason: 'shared fixture missing — the forward has nothing to be pinned against');
    final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final reply = (fixture['setup']['session_data']['host_interaction_reply'] as Map).cast<String, dynamic>();

    await AppDNA.configure(apiKey: 'adn_test_fixture');
    final host = _Host(reply);
    AppDNA.onboarding.setDelegate(host);

    final answer = await fire('onElementInteraction', {
      'flowId': 'f1',
      'stepId': 'step_eir',
      'blockId': 'show_more',
      'action': 'refresh',
      'value': 'more',
      'inputValues': <String, Object?>{},
    });

    expect(host.calls, [
      ['f1', 'step_eir', 'show_more', 'refresh', 'more'],
    ]);
    expect(answer, equals(reply));
    final dc = (answer as Map)['dataContext'] as Map;
    expect(dc.containsKey('banner'), isTrue, reason: 'a null member is a removal, and must cross');
    expect(dc['banner'], isNull);
    expect(dc['count'], 0);
    expect(dc['count'], isA<int>());
    expect(dc['flag'], 1);
    expect(dc['enabled'], isTrue);
    expect(dc['ratio'], 0.5);
  });
}
