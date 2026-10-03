import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show StandardMessageCodec;
import 'package:flutter/widgets.dart';

/// PlatformView viewType shared by the iOS + Android factories
/// Must match the id registered in
/// `AppdnaPlugin.register(...)` (iOS) and `binding.platformViewRegistry
/// .registerViewFactory(...)` (Android).
const String _kScreenSlotViewType = 'com.appdna.sdk/screen_slot';

/// Inline server-driven screen slot.
///
/// Hosts the native `AppDNAScreenSlot` (iOS SwiftUI / Android Jetpack Compose)
/// as a Flutter platform view. Growth teams assign a screen to the named slot
/// from the console; the native SDK renders its sections here inline.
///
/// This widget does NO rendering, network, or storage itself — it only embeds
/// the native platform view — so it remains thin-wrapper compliant per ADR-001.
///
/// Flutter platform views do NOT auto-size to their native intrinsic content,
/// so a [height] is required. The slot fills the available width and the given
/// height (place it inside a bounded-width parent such as a `Column`).
///
/// Usage:
/// ```dart
/// // Inside your app's own layout:
/// AppDNAScreenSlot(name: 'home_hero', height: 120)
/// ```
class AppDNAScreenSlot extends StatelessWidget { // thin-wrapper-ignore
  /// The console slot name to render (e.g. `home_hero`, `home_bottom`).
  final String name;

  /// Fixed height (logical px) the slot occupies. Flutter platform views can't
  /// measure native intrinsic content, so the host must reserve the height.
  final double height;

  const AppDNAScreenSlot({
    super.key,
    required this.name,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    // creationParams are encoded with the StandardMessageCodec — the iOS
    // factory decodes them as `[String: Any]` and Android as `Map<String, Any?>`.
    const StandardMessageCodec creationParamsCodec = StandardMessageCodec();
    final Map<String, dynamic> creationParams = <String, dynamic>{'name': name};

    Widget platformView;
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        platformView = UiKitView(
          viewType: _kScreenSlotViewType,
          creationParams: creationParams,
          creationParamsCodec: creationParamsCodec,
        );
        break;
      case TargetPlatform.android:
        platformView = AndroidView(
          viewType: _kScreenSlotViewType,
          creationParams: creationParams,
          creationParamsCodec: creationParamsCodec,
        );
        break;
      default:
        // No native slot renderer on other platforms — render nothing.
        platformView = const SizedBox.shrink();
    }

    return SizedBox(height: height, child: platformView);
  }
}
