// push_payload_typing_test.dart
//
// The `notification` map a push delegate receives has real Dart types. The channel delivers nested
// maps as Map<Object?, Object?> and lists as List<Object?>; the module used to hand them on through a
// lazy `.cast()`, so `notification['actions'] as List<Map<String, dynamic>>` (the documented type)
// threw a TypeError in the host. A push without buttons has no `actions` key.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appdna_sdk/appdna_sdk.dart';

class _Host extends AppDNAPushDelegate {
  final received = <Map<String, dynamic>>[];
  final tapped = <Map<String, dynamic>>[];

  @override
  void onPushReceived(Map<String, dynamic> notification, bool inForeground) => received.add(notification);

  @override
  void onPushTapped(Map<String, dynamic> notification, String? actionId) => tapped.add(notification);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pushEvents = MethodChannel('com.appdna.sdk/events/push');
  const codec = StandardMethodCodec();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => messenger.setMockMethodCallHandler(pushEvents, (MethodCall call) async => null));
  tearDown(() {
    AppDNA.push.setDelegate(null);
    messenger.setMockMethodCallHandler(pushEvents, null);
  });

  Future<void> emit(Map<Object?, Object?> event) async {
    await messenger.handlePlatformMessage(
      'com.appdna.sdk/events/push',
      codec.encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  test('actions, action and data arrive as real Dart types', () async {
    final host = _Host();
    AppDNA.push.setDelegate(host);
    await Future<void>.delayed(Duration.zero);
    await emit(<Object?, Object?>{
      'type': 'onPushTapped',
      'args': <Object?, Object?>{
        'actionId': 'view',
        'notification': <Object?, Object?>{
          'pushId': 'p1',
          'data': <Object?, Object?>{'k': 'v'},
          'action': <Object?, Object?>{'type': 'deep_link', 'value': 'x://y'},
          'actions': <Object?>[
            <Object?, Object?>{'id': 'view', 'label': 'View', 'action_type': 'open_url', 'action_value': 'https://e.test'},
            <Object?, Object?>{'id': 'later', 'label': 'Later', 'action_type': 'dismiss'},
          ],
        },
      },
    });
    final n = host.tapped.single;
    final actions = n['actions'] as List<Map<String, dynamic>>; // the documented type: must not throw
    expect(actions.map((a) => a['id']), ['view', 'later']);
    expect((n['action'] as Map<String, dynamic>)['value'], 'x://y');
    expect((n['data'] as Map<String, dynamic>)['k'], 'v');
  });

  test('a push without buttons has no actions key', () async {
    final host = _Host();
    AppDNA.push.setDelegate(host);
    await Future<void>.delayed(Duration.zero);
    await emit(<Object?, Object?>{
      'type': 'onPushReceived',
      'args': <Object?, Object?>{'inForeground': true, 'notification': <Object?, Object?>{'pushId': 'p2'}},
    });
    expect(host.received.single.containsKey('actions'), isFalse);
    expect(host.received.single['actions'] as List<Map<String, dynamic>>?, isNull);
  });
}
