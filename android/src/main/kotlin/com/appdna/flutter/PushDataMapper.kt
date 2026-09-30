package com.appdna.flutter

import org.json.JSONArray
import org.json.JSONObject

/**
 * SPEC-497 §9.2 "Nested values" — the host's push map (as Flutter's codec delivers it) → the SDK's
 * `Map<String, String>` for `AppDNA.push.isAppDNAMessage` / `handleMessageData` / `handleTapData`.
 *
 * - a scalar crosses as its string, in plain decimal without a trailing `.0` (`5.0` → `"5"`), the same
 *   as React Native Android (R82), so the one payload converts identically on both wrappers; NaN /
 *   ±Infinity are dropped (nested: null);
 * - a nested map or list crosses as JSON text (`JSONObject` / `JSONArray`) — never `toString()`,
 *   which yields `{type=deep_link, …}` that the SDK's `PushPayloadParser` cannot read;
 * - a `null` value is dropped (the SDK map has no null).
 *
 * Marshalling only: which message is AppDNA's, and what it does, is decided in the native SDK.
 */
internal object PushDataMapper {

    fun toStringMap(raw: Map<*, *>?): Map<String, String> {
        if (raw == null) return emptyMap()
        val out = LinkedHashMap<String, String>()
        for ((k, v) in raw) {
            val key = k?.toString() ?: continue
            val value = stringify(v) ?: continue
            out[key] = value
        }
        return out
    }

    private fun stringify(v: Any?): String? = when (v) {
        null -> null
        is String -> v
        is Map<*, *> -> toJson(v).toString()
        is List<*> -> toJson(v).toString()
        is Array<*> -> toJson(v.toList()).toString()
        is Double -> plain(v)
        is Float -> plain(v.toDouble())
        else -> v.toString()
    }

    /**
     * A Dart number as the host wrote it: `5.0` → `"5"`, `1e15` → `"1000000000000000"`, `0.0001` →
     * `"0.0001"` (never scientific notation), `-0.0` → `"0"`. NaN / ±Infinity have no JSON or decimal
     * form: dropped at the top level, `null` when nested — org.json would otherwise throw a
     * `JSONException` that reached Dart as a `PlatformException`.
     */
    internal fun plain(d: Double): String? {
        if (!d.isFinite()) return null
        if (d == 0.0) return "0"
        return java.math.BigDecimal.valueOf(d).stripTrailingZeros().toPlainString()
    }

    private fun toJson(v: Any?): Any = when (v) {
        null -> JSONObject.NULL
        is Map<*, *> -> JSONObject().also { o -> v.forEach { (k, x) -> if (k != null) o.put(k.toString(), toJson(x)) } }
        is List<*> -> JSONArray().also { a -> v.forEach { a.put(toJson(it)) } }
        is Array<*> -> toJson(v.toList())
        is Double -> if (!v.isFinite()) JSONObject.NULL else if (v == Math.floor(v) && Math.abs(v) < 1e15) v.toLong() else v
        is Float -> toJson(v.toDouble())
        else -> v
    }
}
