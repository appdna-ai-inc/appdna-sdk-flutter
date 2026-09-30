# AppDNA Flutter plugin — consumer ProGuard / R8 rules (SPEC-497 D1).
#
# Shipped to the host app through `consumerProguardFiles` in build.gradle, so a host that builds a
# minified release (R8, the Flutter default for `flutter build apk/appbundle --release`) keeps what the
# plugin needs. The native SDK (`ai.appdna:sdk-android`) ships its own rules for its DTO packages and
# its FCM service; the React Native wrapper does the same for its module.
#
# The Flutter embedding instantiates the plugin by class name from the generated registrant, and the
# platform-view factory is registered from it; keep both, with their constructors.
-keep class com.appdna.flutter.AppdnaPlugin { public <init>(); }
-keep class com.appdna.flutter.AppDNAScreenSlotViewFactory { *; }

# The bridge reports a failure's class name to Dart (`error.type` in the event envelope); keep the
# names of the SDK's public exception types so a minified build reports the same strings.
-keepnames class ai.appdna.sdk.** extends java.lang.Throwable
