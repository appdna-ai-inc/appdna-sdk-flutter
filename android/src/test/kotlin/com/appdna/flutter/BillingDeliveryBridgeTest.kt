package com.appdna.flutter

import ai.appdna.sdk.AppDNA
import ai.appdna.sdk.AppDNABillingDelegate
import ai.appdna.sdk.TransactionInfo
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * SPEC-497 D-R40-1 — the Flutter half of the late-purchase delivery queue.
 *
 *  - Dart listening on `events/billing` makes the plugin's forwarder a DELIVERING billing delegate
 *    (the drain may call it: Flutter cannot see whether the Dart delegate overrides
 *    `onPurchaseCompleted`, so any listener counts); cancelling takes it back BEFORE the sink goes.
 *  - The drain calls `onPurchaseCompleted` synchronously on Main and counts the entry delivered when it
 *    returns — so on Main the forwarder hands the event to the sink it reads THEN, not to a later
 *    coroutine that could find the stream cancelled (a null sink is never counted as a delivery).
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

    @After
    fun tearDown() {
        runCatching { plugin.billingStreamHandler.onCancel(null) }
    }

    /** `BillingModule.deliveringDelegate()` — `internal` to the SDK module, found by name prefix. */
    private fun deliveringDelegate(): AppDNABillingDelegate? {
        val billing = AppDNA.billing
        val m = billing::class.java.declaredMethods.first { it.name.startsWith("deliveringDelegate") }
        return m.apply { isAccessible = true }.invoke(billing) as AppDNABillingDelegate?
    }

    @Test
    fun `listening makes the forwarder a delivering delegate and cancelling takes it back`() {
        assertNull(deliveringDelegate())
        plugin.billingStreamHandler.onListen(null, sink)
        val forwarder = deliveringDelegate()
        assertTrue("the Dart listener must drain the queue", forwarder != null)
        plugin.billingStreamHandler.onCancel(null)
        assertNull("after cancel nothing may be counted as delivered to Dart", deliveringDelegate())
    }

    @Test
    fun `on Main a delivery reaches the sink before the call returns`() {
        plugin.billingStreamHandler.onListen(null, sink)
        val forwarder = deliveringDelegate()!!
        forwarder.onPurchaseCompleted("coins_100", TransactionInfo("GPA.1", "coins_100", "1700000000000", "production"))
        // No looper idle: the event must already be on the sink.
        val one = events.single()
        assertEquals("onPurchaseCompleted", one["type"])
        assertEquals("coins_100", (one["args"] as Map<*, *>)["productId"])
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals("delivered once, not again from a hop", 1, events.size)
    }
}
