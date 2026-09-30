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
    /// Maps a successful native `TransactionInfo` to the Dart
    /// `PurchaseResult.fromMap` shape: { status: "purchased", entitlement: {...} }.
    /// Mirrors the Android success mapping. The native `purchase` throws on
    /// user-cancel, so the "cancelled" status is produced at the call site.
    func toPurchaseResultMap() -> [String: Any?] {
        let entitlement: [String: Any?] = [
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
    /// The iOS billing bridge throws an internal `StoreKit2Error.userCancelled`
    /// (errorDescription: "Purchase was cancelled") when the user dismisses the
    /// App Store sheet. That type is not public, so detect cancellation by its
    /// localized description to map it to the Dart `{status: "cancelled"}`
    /// contract instead of surfacing a FlutterError.
    static func isUserCancellation(_ error: Error) -> Bool {
        return error.localizedDescription.lowercased().contains("cancel")
    }

    /// SPEC-497 §3.4 / §13b.2 — the `details` of a `PURCHASE_ERROR` / `RESTORE_ERROR` FlutterError:
    /// the stable `billingErrorType` of the failure (`providerNotAvailable`, `productNotFound`, …), so a
    /// Dart host reads `(e as PlatformException).details?['errorType']`. Pure — RunnerTests asserts it.
    static func errorDetails(_ error: Error) -> [String: Any] {
        return ["errorType": billingErrorType(error)]
    }
}
