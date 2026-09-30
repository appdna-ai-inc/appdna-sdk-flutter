package com.appdna.flutter

import ai.appdna.sdk.AppDNA
import ai.appdna.sdk.billing.BillingError
import android.app.Activity
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.CountDownLatch

/**
 * SPEC-497 §3.4 (R8-S1) and §3.9 — what a Dart host learns when a purchase fails.
 *
 *  1. The plugin's paywall delegate, called through the 4-arg `onPaywallPurchaseFailed` every native
 *     path uses (and, separately, the 2- and 3-arg ones), emits EXACTLY ONE `onPaywallPurchaseFailed`
 *     on the paywall event sink, carrying `errorType` and `productId`. It used to override only the
 *     2-arg overload, so the native default chain dropped both and Dart saw `'unknown'` / `null`.
 *  2. A failed `billing.purchase` / `billing.restorePurchases` keeps its code and gains
 *     `details['errorType']` (was `null`).
 *  3. The wrapper-reachable half of `billing/paywall_purchase_no_provider_fails_loudly` and
 *     `…_revenuecat_fails_loudly`: configured through the plugin's own "configure" with that
 *     `billing_provider`, `billing.purchase` rejects with `PURCHASE_ERROR` whose `details.errorType`
 *     equals the fixture's `expect.delegate_calls[0].args.errorType` (the paywall-tap half needs UI and
 *     is asserted by the native runners).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class PurchaseFailureBridgeTest {

    private val plugin = AppdnaPlugin()

    /** Every `{type, args}` the plugin pushed to the Dart side, in order. */
    private val events = mutableListOf<Map<*, *>>()

    private val recordingSink = object : EventChannel.EventSink {
        override fun success(event: Any?) {
            events += event as Map<*, *>
        }
        override fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) =
            throw AssertionError("the forwarder sent an error to Dart: $errorCode")
        override fun endOfStream() {}
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @After
    fun tearDown() {
        runCatching { AppDNA.shutdown() }
        idle()
    }

    private fun failedEvents() = events.filter { it["type"] == "onPaywallPurchaseFailed" }

    @Test
    fun `the 4-arg overload emits one event with the real errorType and productId`() {
        plugin.paywallEventSink = recordingSink
        plugin.PaywallDelegateForwarder().onPaywallPurchaseFailed(
            "pw_1", BillingError.ProviderNotAvailable("revenueCat: purchases are made by revenueCat in your app"),
            "providerNotAvailable", "plan_monthly",
        )
        idle()
        val one = failedEvents().single()
        val args = one["args"] as Map<*, *>
        assertEquals("pw_1", args["paywallId"])
        assertEquals("providerNotAvailable", args["errorType"])
        assertEquals("plan_monthly", args["productId"])
    }

    @Test
    fun `the 2-arg overload emits one event whose errorType comes from the error`() {
        plugin.paywallEventSink = recordingSink
        plugin.PaywallDelegateForwarder().onPaywallPurchaseFailed("pw_1", BillingError.ProviderNotAvailable("x"))
        idle()
        val args = failedEvents().single()["args"] as Map<*, *>
        assertEquals("providerNotAvailable", args["errorType"])
        assertNull(args["productId"])
    }

    @Test
    fun `the 3-arg overload emits one event`() {
        plugin.paywallEventSink = recordingSink
        plugin.PaywallDelegateForwarder().onPaywallPurchaseFailed("pw_1", RuntimeException("x"), "networkError")
        idle()
        val args = failedEvents().single()["args"] as Map<*, *>
        assertEquals("networkError", args["errorType"])
        assertNull(args["productId"])
    }

    @Test
    fun `a failed purchase or restore carries details errorType`() {
        assertEquals(
            mapOf("errorType" to "providerNotAvailable"),
            plugin.purchaseErrorDetails(BillingError.ProviderNotAvailable("No billing provider configured")),
        )
        assertEquals("networkError", plugin.purchaseErrorDetails(BillingError.NetworkError(java.io.IOException("offline")))["errorType"])
        assertEquals("unknown", plugin.purchaseErrorDetails(IllegalStateException("x"))["errorType"])
    }

    @Test
    fun `fails_loudly fixtures - billing purchase rejects with the fixture's errorType`() {
        // The §3.9 `*_fails_loudly` set, by SHAPE: a `purchase` fixture whose setup provider must refuse.
        val loud = File(fixturesRoot(), "billing").listFiles().orEmpty()
            .filter { it.name.endsWith(".fixture.json") }
            .sortedBy { it.name }
            .map { it.name.removeSuffix(".fixture.json") to JSONObject(it.readText()) }
            .filter { (_, json) ->
                json.getJSONObject("action").getString("kind") == "purchase" &&
                    json.optJSONObject("setup")?.optJSONObject("config")?.optString("billing_provider") in setOf("none", "revenueCat")
            }
        assertEquals("§3.9 has exactly two refusing-provider purchase fixtures (none, revenueCat)", 2, loud.size)
        for ((id, fixture) in loud) {
            val provider = fixture.getJSONObject("setup").getJSONObject("config").getString("billing_provider")
            val call = fixture.getJSONObject("expect").getJSONArray("delegate_calls").getJSONObject(0)
            val expectedErrorType = call.getJSONObject("args").getString("errorType")
            val productId = call.getJSONObject("args").optString("productId", "plan_monthly")

            configureWith(provider)
            val (code, details) = purchase(productId)
            assertEquals("[$id] the rejection code hosts match", "PURCHASE_ERROR", code)
            assertEquals("[$id] details.errorType", expectedErrorType, (details as? Map<*, *>)?.get("errorType"))

            val (restoreCode, restoreDetails) = billingCall(MethodCall("restorePurchases", null))
            assertEquals("[$id] restore code", "RESTORE_ERROR", restoreCode)
            assertEquals("[$id] restore details.errorType (restore error contract)",
                "providerNotAvailable", (restoreDetails as? Map<*, *>)?.get("errorType"))
            AppDNA.shutdown()
            idle()
        }
    }

    /** The plugin's own "configure", as Dart calls it, then wait for the SDK to be ready. */
    private fun configureWith(provider: String) {
        runCatching { AppDNA.shutdown() }
        idle()
        plugin.context = RuntimeEnvironment.getApplication()
        val ready = CountDownLatch(1)
        plugin.onMethodCall(
            MethodCall("configure", mapOf(
                "apiKey" to "adn_test_placeholder",
                "env" to "staging",
                "options" to mapOf("billingProvider" to provider, "batchSize" to 0, "logLevel" to "none"),
            )),
            object : MethodChannel.Result {
                override fun success(result: Any?) {}
                override fun error(code: String, message: String?, details: Any?) = throw AssertionError(code)
                override fun notImplemented() = throw AssertionError("configure not implemented")
            },
        )
        AppDNA.onReady { ready.countDown() }
        val deadline = System.currentTimeMillis() + 20_000
        while (ready.count > 0L && System.currentTimeMillis() < deadline) {
            idle()
            Thread.sleep(20)
        }
        assertTrue("the SDK never reached READY — the purchase below would assert nothing", ready.count == 0L)
    }

    private fun purchase(productId: String): Pair<String?, Any?> {
        plugin.activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        return billingCall(MethodCall("purchase", mapOf("productId" to productId)))
    }

    /** Run a billing-channel call and return the rejection (code, details); fail on success. */
    private fun billingCall(call: MethodCall): Pair<String?, Any?> {
        var outcome: Pair<String?, Any?>? = null
        plugin.handleBilling(call, object : MethodChannel.Result {
            override fun success(result: Any?) {
                throw AssertionError("${call.method} SUCCEEDED ($result) — it must be refused on this provider")
            }
            override fun error(code: String, message: String?, details: Any?) {
                outcome = code to details
            }
            override fun notImplemented() = throw AssertionError("${call.method} not implemented")
        })
        val deadline = System.currentTimeMillis() + 10_000
        while (outcome == null && System.currentTimeMillis() < deadline) {
            idle()
            Thread.sleep(10)
        }
        return outcome ?: throw AssertionError("${call.method} never settled its result")
    }

    private fun fixturesRoot(): File {
        System.getenv("APPDNA_SDK_FIXTURES_DIR")?.let { if (File(it).isDirectory) return File(it) }
        var here: File? = File(".").canonicalFile
        repeat(12) {
            val candidate = File(here, "packages/sdk-shared-fixtures")
            if (candidate.isDirectory) return candidate
            here = here?.parentFile
        }
        val codespace = File("/workspaces/appdna-ai/packages/sdk-shared-fixtures")
        if (codespace.isDirectory) return codespace
        error("Could not locate packages/sdk-shared-fixtures. Set APPDNA_SDK_FIXTURES_DIR.")
    }
}
