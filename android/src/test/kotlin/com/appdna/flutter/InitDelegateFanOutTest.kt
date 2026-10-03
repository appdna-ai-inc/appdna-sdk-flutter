package com.appdna.flutter

import ai.appdna.sdk.AppDNA
import ai.appdna.sdk.AppDNAInitDelegate
import ai.appdna.sdk.AppDNAInitError
import android.os.Looper
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The native init delegate is one per process, and every Flutter engine's init stream used to install its own
 * forwarder: the last engine to listen won (the others stopped receiving `onInitDegraded`), and any engine's
 * cancel cleared the delegate for all of them. The streams now listen through one fan-out (iOS
 * `InitDelegateFanOut`, same rules).
 *
 * NEGATIVE CONTROL: with each forwarder calling `AppDNA.setInitDelegate(fwd)` / `setInitDelegate(null)` itself, `a`
 * receives nothing once `b` listens, and nothing at all after `b` cancels — the first two assertions fail.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class InitDelegateFanOutTest {

    private class Recorder : AppDNAInitDelegate {
        val types = mutableListOf<String>()
        override fun onInitDegraded(reason: Throwable) { types += reason::class.java.simpleName }
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @After fun tearDown() {
        InitDelegateFanOut.pendingErrorForTest = null
        AppDNA.setInitDelegate(null)
    }

    @Test fun everyListeningEngineReceivesOneCancelSilencesNoOneAndALateJoinerIsReplayedAlone() {
        val a = Recorder(); val b = Recorder(); val c = Recorder()
        // Nothing pending for the joiners: another test in this process can leave `AppDNA.lastInitError` set
        // (its setter is internal to the core), which the join would rightly replay.
        InitDelegateFanOut.pendingErrorForTest = { null }
        InitDelegateFanOut.join(a)
        InitDelegateFanOut.join(b)
        idle()

        // The native SDK reports to its one delegate: the fan-out.
        InitDelegateFanOut.onInitDegraded(AppDNAInitError.BootstrapFailed("offline"))
        assertEquals("the first engine missed the degradation", listOf("BootstrapFailed"), a.types)
        assertEquals(listOf("BootstrapFailed"), b.types)

        InitDelegateFanOut.leave(b)
        InitDelegateFanOut.onInitDegraded(AppDNAInitError.SubsystemFailed("x", "y"))
        assertEquals("one engine's cancel silenced the others", listOf("BootstrapFailed", "SubsystemFailed"), a.types)
        assertEquals("a cancelled engine still received", 1, b.types.size)

        // A late joiner is replayed the pending degradation — only it.
        InitDelegateFanOut.pendingErrorForTest = { AppDNAInitError.FirebaseConfigMissing("no config") }
        InitDelegateFanOut.join(c)
        idle()
        assertEquals(listOf("FirebaseConfigMissing"), c.types)
        assertEquals("the replay reached an engine already listening", 2, a.types.size)

        InitDelegateFanOut.leave(a)
        InitDelegateFanOut.leave(c)
        assertEquals(0, InitDelegateFanOut.listenerCountForTest)
        InitDelegateFanOut.onInitDegraded(AppDNAInitError.BootstrapFailed("late"))
        assertEquals("a left engine still received", 1, c.types.size)
    }
}
