import 'dart:async';
import 'package:flutter/services.dart';

/// Push notification management for AppDNA Flutter SDK.
///
/// Push lifecycle callbacks (`onPushReceived`/`onPushTapped`/`onPushTokenRegistered`)
/// are delivered via `AppDNA.push.setDelegate(AppDNAPushDelegate)` over the
/// `com.appdna.sdk/events/push` channel — see [AppDNAPushModule]. The delegate's
/// `notification` is a `Map<String, dynamic>` with camelCase keys (`pushId`/`title`/`body`/
/// `imageUrl`/`data`/`action:{type,value}`), plus `actions` — the action buttons, a
/// `List<Map<String, dynamic>>` of `{id, label, action_type, action_value?}`, present only when the
/// push has buttons (the same shape as React Native). `onPushTapped`'s `actionId` is one of these ids.
class AppDNAPush {
  static const MethodChannel _channel = MethodChannel('com.appdna.sdk/main');

  /// Request push notification permission.
  static Future<bool> requestPermission() async {
    final result = await _channel.invokeMethod<bool>('requestPushPermission');
    return result ?? false;
  }

  /// SPEC-070-C §3.11 — request permission AND register for remote
  /// notifications. Returns whether permission was granted. Real on iOS;
  /// on Android this routes to [requestPermission] (§3.14).
  static Future<bool> registerForPush() async {
    final result = await _channel.invokeMethod<bool>('registerForPush');
    return result ?? false;
  }

  /// SPEC-070-C §3.11 — hand a push-open (notification tap) to the SDK so it
  /// can attribute + route the tap: the newest intent the activity received,
  /// then its launch intent. The plugin already hands both to the SDK (the
  /// launch intent at `configure`), so this is optional; a tap the SDK already
  /// handled returns `true` and is not tracked or routed again. The SDK gets a
  /// copy of the intent, so the intent keeps its extras. Returns whether it is
  /// an AppDNA tap. **Android-only** — a no-op returning `false` on iOS
  /// (§3.14).
  static Future<bool> handlePushTap() async {
    final result = await _channel.invokeMethod<bool>('handlePushTap');
    return result ?? false;
  }

  /// SPEC-070-C §3.11 — feed a freshly-issued push token (e.g. from FCM
  /// `onNewToken`) into the SDK for backend registration. **Android-only** — a
  /// no-op on iOS (§3.14).
  static Future<void> onNewPushToken(String token) async {
    await _channel.invokeMethod('onNewPushToken', {'token': token});
  }
}
