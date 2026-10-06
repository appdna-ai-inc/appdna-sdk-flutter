package com.appdna.flutter

import ai.appdna.sdk.AppDNA
import android.content.Context
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The entitlement streams survive `shutdown()` → `configure()`.
 *
 * Both streams used a `registered` latch. Native `shutdown()` nulls the billing and web-entitlement
 * managers — their listeners go with them — the latch stayed set, and after a re-configure neither
 * stream emitted again. The plugin now re-attaches (remove-then-add) on every `configure`.
 *
 * Counted on the live core through reflection: the web manager's listener list, and the billing
 * module's pre-init queue plus the entitlement cache's listeners (a listener registered before billing
 * is up waits in the queue and is attached when it comes up).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class EntitlementStreamReattachTest {

    private val plugin = AppdnaPlugin()
    private val webEvents = mutableListOf<Any?>()
    private val entitlementEvents = mutableListOf<Any?>()
    private fun sink(into: MutableList<Any?>) = object : EventChannel.EventSink {
        override fun success(event: Any?) { into += event }
        override fun error(errorCode: String?, errorMessage: String?, errorDetails: Any?) = throw AssertionError(errorCode)
        override fun endOfStream() {}
    }
    private val app: Context get() = RuntimeEnvironment.getApplication()
    private val ignore = object : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(code: String, message: String?, details: Any?) = throw AssertionError(code)
        override fun notImplemented() = throw AssertionError("notImplemented")
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

    @Suppress("UNCHECKED_CAST")
    private fun webListeners(): List<(Any?) -> Unit> {
        val f = AppDNA::class.java.getDeclaredField("webEntitlementManager").apply { isAccessible = true }
        val mgr = f.get(AppDNA) ?: return emptyList()
        val l = mgr.javaClass.getDeclaredField("changeListeners").apply { isAccessible = true }
        return (l.get(mgr) as List<(Any?) -> Unit>).toList()
    }

    private fun billingListenerCount(): Int {
        val billing = AppDNA.billing
        val pending = billing.javaClass.getDeclaredField("pendingEntitlementListeners").apply { isAccessible = true }
        val queued = (pending.get(billing) as List<*>).size
        val mgrField = billing.javaClass.getDeclaredField("manager").apply { isAccessible = true }
        val mgr = mgrField.get(billing) ?: return queued
        val cacheField = mgr.javaClass.getDeclaredField("entitlementCache").apply { isAccessible = true }
        val cache = cacheField.get(mgr)
        val l = cache.javaClass.getDeclaredField("changeListeners").apply { isAccessible = true }
        return queued + (l.get(cache) as List<*>).size
    }

    /**
     * 🔴 `AppDNA.shutdown()` DOES NOT EMPTY THE ENTITLEMENT LISTENERS, and this class counts them.
     *
     * `BillingModule.shutdown()` cancels its scope, drops the delegate and resets the ownership
     * policy — it leaves `pendingEntitlementListeners` (a JVM-static `CopyOnWriteArrayList`) exactly
     * as it found it. Anything registered while billing was down therefore outlives the test that
     * registered it, and the NEXT `configure()` attaches it alongside this test's own listener.
     * `entitlementStreamIsRegisteredAgainAfterShutdownThenConfigure` then counts 2 where it asserts
     * 1 and fails — in CI, on a machine whose test order differed, with nothing in the diff to
     * explain it. That is this file's CI failure, and it is order-dependent, so it comes and goes.
     *
     * Cleared through the same reflection `billingListenerCount()` already uses to read them. Both
     * ends, because a test that fails mid-way never reaches its own cleanup.
     *
     * The production side of this — a host that registers a listener before `configure`, then
     * shuts down and re-configures, gets it attached twice — is real, pre-existing and NOT fixed
     * here: changing `shutdown()` is SDK runtime behaviour with parity, fixture and release-checklist
     * consequences (CLAUDE.md rules 5 and 9), which do not belong in a console pricing change.
     */
    private fun clearBillingEntitlementListeners() {
        val billing = AppDNA.billing
        runCatching {
            val pending = billing.javaClass.getDeclaredField("pendingEntitlementListeners").apply { isAccessible = true }
            (pending.get(billing) as MutableList<*>).clear()
        }
        runCatching {
            val mgrField = billing.javaClass.getDeclaredField("manager").apply { isAccessible = true }
            val mgr = mgrField.get(billing) ?: return@runCatching
            val cacheField = mgr.javaClass.getDeclaredField("entitlementCache").apply { isAccessible = true }
            val cache = cacheField.get(mgr)
            val l = cache.javaClass.getDeclaredField("changeListeners").apply { isAccessible = true }
            (l.get(cache) as MutableList<*>).clear()
        }
    }

    /** The web stream keeps its listeners in the same shape, on a manager that survives `shutdown()`. */
    private fun clearWebEntitlementListeners() {
        runCatching {
            val f = AppDNA::class.java.getDeclaredField("webEntitlementManager").apply { isAccessible = true }
            val mgr = f.get(AppDNA) ?: return@runCatching
            val l = mgr.javaClass.getDeclaredField("changeListeners").apply { isAccessible = true }
            (l.get(mgr) as MutableList<*>).clear()
        }
    }

    @Before
    fun setUp() {
        // `InitDelegateFanOut` is an `object` — one mutable singleton for the whole JVM, holding
        // `installed`, its listener list and the swallow signature. `InitDelegateFanOutTest` clears
        // it after itself; this class drives `configure()` (which installs it) and did not, so
        // whatever ran before or after inherited that state. A singleton with asymmetric cleanup is
        // how an order-dependent flake is built; both ends are reset here.
        InitDelegateFanOut.resetForTest()
        runCatching { AppDNA.shutdown() }
        clearBillingEntitlementListeners()
        clearWebEntitlementListeners()
        idle()
        plugin.context = app
    }

    @After
    fun tearDown() {
        runCatching { plugin.onCancel(null) }
        runCatching { AppDNA.shutdown() }
        clearBillingEntitlementListeners()
        clearWebEntitlementListeners()
        InitDelegateFanOut.resetForTest()
        idle()
    }

    @Test
    fun webStreamStillEmitsOnceAfterShutdownThenConfigure() {
        configure()
        plugin.onListen(null, sink(webEvents))
        assertEquals(1, webListeners().size)

        plugin.onMethodCall(MethodCall("shutdown", null), ignore)
        idle()
        configure()

        val listeners = webListeners()
        assertEquals("after shutdown() → configure() the web stream must be registered again, once", 1, listeners.size)
        listeners.forEach { it(null) }
        assertEquals(1, webEvents.size)
    }

    @Test
    fun webListenBeforeConfigureIsAttachedByConfigure() {
        plugin.onListen(null, sink(webEvents))   // no manager yet: the core drops it
        configure()
        assertEquals("a listen before configure() must be attached by configure()", 1, webListeners().size)
    }

    @Test
    fun entitlementStreamIsRegisteredAgainAfterShutdownThenConfigure() {
        configure()
        plugin.entitlementEventSink = sink(entitlementEvents)
        plugin.attachBillingEntitlementListener()
        assertEquals(1, billingListenerCount())

        plugin.onMethodCall(MethodCall("shutdown", null), ignore)
        idle()
        configure()

        assertEquals(
            "after shutdown() → configure() the entitlement stream must be registered again, exactly once",
            1, billingListenerCount(),
        )
        plugin.reattachStreams()   // a second re-attach never stacks a listener
        assertEquals(1, billingListenerCount())
    }

    /**
     * `remoteConfig` / `features` change streams: they attached to the CURRENT core manager, so a
     * listen before the bootstrap — and every listen after `shutdown()` → `configure()` — never fired
     * (and `features.onChanged` is a stub in the core). They now observe `AppDNA.configUpdated`.
     */
    @Test
    fun configChangeStreamsFireAfterShutdownThenConfigure() {
        val remote = mutableListOf<Any?>()
        val flags = mutableListOf<Any?>()
        fun setSink(name: String, value: EventChannel.EventSink) {
            AppdnaPlugin::class.java.getDeclaredField(name).apply { isAccessible = true }.set(plugin, value)
        }
        setSink("remoteConfigChangeSink", sink(remote))
        setSink("featuresChangeSink", sink(flags))
        plugin.ensureConfigUpdatesCollector()   // what each stream's onListen does
        configure()
        plugin.onMethodCall(MethodCall("shutdown", null), ignore)
        idle()
        configure()

        @Suppress("UNCHECKED_CAST")
        val flow = AppDNA::class.java.getDeclaredField("_configUpdated").apply { isAccessible = true }
            .get(AppDNA) as kotlinx.coroutines.flow.MutableSharedFlow<Unit>
        flow.tryEmit(Unit)
        idle()
        assertEquals("remote-config change stream after shutdown() → configure()", 1, remote.size)
        assertEquals("feature-flag change stream after shutdown() → configure()", 1, flags.size)
    }
}
