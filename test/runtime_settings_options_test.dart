// runtime_settings_options_test.dart
//
// The Flutter half of the `runtime_settings_precedence` shared fixture.
//
// Native resolves `flushInterval` / `batchSize` / `configTTL` as host option > the bootstrap answer's
// `settings` > its built-in default. A thin wrapper can break that one way: by sending a value the host
// never set — a filled-in default reads, natively, as the host's own choice and beats the server's. So
// the channel arguments must carry exactly what the host set. The expectation is READ FROM THE FIXTURE
// the iOS and Android runners drive; the native half of the bridge (the plugin's `parseOptions`) is
// pinned by `AppdnaParseOptionsTest` (Android).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:appdna_sdk/appdna_sdk.dart';

void main() {
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

  final fixtureFile = File(
    '${resolveFixturesRoot().path}/resilience/runtime_settings_precedence.fixture.json',
  );

  test('runtime settings reach the channel only when the host set them', () {
    final fixture = jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;
    final w = (fixture['resilience'] as Map<String, dynamic>)['wrapper_options'] as Map<String, dynamic>;
    final hostSets = w['host_sets'] as Map<String, dynamic>;

    final options = AppDNAOptions(
      flushInterval: hostSets['flushInterval'] as int?,
      batchSize: hostSets['batchSize'] as int?,
      configTTL: hostSets['configTTL'] as int?,
    );
    final sent = options.toMap();
    (w['native_receives'] as Map<String, dynamic>).forEach((k, v) => expect(sent[k], v, reason: k));
    for (final k in (w['native_unset'] as List).cast<String>()) {
      expect(sent.containsKey(k), isFalse, reason: '$k was sent though the host did not set it');
    }
  });

  test('no options → no runtime setting on the channel', () {
    final sent = const AppDNAOptions().toMap();
    for (final k in ['flushInterval', 'batchSize', 'configTTL']) {
      expect(sent.containsKey(k), isFalse, reason: k);
    }
  });
}
