## 1.0.20

- **Interactive maps with no host code.** A map block with interactivity on now pans and zooms from
  the bundled native map — before, without `registerMapView` it silently drew a still image (#671). Mapbox /
  Google provider choice, fullscreen and top/bottom placement, editable theme colours. Existing flows with
  interactivity on become interactive on upgrade without being republished.
- **Host data reaches every onboarding field.** `onBeforeStepRender`'s `dataContext` now resolves in
  every text and image field, and a Select can build its options — including the stored value — from a host
  list. Unresolved `{{…}}` text renders empty instead of the literal token.
- **"Show more".** A button with action "Refresh this step" calls `onElementInteraction` with
  action `refresh`; return `{'dataContext': {...}}` to replace keys of the step's `hook_data` (`null` removes a
  key). A `refresh` reply now gets **8 seconds** — the bridge waits that long even when
  `vetoTimeout` is shorter, and the SDK drops a later reply even when it is larger (other interactions
  keep `vetoTimeout`, default 5 s) — and `dataContext` crosses the bridge with its `null` members intact.

- 🔴 **Four presentation calls stopped throwing the native answer away.** `AppDNA.presentOnboarding`,
  `AppDNA.onboarding.present`, `AppDNA.screen.show` and `AppDNA.screen.showFlow` returned
  `Future<void>`, so `await AppDNA.presentOnboarding('typo_id')` completed **successfully** with no
  onboarding on screen and a host could not tell that from a flow that ran. All four now return
  `Future<bool>` — `false` when the id is not in the published config, when the SDK is not configured
  yet, or when there was no view controller / foreground Activity to present from. Both natives
  always returned this value and React Native always delivered it; Flutter was the only surface that
  did not. This fix is in the Flutter plugin only (the Dart facade and its Kotlin / Swift bridge); it
  needed no change to the wrapped native SDKs (the billing, push and onboarding items below do change
  the wrapped iOS 1.0.82 / Android 1.0.54).
- **Source-compatible.** Existing code that awaits and ignores the result keeps compiling; only the
  declared type widened.
- 🔴 **The plugin's iOS side now COMPILES.** `ElementInteractionResult(...)` was called with its
  arguments out of declaration order, which Swift rejects — so since 1.0.17 a Flutter host building
  for iOS failed with *"Argument 'fieldConfigPatches' must precede argument 'fieldOptions'"*. Nothing
  caught it because nothing compiled this file: `flutter analyze`/`flutter test` are Dart and CI
  compiled only the Android half. CI now compiles the iOS half too.

### Billing ownership, sign-in timeout, push forwarding, consumables, location

Needs the AppDNA server from the same release. Wraps iOS 1.0.82 / Android 1.0.54.

**Billing ownership (both platforms)**
- `billingProvider` now decides who owns a store transaction. Only `storeKit2` (the default) lets
  the SDK buy through the store itself and finish (iOS) or verify + acknowledge (Android). Under `revenueCat`, `adapty` or
  `none` the SDK never finishes, acknowledges or consumes a transaction; before, a `revenueCat` host
  on iOS had every StoreKit update finished by the SDK, and on Android its paywall bought through
  Play.
- A paywall tap under `revenueCat` (not linked into the native SDK — every published channel),
  `adapty` (Android, and iOS unlinked) or `none` fails loudly: one `purchase_failed`
  (`error_type: providerNotAvailable`), then `onPaywallPurchaseFailed` with `errorType:
  'providerNotAvailable'` and the tapped plan's `productId`, then the paywall's failure route. No
  `onPaywallPurchaseStarted`. On iOS a tap under `none` used to do nothing at all. Start the
  purchase with your provider from that callback.
- **`onPaywallPurchaseFailed` now receives the real `errorType` and `productId`** (it received
  `'unknown'` / `null` on both platforms, whatever the failure). A failed `billing.purchase` keeps
  its `PURCHASE_ERROR` code and now carries `details['errorType']`
  (`(e as PlatformException).details?['errorType']`).
- **Restore can fail.** `billing.restorePurchases()` throws `PlatformException('RESTORE_ERROR')`
  with `details['errorType']` (`details` was `null` on both platforms): `providerNotAvailable` under
  `revenueCat` / `adapty` / `none` (restore through your provider — on iOS an unlinked `revenueCat`
  used to run a StoreKit restore, and an unlinked `adapty` returned `[]` and fired
  `onRestoreCompleted([])`; on Android it returned `[]` under `none`, and under `revenueCat` / `adapty` ran
  AppDNA's own Play restore and returned the cached entitlements); on Android `storeKit2`, `networkError` /
  `serverError`. Entitlements stay unchanged.
- Under `revenueCat` the device no longer emits `subscription_renewed` / `subscription_canceled` /
  `subscription_renewal_failed`; the RevenueCat webhook is the single source. `adapty` keeps them.
- **iOS: an `adapty` provider with an empty key** (`AppDNABillingProvider.adapty('')`) is refused,
  logged as a warning, and falls back to the default `storeKit2`. Android already fell back to
  `storeKit2` (silently, with no log). It used to configure Adapty with an empty key.
- `purchase` / `restorePurchases` called before `configure` completes fail with "AppDNA SDK not
  configured yet — call configure() first" (`errorType` `unknown`); on Android a paywall tap made
  after `configure` but before billing has initialised reports the same (not `providerNotAvailable`).
  A paywall restore tap before billing is ready, or after `shutdown()`, reports the same `unknown`
  error on both platforms, without `onPaywallRestoreStarted` (on iOS it was `providerNotAvailable`; on
  Android `onPaywallRestoreStarted` fired first, then an `unknown` "Billing bridge not configured"
  failure). On Android a paywall restore tap under `revenueCat` / `adapty` / `none` is now refused with
  `providerNotAvailable`, without `onPaywallRestoreStarted` (iOS never fired it); before, Started fired,
  then `revenueCat` / `adapty` ran a Play restore through AppDNA and `none` failed with `unknown`.
  `shutdown()` during a paywall purchase or restore no longer reports it as failed.
- Android purchase errors: re-buying an owned item can fail — with a message ending in `item_already_owned`
  (error type `unknown`) when an owned consumable cannot be consumed and bought again in the same tap, and with
  `verificationFailed` when the owned purchase's verification fails. `productNotFound` now reaches
  you as the purchase error type, and verification failures report `verificationFailed` (was
  `unknown`) — `networkError` when the verify does not answer within 30 s. A purchase started while the Play connection is failing fails within 30 s with
  `serverError`.
- A refused purchase or restore under `revenueCat` / `adapty` carries one message on both platforms
  and on every path (direct call and paywall tap): "RevenueCat: purchases are made by RevenueCat in
  your app" ("Adapty: …" for Adapty).
- The paywall's purchase button no longer stays disabled with its spinner: it is enabled again after
  every failed, cancelled or pending purchase (both platforms), after a successful purchase when it
  has no `on_success` action or one this SDK version does not know (the paywall stays up for your
  app to close), and on Android when `shutdown()` cancels the purchase.
- **Android `storeKit2` purchases are now verified and acknowledged.** The SDK's `/billing/verify`
  call was refused by the server, so a Play purchase was never acknowledged and Play refunded it after
  3 days. It is now verified and acknowledged (or consumed).
- iOS event parity: the paywall `purchase_restore_failed` carries `error_type`; a paywall restore with
  no billing bridge emits `purchase_restore_failed{error_type: providerNotAvailable}`; a direct
  `billing.purchase` emits `purchase_started` / `purchase_failed`, as on Android; a failed direct
  `restorePurchases()` tracks `purchase_restore_failed` (no `paywall_id`).
- Native API note (Android): source-compatible; binary-incompatible only for precompiled callers of
  `PurchaseResult.Failed.copy` (it gained `errorType`).
- The SDK sends `billing_owner` on its Android verify / restore calls; an app with a connected
  RevenueCat or Adapty integration that still runs an older Android SDK on `storeKit2` gets its
  verifications refused until it updates.

**Late purchases and consumables (no Dart API change)**
- `onPurchaseCompleted` may arrive later, through a delivery queue: on Android for a purchase whose
  verification failed or that was made outside the app — e.g. a resubscribe from the Play Store, a
  promo-code redemption, a PENDING purchase that completed while the app was killed, or a plan change
  (reported once at the next return to the foreground — app start included — `identify`, restore or
  `refreshEntitlementCache()`, as `purchase_completed` + `subscription_started` for a subscription,
  with an empty `paywall_id`); on iOS for interrupted and Ask-to-Buy purchases.
  The queue also holds an iOS Ask-to-Buy approval that arrives with no `purchase()` call waiting for
  it, and a purchase reported after its `purchase()` call was cancelled (e.g. the paywall closed). On iOS a re-buy of an owned item
  fires no `onPurchaseCompleted` (`billing.purchase()` still returns `status: 'purchased'`). The queue is
  drained when your billing listener is attached, after `identify` and at app start. **Any Flutter
  billing listener drains it** (the plugin cannot see whether you override `onPurchaseCompleted`), so
  implement `onPurchaseCompleted` and grant idempotently by `transactionId` — delivery is at least
  once. The queue keeps 100 entries for 30 days; past either, a purchase needs a manual grant.
- Known: after a reinstall, a purchase acknowledged before it is not reported again; a late-reported
  Android plan change looks like a new subscription.
- Android consumables are consumed immediately, so they can be bought again at once;
  the `transaction` map passed to `onPurchaseCompleted` has no quantity.
- Re-buying an owned item emits `purchase_restored` (`reason: "item_already_owned"`, no price)
  instead of a second `purchase_completed`; restore emits no `purchase_restored` for a purchase it
  just reported. On Android an `ITEM_ALREADY_OWNED` returned synchronously by Play is handled like
  the listener result (it was `launch_billing_flow_failed`).
- On `storeKit2`, a trial purchase reports `is_trial: true` and price 0, and iOS purchases report
  the charged price (RevenueCat / Adapty omit `is_trial`). A late iOS purchase made while another
  user was signed in is delivered when that user signs in; the SDK keeps one device-wide owner map
  for purchase tokens.
- Android: `TransactionInfo.transactionId` falls back to the purchase token (not the product id)
  when Play gives no order id; a user id that is not a canonical 8-4-4-4-12 UUID (e.g. `1-2-3-4-5`)
  is now hashed into the `appAccountToken`, as on iOS; a lifetime purchase no longer disappears after
  an entitlement update (older cached entries without a type are read as lifetime when they are
  active Play entries without an expiry); server-side refunds and renewals now reach the device;
  `reset()` and `identify` with a different user clear the cached entitlements
  (the first `identify` after an anonymous session keeps them).
- Android now also detects a renewal by the Play order id's `..N` suffix, so new
  `subscription_renewed` events appear, including on a trial conversion. Known: a same-product
  base-plan change counts as a renewal, and a 7-day trial conversion found this way is timed when the
  device notices it — mostly in the d30 trial-to-paid window rather than d7.
- New event properties: `emitted_by`, lifecycle `transaction_id` / `original_transaction_id` /
  `cancel_semantics`, `original_transaction_id` on `purchase_completed` and `subscription_started`,
  `is_consumable`; `delivery_id` on `push_delivered` / `push_tapped`; `purchase_failed.reason` now
  carries the server's code for a verification failure. `AppDNA.track` drops a host-passed
  `emitted_by` / `_appdna_origin`, also on calls made before `configure`.

**Streams after `shutdown()` → `configure()`**
- **`billing.onEntitlementsChanged` and the web-entitlement stream keep emitting after
  `AppDNA.shutdown()` then `AppDNA.configure()`** (both platforms). They went silent for the rest of
  the process: the native `shutdown()` drops every entitlement listener and the plugin never registered
  again. Each change is still emitted once. A web-entitlement listen made before `configure()` is now
  attached by `configure()` on Android (it was dropped).
- Android: the remote-config and feature-flag change streams now fire on every config refresh,
  including after `shutdown()` → `configure()` and when listened to before the SDK is ready (they could
  stay silent for the whole session).
- iOS: `billing.purchase()` returns `{status: 'cancelled'}` only for a real user cancellation (typed
  error), no longer for any error whose message contains "cancel"; other failures throw
  `PURCHASE_ERROR` with their `errorType`.

**Onboarding**
- **`vetoTimeout` is honoured on every Flutter hook** (it was ignored — 5 s everywhere), and
  `diagnose()` reports the real number of timed-out hooks. A value ≤ 0 means the default (5 s).
- **Sign-in actions in `onBeforeStepAdvance` wait at least 120 s** (`max(vetoTimeout, 120 s)`), so a
  Google / Apple sign-in with an account picker or 2FA no longer ends in "Sign-in isn't available
  right now" after 5 s. Make the sign-in hook idempotent: a reply after 120 s is dropped and the
  user retries.
- iOS: an `onBeforeStepAdvance` answer of `{'type': 'skipToWithData', 'stepId': …}` now skips to
  `stepId`, as on Android; it advanced to the next step instead. `{'type': 'skipTo', 'stepId': …,
  'data': {…}}` remains the canonical form.
- The SDK's own interactive map (new in this release — see the interactive-maps entry above) draws the route polyline, otherwise
  straight segments between the stops. With auto-fit on (the default) the camera fits the route and its
  stops, and a single point uses zoom 15; with auto-fit off it centres on the authored centre at the
  authored zoom.
- **`AppDNA.deepLinks.getLocationData` no longer crashes on iOS** after a typed answer, and returns
  `formattedAddress` / `rawQuery` with null coordinates for text typed without selecting a
  suggestion (Android returned `null`); a selection carries city, state, country, coordinates and
  timezone. Both location writers on both platforms (the form-step Location field and the Location
  content block) now store the same shape: the iOS form-step field stores typed text (it stored
  nothing), a blank value is left out rather than stored as `''`, the iOS content block stores no zone
  rather than `'UTC'` when its time-zone lookup fails, and a selection stores `timezoneOffset` and
  `rawQuery` (the typed search text).
- An `onBeforeStepAdvance` reply `{'type': 'skipTo'}` (or `skipToWithData`) without a `stepId`, or with
  a blank one, is no longer a skip: on a sign-in step the bridge blocks it as no answer (it advanced the
  user past the sign-in step), elsewhere it proceeds (with its `data`, if any).
- `AppDNA.setSessionData` with a value that is not valid JSON (for example `double.nan`) no longer
  throws on Android; on both platforms the value is not saved to disk, a warning is logged and the
  previously saved copy is cleared.
- 🔴 **Dart source break:** `LocationData`'s fields other than `formattedAddress` are now nullable
  (`city`, `state`, `stateCode`, `country`, `countryCode`, `latitude`, `longitude`, `timezone`,
  `timezoneOffset`, `rawQuery`), and `LocationData.fromMap` no longer invents `''` / `0.0` /
  `'UTC'` / `0` for a missing value. Code that reads them as non-null must handle `null`.
- Android: location autocomplete no longer stores `0,0` for a suggestion that comes back without
  coordinates (the suggestion is kept, without `latitude` / `longitude`); the event
  queue no longer spins the IO thread pool when `flushInterval` is very large.

**Push**
- Android: the SDK's messaging service handles only AppDNA-marked pushes (`appdna: "1"`);
  `onPushReceived` no longer fires for your own messages, and a data-only message is never shown as a
  blank notification. Turn the service off with the resource bool
  `appdna_messaging_service_enabled` = `false`.
- **Tap routing follows one ladder on both platforms:** the tapped button, then the push's `action`,
  then flat `action_type` / `action_value`, then `screen_id`, then `deep_link` — a push with both an
  action and a `screen_id` now follows the action (Android used to prefer `screen_id`). iOS
  additionally falls back to the first button's action when the push has none of these.
- `AppDNAPush.handlePushTap()` (Android) returns `false` and does nothing for an intent without the
  AppDNA marker.
- Android: a push action (tapped button or body action) with a blank value routes nowhere instead of
  falling through to `screen_id` / `deep_link`; once `handlePushTap()` has handled the launch intent
  it removes the `appdna` / `push_id` / `delivery_id` extras, so calling it again returns `false`.
- New `AppDNA.push.isAppDNAMessage(data)`, `handleMessage(data)` and `handleTap(data, actionId:)`
  for apps that own Firebase Messaging (`firebase_messaging`). Each is a no-op returning `false` for
  a push without the marker, and tracks each push once even if the SDK also saw it.
  `handleMessage` tracks delivery and never displays anything.
- **iOS: the SDK installs its notification handler at launch**, chaining any existing
  `UNUserNotificationCenter` delegate (including `FlutterAppDelegate` / FlutterFire), so AppDNA pushes
  are tracked and routed — cold-start taps included — with no forwarding code. Info.plist keys:
  `AppDNADisableNotificationProxy` (opt out) and `AppDNAForegroundPresentation`. With FlutterFire as
  the outer notification delegate, a push arriving in the **foreground** keeps FlutterFire's
  presentation and is not tracked as delivered unless `AppDNAForegroundPresentation` is set or the
  delegate AppDNA wrapped implements `willPresent`; taps are still tracked, because FlutterFire forwards
  them to the delegate it wrapped. With **no** notification delegate and no push library, an AppDNA push arriving in
  the foreground is now shown (AppDNA's foreground options), tracked as delivered and passed to
  `onPushReceived` — before, it was not shown. When the SDK ends up as the OUTER delegate, AppDNA's
  foreground options apply to AppDNA pushes and your delegate is not called for them. Other pushes
  are forwarded to your delegate when it implements the method (otherwise completed with no
  presentation, the iOS default); the exception is the `AppDNAForegroundPresentation` trade-off (with
  the key set, and AppDNA innermost under FlutterFire with no delegate of its own to forward to, your
  own FCM pushes get no foreground presentation).

**Build**
- The plugin ships a `consumer-rules.pro`, so an R8-minified Android release build keeps the classes
  the plugin needs.
- iOS: the SDK no longer references the Contacts, EventKit, App Tracking Transparency or
  Photos-library APIs unless your flow uses those permission steps. Every app still needs
  `NSLocationWhenInUseUsageDescription`. If App Store Connect still asks for a key, add it and tell us.

## 1.0.17

- Wraps iOS 1.0.79 / Android 1.0.51. **No Dart API change** — every fix and addition below is in the
  wrapped native SDKs, so upgrading is a version bump only.
- Onboarding fixes: the stray grey "Skip" no longer draws on every Android screen; `horizontal_align`
  is honoured on a width-constrained block (a 75%-wide sound button or button authored `center`
  was stuck left); content pinned behind the bottom button zone is reachable again, because the
  scroll reserve is measured instead of a hardcoded 80dp; a summary card with one unresolved token
  keeps the card instead of disappearing; the "or" between the social-login divider segments takes
  the authored colour.
- Onboarding additions: a **Multi-buttons** group that lays 1–3 real buttons per row with a centred
  or stretched last row and its own background; and a button action that **refreshes a step in place**,
  letting the host swap a select's options without advancing the flow.
- Paywalls: a standalone **Back button** (style, position, colour, size, delay, text) independent of
  the close affordance, plus a Restore background colour and corner radius and a corner radius on
  each extra CTA button.

## 1.0.16

- Wraps iOS 1.0.78 / Android 1.0.50. **No Dart API change** — every fix and addition below is in the
  wrapped native SDKs, so upgrading is a version bump only.
- Onboarding: a CTA with `action: "skip"` now advances on Android (it was a dead button); the
  social-login divider draws once and honours its authored position; the warning banner gained a
  subtitle, text alignment, its own border and corner radius, per-role font sizes and a font family;
  the device mockup keeps real phone proportions instead of stretching vertically, and `image_fit`
  applies inside the frame.
- Paywalls: legal text renders inline `[label](url)` links in the authored Link Color — which
  previously never reached the device at all; the sticky-footer subtitle takes a size and colour
  instead of being pinned at 10pt; the CTA section gained a Restore gap, up to six extra buttons
  with configurable actions, and actions on the CTA and Restore link themselves; a paywall can show
  a back chevron that returns the user to the previous screen.

## 1.0.15

- Wraps iOS 1.0.77 / Android 1.0.49. Navigation rules that branch on an answer given on an
  earlier screen now match; previously they silently fell through to the next screen in order.
  No Dart API change — the fix is entirely in the wrapped native SDKs.

## 1.0.6

- Full feature parity with the native SDK's expanded surface (wraps iOS 1.0.68 /
  Android 1.0.40). The Flutter API now covers the complete capability set: host
  approval callbacks for in-app messages, server-driven screen actions, deep links
  and promo codes, plus onboarding step and permission hooks; an inline
  `AppDNAScreenSlot` widget for embedding server-driven screens; brand-accent,
  runtime-lock, bundle-version and notification-icon reads; session-data
  get/set/clear; and SDK lifecycle and init delegates. `diagnose()` now returns the
  health report as a string and reports the Flutter SDK version. All rendering,
  business logic, networking and storage remain in the native SDK.

## 1.0.5

- `appdna_feature_parity: 1.0.65` — parity marker advanced to wrap iOS 1.0.65
  + Android 1.0.37, SPEC-036-F Phase 1 experiment-aware presentation. This is
  a purely-native change: the native surface managers decide treatment-vs-
  active inside `present()`, so a Flutter app embedding the native SDKs renders
  experiment treatments automatically with no Dart change. The publishable
  Flutter `version` stays at 1.0.5; the thin-wrapper Dart catch-up (if any) is
  owned by SPEC-070-C. Flutter remains a thin wrapper per ADR-001.
- `appdna_feature_parity: 1.0.64` — Flutter now wraps iOS 1.0.64 + Android
  1.0.36, SPEC-404 hard SDK suspension. Adds the codegen'd
  `AppDNALifecycleDelegate` interface (`onSdkRuntimeLocked` /
  `onSdkRuntimeUnlocked`) so hosts can react to backend-driven SDK lock
  state changes. Lock state arrives on the `/sdk/bootstrap` response's
  new optional `runtime_lock` object when the tenant has been per-key-
  suspended (day 20+ of billing overdue, via the SPEC-322 sweep) or
  cancelled. Flutter remains a thin wrapper per ADR-001: enforcement
  lives in the native layer (iOS 1.0.64 / Android 1.0.36).

## 1.0.4

- `appdna_feature_parity: 1.0.63` — Flutter now wraps iOS 1.0.63 + Android
  1.0.35, the cross-account-entitlement-leak follow-up. The 1.0.3
  migration-tolerant policy (granting untagged historical purchases to
  whoever was currently identified) is now **scoped to the device's
  first identified user**, so an SDK-paywall-during-onboarding purchase
  made before `identify(...)` was called can only be claimed by the
  legitimate first user — a later user-switch on the same device is
  denied. Device QA reproduced the original leak; this release closes it.
  **No Dart code changes** — hosts pick up the fix automatically by
  upgrading the Flutter package.

## 1.0.3

- `appdna_feature_parity: 1.0.62` — Flutter now wraps iOS 1.0.62 + Android
  1.0.34, the cross-account-entitlement-leak hotfix. Both halves of the
  fix (write-side per-user `appAccountToken` / `obfuscatedAccountId`
  binding via `AppAccountTokenResolver`; read-side filter on every
  device-level entitlement read via `EntitlementOwnerFilter`) ship in the
  bundled native iOS + Android — **no Dart code changes**, hosts pick up
  the fix automatically by upgrading the Flutter package.

## 1.0.2

- SPEC-070-0 codegen artifacts for `AppDNAEnvironment` DTO + delegate
  interfaces shipped under `lib/generated/` (autogenerated; do not hand-
  edit). `appdna_feature_parity: 1.0.61` — Flutter now wraps iOS 1.0.61
  (entitlement-aware paywall triggers + restore routing) plus the
  Android catch-up (SPEC-070-A). No Dart code changes from the parity
  bump — the new behavior ships in the bundled native iOS + Android.
- Test runner: `shared_fixtures_test.dart` runner self-check moved
  inside a `test()` block so Flutter 3.41+ doesn't throw
  `OutsideTestException` at file-load time.

## 1.0.1

- Fix build errors and add smoke tests
- Add repository field to pubspec.yaml
- Add MIT LICENSE file

## 1.0.0

- Initial release
- Core SDK: configure, identify, track, reset
- Push notifications module
- Billing module (StoreKit 2 / Google Play Billing)
- Onboarding flows
- Paywall presentation
- Offline-first architecture
- Config bundle support
