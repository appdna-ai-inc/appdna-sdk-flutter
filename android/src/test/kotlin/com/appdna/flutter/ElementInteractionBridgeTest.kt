package com.appdna.flutter

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * SPEC-496 §5b C9 — the Flutter Android bridge half of "Show more":
 *
 *  1. `onElementInteraction` with `action == "refresh"` waits `max(syncCallbackTimeoutMs, core
 *     minimumBridgeTimeoutMs)` — a Dart host answering at 6 s (above the 5 s default) IS delivered,
 *     while a non-refresh interaction still times out at 5 s;
 *  2. `dataContext` is forwarded through the CORE decoder: the shared decode fixture, in the shape the
 *     Flutter codec hands the plugin (HashMap / ArrayList / Integer / Double / Boolean / null), decodes
 *     type-strictly — a null member is kept (it removes the key), 0/1 stay numbers.
 *
 * Driven through the REAL forwarder and the REAL `invokeDart` (only the MethodChannel hop is scripted).
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class ElementInteractionBridgeTest {

    private val plugin = AppdnaPlugin()

    /** A plugin whose Dart host (injected through the constructor) answers after 6 s of virtual time. */
    private suspend fun kotlinx.coroutines.test.TestScope.interact(action: String) =
        AppdnaPlugin { _, _, reply ->
            backgroundScope.launch {
                delay(6_000)
                reply(mapOf("dataContext" to mapOf("recommendations" to listOf(mapOf("id" to "e")))))
            }
        }.OnboardingDelegateForwarder().onElementInteraction("f", "step_eir", "show_more", action, "more", emptyMap())

    @Test
    fun `a refresh reply at 6 s is delivered although the bridge timeout is 5 s`() = runTest {
        val result = interact("refresh")
        assertNotNull("the bridge cut the refresh short of the SDK's 8 s deadline", result)
        val recs = result!!.dataContext!!["recommendations"] as List<*>
        assertEquals("e", (recs.single() as Map<*, *>)["id"])
    }

    @Test
    fun `a non-refresh interaction still times out at the configured 5 s`() = runTest {
        val start = testScheduler.currentTime
        assertNull(interact("otp_entered"))
        assertEquals(5_000L, testScheduler.currentTime - start)
    }

    @Test
    fun `the decode fixture round-trips through the bridge type-strictly`() {
        val fixture = JSONObject(File(fixturesRoot(), "config_overrides/element_interaction_data_context_decode.fixture.json").readText())
        val reply = fixture.getJSONObject("setup").getJSONObject("session_data").getJSONObject("host_interaction_reply")
        val expected = fixture.getJSONObject("expect").getJSONObject("state_after").get("decoded_data_context")
        val result = plugin.toElementInteractionResult(codec(reply))
        assertNotNull(result)
        assertFalse(result!!.advance)
        strict(expected, result.dataContext, "$")
        assertTrue("a null member is the removal marker", result.dataContext!!.containsKey("banner"))
    }

    /** What Flutter's StandardMessageCodec hands the plugin for a Dart map. */
    private fun codec(v: Any?): Any? = when (v) {
        null, JSONObject.NULL -> null
        is JSONObject -> HashMap<Any?, Any?>().also { m -> v.keys().forEach { k -> m[k] = codec(v.opt(k)) } }
        is JSONArray -> ArrayList<Any?>().also { l -> for (i in 0 until v.length()) l += codec(v.opt(i)) }
        else -> v
    }

    private fun strict(expected: Any?, actual: Any?, path: String) {
        fun no(msg: String): Nothing = throw AssertionError("$path: $msg (expected=$expected actual=$actual)")
        when (expected) {
            null, JSONObject.NULL -> if (actual != null) no("expected null")
            is JSONObject -> {
                val m = actual as? Map<*, *> ?: no("expected an object")
                val ek = expected.keys().asSequence().toSet()
                if (ek != m.keys.map { it.toString() }.toSet()) no("keys differ")
                ek.forEach { strict(expected.opt(it), m[it], "$path.$it") }
            }
            is JSONArray -> {
                val l = actual as? List<*> ?: no("expected an array")
                if (l.size != expected.length()) no("length differs")
                for (i in 0 until expected.length()) strict(expected.opt(i), l[i], "$path[$i]")
            }
            is Boolean -> if (actual != expected) no("expected a bool")
            is Int, is Long -> if (actual !is Int && actual !is Long || (actual as Number).toLong() != (expected as Number).toLong()) no("expected an integer")
            is Number -> if (actual !is Double && actual !is Float || (actual as Number).toDouble() != expected.toDouble()) no("expected a fractional number")
            else -> if (actual != expected) no("differs")
        }
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
