package ai.appdna.appdna_sdk_example

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    /**
     * Opt-in launch values for test harnesses (see `_readLaunchValues` in lib/main.dart):
     * `adb shell am start -n ai.appdna.appdna_sdk_example/.MainActivity --es appdnaApiKey <key> ...`.
     * Only the three keys below are exposed; with no extras the map is empty and nothing changes.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "appdna_example/launch")
            .setMethodCallHandler { call, result ->
                if (call.method != "launchValues") return@setMethodCallHandler result.notImplemented()
                val values = mutableMapOf<String, String>()
                for (key in LAUNCH_KEYS) intent?.getStringExtra(key)?.let { values[key] = it }
                result.success(values)
            }
    }

    private companion object {
        val LAUNCH_KEYS = listOf("appdnaApiKey", "appdnaOnboardingId", "appdnaHostDataDemo")
    }
}
