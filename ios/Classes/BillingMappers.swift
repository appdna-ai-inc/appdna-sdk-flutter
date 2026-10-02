import Foundation
import AppDNASDK

// MARK: - Billing type -> Flutter map bridging
//
// Thin marshalling layer only: converts the native AppDNASDK billing value
// types into `[String: Any?]` dictionaries whose KEYS match the Dart parsers
// in `lib/billing.dart` (`Entitlement.fromMap`, `ProductInfo.fromMap`,
// `PurchaseResult.fromMap`). No rendering, network, storage, or business
// logic — pure field mapping.

private let iso8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

extension Entitlement {
    /// Maps native `Entitlement` (identifier / isActive / expiresAt / productId)
    /// to the Dart `Entitlement.fromMap` shape:
    /// productId / store / status / expiresAt / isTrial / offerType.
    func toFlutterMap() -> [String: Any?] {
        return [
            "productId": productId,
            // Native iOS entitlements come from StoreKit / App Store.
            "store": "app_store",
            "status": isActive ? "active" : "expired",
            "expiresAt": expiresAt.map { iso8601Formatter.string(from: $0) },
            // Native `Entitlement` carries no trial/offer metadata; the Dart
            // parser defaults these, so we emit stable placeholders.
            "isTrial": false,
            "offerType": nil,
        ]
    }
}

extension ProductInfo {
    /// Maps native `ProductInfo` (id / displayName / description / price:Decimal
    /// / displayPrice / subscription) to the Dart `ProductInfo.fromMap` shape:
    /// id / name / description / displayPrice / price / offerToken.
    func toFlutterMap() -> [String: Any?] {
        return [
            "id": id,
            "name": displayName,
            "description": description,
            "displayPrice": displayPrice,
            "price": NSDecimalNumber(decimal: price).doubleValue,
            // `offerToken` is a Play Billing concept with no StoreKit equivalent.
            "offerToken": nil,
        ]
    }
}

extension TransactionInfo {
    /// Maps a successful native `TransactionInfo` to the Dart `PurchaseResult.fromMap` shape:
    /// `{status: "purchased", entitlement: {...}}`. The entitlement is the product's entry in
    /// `entitlements` (`AppDNA.billing.getEntitlements()` after the purchase — StoreKit's real
    /// `expiresAt`, and `status` from `isActive`); it used to be a placeholder with `expiresAt: nil`
    /// always. `getEntitlements()` is local (StoreKit), so the entry does not depend on the server read
    /// the purchase queues in the background: a server answer that arrives later changes
    /// `onEntitlementsChanged`, not this result. Without an entry (a consumable, or a provider that has not caught up) it falls back to
    /// `status: "active"`, `expiresAt: nil`. The native `purchase` throws on user-cancel, so the
    /// "cancelled" status is produced at the call site.
    func toPurchaseResultMap(entitlements: [Entitlement] = []) -> [String: Any?] {
        let entitlement: [String: Any?] = entitlements.first { $0.productId == productId }?.toFlutterMap() ?? [
            "productId": productId,
            "store": "app_store",
            "status": "active",
            "expiresAt": nil,
            "isTrial": false,
            "offerType": nil,
        ]
        return [
            "status": "purchased",
            "entitlement": entitlement,
        ]
    }
}

enum BillingMappers {
    /// A user cancellation (the App Store sheet dismissed) maps to the Dart `{status: "cancelled"}`
    /// contract instead of a FlutterError. Decided by the TYPED error — the SDK's public
    /// `billingErrorType` (`BillingError.userCancelled`, the bridge's `StoreKit2Error.userCancelled`,
    /// `SKError.paymentCancelled`) — never by the message: this used to treat ANY error whose
    /// localized text contained "cancel" (a Swift `CancellationError` from a shutdown, a server
    /// message, a localized string) as the user cancelling, and every non-English message as not.
    static func isUserCancellation(_ error: Error) -> Bool {
        return billingErrorType(error) == "userCancelled"
    }

    /// SPEC-497 §3.4 / §13b.2 — the `details` of a `PURCHASE_ERROR` / `RESTORE_ERROR` FlutterError:
    /// the stable `billingErrorType` of the failure (`providerNotAvailable`, `productNotFound`, …), so a
    /// Dart host reads `(e as PlatformException).details?['errorType']`. Pure — RunnerTests asserts it.
    static func errorDetails(_ error: Error) -> [String: Any] {
        return ["errorType": billingErrorType(error)]
    }
}
