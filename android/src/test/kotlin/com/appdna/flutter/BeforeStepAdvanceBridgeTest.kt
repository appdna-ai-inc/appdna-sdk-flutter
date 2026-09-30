package com.appdna.flutter

import ai.appdna.sdk.AppDNA
import ai.appdna.sdk.onboarding.StepAdvanceResult
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File

/**
 * SPEC-497 §4.2 / §4.9 — the Flutter Android bridge half of the sign-in timeout floor, on virtual time.
 *
 *  - `onBeforeStepAdvance` for a sign-in action waits `max(configured vetoTimeout, core 120 s floor)`:
 *    a Dart reply at 60 s is delivered; at 121 s the bridge has already answered
 *    `Block(AUTH_UNAVAILABLE_MESSAGE)` at exactly 120 000 ms;
 *  - a non-auth step keeps the configured timeout (5 s default), and `configure(vetoTimeout = 10)` —
 *    which used to reach only `diagnose()` — now lets a 6 s reply through;
 *  - every timeout is counted: `diagnose()`'s `veto.timeouts_observed` moves by exactly 1;
 *  - the shared fixture's `bridge_waits` rows (the bridge half of
 *    `delegate_contracts/sign_in_bridge_timeout_floor`) hold as measured waits.
 *
 * Driven through the REAL forwarder, the REAL `invokeDart` and the REAL "configure" handler; only the
 * Dart host is scripted (injected through the constructor, as `ElementInteractionBridgeTest` does).
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class BeforeStepAdvanceBridgeTest {

    private val authBlock = "Sign-in isn't available right now. Please try again later."

    /** A plugin whose Dart host answers [reply] after [afterMs] of virtual time (never, when null). */
    private fun TestScope.plugin(afterMs: Long?, reply: Any? = mapOf("type" to "proceed")) =
        AppdnaPlugin { _, _, answer ->
            if (afterMs != null) {
                backgroundScope.launch {
                    delay(afterMs)
                    answer(reply)
                }
            }
        }

    /** The "configure" handler as Dart calls it. No context → no native configure; the timeout still applies. */
    private fun AppdnaPlugin.configureVetoTimeout(seconds: Int) {
        onMethodCall(
            MethodCall("configure", mapOf("apiKey" to "adn_test_placeholder", "options" to mapOf("vetoTimeout" to seconds))),
            object : MethodChannel.Result {
                override fun success(result: Any?) {}
                override fun error(code: String, message: String?, details: Any?) = throw AssertionError("configure: $code")
                override fun notImplemented() = throw AssertionError("configure not implemented")
            },
        )
    }

    private suspend fun AppdnaPlugin.advance(action: String?) =
        OnboardingDelegateForwarder().onBeforeStepAdvance(
            "flow", "step_a", 0, "question", emptyMap(), action?.let { mapOf("action" to it) },
        )

    private fun timeoutsObserved(): Int =
        Regex("veto\\.timeouts_observed: (\\d+)").find(AppDNA.diagnose())?.groupValues?.get(1)?.toInt()
            ?: throw AssertionError("diagnose() has no veto.timeouts_observed line")

    @Test
    fun `a sign-in reply at 60 s is delivered, not blocked at the 5 s default`() = runTest {
        val result = plugin(60_000L).advance("social_login")
        assertEquals(StepAdvanceResult.Proceed, result)
    }

    @Test
    fun `a sign-in reply at 121 s is too late - the bridge blocks at exactly 120 s and counts it`() = runTest {
        val before = timeoutsObserved()
        val start = testScheduler.currentTime
        val result = plugin(121_000L).advance("social_login")
        assertEquals(120_000L, testScheduler.currentTime - start)
        assertEquals(StepAdvanceResult.Block(authBlock), result)
        assertEquals("a bridge timeout must reach diagnose()", before + 1, timeoutsObserved())
    }

    @Test
    fun `a non-auth reply at 6 s times out at the configured 5 s and counts it`() = runTest {
        val before = timeoutsObserved()
        val start = testScheduler.currentTime
        val result = plugin(6_000L, mapOf("type" to "stay")).advance("next")
        assertEquals(5_000L, testScheduler.currentTime - start)
        assertEquals("a non-auth timeout falls back to the SDK default", StepAdvanceResult.Proceed, result)
        assertEquals(before + 1, timeoutsObserved())
    }

    @Test
    fun `after configure(vetoTimeout = 10) a non-auth reply at 6 s is delivered`() = runTest {
        val p = plugin(6_000L, mapOf("type" to "stay"))
        p.configureVetoTimeout(10)
        val before = timeoutsObserved()
        assertEquals(StepAdvanceResult.Stay(null), p.advance("next"))
        assertEquals("a delivered reply is not a timeout", before, timeoutsObserved())
    }

    @Test
    fun `a non-positive vetoTimeout is the 5 s default`() = runTest {
        val p = plugin(null)
        p.configureVetoTimeout(0)
        val start = testScheduler.currentTime
        p.advance("next")
        assertEquals(5_000L, testScheduler.currentTime - start)
    }

    @Test
    fun `diagnose reports the effective vetoTimeout and a huge value does not overflow`() {
        // Through the plugin's own "configure" with a context, so the native SDK is configured too.
        runCatching { AppDNA.shutdown() }
        shadowOf(android.os.Looper.getMainLooper()).idle()
        val p = AppdnaPlugin()
        p.context = org.robolectric.RuntimeEnvironment.getApplication()
        p.onMethodCall(
            MethodCall("configure", mapOf("apiKey" to "adn_test_placeholder", "env" to "staging",
                "options" to mapOf("vetoTimeout" to 0, "batchSize" to 0, "logLevel" to "none"))),
            object : MethodChannel.Result {
                override fun success(result: Any?) {}
                override fun error(code: String, message: String?, details: Any?) = throw AssertionError(code)
                override fun notImplemented() = throw AssertionError("configure")
            },
        )
        assertTrue(AppDNA.diagnose(), AppDNA.diagnose().contains("veto.timeout_seconds: 5"))
        runCatching { AppDNA.shutdown() }
        shadowOf(android.os.Looper.getMainLooper()).idle()

        // A value whose milliseconds would overflow a Long is coerced, not wrapped negative.
        val huge = AppdnaPlugin()
        huge.configureVetoTimeoutRaw(Long.MAX_VALUE)
        val field = AppdnaPlugin::class.java.getDeclaredField("syncCallbackTimeoutMs").apply { isAccessible = true }
        assertTrue("got ${field.getLong(huge)}", field.getLong(huge) > 0)
    }

    private fun AppdnaPlugin.configureVetoTimeoutRaw(seconds: Long) {
        onMethodCall(
            MethodCall("configure", mapOf("apiKey" to "adn_test_placeholder", "options" to mapOf("vetoTimeout" to seconds))),
            object : MethodChannel.Result {
                override fun success(result: Any?) {}
                override fun error(code: String, message: String?, details: Any?) = throw AssertionError(code)
                override fun notImplemented() = throw AssertionError("configure")
            },
        )
    }

    @Test
    fun `the shared fixture's bridge_waits hold as measured waits`() = runTest {
        val action = JSONObject(File(fixturesRoot(), "delegate_contracts/sign_in_bridge_timeout_floor.fixture.json").readText())
            .getJSONObject("action")
        assertEquals("onBeforeStepAdvance", action.getString("hook"))
        val waits = action.getJSONArray("bridge_waits")
        assertTrue("the fixture has no bridge_waits — this would assert nothing", waits.length() > 0)
        for (i in 0 until waits.length()) {
            val row = waits.getJSONObject(i)
            val p = plugin(null)
            p.configureVetoTimeout((row.getLong("configured_ms") / 1000).toInt())
            val stepAction = row.optJSONObject("step_data")?.optString("action")
            val start = testScheduler.currentTime
            p.advance(stepAction)
            assertEquals("bridge_waits[$i] ($stepAction, configured ${row.getLong("configured_ms")} ms)",
                row.getLong("expect_wait_ms"), testScheduler.currentTime - start)
        }
        // The floor function the call site takes `max` with — the `cases` rows, through the core.
        val cases = action.getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val row = cases.getJSONObject(i)
            val stepData = row.optJSONObject("step_data")?.let { o -> o.keys().asSequence().associateWith { o.get(it) } }
            val expected = if (row.isNull("expect_floor_ms")) null else row.getLong("expect_floor_ms")
            assertEquals("cases[$i]", expected, StepAdvanceResult.minimumBridgeTimeoutMs(stepData))
        }
    }

    /**
     * The bridge half of `delegate_contracts/skip_to_without_step_id_is_not_a_decision`: each reply
     * goes through the REAL forwarder (auth gate + decoder). NEGATIVE CONTROL: with the old decoder a
     * `{type: "skipTo"}` on a sign-in step returned `SkipTo("")` (which advances) instead of `Block`.
     */
    @Test
    fun `the shared fixture's skipTo replies decode as the fixture says`() = runTest {
        val cases = JSONObject(File(fixturesRoot(), "delegate_contracts/skip_to_without_step_id_is_not_a_decision.fixture.json").readText())
            .getJSONObject("action").getJSONArray("cases")
        assertTrue(cases.length() > 0)
        for (i in 0 until cases.length()) {
            val row = cases.getJSONObject(i)
            val reply = jsonToKotlin(row.opt("reply"))
            val result = plugin(0L, reply).advance(if (row.getBoolean("auth_action")) "email_login" else "next")
            val expected = row.getJSONObject("expect_result")
            val (type, stepId) = when (result) {
                is StepAdvanceResult.Proceed -> "proceed" to null
                is StepAdvanceResult.ProceedWithData -> "proceedWithData" to null
                is StepAdvanceResult.Block -> "block" to null
                is StepAdvanceResult.SkipTo -> "skipTo" to result.stepId
                is StepAdvanceResult.Stay -> "stay" to null
            }
            assertEquals("cases[$i] ${row.opt("reply")} type", expected.getString("type"), type)
            assertEquals("cases[$i] step_id", if (expected.has("step_id")) expected.getString("step_id") else null, stepId)
        }
    }

    private fun jsonToKotlin(v: Any?): Any? = when (v) {
        null, JSONObject.NULL -> null
        is JSONObject -> v.keys().asSequence().associateWith { jsonToKotlin(v.get(it)) }
        is org.json.JSONArray -> (0 until v.length()).map { jsonToKotlin(v.get(it)) }
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
        val codespace = File("/workspaces/appdna-ai/packages/sdk-shared-fixtures")
        if (codespace.isDirectory) return codespace
        error("Could not locate packages/sdk-shared-fixtures. Set APPDNA_SDK_FIXTURES_DIR.")
    }
}
