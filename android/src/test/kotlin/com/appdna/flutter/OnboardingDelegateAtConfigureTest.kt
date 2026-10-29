package com.appdna.flutter

import ai.appdna.sdk.AppDNA
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.assertEquals
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
 * Configuring the SDK from Dart binds the onboarding delegate, as the React Native wrapper's
 * configure does — not only the first presentOnboarding call. One delegate at a time: a later stream
 * subscription replaces it, and cancelling the stream still clears it.
 *
 * The delegate the core holds is read through its field, because the core exposes no getter for it.
 *
 * NEGATIVE CONTROL: without `ensureOnboardingDelegate()` in the "configure" handler, the first test
 * fails — the core holds no delegate after configure.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class OnboardingDelegateAtConfigureTest {

    private val plugin = AppdnaPlugin { _, _, reply -> reply(null) }

    private val sink = object : EventChannel.EventSink {
        override fun success(event: Any?) {}
        override fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) {}
        override fun endOfStream() {}
    }

    private val result = object : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
            throw AssertionError("configure answered an error: $errorCode $errorMessage")
        override fun notImplemented() = throw AssertionError("configure is not implemented")
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    /** The delegate the core's onboarding module holds. */
    private fun coreDelegate(): Any? {
        val field = AppDNA.onboarding.javaClass.getDeclaredField("listener")
        field.isAccessible = true
        return field.get(AppDNA.onboarding)
    }

    private fun configureFromDart() {
        plugin.onMethodCall(
            MethodCall("configure", mapOf("apiKey" to "adn_test_onboarding_delegate", "env" to "staging")),
            result,
        )
        idle()
    }

    @Before
    fun setUp() {
        runCatching { AppDNA.shutdown() }
        idle()
        AppDNA.onboarding.setDelegate(null)
        plugin.context = RuntimeEnvironment.getApplication()
    }

    @After
    fun tearDown() {
        runCatching { plugin.onboardingStreamHandler.onCancel(null) }
        AppDNA.onboarding.setDelegate(null)
        runCatching { AppDNA.shutdown() }
        idle()
    }

    @Test
    fun `configure from Dart binds the onboarding delegate`() {
        assertNull(coreDelegate())
        configureFromDart()
        val bound = coreDelegate()
        assertNotNull("configure must bind the onboarding delegate", bound)
        assertEquals("OnboardingDelegateForwarder", bound!!.javaClass.simpleName)
    }

    @Test
    fun `a stream subscribed before configure keeps its forwarder, and cancelling still clears it`() {
        plugin.onboardingStreamHandler.onListen(null, sink)
        val fromStream = coreDelegate()
        assertNotNull(fromStream)

        configureFromDart()
        assertSame("configure must reuse the stream's forwarder, not install a second one", fromStream, coreDelegate())

        plugin.onboardingStreamHandler.onCancel(null)
        assertNull("cancelling the stream must still clear the delegate", coreDelegate())
    }
}
