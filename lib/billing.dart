import 'dart:async';
import 'package:flutter/services.dart';
import 'generated/delegates.dart';

/// Represents a user's entitlement to a product or subscription.
class Entitlement {
  final String productId;
  final String store;
  final String status;
  final String? expiresAt;
  final bool isTrial;
  final String? offerType;

  Entitlement({
    required this.productId,
    required this.store,
    required this.status,
    this.expiresAt,
    this.isTrial = false,
    this.offerType,
  });

  factory Entitlement.fromMap(Map<dynamic, dynamic> map) {
    return Entitlement(
      productId: map['productId'] ?? '',
      store: map['store'] ?? '',
      status: map['status'] ?? '',
      expiresAt: map['expiresAt'],
      isTrial: map['isTrial'] ?? false,
      offerType: map['offerType'],
    );
  }
}

/// Result of a purchase operation.
class PurchaseResult {
  /// Status of the purchase: purchased, cancelled, pending, or unknown.
  final String status;

  /// The entitlement granted by the purchase, if successful.
  final Entitlement? entitlement;

  PurchaseResult({required this.status, this.entitlement});

  factory PurchaseResult.fromMap(Map<dynamic, dynamic> map) {
    return PurchaseResult(
      status: map['status'] ?? 'unknown',
      entitlement: map['entitlement'] != null
          ? Entitlement.fromMap(map['entitlement'])
          : null,
    );
  }
}

/// Localized product information from the app store.
class ProductInfo {
  final String id;
  final String name;
  final String description;
  final String displayPrice;
  final double price;
  final String? offerToken;

  ProductInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.displayPrice,
    required this.price,
    this.offerToken,
  });

  factory ProductInfo.fromMap(Map<dynamic, dynamic> map) {
    return ProductInfo(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      description: map['description'] ?? '',
      displayPrice: map['displayPrice'] ?? '',
      price: (map['price'] ?? 0).toDouble(),
      offerToken: map['offerToken'],
    );
  }
}

/// Billing bridge for AppDNA in-app purchases.
///
/// Provides purchase, restore, product info, and entitlement streaming
/// via platform channels that delegate to native iOS/Android SDKs.
class AppDNABilling {
  static const MethodChannel _channel =
      MethodChannel('com.appdna.sdk/billing');
  static const EventChannel _entitlementChannel =
      EventChannel('com.appdna.sdk/entitlements');
  // The billing lifecycle delegate is fed by the native
  // BillingDelegateForwarder over this observe-only EventChannel (the same
  // `{type, args}` envelope every other delegate stream uses). The old wiring
  // set a handler on the `com.appdna.sdk/billing` COMMAND channel, which native
  // never invokes — the delegate was dead.
  static const EventChannel _delegateChannel =
      EventChannel('com.appdna.sdk/events/billing');
  AppDNABillingDelegate? _delegate;
  StreamSubscription? _delegateSub;
  // Store the callback-style entitlements subscription so a
  // re-registration cancels the prior one instead of stacking permanent listeners.
  StreamSubscription? _entitlementsCallbackSub;

  /// Set a delegate to receive billing lifecycle callbacks (purchases,
  /// failures, entitlement changes, restores, billing-unavailable).
  /// Pass `null` to clear the current delegate and stop listening.
  void setDelegate(AppDNABillingDelegate? delegate) {
    _delegate = delegate;
    _delegateSub?.cancel();
    _delegateSub = null;
    if (delegate == null) return;
    _delegateSub = _delegateChannel.receiveBroadcastStream().listen(_dispatch);
  }

  void _dispatch(dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type'] as String?;
    final args =
        (raw['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final d = _delegate;
    if (d == null || type == null) return;
    switch (type) {
      case 'onPurchaseCompleted':
        d.onPurchaseCompleted(
          args['productId'] as String? ?? '',
          (args['transaction'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{},
        );
        break;
      case 'onPurchaseFailed':
        // Generated delegate types this as `Object`; native sends a
        // { message, type } map. Pass through verbatim.
        d.onPurchaseFailed(
          args['productId'] as String? ?? '',
          args['error'] ?? const <String, dynamic>{},
        );
        break;
      case 'onEntitlementsChanged':
        // Each entry is an Entitlement-shaped map (productId/store/status/…);
        // the host parses via Entitlement.fromMap.
        final entitlements = (args['entitlements'] as List?)
                ?.map((e) => (e as Map).cast<String, dynamic>())
                .toList() ??
            <Map<String, dynamic>>[];
        d.onEntitlementsChanged(entitlements);
        break;
      case 'onRestoreCompleted':
        final restored = (args['restoredProductIds'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[];
        d.onRestoreCompleted(restored);
        break;
      case 'onBillingUnavailable':
        d.onBillingUnavailable();
        break;
      default:
        // Unknown event — forward-compat with future native methods.
        break;
    }
  }

  /// Register a callback for entitlement changes.
  /// Alternative to the [onEntitlementsChanged] stream for delegate-style usage.
  void onEntitlementsChangedCallback(void Function(List<Entitlement>) callback) {
    _entitlementsCallbackSub?.cancel();
    _entitlementsCallbackSub = onEntitlementsChanged.listen(callback);
  }

  /// Purchase a product by its store product ID.
  ///
  /// On Android, pass [offerToken] for subscription offers (base plan tokens).
  /// Returns a [PurchaseResult] indicating the outcome.
  Future<PurchaseResult> purchase(String productId,
      {String? offerToken}) async {
    final result = await _channel.invokeMethod('purchase', {
      'productId': productId,
      'offerToken': offerToken,
    });
    return PurchaseResult.fromMap(Map<dynamic, dynamic>.from(result));
  }

  /// Restore previously purchased products.
  ///
  /// Syncs with the App Store / Google Play and returns all active entitlements.
  Future<List<Entitlement>> restorePurchases() async {
    final result = await _channel.invokeMethod('restorePurchases');
    return (result as List)
        .map((e) => Entitlement.fromMap(Map<dynamic, dynamic>.from(e)))
        .toList();
  }

  /// Get localized product information from the store.
  ///
  /// Pass a list of product IDs configured in App Store Connect / Google Play Console.
  Future<List<ProductInfo>> getProducts(List<String> productIds) async {
    final result =
        await _channel.invokeMethod('getProducts', {'productIds': productIds});
    return (result as List)
        .map((e) => ProductInfo.fromMap(Map<dynamic, dynamic>.from(e)))
        .toList();
  }

  /// Check if the user has an active subscription.
  Future<bool> hasActiveSubscription() async {
    return await _channel.invokeMethod('hasActiveSubscription');
  }

  /// Force a refresh of the native entitlement cache from
  /// the store / backend. Real on both platforms.
  Future<void> refreshEntitlementCache() async {
    await _channel.invokeMethod('refreshEntitlementCache');
  }

  /// Get all current entitlements for the user.
  Future<List<Entitlement>> getEntitlements() async {
    final result = await _channel.invokeMethod('getEntitlements');
    return (result as List)
        .map((e) => Entitlement.fromMap(Map<dynamic, dynamic>.from(e)))
        .toList();
  }

  /// Stream of entitlement changes.
  ///
  /// Emits updated entitlements when purchases, renewals, or revocations occur.
  Stream<List<Entitlement>> get onEntitlementsChanged {
    return _entitlementChannel
        .receiveBroadcastStream()
        .map((data) => (data as List)
            .map((e) => Entitlement.fromMap(Map<dynamic, dynamic>.from(e)))
            .toList());
  }
}
