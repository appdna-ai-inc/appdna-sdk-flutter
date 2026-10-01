package com.appdna.flutter

import ai.appdna.sdk.AppDNA
import android.content.Context
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The in-app message stream keeps its delegate and async veto across `shutdown()` → `configure()`,
 * and a listen before `configure()` reaches the configured SDK.
 *
 * The stream set both on listen only, on the CURRENT native `MessageManager`; `shutdown()` →
 * `configure()` built a new one without them and a listen before `configure()` set them on nothing,
 * so `onMessageShown` / `shouldShowMessage` never reached Dart. `reattachStreams()` (run by every
 * `configure`) now re-applies both, and the core keeps them on its module too.
 *
 * Read from the live core's `MessageManager` through reflection.
 * NEGATIVE CONTROL: against a core without the module fix, and without the `attachInAppMessageDelegate()`
 * line in `reattachStreams()`, both tests fail.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class InAppMessageStreamReattachTest {

    private val plugin = AppdnaPlugin()
    private val app: Context get() = RuntimeEnvironment.getApplication()
    private val ignore = object : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(code: String, message: String?, details: Any?) = throw AssertionError(code)
        override fun notImplemented() = throw AssertionError("notImplemented")
    }
    private val sink = object : EventChannel.EventSink {
        override fun success(event: Any?) {}
        override fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) {}
        override fun endOfStream() {}
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private fun configure() {
        plugin.onMethodCall(
            MethodCall("configure", mapOf(
                "apiKey" to "adn_test_placeholder", "env" to "staging",
                "options" to mapOf("batchSize" to 0, "logLevel" to "none"),
            )),
            ignore,
        )
        idle()
    }

    private fun shutdown() {
        plugin.onMethodCall(MethodCall("shutdown", null), ignore)
        idle()
    }

    /** The configured core's MessageManager (an `internal` field of the core). */
    private fun messageManager(): Any {
        val f = AppDNA::class.java.getDeclaredField("messageManager").apply { isAccessible = true }
        val m = f.get(AppDNA)
        assertNotNull("configure builds the MessageManager", m)
        return m!!
    }
    private fun managerDelegate(): Any? = messageManager().javaClass.getMethod("getDelegate").invoke(messageManager())
    private fun managerVeto(): Any? = messageManager().javaClass.getMethod("getAsyncShouldShowMessage").invoke(messageManager())

    @Before
    fun setUp() {
        runCatching { AppDNA.shutdown() }
        idle()
        plugin.context = app
    }

    @After
    fun tearDown() {
        runCatching { plugin.inAppMessageStreamHandler.onCancel(null) }
        runCatching { AppDNA.shutdown() }
        idle()
    }

    @Test
    fun inAppStreamDelegateAndVetoSurviveShutdownThenConfigure() {
        configure()
        plugin.inAppMessageStreamHandler.onListen(null, sink)
        val forwarder = AppDNA.inAppMessages.delegate
        assertNotNull(forwarder)
        assertSame(forwarder, managerDelegate())

        shutdown()
        configure()

        assertSame("the configured MessageManager calls the stream's forwarder", forwarder, managerDelegate())
        assertNotNull("the stream's async veto is set on the configured MessageManager", managerVeto())
    }

    @Test
    fun inAppListenBeforeConfigureReachesTheConfiguredManager() {
        plugin.inAppMessageStreamHandler.onListen(null, sink)
        val forwarder = AppDNA.inAppMessages.delegate
        configure()
        assertSame(forwarder, managerDelegate())
        assertNotNull(managerVeto())
    }

    @Test
    fun cancelClearsBothOnTheConfiguredManager() {
        configure()
        plugin.inAppMessageStreamHandler.onListen(null, sink)
        plugin.inAppMessageStreamHandler.onCancel(null)
        assertNull(managerDelegate())
        assertNull(managerVeto())
        shutdown()
        configure()
        assertNull("a cancelled stream is not re-applied", managerDelegate())
        assertNull(managerVeto())
    }
}
