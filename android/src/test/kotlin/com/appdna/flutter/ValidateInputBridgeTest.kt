package com.appdna.flutter

import ai.appdna.sdk.onboarding.InputValidationResult
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * Live validation — the Flutter Android bridge half of `onValidateInput`, through the REAL forwarder and the REAL
 * `invokeDart` (only the MethodChannel hop is scripted):
 *
 *  1. every reply in the shared parse fixture, in the shape the Flutter codec hands the plugin, decodes to the
 *     fixture's expected result through core's `InputValidationResult.decodeBridgeReply`;
 *  2. outside a check the bridge waits `bridgeTimeoutMs()` (the field's 5 s default plus a second), not the 5 s
 *     sync-callback timeout.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class ValidateInputBridgeTest {

    private suspend fun kotlinx.coroutines.test.TestScope.validate(reply: Any?, afterMs: Long = 0) =
        AppdnaPlugin { _, _, answer ->
            backgroundScope.launch {
                delay(afterMs)
                answer(reply)
            }
        }.OnboardingDelegateForwarder().onValidateInput("f", "s", "username", "abc")

    @Test
    fun `every fixture reply decodes as the fixture says`() = runTest {
        val fixture = JSONObject(File(fixturesRoot(), "delegate_contracts/validate_input_result_parse.fixture.json").readText())
        val cases = fixture.getJSONObject("action").getJSONArray("cases")
        val expected = fixture.getJSONObject("expect").getJSONObject("state_after").getJSONArray("results")
        for (i in 0 until cases.length()) {
            val name = cases.getJSONObject(i).getString("name")
            val got = validate(codec(cases.getJSONObject(i).opt("reply")))
            val want = expected.opt(i)
            if (want == null || want == JSONObject.NULL) {
                assertNull("[$name] expected no answer, got $got", got)
            } else {
                val w = want as JSONObject
                val message = if (w.isNull("message")) null else w.getString("message")
                when (w.getString("status")) {
                    "valid" -> assertEquals(name, InputValidationResult.Valid(message), got)
                    "invalid" -> assertEquals(name, InputValidationResult.Invalid(message), got)
                    "not_implemented" -> assertEquals(name, "NotImplemented", got?.javaClass?.simpleName)
                }
            }
        }
    }

    @Test
    fun `the bridge waits the field timeout, not the sync-callback timeout`() = runTest {
        assertEquals(InputValidationResult.Valid(), validate(mapOf("status" to "valid"), afterMs = 5_500))
        val start = testScheduler.currentTime
        assertNull(validate(mapOf("status" to "valid"), afterMs = 7_000))
        assertEquals(6_000L, testScheduler.currentTime - start)
    }

    /** What the StandardMessageCodec hands the plugin: HashMap / ArrayList / Integer / String / null. */
    private fun codec(v: Any?): Any? = when (v) {
        null, JSONObject.NULL -> null
        is JSONObject -> HashMap<String, Any?>().also { m -> v.keys().forEach { m[it] = codec(v.get(it)) } }
        is JSONArray -> ArrayList<Any?>().also { l -> for (i in 0 until v.length()) l.add(codec(v.get(i))) }
        else -> v
    }

    private fun fixturesRoot(): File {
        System.getenv("APPDNA_SDK_FIXTURES_DIR")?.let { if (File(it).isDirectory) return File(it) }
        var here: File? = File(".").canonicalFile
        repeat(12) {
            val candidate = File(here, "packages/sdk-shared-fixtures")
            if (candidate.isDirectory) return candidate
            here = here?.parentFile
        }
        val synced = File("../../test/fixtures/sdk-shared-fixtures")
        if (synced.isDirectory) return synced
        error("Could not locate packages/sdk-shared-fixtures. Set APPDNA_SDK_FIXTURES_DIR.")
    }
}
