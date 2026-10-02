package com.appdna.flutter

import ai.appdna.sdk.AppDNA
import android.content.Intent
import android.os.Bundle
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch

/**
 * A tap on a notification the SDK displayed reaches a running Flutter app through
 * `Activity.onNewIntent`, and FlutterActivity does not `setIntent`. The plugin read only
 * `activity.intent` (the launch intent) and registered no new-intent listener, so button, body and
 * reply taps were never tracked or routed and Dart `onPushTapped` never fired — also when Android
 * restored the task after the process was killed (the tap then arrives in `onNewIntent` too, before
 * Dart has called `configure`).
 *
 * These drive the plugin's REAL new-intent listener and its REAL "handlePushTap" channel handler into
 * the live native SDK, and assert native OUTPUTS: the `push_tapped` envelope the SDK persisted, the
 * `onPushTapped` the plugin pushed to Dart, and the route the core push-tap router took.
 *
 * NEGATIVE CONTROL: with `pushTapIntentListener` reduced to `{ false }` (no routing) the first three
 * tests fail; with "handlePushTap" back to `AppDNA.handlePushTap(activity?.intent)` the fourth fails.
 * Each test below names its own negative control.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class PushTapIntentBridgeTest {

    private val plugin = AppdnaPlugin { method, _, reply -> reply(if (method == "shouldOpen") true else null) }
    private val emitted = ConcurrentLinkedQueue<Map<*, *>>()
    private val routes = mutableListOf<Pair<String, String>>()

    private val recordingSink = object : EventChannel.EventSink {
        override fun success(event: Any?) {
            emitted += event as Map<*, *>
        }
        override fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) =
            throw AssertionError("the plugin sent an error to Dart: $errorCode")
        override fun endOfStream() {}
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Before
    fun setUp() {
        runCatching { AppDNA.shutdown() }
        idle()
        plugin.context = RuntimeEnvironment.getApplication()
        resetPushIdempotency()
        // The Dart push delegate is listened to BEFORE configure — the order a Flutter app uses.
        plugin.pushStreamHandler.onListen(null, recordingSink)
        setRouteSink { type, value -> routes += type to value }
    }

    @After
    fun tearDown() {
        setRouteSink(null)
        runCatching { plugin.pushStreamHandler.onCancel(null) }
        runCatching { AppDNA.shutdown() }
        idle()
    }

    @Test
    fun `a body tap that arrives through onNewIntent is tracked, routed and reaches Dart`() {
        configureAndWait()
        val intent = tapIntent("p-body", "d-body").apply {
            putExtra("action_type", "deep_link")
            putExtra("action_value", "https://example.com/body")
        }

        assertFalse("the listener must not consume the intent", plugin.pushTapIntentListener.onNewIntent(intent))
        settle()

        assertEquals(listOf("d-body"), tappedDeliveryIds())
        assertEquals(listOf(null), tappedActionIds())
        assertEquals(listOf("deep_link" to "https://example.com/body"), routes)
        assertEquals("the activity's intent keeps the marker (native handles a copy)", "1", intent.getStringExtra("appdna"))
    }

    @Test
    fun `a reply button tap carries the typed text and its button id to Dart`() {
        configureAndWait()
        val intent = tapIntent("p-reply", "d-reply").apply {
            putExtra("action_id", "btn_reply")
            putExtra("action_type", "text_reply")
            putExtra("appdna_notification_id", "42")
        }
        android.app.RemoteInput.addResultsToIntent(
            arrayOf(android.app.RemoteInput.Builder("appdna_reply_text").build()),
            intent,
            Bundle().apply { putCharSequence("appdna_reply_text", "hello e2e") },
        )

        plugin.pushTapIntentListener.onNewIntent(intent)
        settle()

        assertEquals(listOf("d-reply"), tappedDeliveryIds())
        assertEquals(listOf("btn_reply"), tappedActionIds())
        val data = (tappedNotifications().single()["data"] as Map<*, *>)
        assertEquals("hello e2e", data["reply_text"])
    }

    @Test
    fun `a tap that restores a killed process waits for configure, then is handled once`() {
        // No configure yet: Android delivered the tap to the re-created activity before Dart ran.
        val intent = tapIntent("p-cold", "d-cold").apply { putExtra("action_id", "btn_open") }
        plugin.pushTapIntentListener.onNewIntent(intent)
        idle()
        assertTrue("nothing can be handled before configure", tappedNotifications().isEmpty())

        // The queued tap runs as the SDK becomes ready — before anything here could clear the event store, so
        // the store is not cleared and only this tap's envelopes are counted.
        configureAndWait(clearEvents = false)
        settle()
        val coldTaps = { persistedTaps().filter { it.getJSONObject("properties").optString("delivery_id") == "d-cold" } }
        assertEquals(1, coldTaps().size)
        assertEquals(listOf("btn_open"), tappedActionIds())

        // Dart's own call for the same tap afterwards does not track it again: it is still an AppDNA tap
        // (the plugin handed native a copy), answered `true` as one handled earlier.
        assertEquals(true, call("handlePushTap"))
        settle()
        assertEquals(1, coldTaps().size)
        assertEquals(1, tappedNotifications().size)
    }

    @Test
    fun `Dart handlePushTap reads the newest intent, not only the launch intent`() {
        configureAndWait()
        plugin.activity = org.robolectric.Robolectric.buildActivity(android.app.Activity::class.java, Intent()).setup().get()
        // The intent arrived through onNewIntent; the activity's own intent is still the bare launch one.
        val latest = tapIntent("p-latest", "d-latest")
        plugin.latestNewIntent = latest

        assertEquals(true, call("handlePushTap"))
        settle()
        assertEquals(listOf("d-latest"), tappedDeliveryIds())
        // Dart's call hands native a COPY, as the listener and React Native do — it used to
        // pass the activity's intent itself, and native removed its extras.
        assertEquals("the intent keeps the marker", "1", latest.getStringExtra("appdna"))
        assertEquals("p-latest", latest.getStringExtra("push_id"))
        assertEquals("d-latest", latest.getStringExtra("delivery_id"))
    }

    /**
     * Native handles a copy, so the launch intent stays a live tap; only the persisted
     * claim (the last 32 tap keys) kept a re-`configure` from routing it again — after 33 later taps it
     * fired again. NEGATIVE CONTROL: without the [PushTapIntentLedger] check in `routePushTap` the launch
     * tap is routed twice.
     */
    @Test
    fun `a re-configure after more than 32 taps does not re-fire the launch tap`() {
        val launch = tapIntent("p-launch33", "d-launch33").apply {
            putExtra("action_type", "deep_link")
            putExtra("action_value", "https://example.com/launch33")
        }
        plugin.activity = org.robolectric.Robolectric.buildActivity(android.app.Activity::class.java, launch).setup().get()
        configureAndWait(clearEvents = false)
        settle()
        val launchRoutes = { routes.count { it.second == "https://example.com/launch33" } }
        assertEquals(1, launchRoutes())

        repeat(33) { i -> plugin.pushTapIntentListener.onNewIntent(tapIntent("p-later-$i", "d-later-$i")) }
        settle()

        call("shutdown")
        idle()
        configureAndWait(clearEvents = false)
        settle()
        assertEquals("the launch tap is routed once", 1, launchRoutes())
        assertEquals(
            "onPushTapped once for the launch tap",
            1,
            tappedNotifications().count { (it["data"] as? Map<*, *>)?.get("delivery_id") == "d-launch33" },
        )
        assertEquals("the launch intent keeps the marker", "1", launch.getStringExtra("appdna"))
    }

    /**
     * A tap on a notification the previous SDK version posted (no marker, no key) cannot be
     * deduplicated by native. The plugin hands native a copy, so the launch intent kept its legacy extras:
     * Dart's `handlePushTap()` routed it again (and stripped the activity's intent), and so did every
     * re-`configure`. NEGATIVE CONTROL: with "handlePushTap" back to `AppDNA.handlePushTap(launch)` the
     * Dart call routes it a second time; without the ledger check in `routePushTap` the re-configure does.
     */
    @Test
    fun `a legacy unkeyed launch tap is routed once - configure, Dart handlePushTap, re-configure`() {
        val launch = legacyTapIntent("https://example.com/legacy-launch")
        plugin.activity = org.robolectric.Robolectric.buildActivity(android.app.Activity::class.java, launch).setup().get()
        configureAndWait(clearEvents = false)
        settle()
        val legacyRoutes = { routes.count { it.second == "https://example.com/legacy-launch" } }
        assertEquals("handled at configure", 1, legacyRoutes())

        assertEquals("Dart sees a tap already handled", true, call("handlePushTap"))
        settle()
        assertEquals("Dart's call does not route it again", 1, legacyRoutes())

        call("shutdown")
        idle()
        configureAndWait(clearEvents = false)
        settle()
        assertEquals("a re-configure does not route it again", 1, legacyRoutes())
        assertEquals("onPushTapped once", 1, tappedNotifications().size)
    }

    /** The same for a legacy tap that reaches the running app through `onNewIntent`. */
    @Test
    fun `a legacy unkeyed new-intent tap is routed once when Dart also calls handlePushTap`() {
        configureAndWait()
        val intent = legacyTapIntent("https://example.com/legacy-new")
        plugin.pushTapIntentListener.onNewIntent(intent)
        settle()
        assertEquals(true, call("handlePushTap"))
        settle()
        assertEquals(1, routes.count { it.second == "https://example.com/legacy-new" })
        assertEquals(1, tappedNotifications().size)
    }

    /**
     * A Dart call while the plugin's own hand-over still waits for the SDK answers AT ONCE,
     * from the intent's extras — it used to wait for a ready SDK, and after `shutdown` (or a `configure`
     * that threw) that never came. The tap is routed once, by the queued hand-over, when the SDK is ready.
     * NEGATIVE CONTROL: with the QUEUED branch back to `AppDNA.onReady { … }` there is no answer here.
     */
    @Test
    fun `Dart handlePushTap for a queued legacy tap answers at once and routes it once`() {
        val intent = legacyTapIntent("https://example.com/legacy-queued")
        plugin.pushTapIntentListener.onNewIntent(intent) // before configure: queued
        assertEquals("answered before the SDK is ready", true, call("handlePushTap"))

        configureAndWait(clearEvents = false)
        settle()
        assertEquals(1, routes.count { it.second == "https://example.com/legacy-queued" })
        assertEquals(true, call("handlePushTap"))
        settle()
        assertEquals(1, routes.count { it.second == "https://example.com/legacy-queued" })
    }

    /**
     * After `shutdown` the SDK is not ready; Dart's call still answers at once — `true` for a
     * tap, `false` for any other intent — and the tap is handled once the next `configure` is ready.
     */
    @Test
    fun `after shutdown Dart handlePushTap answers at once and the tap is handled at the next configure`() {
        configureAndWait()
        call("shutdown")
        idle()
        plugin.latestNewIntent = Intent(Intent.ACTION_VIEW)
        assertEquals("not a tap", false, call("handlePushTap"))

        val tap = tapIntent("p-after", "d-after").apply {
            putExtra("action_type", "deep_link")
            putExtra("action_value", "https://example.com/after-shutdown")
        }
        plugin.latestNewIntent = tap
        assertEquals("a tap, answered without a ready SDK", true, call("handlePushTap"))
        settle()
        assertTrue("nothing handled while shut down", routes.isEmpty())

        configureAndWait(clearEvents = false)
        settle()
        assertEquals(listOf("deep_link" to "https://example.com/after-shutdown"), routes)
        assertEquals(1, persistedTaps().count { it.getJSONObject("properties").optString("delivery_id") == "d-after" })
    }

    /**
     * Dart's call BEFORE `configure` for a launch tap the plugin has not seen. It used to
     * hand the tap to the unconfigured native SDK and record it as handled: nothing was tracked, and the
     * hand-over at `configure` then skipped it — the tap was never tracked. Now it is queued like any
     * other, and tracked and routed once the SDK is ready.
     * NEGATIVE CONTROL: with the UNSEEN branch back to a direct `AppDNA.handlePushTap(Intent(intent))` the
     * tap is never tracked (0 envelopes).
     */
    @Test
    fun `Dart handlePushTap before configure - the launch tap is tracked once the SDK is ready`() {
        val launch = tapIntent("p-early", "d-early").apply {
            putExtra("action_type", "deep_link")
            putExtra("action_value", "https://example.com/early")
        }
        plugin.activity = org.robolectric.Robolectric.buildActivity(android.app.Activity::class.java, launch).setup().get()
        assertEquals(true, call("handlePushTap"))

        configureAndWait(clearEvents = false)
        settle()
        val early = { persistedTaps().count { it.getJSONObject("properties").optString("delivery_id") == "d-early" } }
        assertEquals("tracked once", 1, early())
        assertEquals(listOf("deep_link" to "https://example.com/early"), routes)
        assertEquals(1, tappedNotifications().size)
    }

    /**
     * Only the NEWEST intent answers. A launch tap followed by a newer intent that is not a
     * tap answered `true` (the launch tap was asked next). NEGATIVE CONTROL: asking every candidate in
     * turn (newest, then launch) answers `true` here.
     */
    @Test
    fun `a newer non-tap intent answers false even when the launch intent was a tap`() {
        val launch = tapIntent("p-stale", "d-stale")
        plugin.activity = org.robolectric.Robolectric.buildActivity(android.app.Activity::class.java, launch).setup().get()
        configureAndWait(clearEvents = false)
        settle()
        assertEquals("the launch tap itself", true, call("handlePushTap"))

        val newer = Intent(Intent.ACTION_VIEW).apply { putExtra("host_key", "x") }
        plugin.pushTapIntentListener.onNewIntent(newer)
        settle()
        assertEquals("the newest intent is not a tap", false, call("handlePushTap"))
    }

    /**
     * An engine that outlives its activity (cached engine; the activity finished with Back
     * while the process lived). A tap starts a NEW activity, whose launch intent carries it — no
     * `onNewIntent`, and `configure` already ran. It was handed over only if Dart called `handlePushTap`.
     * Now attaching to the activity hands it over; a config-change re-attach and Dart's call do not hand
     * it over again.
     * NEGATIVE CONTROL: without `routePushTap(binding.activity.intent)` in `bindActivity` nothing is routed.
     */
    @Test
    fun `warm start with a surviving engine - the new activity's tap is handled once`() {
        configureAndWait()
        plugin.onDetachedFromActivity()

        val tap = tapIntent("p-warm", "d-warm").apply {
            putExtra("action_type", "deep_link")
            putExtra("action_value", "https://example.com/warm")
        }
        val activity = org.robolectric.Robolectric.buildActivity(android.app.Activity::class.java, tap).setup().get()
        plugin.onAttachedToActivity(binding(activity))
        settle()
        val warm = { persistedTaps().count { it.getJSONObject("properties").optString("delivery_id") == "d-warm" } }
        assertEquals("tracked at attach", 1, warm())
        assertEquals(listOf("deep_link" to "https://example.com/warm"), routes)

        plugin.onDetachedFromActivityForConfigChanges()
        plugin.onReattachedToActivityForConfigChanges(binding(activity))
        settle()
        assertEquals(true, call("handlePushTap"))
        settle()
        assertEquals("tracked once", 1, warm())
        assertEquals("routed once", 1, routes.size)
        assertEquals("onPushTapped once", 1, tappedNotifications().size)
        assertEquals("the activity's intent keeps the marker", "1", tap.getStringExtra("appdna"))
    }

    /** A minimal `ActivityPluginBinding` for [activity]; the plugin uses `activity` and the listener calls. */
    private fun binding(activity: android.app.Activity): io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding {
        val handler = java.lang.reflect.InvocationHandler { proxy, method, args ->
            when (method.name) {
                "getActivity" -> activity
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> proxy === args?.getOrNull(0)
                "toString" -> "ActivityPluginBinding(test)"
                else -> null
            }
        }
        val type = io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding::class.java
        val proxy: Any = java.lang.reflect.Proxy.newProxyInstance(type.classLoader, arrayOf(type), handler)
        return proxy as io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
    }

    /**
     * A cold start from a tap — the launch intent is handed to native at `configure`, as on
     * React Native, so a host that never calls `AppDNAPush.handlePushTap()` still has the tap tracked and
     * routed; a later Dart call for it is answered `true` and tracks nothing.
     * NEGATIVE CONTROL: without `routePushTap(activity?.intent)` in "configure" nothing is tracked or
     * routed until Dart calls `handlePushTap`.
     */
    @Test
    fun `a cold-start tap is handled at configure, without Dart calling handlePushTap`() {
        val launch = tapIntent("p-launch", "d-launch").apply {
            putExtra("action_type", "deep_link")
            putExtra("action_value", "https://example.com/launch")
        }
        plugin.activity = org.robolectric.Robolectric.buildActivity(android.app.Activity::class.java, launch).setup().get()

        configureAndWait(clearEvents = false)
        settle()
        val launchTaps = { persistedTaps().filter { it.getJSONObject("properties").optString("delivery_id") == "d-launch" } }
        assertEquals(1, launchTaps().size)
        assertEquals(listOf("deep_link" to "https://example.com/launch"), routes)
        assertEquals(1, tappedNotifications().size)
        assertEquals("the launch intent keeps the marker", "1", launch.getStringExtra("appdna"))

        assertEquals(true, call("handlePushTap"))
        settle()
        assertEquals("tracked once", 1, launchTaps().size)
        assertEquals("routed once", 1, routes.size)
        assertEquals(1, tappedNotifications().size)
    }

    // ── Plumbing ─────────────────────────────────────────────────────────────────

    /** The exact extras of a body tap on a notification Android SDK 1.0.53 or earlier posted: no marker, no key. */
    private fun legacyTapIntent(url: String) = Intent(Intent.ACTION_MAIN).apply {
        putExtra("push_id", "")
        putExtra("action_type", "deep_link")
        putExtra("action_value", url)
        putExtra("screen_id", "")
        putExtra("deep_link", "")
    }

    private fun tapIntent(pushId: String, deliveryId: String) = Intent(Intent.ACTION_MAIN).apply {
        putExtra("appdna", "1")
        putExtra("push_id", pushId)
        putExtra("delivery_id", deliveryId)
    }

    private fun configureAndWait(clearEvents: Boolean = true) {
        val ready = CountDownLatch(1)
        call("configure", mapOf(
            "apiKey" to "adn_test_placeholder",
            "env" to "staging",
            "options" to mapOf("batchSize" to 0, "flushInterval" to 86_400, "logLevel" to "none"),
        ))
        AppDNA.onReady { ready.countDown() }
        val deadline = System.currentTimeMillis() + 20_000
        while (ready.count > 0L && System.currentTimeMillis() < deadline) {
            idle()
            Thread.sleep(20)
        }
        assertTrue("the SDK never reached READY in 20 s", ready.count == 0L)
        if (clearEvents) clearPersistedEvents()
    }

    /** onReady posts to the main looper, the delegate posts again, the tracker writes on its own thread. */
    private fun settle() {
        repeat(5) {
            idle()
            Thread.sleep(50)
        }
        idle()
    }

    private fun tappedNotifications(): List<Map<*, *>> = emitted.filter { it["type"] == "onPushTapped" }
        .map { (it["args"] as Map<*, *>)["notification"] as Map<*, *> }

    private fun tappedActionIds(): List<Any?> = emitted.filter { it["type"] == "onPushTapped" }
        .map { (it["args"] as Map<*, *>)["actionId"] }

    private fun persistedTaps(): List<JSONObject> =
        persistedEnvelopes().filter { it.optString("event_name") == "push_tapped" }

    private fun tappedDeliveryIds(): List<String> {
        val tracked = persistedTaps().map { it.getJSONObject("properties").optString("delivery_id") }
        assertEquals("every tracked tap reached Dart once", tracked.size, tappedNotifications().size)
        return tracked
    }

    private fun call(method: String, args: Map<String, Any?> = emptyMap()): Any? {
        var out: Any? = null
        var settled = false
        plugin.onMethodCall(MethodCall(method, args), object : MethodChannel.Result {
            override fun success(result: Any?) { out = result; settled = true }
            override fun error(code: String, message: String?, details: Any?) =
                throw AssertionError("[$method] rejected: $code $message")
            override fun notImplemented() = throw AssertionError("[$method] is not implemented by the plugin")
        })
        assertTrue("[$method] did not settle synchronously", settled)
        idle()
        return out
    }

    private fun resetPushIdempotency() {
        val cls = Class.forName("ai.appdna.sdk.integrations.PushIdempotency")
        val instance = cls.getDeclaredField("INSTANCE").get(null)
        cls.getDeclaredMethod("resetForTesting").apply { isAccessible = true }.invoke(instance)
    }

    private fun setRouteSink(sink: ((String, String) -> Unit)?) {
        val cls = Class.forName("ai.appdna.sdk.integrations.PushTapRouter")
        cls.getDeclaredField("routeSink").apply { isAccessible = true }.set(null, sink)
    }

    private fun eventDatabase(): Any {
        val tracker = AppDNA::class.java.getDeclaredField("eventTracker").apply { isAccessible = true }.get(AppDNA)
            ?: throw AssertionError("the SDK is READY but has no EventTracker")
        val queue = tracker::class.java.getDeclaredField("eventQueue").apply { isAccessible = true }.get(tracker)
            ?: throw AssertionError("the SDK's EventTracker has no EventQueue")
        return queue::class.java.getDeclaredField("eventDatabase").apply { isAccessible = true }.get(queue)
            ?: throw AssertionError("the SDK's EventQueue has no EventDatabase")
    }

    @Suppress("UNCHECKED_CAST")
    private fun persistedEnvelopes(): List<JSONObject> {
        val db = eventDatabase()
        return (db::class.java.getMethod("loadAll").invoke(db) as List<String>).map { JSONObject(it) }
    }

    private fun clearPersistedEvents() {
        val db = eventDatabase()
        db::class.java.getMethod("clearAll").invoke(db)
    }
}
