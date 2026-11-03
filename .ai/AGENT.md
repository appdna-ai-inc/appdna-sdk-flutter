# AppDNA Flutter SDK (v0.3.0)

Dart/Flutter SDK. Thin platform channel wrapper around the native iOS and Android SDKs. All logic is delegated to the native layer via `MethodChannel` and `EventChannel`.

---

## Public API

### Initialization

- `AppDNA.configure({required String apiKey, AppDNAEnvironment env = AppDNAEnvironment.production, AppDNAOptions? options})` -- Initialize the SDK. Call once at app startup. Delegates to native `AppDNA.configure()`.
- `AppDNA.onReady(void Function() callback)` -- Register a callback that fires when the SDK is fully initialized.

### Identity

- `AppDNA.identify(String userId, {Map<String, dynamic>? traits})` -- Link the anonymous device to a known user.
- `AppDNA.reset()` -- Clear user identity (keeps anonymous ID).

### Events

- `AppDNA.track(String event, {Map<String, dynamic>? properties})` -- Track a custom event.
- `AppDNA.flush()` -- Force flush all queued events.

### Remote Config

- `AppDNA.getRemoteConfig(String key) -> Future<dynamic>` -- Get a remote config value by key.
- `AppDNA.isFeatureEnabled(String flag) -> Future<bool>` -- Check if a feature flag is enabled.

### Experiments

- `AppDNA.getExperimentVariant(String experimentId) -> Future<String?>` -- Get the variant assignment for an experiment.
- `AppDNA.isInVariant(String experimentId, String variantId) -> Future<bool>` -- Check if the user is in a specific variant.
- `AppDNA.getExperimentConfig(String experimentId, String key) -> Future<dynamic>` -- Get experiment config value.

### Paywalls

- `AppDNA.presentPaywall(String id, {PaywallContext? context})` -- Present a paywall.

### Onboarding

- `AppDNA.presentOnboarding(String flowId)` -- Present an onboarding flow by ID.

### Push Notifications

- `AppDNA.setPushToken(String token)` -- Set push token (APNS hex string on iOS, FCM token on Android).
- `AppDNA.setPushPermission(bool granted)` -- Report push permission status.

### Web Entitlements (v0.3)

- `AppDNA.webEntitlement -> Future<WebEntitlement?>` -- Get the current web subscription entitlement.
- `AppDNA.onWebEntitlementChanged -> Stream<WebEntitlement?>` -- Listen for web entitlement changes (via EventChannel).
- `AppDNA.checkDeferredDeepLink() -> Future<DeferredDeepLink?>` -- Check for a deferred deep link on first launch.

### Privacy

- `AppDNA.setConsent({required bool analytics})` -- Set analytics consent.

### Lifecycle

- `AppDNA.shutdown()` -- Shut down the SDK. Android delegates to `AppDNA.shutdown()`; iOS is a no-op.
- `AppDNA.getSdkVersion() -> Future<String>` -- Get the native SDK version string.

### Configuration Options (`AppDNAOptions`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `flushInterval` | `int?` | 30 | Auto flush interval in seconds |
| `batchSize` | `int?` | 20 | Events per flush batch |
| `configTTL` | `int?` | 3600 | Remote config cache TTL in seconds |
| `logLevel` | `AppDNALogLevel?` | `warning` | Log verbosity (none/error/warning/info/debug) |
| `billingProvider` | `AppDNABillingProvider?` | `storeKit2` | Billing provider (iOS only) |

---

## Platform Channels

| Channel | Type | Purpose |
|---------|------|---------|
| `com.appdna.sdk/main` | MethodChannel | All method calls (configure, track, identify, etc.) |
| `com.appdna.sdk/web_entitlement` | EventChannel | Real-time web entitlement change stream |

---

## Models

### `WebEntitlement`
- `isActive: bool` -- Whether the entitlement is active
- `planName: String?` -- Plan name
- `priceId: String?` -- Stripe price ID
- `interval: String?` -- Billing interval ("month", "year")
- `status: String` -- Status (active, trialing, past_due, canceled)
- `currentPeriodEnd: DateTime?` -- Current period end date
- `trialEnd: DateTime?` -- Trial end date

### `DeferredDeepLink`
- `screen: String` -- Target screen path (e.g., "/workout/123")
- `params: Map<String, String>` -- Additional context params
- `visitorId: String` -- Web visitor ID

### `PaywallContext`
- `placement: String?` -- Where the paywall is shown
- `customData: Map<String, dynamic>?` -- Extra context data

---

## Firestore Paths (Read)

This SDK does NOT read Firestore directly. All Firestore reads are handled by the native iOS and Android SDKs. See their respective AGENT.md files for Firestore path details.

---

## Events Emitted

This SDK does NOT emit events directly. All event tracking is handled by the native iOS and Android SDKs via platform channels. See their respective AGENT.md files for event details.

---

## File Structure

### Dart (Public API)

- `lib/appdna_sdk.dart` -- Main AppDNA class with all static methods; MethodChannel/EventChannel setup
- `lib/models/web_entitlement.dart` -- WebEntitlement model
- `lib/models/deferred_deep_link.dart` -- DeferredDeepLink model
- `lib/models/paywall_context.dart` -- PaywallContext model
- `lib/models/survey_result.dart` -- SurveyResult model
- `lib/models/appdna_options.dart` -- AppDNAOptions, AppDNALogLevel, AppDNABillingProvider

### iOS Bridge

- `ios/appdna_sdk/Sources/appdna_sdk/AppdnaPlugin.swift` -- FlutterPlugin implementing MethodChannel handler and EventChannel stream handler; delegates to native `AppDNA` singleton
- `ios/appdna_sdk.podspec` -- CocoaPods spec

### Android Bridge

- `android/src/main/kotlin/com/appdna/flutter/AppdnaPlugin.kt` -- Flutter plugin implementing MethodChannel handler; delegates to native `AppDNA` singleton
- `android/build.gradle` -- Gradle build config

### Example

- `example/lib/main.dart` -- Example Flutter app demonstrating SDK usage

---

## Backend Module Dependencies

All backend dependencies are inherited from the native iOS and Android SDKs:

- **monetization**: paywall configs (via native SDK)
- **onboarding**: onboarding flow configs (via native SDK)
- **experiments**: experiment configs (via native SDK)
- **feature-flags**: feature flags (via native SDK)
- **feedback**: survey configs and responses (via native SDK)
- **web-entitlements**: web entitlements (via native SDK)
- **deep-links**: deferred deep links (via native SDK)
- **ingest**: event ingestion (via native SDK)
- **sdk-bootstrap**: bootstrap (via native SDK)

---

## Rule

Any new module feature that writes config to Firestore or adds new events MUST update this SDK. For Flutter, this means:
1. Add a new method in `lib/appdna_sdk.dart`
2. Add the corresponding MethodChannel handler in `ios/appdna_sdk/Sources/appdna_sdk/AppdnaPlugin.swift`
3. Add the corresponding MethodChannel handler in `android/src/main/kotlin/com/appdna/flutter/AppdnaPlugin.kt`
4. Add any new model classes in `lib/models/`
