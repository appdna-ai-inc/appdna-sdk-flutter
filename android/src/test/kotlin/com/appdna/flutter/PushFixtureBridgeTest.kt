package com.appdna.flutter

import ai.appdna.sdk.AppDNA
import android.app.NotificationManager
import android.content.Context
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch

/**
 * SPEC-497 §8.7 — the Flutter leg of the push fixtures: every fixture whose `platforms` claims `flutter`
 * and whose category is `push_payload` is driven through the plugin's REAL `push.*` method-channel
 * handlers (`push.isAppDNAMessage` / `push.handleMessageData` / `push.handleTap`) into the live native
 * SDK, and its `expect` block is asserted against native OUTPUTS:
 *
 *   - **events** — the envelopes the SDK's own `EventQueue` persisted (configured with `batchSize = 0`
 *     through the plugin's own "configure", so nothing uploads); every one must carry
 *     `device.framework == "flutter"` (the tag the bridge injects);
 *   - **delegate_calls** — what the plugin pushed to Dart on `events/push` and `events/deep_link`
 *     (listened to exactly as a Dart listener would), projected per the §8.7 rule: `notification` is
 *     unwrapped, `push_id` → `pushId`, `onHostCallback` dropped; compared ORDER-INSENSITIVELY (the
 *     `push_payload` comparison rule, §14);
 *   - **state_after** — `returned` / `is_appdna` (the channel result), `routed` (the core push-tap
 *     router's `routeSink` test seam, reached by reflection because it is `internal` to another
 *     module), `notification_posted` (Robolectric's notification manager). A `state_after` key no
 *     observer produced FAILS — a vacuous assertion is impossible.
 *
 * The Dart runner (`test/shared_fixtures_test.dart`) proves the CHANNEL CONTRACT for the same fixtures;
 * this file proves the BEHAVIOUR. Before each fixture `PushIdempotency.resetForTesting()` runs (by
 * reflection, `@JvmName`), so two fixtures sharing a `push_id` do not dedup each other.
 *
 * Plus the §9.8 nested-value case: a map with a number, a nested `action: {type, value}` and a list
 * crosses the Android channel as strings / VALID JSON that the SDK's parser reads — the deep link routes.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class PushFixtureBridgeTest {

    /** The Dart host: answers the deep-link `shouldOpen` veto with "open". */
    private val plugin = AppdnaPlugin { method, _, reply -> reply(if (method == "shouldOpen") true else null) }

    private val emitted = ConcurrentLinkedQueue<Map<*, *>>()
    private val state = LinkedHashMap<String, Any?>()
    private var routed: Pair<String, String>? = null
    private lateinit var fixtureName: String

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
        assertTrue("the SDK never reached READY in 20 s — every fixture would assert nothing", ready.count == 0L)
        plugin.pushStreamHandler.onListen(null, recordingSink)
        plugin.deepLinkStreamHandler.onListen(null, recordingSink)
        setRouteSink { type, value -> routed = type to value }
    }

    @After
    fun tearDown() {
        setRouteSink(null)
        runCatching { plugin.pushStreamHandler.onCancel(null) }
        runCatching { plugin.deepLinkStreamHandler.onCancel(null) }
        runCatching { AppDNA.shutdown() }
        idle()
    }

    // ── The run ──────────────────────────────────────────────────────────────────

    @Test
    fun everyFlutterPushFixtureIsDrivenThroughTheChannelIntoLiveNative() {
        val fixtures = flutterPushFixtures()
        assertTrue("no push_payload fixture claims `flutter` — this runner would be green over nothing", fixtures.isNotEmpty())
        val failures = LinkedHashMap<String, String>()
        for ((name, json) in fixtures) {
            fixtureName = name
            try {
                runOne(json)
                println("  ✓ $name — driven through the push.* channel into live native")
            } catch (t: Throwable) {
                failures[name] = t.message ?: t::class.java.name
            }
        }
        assertTrue(
            "${failures.size} of ${fixtures.size} flutter push fixture(s) FAILED:\n" +
                failures.entries.joinToString("\n\n") { "  [${it.key}]\n    ${it.value}" },
            failures.isEmpty(),
        )
    }

    private fun runOne(fixture: JSONObject) {
        resetPushIdempotency()
        idle()
        clearPersistedEvents()
        emitted.clear()
        state.clear()
        routed = null
        val postedBefore = postedCount()

        val action = fixture.getJSONObject("action")
        val payload = codec(action.getJSONObject("payload"))
        when (val kind = action.getString("kind")) {
            "classify_push" -> state["is_appdna"] = call("push.isAppDNAMessage", mapOf("data" to payload))
            "tap_push" -> state["returned"] = call("push.handleTap", buildMap {
                put("data", payload)
                action.optString("action_id").takeIf { it.isNotEmpty() }?.let { put("actionId", it) }
            })
            "receive_push" -> {
                if (action.optString("via") != "handleMessageData") {
                    throw AssertionError("[$fixtureName] receive_push without via=handleMessageData has no host entry point")
                }
                state["returned"] = call("push.handleMessageData", mapOf("data" to payload))
            }
            else -> throw AssertionError("[$fixtureName] NO FLUTTER PUSH DRIVER for action.kind=$kind")
        }
        settle(fixture.getJSONObject("expect"))
        state["routed"] = routed?.let { mapOf("type" to it.first, "value" to it.second) }
        state["notification_posted"] = postedCount() > postedBefore
        assertExpectations(fixture.getJSONObject("expect"))
    }

    /** Idle until the expected events and delegate calls have arrived (routing hops through coroutines). */
    private fun settle(expect: JSONObject) {
        val wantEvents = expect.optJSONArray("events")?.length() ?: 0
        val wantCalls = expect.optJSONArray("delegate_calls")?.length() ?: 0
        val deadline = System.currentTimeMillis() + 5_000
        do {
            idle()
            if (pushPathEnvelopes().size >= wantEvents && projectedCalls().size >= wantCalls) {
                // One more turn: a surplus would otherwise be missed.
                Thread.sleep(50); idle()
                return
            }
            Thread.sleep(20)
        } while (System.currentTimeMillis() < deadline)
    }

    // ── Assertions ───────────────────────────────────────────────────────────────

    /**
     * The events the PUSH path emitted. A tap routed to `show_screen` hands the id to the live SDK's
     * ScreenManager, which — with no such screen in this runner's config — emits its own
     * `screen_dismissed`. That event belongs to the routed destination, not to the push path the
     * fixture pins (the core runners never present anything, so they never see it); the route itself
     * is asserted through `state_after.routed`. So `screen_*` lifecycle events are left out here.
     */
    private fun pushPathEnvelopes(): List<JSONObject> =
        persistedEnvelopes().filterNot { it.optString("event_name").startsWith("screen_") }

    private fun assertExpectations(expect: JSONObject) {
        val envelopes = pushPathEnvelopes()
        for (e in envelopes) {
            assertEquals("[$fixtureName] event '${e.optString("event_name")}' must carry framework=flutter",
                "flutter", e.optJSONObject("device")?.optString("framework"))
        }
        val expectedEvents = expect.optJSONArray("events") ?: JSONArray()
        assertEquals("[$fixtureName] event count (native emitted ${envelopes.map { it.optString("event_name") }})",
            expectedEvents.length(), envelopes.size)
        for (i in 0 until expectedEvents.length()) {
            val expected = expectedEvents.getJSONObject(i)
            val envelope = envelopes[i]
            assertEquals("[$fixtureName] event[$i].name", expected.getString("name"), envelope.optString("event_name"))
            val props = expected.optJSONObject("properties") ?: continue
            val actual = envelope.optJSONObject("properties") ?: JSONObject()
            for (key in props.keys()) {
                assertEquals("[$fixtureName] event[$i].properties.$key", canon(props.opt(key)), canon(actual.opt(key)))
            }
        }

        // Delegate calls: projected, compared order-insensitively (push_payload rule, §14).
        val expectedCalls = expect.optJSONArray("delegate_calls") ?: JSONArray()
        val actual = projectedCalls().toMutableList()
        assertEquals("[$fixtureName] delegate-call count (the plugin sent ${actual.map { it.first }} to Dart)",
            expectedCalls.length(), actual.size)
        for (i in 0 until expectedCalls.length()) {
            val exp = expectedCalls.getJSONObject(i)
            val args = exp.optJSONObject("args") ?: JSONObject()
            val match = actual.indexOfFirst { (name, a) ->
                name == exp.getString("name") && args.keys().asSequence().all { k -> canon(args.opt(k)) == canon(a[k]) }
            }
            assertTrue("[$fixtureName] no delegate call matches expected ${exp} among $actual", match >= 0)
            actual.removeAt(match)
        }

        expect.optJSONObject("state_after")?.let { st ->
            for (key in st.keys()) {
                assertTrue("[$fixtureName] state_after.$key — no observer produced it", state.containsKey(key))
                assertEquals("[$fixtureName] state_after.$key", canon(st.opt(key)), canon(state[key]))
            }
        }
    }

    /**
     * The §8.7 projection: `(type, args)` with `notification` unwrapped into the args, `push_id` →
     * `pushId`, and `onHostCallback` dropped.
     */
    private fun projectedCalls(): List<Pair<String, Map<String, Any?>>> = emitted.toList().mapNotNull { ev ->
        val type = ev["type"] as? String ?: return@mapNotNull null
        if (type == "onHostCallback") return@mapNotNull null
        val args = (ev["args"] as? Map<*, *>).orEmpty()
        val out = LinkedHashMap<String, Any?>()
        args.forEach { (k, v) -> if (k != "notification") out[k.toString()] = v }
        (args["notification"] as? Map<*, *>)?.forEach { (k, v) -> out[k.toString()] = v }
        if (out.containsKey("push_id") && !out.containsKey("pushId")) out["pushId"] = out.remove("push_id")
        type to out
    }

    private fun canon(v: Any?): String = when (v) {
        null, JSONObject.NULL -> "null"
        is Boolean -> v.toString()
        is Number -> if (v.toDouble() == Math.floor(v.toDouble()) && !v.toDouble().isInfinite()) v.toLong().toString() else v.toDouble().toString()
        is String -> v
        is JSONObject -> canon(v.keys().asSequence().associateWith { v.opt(it) })
        is JSONArray -> (0 until v.length()).joinToString(",", "[", "]") { canon(v.opt(it)) }
        is Map<*, *> -> v.entries.sortedBy { it.key.toString() }.joinToString(",", "{", "}") { (k, x) -> "$k=${canon(x)}" }
        is List<*> -> v.joinToString(",", "[", "]") { canon(it) }
        else -> v.toString()
    }

    // ── §9.8 nested values ───────────────────────────────────────────────────────

    @Test
    fun `a number, a nested action map and a list cross as strings and valid JSON, and the deep link routes`() {
        resetPushIdempotency()
        val raw = hashMapOf<String, Any?>(
            "appdna" to "1",
            "push_id" to "p_nested",
            "badge" to 5,
            "ratio" to 5.0,
            "action" to hashMapOf("type" to "deep_link", "value" to "x://y"),
            "tags" to arrayListOf("a", "b"),
        )
        val converted = PushDataMapper.toStringMap(raw)
        assertEquals("5", converted["badge"])
        assertEquals("an integral double crosses without .0 (as on React Native)", "5", converted["ratio"])
        assertEquals("deep_link", JSONObject(converted["action"]!!).getString("type"))
        assertEquals("x://y", JSONObject(converted["action"]!!).getString("value"))
        assertEquals(2, JSONArray(converted["tags"]!!).length())
        assertTrue("never Kotlin toString() output", converted.values.none { it.startsWith("{type=") })

        assertEquals(true, call("push.handleTap", mapOf("data" to raw)))
        val deadline = System.currentTimeMillis() + 3_000
        while (routed == null && System.currentTimeMillis() < deadline) { idle(); Thread.sleep(10) }
        assertEquals("deep_link" to "x://y", routed)
    }

    // ── Plumbing ─────────────────────────────────────────────────────────────────

    /** A main-channel call, as Dart makes it; returns the success value, fails on error. */
    private fun call(method: String, args: Map<String, Any?>): Any? {
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

    /** What Flutter's StandardMessageCodec hands the plugin for a Dart map. */
    private fun codec(v: Any?): Any? = when (v) {
        null, JSONObject.NULL -> null
        is JSONObject -> HashMap<Any?, Any?>().also { m -> v.keys().forEach { k -> m[k] = codec(v.opt(k)) } }
        is JSONArray -> ArrayList<Any?>().also { l -> for (i in 0 until v.length()) l += codec(v.opt(i)) }
        else -> v
    }

    private fun postedCount(): Int {
        val nm = RuntimeEnvironment.getApplication().getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return shadowOf(nm).allNotifications.size
    }

    /** `PushIdempotency.resetForTesting()` — `internal` to the SDK module, `@JvmName` for exactly this call. */
    private fun resetPushIdempotency() {
        val cls = Class.forName("ai.appdna.sdk.integrations.PushIdempotency")
        val instance = cls.getDeclaredField("INSTANCE").get(null)
        cls.getDeclaredMethod("resetForTesting").apply { isAccessible = true }.invoke(instance)
    }

    /** `PushTapRouter.routeSink` — an `internal @JvmField`, so a static field of that name. */
    private fun setRouteSink(sink: ((String, String) -> Unit)?) {
        val cls = Class.forName("ai.appdna.sdk.integrations.PushTapRouter")
        cls.getDeclaredField("routeSink").apply { isAccessible = true }.set(null, sink)
    }

    /** The SDK's OWN EventDatabase (the one its queue writes to) — asked for, never guessed at. */
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

    private fun flutterPushFixtures(): List<Pair<String, JSONObject>> =
        fixturesRoot().walkTopDown()
            .filter { it.isFile && it.name.endsWith(".fixture.json") }
            .sortedBy { it.path }
            .mapNotNull { file ->
                val json = JSONObject(file.readText(Charsets.UTF_8))
                val platforms = json.optJSONArray("platforms") ?: JSONArray()
                val claims = (0 until platforms.length()).any { platforms.getString(it) == "flutter" }
                if (claims && json.optString("category") == "push_payload") file.name.removeSuffix(".fixture.json") to json else null
            }
            .toList()

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
