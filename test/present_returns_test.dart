import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appdna_sdk/appdna_sdk.dart';

/// The presentation calls must REPORT what the native side answered.
///
/// 🔴 `AppDNA.presentOnboarding` shipped as `Future<void>`: it invoked the channel and threw the
/// native Bool away, so `await AppDNA.presentOnboarding('typo_id')` completed successfully with no
/// onboarding on screen and a Flutter host had no way to tell that from a flow that ran. The same
/// hole existed on `onboarding.present`, `screen.show` and `screen.showFlow`. React Native returned
/// the value on all four, both natives returned it, and the method IR declared `boolean` — Flutter
/// was the only surface that lied.
///
/// These tests pin the contract at the facade, where the defect lived. The bridges are covered by
/// the platform unit suites and by the device pass.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.appdna.sdk/main');
  late List<String> called;
  Object? nativeAnswer;

  setUp(() {
    called = <String>[];
    nativeAnswer = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      called.add(call.method);
      return nativeAnswer;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('the native answer reaches the caller', () {
    test('AppDNA.presentOnboarding returns true when native presented', () async {
      nativeAnswer = true;
      expect(await AppDNA.presentOnboarding('flow_1'), isTrue);
      expect(called, contains('presentOnboarding'));
    });

    test('AppDNA.presentOnboarding returns FALSE when native did not present', () async {
      // The case that matters: an id that is not in the published config. Before the fix this
      // completed exactly like success.
      nativeAnswer = false;
      expect(await AppDNA.presentOnboarding('typo_id'), isFalse);
    });

    test('onboarding.present reports the same answer as the top-level call', () async {
      nativeAnswer = false;
      expect(await AppDNA.onboarding.present('typo_id'), isFalse);
      nativeAnswer = true;
      expect(
        await AppDNA.onboarding.present('flow_1',
            context: const OnboardingContext(source: 'test')),
        isTrue,
      );
    });

    test('screen.show / screen.showFlow report whether there was a host surface', () async {
      nativeAnswer = false;
      expect(await AppDNA.screen.show('screen_1'), isFalse);
      expect(await AppDNA.screen.showFlow('flow_1'), isFalse);
      nativeAnswer = true;
      expect(await AppDNA.screen.show('screen_1'), isTrue);
      expect(await AppDNA.screen.showFlow('flow_1'), isTrue);
      expect(called, contains('showScreen'));
      expect(called, contains('showScreenFlow'));
    });
  });

  group('edge cases that must not throw', () {
    // A host can update the Dart package while an OLDER native SDK is still linked (a cached pod,
    // a stale `mavenLocal` AAR — both happened during this change). That native returns nothing.
    // `Future<bool>` must degrade to `false`, not throw a null-cast into the host's app.
    test('a null answer from an older native degrades to false', () async {
      nativeAnswer = null;
      expect(await AppDNA.presentOnboarding('flow_1'), isFalse);
      expect(await AppDNA.onboarding.present('flow_1'), isFalse);
      expect(await AppDNA.screen.show('screen_1'), isFalse);
      expect(await AppDNA.screen.showFlow('flow_1'), isFalse);
    });

    test('presentPaywall still returns its answer (the fix it already had)', () async {
      nativeAnswer = true;
      expect(await AppDNA.presentPaywall('pw_1'), isTrue);
      nativeAnswer = false;
      expect(await AppDNA.presentPaywall('pw_1'), isFalse);
    });
  });
}
