package com.appdna.flutter

import ai.appdna.sdk.AppDNAOptions
import ai.appdna.sdk.BillingProvider
import ai.appdna.sdk.LogLevel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * SPEC-070-B AC-11 — the native `parseOptions` mapping, on Flutter/Android.
 *
 * ## Why this file (and this whole source set) exists
 *
 * AC-11 asks for native `parseOptions` unit tests — Swift AND Kotlin — for **RN *and* Flutter**,
 * because both wrappers once hardcoded `?? 300` for `configTTL` and both once read the `framework`
 * tag out of the host's own map. RN got its two suites. Flutter got the CODE FIX and nothing else:
 * this plugin had no `src/test` source set at all, and `parseOptions` was `private`, so the AC's own
 * testability prerequisite had never been applied. A guarantee that is only tested on one platform
 * is a guarantee on one platform.
 *
 * A Dart test cannot reach any of this — `MethodChannel` is mocked away in `flutter test`, so it
 * observes neither a Kotlin `?:` default nor the tag the bridge injects. Only a native test does.
 *
 * ## The oracle
 *
 * Every default is compared against `AppDNAOptions()`'s own value, never against a literal. Asserting
 * `configTTL == 3600` against a number written here would re-create the exact defect: a constant in
 * the wrapper that agrees with nothing. If native moves, this test moves with it — and the wrapper is
 * forced to move too.
 *
 * The one deliberate literal is the wire value `"flutter"`, because that string IS the contract
 * (BigQuery's `framework` column); mirroring it from the constant under test would assert nothing.
 *
 * Robolectric, not a plain JVM test: `parseOptions` itself is pure Kotlin (a plain `Map` in, an
 * `AppDNAOptions` out), but REACHING it means constructing `AppdnaPlugin`, whose field initializers
 * build a `Handler(Looper.getMainLooper())` — and on the stock `android.jar` every method throws.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class AppdnaParseOptionsTest {

    private val plugin = AppdnaPlugin()

    /** The native defaults. The oracle — never a literal. */
    private val defaults = AppDNAOptions()

    // ── AC-11 leg 1: the `framework` tag ─────────────────────────────────────

    @Test
    fun `framework is flutter regardless of what the host sends`() {
        assertEquals("flutter", plugin.parseOptions(null).framework)
        assertEquals("flutter", plugin.parseOptions(emptyMap()).framework)

        // SPEC-070-B §7 rule 1 — the tag is INJECTED, never read from the host's map. This used to be
        // `map["framework"] as? String ?: "native"`, which had two failure modes and no way to notice
        // either: a host could SPOOF its attribution, and any path reaching configure without Dart's
        // `toMap()` fell back to "native" and tagged every Flutter event as a native one. The event
        // envelope schema is `.catch('native')`, so a wrong tag does not error, is not logged and is
        // not metered — it just quietly lies in BigQuery, which is the worst possible failure.
        assertEquals("flutter", plugin.parseOptions(mapOf("framework" to "native")).framework)
        assertEquals("flutter", plugin.parseOptions(mapOf("framework" to "react_native")).framework)

        // …and it is never the native default, which is what a dropped tag would silently produce.
        assertFalse(plugin.parseOptions(emptyMap()).framework == defaults.framework)
    }

    @Test
    fun `frameworkVersion carries the wrapper's own version from Dart`() {
        // ⚠ NOT the same rule as the tag. The Flutter wrapper's version lives in Dart
        // (`AppDNAOptions.toMap()` always supplies it, even on `configure(apiKey:)` with no options),
        // so on this platform native passes it through rather than injecting it. What matters here is
        // that the plumbing does not DROP it — a null `frameworkVersion` is what `diagnose()` and
        // every event envelope reported for two releases while the constant was stale.
        // `check:wrapper-version-selfreport` owns the value itself.
        assertEquals("1.2.3", plugin.parseOptions(mapOf("frameworkVersion" to "1.2.3")).frameworkVersion)
        assertNull(plugin.parseOptions(emptyMap()).frameworkVersion)
    }

    // ── AC-11 leg 2: `configTTL` (E7 — the 12× drift) ────────────────────────

    @Test
    fun `configTTL defaults to the native value, not a wrapper literal`() {
        // 🔴 THE BUG. A `?: 300` here sat 12× below native's 3600, so every wrapped app re-fetched its
        // remote config twelve times as often as a native one — burning battery and quota — and no
        // test could see it, because the only place the number existed was a Kotlin `?:`.
        assertEquals(defaults.configTTL, plugin.parseOptions(null).configTTL)
        assertEquals(defaults.configTTL, plugin.parseOptions(emptyMap()).configTTL)
    }

    @Test
    fun `configTTL is honored when the host provides one`() {
        // Dart sends numbers over the MethodChannel as `Integer`/`Double` depending on the value, so
        // the cast is `as? Number` — both must land on the same Long.
        assertEquals(900L, plugin.parseOptions(mapOf("configTTL" to 900)).configTTL)
        assertEquals(900L, plugin.parseOptions(mapOf("configTTL" to 900.0)).configTTL)
    }

    @Test
    fun `a zero, negative or non-numeric vetoTimeout is the native default`() {
        // Mapped HERE, so diagnose() reports the value the bridge applies.
        assertEquals(defaults.vetoTimeout, plugin.parseOptions(mapOf("vetoTimeout" to 0)).vetoTimeout)
        assertEquals(defaults.vetoTimeout, plugin.parseOptions(mapOf("vetoTimeout" to -3)).vetoTimeout)
        assertEquals(defaults.vetoTimeout, plugin.parseOptions(mapOf("vetoTimeout" to "ten")).vetoTimeout)
        assertEquals(5L, plugin.parseOptions(mapOf("vetoTimeout" to 0)).vetoTimeout)
    }

    /**
     * The exact value reaches the core, which diagnose() reports as given (core `DiagnoseVetoTimeoutTest`).
     * NEGATIVE CONTROL: only the rounded-up whole seconds reached the core, so diagnose() said 1 for 0.5.
     */
    @Test
    fun `the exact vetoTimeout reaches the core for diagnose`() {
        assertEquals(0.5, plugin.parseOptions(mapOf("vetoTimeout" to 0.5)).vetoTimeoutSeconds!!, 0.0)
        assertEquals(1L, plugin.parseOptions(mapOf("vetoTimeout" to 0.5)).vetoTimeout)
        assertEquals(null, plugin.parseOptions(mapOf("vetoTimeout" to 0)).vetoTimeoutSeconds)
        assertEquals(null, plugin.parseOptions(emptyMap()).vetoTimeoutSeconds)
    }

    /**
     * The runtime settings reach native only when the host set them — native resolves host option >
     * bootstrap `settings` > default, so a value this bridge filled in (it used `?: 30L` / `?: 20`) would read
     * as the host's own and beat the server's. Driven by the shared fixture `runtime_settings_precedence`.
     * NEGATIVE CONTROL: the old `?: 20` → `batchSize` 20 for every Flutter app; this test fails on it.
     */
    @Test
    fun `runtime settings reach native only when the host set them (shared fixture)`() {
        val w = wrapperOptionsFixture()
        val hostSets = w.getJSONObject("host_sets")
        val map = hostSets.keys().asSequence().associateWith { hostSets.get(it) }
        val parsed = plugin.parseOptions(map)
        val receives = w.getJSONObject("native_receives")
        for (key in receives.keys()) assertEquals(key, receives.getInt(key), nativeValue(parsed, key)?.toInt())
        val unset = w.getJSONArray("native_unset")
        for (i in 0 until unset.length()) assertNull(unset.getString(i), nativeValue(parsed, unset.getString(i)))
        val none = plugin.parseOptions(emptyMap())
        for (key in listOf("flushInterval", "batchSize", "configTTL")) assertNull(key, nativeValue(none, key))
    }

    /** The shared fixture's `wrapper_options` — the options a host passes and what native must receive. */
    private fun wrapperOptionsFixture(): org.json.JSONObject {
        fun root(): java.io.File {
            System.getenv("APPDNA_SDK_FIXTURES_DIR")?.let { if (java.io.File(it).isDirectory) return java.io.File(it) }
            var here: java.io.File? = java.io.File(".").canonicalFile
            repeat(12) {
                val candidate = java.io.File(here, "packages/sdk-shared-fixtures")
                if (candidate.isDirectory) return candidate
                here = here?.parentFile
            }
            val codespace = java.io.File("/workspaces/appdna-ai/packages/sdk-shared-fixtures")
            if (codespace.isDirectory) return codespace
            error("Could not locate packages/sdk-shared-fixtures. Set APPDNA_SDK_FIXTURES_DIR.")
        }
        val file = java.io.File(root(), "resilience/runtime_settings_precedence.fixture.json")
        return org.json.JSONObject(file.readText()).getJSONObject("resilience").getJSONObject("wrapper_options")
    }

    /**
     * The value of a runtime setting as native received it (null: not set by the host — native's option left at
     * its default, which native reads as unset).
     */
    private fun nativeValue(o: ai.appdna.sdk.AppDNAOptions, key: String): Number? = when (key) {
        "flushInterval" -> o.flushInterval.takeIf { it != ai.appdna.sdk.AppDNAOptions.DEFAULT_FLUSH_INTERVAL }
        "batchSize" -> o.batchSize.takeIf { it != ai.appdna.sdk.AppDNAOptions.DEFAULT_BATCH_SIZE }
        "configTTL" -> o.configTTL.takeIf { it != ai.appdna.sdk.AppDNAOptions.DEFAULT_CONFIG_TTL }
        else -> error("unknown runtime setting '$key'")
    }

    @Test
    fun `the other scalars also default to the native values`() {
        val d = plugin.parseOptions(emptyMap())
        assertEquals(defaults.flushInterval, d.flushInterval)
        assertEquals(defaults.batchSize, d.batchSize)
        assertEquals(defaults.vetoTimeout, d.vetoTimeout)
        assertEquals(defaults.requireConsent, d.requireConsent)
        assertEquals(defaults.notificationIcon, d.notificationIcon)

        val set = plugin.parseOptions(
            mapOf(
                "flushInterval" to 5,
                "batchSize" to 7,
                "vetoTimeout" to 11,
                "requireConsent" to true,
                "notificationIcon" to 42,
            ),
        )
        assertEquals(5L, set.flushInterval)
        assertEquals(7, set.batchSize)
        assertEquals(11L, set.vetoTimeout)
        assertEquals(true, set.requireConsent)
        assertEquals(42, set.notificationIcon)
    }

    // ── AC-11 leg 3 / AC-21: `billingProvider` ───────────────────────────────

    @Test
    fun `billingProvider decodes the bare strings`() {
        assertEquals(BillingProvider.RevenueCat, plugin.parseOptions(mapOf("billingProvider" to "revenueCat")).billingProvider)
        assertEquals(BillingProvider.StoreKit2, plugin.parseOptions(mapOf("billingProvider" to "storeKit2")).billingProvider)
        assertEquals(BillingProvider.None, plugin.parseOptions(mapOf("billingProvider" to "none")).billingProvider)
    }

    @Test
    fun `billingProvider decodes the adapty tagged map with its apiKey`() {
        assertEquals(
            BillingProvider.Adapty("public_live_abc"),
            plugin.parseOptions(
                mapOf("billingProvider" to mapOf("type" to "adapty", "apiKey" to "public_live_abc")),
            ).billingProvider,
        )
    }

    @Test
    fun `billingProvider refuses an adapty with no usable key`() {
        // A bare "adapty" carries no key, and `Adapty("")` would hand the Adapty SDK an empty key and
        // fail at runtime, far from the cause. `fromWire` returns null for both, and the wrapper falls
        // back to the native default rather than guessing.
        assertEquals(defaults.billingProvider, plugin.parseOptions(mapOf("billingProvider" to "adapty")).billingProvider)
        assertEquals(
            defaults.billingProvider,
            plugin.parseOptions(
                mapOf("billingProvider" to mapOf("type" to "adapty", "apiKey" to "")),
            ).billingProvider,
        )
    }

    @Test
    fun `billingProvider falls back to the native default when absent or unknown`() {
        // 🔴 Android gained `billingProvider` in 1.0.42; before that the Dart-side option a host had
        // been able to set since 070-C reached native on iOS and was silently dropped here — a host
        // configuring RevenueCat got Play Billing.
        assertEquals(defaults.billingProvider, plugin.parseOptions(emptyMap()).billingProvider)
        assertEquals(defaults.billingProvider, plugin.parseOptions(mapOf("billingProvider" to "paddle")).billingProvider)
    }

    // ── `logLevel` ───────────────────────────────────────────────────────────

    @Test
    fun `logLevel maps every wire value and defaults to the native one`() {
        assertEquals(LogLevel.NONE, plugin.parseOptions(mapOf("logLevel" to "none")).logLevel)
        assertEquals(LogLevel.ERROR, plugin.parseOptions(mapOf("logLevel" to "error")).logLevel)
        assertEquals(LogLevel.WARNING, plugin.parseOptions(mapOf("logLevel" to "warning")).logLevel)
        assertEquals(LogLevel.INFO, plugin.parseOptions(mapOf("logLevel" to "info")).logLevel)
        assertEquals(LogLevel.DEBUG, plugin.parseOptions(mapOf("logLevel" to "debug")).logLevel)
        assertEquals(defaults.logLevel, plugin.parseOptions(mapOf("logLevel" to "verbose")).logLevel)
        assertEquals(defaults.logLevel, plugin.parseOptions(emptyMap()).logLevel)
    }

    /** Fractional seconds are not truncated: 0.5 s used to become 0 → the 5 s default, 2.7 s → 2 s. */
    @Test
    fun vetoTimeoutFractionalSecondsBecomeExactMilliseconds() {
        val plugin = AppdnaPlugin()
        assertEquals(500L, plugin.parseVetoTimeoutMs(mapOf("vetoTimeout" to 0.5)))
        assertEquals(2700L, plugin.parseVetoTimeoutMs(mapOf("vetoTimeout" to 2.7)))
        assertEquals(ai.appdna.sdk.AppDNAOptions().vetoTimeout * 1000L, plugin.parseVetoTimeoutMs(mapOf("vetoTimeout" to 0)))
        assertEquals(ai.appdna.sdk.AppDNAOptions().vetoTimeout * 1000L, plugin.parseVetoTimeoutMs(null))
        assertEquals(1L, plugin.parseOptions(mapOf("vetoTimeout" to 0.5)).vetoTimeout)
    }
}
