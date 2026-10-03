import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appdna_sdk/appdna_sdk.dart';

/// `setInitDelegate` consumes the init event stream on both platforms. The iOS plugin used to register this
/// channel with a handler that never emitted, so `onInitDegraded` reached Flutter apps on Android only; it now
/// forwards the native `AppDNA.initDelegate` with Android's envelope, `{type: 'onInitDegraded', args: {error:
/// {message, type}}}`. This pins the Dart half: the delegate subscribes to the stream, receives that envelope,
/// and `setInitDelegate(null)` cancels it. (The Swift half: `example/ios/RunnerTests`.)
class _Recorder implements AppDNAInitDelegate {
  final errors = <Map<String, dynamic>>[];
  @override
  void onInitDegraded(Map<String, dynamic> error) => errors.add(error);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const initChannel = MethodChannel('com.appdna.sdk/events/init');
  const codec = StandardMethodCodec();
  late List<String> streamCalls;

  setUp(() {
    streamCalls = <String>[];
    messenger.setMockMethodCallHandler(initChannel, (MethodCall call) async {
      streamCalls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    AppDNA.setInitDelegate(null);
    messenger.setMockMethodCallHandler(initChannel, null);
  });

  Future<void> emit(Object event) async {
    await messenger.handlePlatformMessage(
      'com.appdna.sdk/events/init',
      codec.encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  test('the delegate subscribes and receives onInitDegraded', () async {
    final rec = _Recorder();
    AppDNA.setInitDelegate(rec);
    await Future<void>.delayed(Duration.zero);
    expect(streamCalls, contains('listen'));

    await emit({
      'type': 'onInitDegraded',
      'args': {
        'error': {'message': 'Bootstrap failed: offline', 'type': 'AppDNAInitError'},
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(rec.errors, hasLength(1));
    expect(rec.errors.single['message'], 'Bootstrap failed: offline');
    expect(rec.errors.single['type'], 'AppDNAInitError');

    // Another envelope type on the channel is not a degradation.
    await emit({'type': 'somethingElse', 'args': <String, Object?>{}});
    await Future<void>.delayed(Duration.zero);
    expect(rec.errors, hasLength(1));
  });

  test('setInitDelegate(null) cancels the subscription', () async {
    final rec = _Recorder();
    AppDNA.setInitDelegate(rec);
    await Future<void>.delayed(Duration.zero);
    AppDNA.setInitDelegate(null);
    await Future<void>.delayed(Duration.zero);
    expect(streamCalls, containsAllInOrder(<String>['listen', 'cancel']));
    await emit({
      'type': 'onInitDegraded',
      'args': {'error': {'message': 'late', 'type': 'X'}},
    });
    await Future<void>.delayed(Duration.zero);
    expect(rec.errors, isEmpty);
  });
}
