// validate_input_forward_test.dart
//
// Live validation — the Dart half of `onValidateInput`. A thin wrapper FORWARDS (ADR-001): the reply is decoded natively by
// core's `InputValidationResult.decodeBridgeReply`. This side proves that every reply in the shared parse fixture
// reaches the channel UNCHANGED, with the call's arguments, and that a host which does not override the hook — or no
// delegate at all — answers `not_implemented`, so the native field behaves as if there were no delegate.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appdna_sdk/appdna_sdk.dart';

class _Host extends AppDNAOnboardingDelegate {
  Object? reply;
  final calls = <List<Object?>>[];

  @override
  Future<Map<String, dynamic>?> onValidateInput(String flowId, String stepId, String fieldId, String value) async {
    calls.add([flowId, stepId, fieldId, value]);
    final r = reply;
    return r is Map ? r.cast<String, dynamic>() : null;
  }
}

class _Bare extends AppDNAOnboardingDelegate {}

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

  const args = {'flowId': 'f1', 'stepId': 's1', 'fieldId': 'username', 'value': 'abc'};
  const notImplemented = {'status': 'not_implemented'};

  test('onValidateInput forwards every fixture reply unchanged', () async {
    final file = File('${resolveFixturesRoot().path}/delegate_contracts/validate_input_result_parse.fixture.json');
    expect(file.existsSync(), isTrue, reason: 'shared fixture missing');
    final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final cases = (fixture['action']['cases'] as List).cast<Map<String, dynamic>>();

    await AppDNA.configure(apiKey: 'adn_test_fixture');
    final host = _Host();
    AppDNA.onboarding.setDelegate(host);
    for (final c in cases) {
      host.reply = c['reply'];
      final answer = await fire('onValidateInput', args);
      // A non-map reply cannot be a Map<String, dynamic> in Dart: the host returns null, which is "no answer" too.
      expect(answer, equals(c['reply'] is Map ? c['reply'] : null), reason: c['name'] as String);
    }
    expect(host.calls.first, ['f1', 's1', 'username', 'abc']);
    expect(host.calls.length, cases.length);
  });

  test('a delegate that does not override onValidateInput answers not_implemented', () async {
    await AppDNA.configure(apiKey: 'adn_test_fixture');
    AppDNA.onboarding.setDelegate(_Bare());
    expect(await fire('onValidateInput', args), equals(notImplemented));
  });

  test('no delegate answers not_implemented', () async {
    await AppDNA.configure(apiKey: 'adn_test_fixture');
    AppDNA.onboarding.setDelegate(null);
    expect(await fire('onValidateInput', args), equals(notImplemented));
  });
}
