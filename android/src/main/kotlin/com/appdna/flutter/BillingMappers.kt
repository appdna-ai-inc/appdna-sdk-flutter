package com.appdna.flutter

import ai.appdna.sdk.billing.Entitlement
import ai.appdna.sdk.billing.ProductInfo
import ai.appdna.sdk.billing.PurchaseResult

/**
 * DTO marshalling for the billing types the plugin bridges to Dart.
 *
 * These `toMap()` extensions previously lived in the native SDK; sdk-android 1.0.39
 * no longer exposes them, and per ADR-001 the thin wrapper owns channel marshalling.
 * The keys match the Dart parsers in `lib/billing.dart` (Entitlement.fromMap /
 * ProductInfo.fromMap / PurchaseResult.fromMap).
 */

internal fun Entitlement.toMap(): Map<String, Any?> = mapOf(
    "productId" to productId,
    "store" to store,
    "status" to status,
    "expiresAt" to expiresAt,
    "isTrial" to isTrial,
    "offerType" to offerType,
)

internal fun ProductInfo.toMap(): Map<String, Any?> = mapOf(
    "id" to id,
    "name" to name,
    "description" to description,
    // Dart reads `displayPrice` (native formattedPrice) + `price` as a double
    // (native priceMicros are 1e6 * the unit price).
    "displayPrice" to formattedPrice,
    "price" to priceMicros / 1_000_000.0,
    "currencyCode" to currencyCode,
    "offerToken" to offerToken,
)

internal fun PurchaseResult.toMap(): Map<String, Any?> = when (this) {
    is PurchaseResult.Purchased -> mapOf("status" to "purchased", "entitlement" to entitlement.toMap())
    is PurchaseResult.Failed -> mapOf("status" to "failed", "error" to error)
    PurchaseResult.Cancelled -> mapOf("status" to "cancelled")
    PurchaseResult.Pending -> mapOf("status" to "pending")
    PurchaseResult.Unknown -> mapOf("status" to "unknown")
}
