package com.appdna.flutter

import ai.appdna.sdk.AppDNA
import ai.appdna.sdk.AppDNABillingDelegate
import ai.appdna.sdk.TransactionInfo
import android.content.Context
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.CountDownLatch

/**
 * The Flutter half of the late-purchase delivery queue, against the LIVE core queue.
 *
 *  - A purchase the core queued (seeded into its own persisted ledger, `appdna.pending_deliveries_v1`)
 *    reaches Dart exactly once when Dart starts listening on `events/billing` — the listener makes the
 *    plugin's forwarder a DELIVERING delegate, which drains the queue — and the queue is then empty.
 *  - Cancelling and listening again delivers nothing a second time.
 *  - A listener cancelled before the drain reaches the entry leaves it QUEUED: the forwarder throws
 *    when it has no Dart sink, which is the drain's "not delivered" signal (a null sink is never
 *    counted as a delivery).
 *  - On Main a delivery reaches the sink before the call returns.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class BillingDeliveryBridgeTest {

    private val plugin = AppdnaPlugin()
    private val events = mutableListOf<Map<*, *>>()
    private val sink = object : EventChannel.EventSink {
        override fun success(event: Any?) { events += event as Map<*, *> }
        override fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) = throw AssertionError(errorCode)
        override fun endOfStream() {}
    }
    private val app: Context get() = RuntimeEnvironment.getApplication()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Before
    fun setUp() {
        runCatching { AppDNA.shutdown() }
        idle()
        plugin.context = app
        val ready = CountDownLatch(1)
        plugin.onMethodCall(
            MethodCall("configure", mapOf(
                "apiKey" to "adn_test_placeholder", "env" to "staging",
                "options" to mapOf("batchSize" to 0, "logLevel" to "none"),
            )),
            object : MethodChannel.Result {
                override fun success(result: Any?) {}
                override fun error(code: String, message: String?, details: Any?) = throw AssertionError(code)
                override fun notImplemented() = throw AssertionError("configure")
            },
        )
        AppDNA.onReady { ready.countDown() }
        waitUntil(20_000) { ready.count == 0L && drainReady() }
        assertTrue("the SDK never became ready to drain its delivery queue", drainReady())
        seedQueue(emptyList())
    }

    @After
    fun tearDown() {
        runCatching { plugin.billingStreamHandler.onCancel(null) }
        runCatching { seedQueue(emptyList()) }
        runCatching { AppDNA.shutdown() }
        idle()
    }

    // ── The core's own state, reached by reflection (internal to the SDK module) ────────────────────

    private fun manager(): Any? = AppDNA.billing.let { b ->
        b::class.java.declaredMethods.first { it.name.startsWith("getManager") }.apply { isAccessible = true }.invoke(b)
    }

    private fun drainReady(): Boolean {
        val mgr = manager() ?: return false
        val completion = mgr::class.java.getDeclaredField("completion").apply { isAccessible = true }.get(mgr)
        return completion::class.java.getDeclaredField("drainReady").apply { isAccessible = true }.getBoolean(completion)
    }

    private fun storage(): Any =
        Class.forName("ai.appdna.sdk.storage.LocalStorage").getConstructor(Context::class.java).newInstance(app)

    /** Write the core's persisted delivery queue exactly as `PurchaseLedger` stores it. */
    private fun seedQueue(tokens: List<String>) {
        val arr = JSONArray()
        for (t in tokens) {
            arr.put(JSONObject().apply {
                put("purchaseToken", t)
                put("transactionId", "GPA.$t")
                put("productId", "coins_100")
                put("purchaseTime", 1_700_000_000_000L)
                put("quantity", 1)
                put("ownerToken", JSONObject.NULL)
                put("queuedAt", System.currentTimeMillis())
            })
        }
        val s = storage()
        s::class.java.getMethod("setString", String::class.java, String::class.java).invoke(s, QUEUE_KEY, arr.toString())
    }

    private fun queuedTokens(): List<String> {
        val s = storage()
        val raw = s::class.java.getMethod("getString", String::class.java).invoke(s, QUEUE_KEY) as String? ?: return emptyList()
        val arr = JSONArray(raw)
        return (0 until arr.length()).map { arr.getJSONObject(it).getString("purchaseToken") }
    }

    private fun deliveringDelegate(): AppDNABillingDelegate? {
        val billing = AppDNA.billing
        val m = billing::class.java.declaredMethods.first { it.name.startsWith("deliveringDelegate") }
        return m.apply { isAccessible = true }.invoke(billing) as AppDNABillingDelegate?
    }

    private fun delivered() = events.filter { it["type"] == "onPurchaseCompleted" }

    private fun waitUntil(ms: Long, cond: () -> Boolean) {
        val deadline = System.currentTimeMillis() + ms
        while (!cond() && System.currentTimeMillis() < deadline) {
            idle()
            Thread.sleep(20)
        }
    }

    // ── Tests ────────────────────────────────────────────────────────────────────────────────────

    @Test
    fun `a queued purchase reaches Dart once when Dart listens, and the queue empties`() {
        seedQueue(listOf("tok-1"))
        plugin.billingStreamHandler.onListen(null, sink)
        waitUntil(5_000) { delivered().isNotEmpty() && queuedTokens().isEmpty() }
        assertEquals(1, delivered().size)
        assertEquals("coins_100", (delivered().single()["args"] as Map<*, *>)["productId"])
        assertEquals(emptyList<String>(), queuedTokens())

        // Cancel, listen again: nothing is delivered a second time.
        plugin.billingStreamHandler.onCancel(null)
        plugin.billingStreamHandler.onListen(null, sink)
        waitUntil(1_000) { false }
        assertEquals("delivered exactly once", 1, delivered().size)
    }

    @Test
    fun `a listener cancelled before the drain leaves the entry queued`() {
        seedQueue(listOf("tok-2"))
        // Listen (the registration launches the drain) and cancel before Main runs the delivery.
        plugin.billingStreamHandler.onListen(null, sink)
        plugin.billingStreamHandler.onCancel(null)
        waitUntil(2_000) { false }
        assertEquals("no Dart listener received it", 0, delivered().size)
        assertEquals("…so it stays queued for the next listener", listOf("tok-2"), queuedTokens())

        // The next listener gets it.
        plugin.billingStreamHandler.onListen(null, sink)
        waitUntil(5_000) { delivered().isNotEmpty() && queuedTokens().isEmpty() }
        assertEquals(1, delivered().size)
        assertEquals(emptyList<String>(), queuedTokens())
    }

    @Test
    fun `listening makes the forwarder a delivering delegate and cancelling takes it back`() {
        plugin.billingStreamHandler.onListen(null, sink)
        assertTrue("the Dart listener must drain the queue", deliveringDelegate() != null)
        plugin.billingStreamHandler.onCancel(null)
        assertNull("after cancel nothing may be counted as delivered to Dart", deliveringDelegate())
    }

    @Test
    fun `a forwarder whose Dart stream was cancelled throws, so the drain keeps the entry`() {
        plugin.billingStreamHandler.onListen(null, sink)
        idle()
        val held = deliveringDelegate()!!
        plugin.billingStreamHandler.onCancel(null)
        events.clear()
        assertThrows(IllegalStateException::class.java) {
            held.onPurchaseCompleted("coins_100", TransactionInfo("GPA.2", "coins_100", "1700000000000", "production"))
        }
        idle()
        assertEquals("no event may reach a cancelled Dart stream", 0, events.size)
    }

    @Test
    fun `on Main a delivery reaches the sink before the call returns`() {
        plugin.billingStreamHandler.onListen(null, sink)
        idle()
        events.clear()
        val forwarder = deliveringDelegate()!!
        forwarder.onPurchaseCompleted("coins_100", TransactionInfo("GPA.1", "coins_100", "1700000000000", "production"))
        // No looper idle: the event must already be on the sink.
        assertEquals("onPurchaseCompleted", events.single()["type"])
        idle()
        assertEquals("delivered once, not again from a hop", 1, events.size)
    }

    private companion object {
        const val QUEUE_KEY = "appdna.pending_deliveries_v1"
    }
}
