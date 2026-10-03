package ai.appdna.appdna_sdk_example

import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    /**
     * Opt-in launch values for test harnesses (see `_readLaunchValues` in lib/main.dart):
     * `adb shell am start -n ai.appdna.appdna_sdk_example/.MainActivity --es appdnaApiKey <key> ...`.
     * Only the keys below are exposed; with no extras the map is empty and nothing changes.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "appdna_example/launch")
            .setMethodCallHandler { call, result ->
                if (call.method != "launchValues") return@setMethodCallHandler result.notImplemented()
                val values = mutableMapOf<String, String>()
                for (key in LAUNCH_KEYS) intent?.getStringExtra(key)?.let { values[key] = it }
                // `appdnaEnv=sandbox` exactly when this build carries a base-URL
                // override (the `ai.appdna.sdk.BASE_URL_OVERRIDE` meta-data, fed from the uncommitted
                // local.properties `APPDNA_BASE_URL`). Emitted even with no intent extras.
                if (!baseUrlOverride().isNullOrBlank()) values["appdnaEnv"] = "sandbox"
                result.success(values)
            }
        // The host's own store calls are an iOS affordance in this example (the
        // Android ownership rows run on the native sample host). Report that plainly.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "appdna_example/host")
            .setMethodCallHandler { call, result ->
                result.error("UNSUPPORTED", "${call.method} is iOS-only in this example", null)
            }
    }

    private fun baseUrlOverride(): String? = try {
        packageManager.getApplicationInfo(packageName, PackageManager.GET_META_DATA)
            .metaData?.getString("ai.appdna.sdk.BASE_URL_OVERRIDE")
    } catch (e: Exception) {
        null
    }

    private companion object {
        val LAUNCH_KEYS = listOf(
            "appdnaApiKey", "appdnaOnboardingId", "appdnaHostDataDemo",
            // The sign-in timeout floor device rows.
            "appdnaSignInDelaySeconds", "appdnaVetoTimeout", "appdnaStepAdvanceDelaySeconds", "appdnaStepAdvanceReply",
            // Billing provider, host-buy product, location flow.
            "appdnaBillingProvider", "appdnaHostProductId", "appdnaLocationFlowId", "appdnaPermissionsFlowId",
        )
    }
}
