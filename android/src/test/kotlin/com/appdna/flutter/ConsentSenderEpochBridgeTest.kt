package com.appdna.flutter

import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File

/**
 * The Flutter plugin's claim on `event_emission/consent_signal_sender_epoch`: `configure`, `setConsent` and `shutdown`
 * through `AppdnaPlugin.onMethodCall` into a real native Android `AppDNA`, against a stub server that records every
 * consent request. The Dart runner proves the channel forwarding; this proves what the native SDK then sends.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class ConsentSenderEpochBridgeTest {

    @Test
    fun `consent_signal_sender_epoch - a dead sender's retry never writes the device's consent state`() {
        val ctx = RuntimeEnvironment.getApplication()
        val plugin = AppdnaPlugin().apply { context = ctx }
        val json = JSONObject(File(fixturesRoot(), "event_emission/consent_signal_sender_epoch.fixture.json").readText())
        FlutterConsentFixtureRunner(ctx, plugin).runAll("consent_signal_sender_epoch", json.getJSONObject("action"))
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
