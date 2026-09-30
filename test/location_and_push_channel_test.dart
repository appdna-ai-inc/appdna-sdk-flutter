import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appdna_sdk/appdna_sdk.dart';

/// SPEC-497 — two channel contracts pinned at the Dart facade.
///
/// §13h (D2): `AppDNA.deepLinks.getLocationData` passes a missing field through as `null`. A typed but
/// unselected address comes back from native as `{formatted_address, raw_query}` only; the facade used
/// to fill the rest with made-up `''` / `0.0` / `'UTC'` / `0`, so a host could not tell "no coordinates"
/// from a point in the Gulf of Guinea.
///
/// §9.2 (B2): the push forwarding API forwards to the native channel methods and reports the native
/// answer; the data map goes across untouched (conversion is native).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.appdna.sdk/main');
  late List<MethodCall> calls;
  Object? nativeAnswer;

  setUp(() {
    calls = <MethodCall>[];
    nativeAnswer = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return nativeAnswer;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('getLocationData', () {
    test('typed but unselected text: every field but the address and query is null', () async {
      nativeAnswer = <String, dynamic>{
        'formatted_address': 'Somewhere typed',
        'raw_query': 'Somewhere typed',
        'city': null,
        'latitude': null,
        'longitude': null,
        'timezone': null,
        'timezone_offset': null,
      };
      final loc = await AppDNA.deepLinks.getLocationData('field_location');
      expect(calls.single.method, 'getLocationData');
      expect((calls.single.arguments as Map)['fieldId'], 'field_location');
      expect(loc, isNotNull);
      expect(loc!.formattedAddress, 'Somewhere typed');
      expect(loc.rawQuery, 'Somewhere typed');
      expect(loc.city, isNull);
      expect(loc.latitude, isNull);
      expect(loc.longitude, isNull);
      expect(loc.timezone, isNull);
      expect(loc.timezoneOffset, isNull);
      expect(loc.state, isNull);
      expect(loc.stateCode, isNull);
      expect(loc.country, isNull);
      expect(loc.countryCode, isNull);
      expect(loc.postalCode, isNull);
    });

    test('keys absent from the map are null too', () async {
      nativeAnswer = <String, dynamic>{'formatted_address': 'Only an address'};
      final loc = await AppDNA.deepLinks.getLocationData('field_location');
      expect(loc!.formattedAddress, 'Only an address');
      expect(loc.city, isNull);
      expect(loc.latitude, isNull);
      expect(loc.timezone, isNull);
      expect(loc.timezoneOffset, isNull);
      expect(loc.rawQuery, isNull);
    });

    test('a selected suggestion carries its values through', () async {
      nativeAnswer = <String, dynamic>{
        'formatted_address': 'A City, A Country',
        'city': 'A City',
        'country': 'A Country',
        'latitude': 12.5,
        'longitude': -3,
        'timezone': 'Etc/UTC',
        'timezone_offset': 60,
      };
      final loc = await AppDNA.deepLinks.getLocationData('field_location');
      expect(loc!.city, 'A City');
      expect(loc.latitude, 12.5);
      expect(loc.longitude, -3.0);
      expect(loc.timezoneOffset, 60);
    });

    test('no answer is null', () async {
      nativeAnswer = null;
      expect(await AppDNA.deepLinks.getLocationData('field_location'), isNull);
    });
  });

  group('push forwarding API', () {
    final data = <String, dynamic>{
      'appdna': '1',
      'push_id': 'p1',
      'badge': 5,
      'action': {'type': 'deep_link', 'value': 'x://y'},
      'tags': ['a', 'b'],
    };

    test('isAppDNAMessage forwards the data and reports the native answer', () async {
      nativeAnswer = true;
      expect(await AppDNA.push.isAppDNAMessage(data), isTrue);
      expect(calls.single.method, 'push.isAppDNAMessage');
      expect((calls.single.arguments as Map)['data'], data);
      nativeAnswer = false;
      expect(await AppDNA.push.isAppDNAMessage({'push_id': 'p1'}), isFalse);
    });

    test('handleMessage forwards to push.handleMessageData', () async {
      nativeAnswer = true;
      expect(await AppDNA.push.handleMessage(data), isTrue);
      expect(calls.single.method, 'push.handleMessageData');
      expect((calls.single.arguments as Map)['data'], data);
    });

    test('handleTap sends actionId only when given', () async {
      nativeAnswer = true;
      expect(await AppDNA.push.handleTap(data), isTrue);
      expect((calls.last.arguments as Map).containsKey('actionId'), isFalse);
      expect(await AppDNA.push.handleTap(data, actionId: 'b1'), isTrue);
      expect(calls.last.method, 'push.handleTap');
      expect((calls.last.arguments as Map)['actionId'], 'b1');
    });

    test('a null native answer is false', () async {
      nativeAnswer = null;
      expect(await AppDNA.push.handleTap(data), isFalse);
      expect(await AppDNA.push.handleMessage(data), isFalse);
      expect(await AppDNA.push.isAppDNAMessage(data), isFalse);
    });
  });
}
