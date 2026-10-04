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
        /** Type AND message, so a test can tell its own errors from the host process's real one. */
        val events = mutableListOf<Pair<String, String?>>()
        override fun onInitDegraded(reason: Throwable) {
            types += reason::class.java.simpleName
            events += reason::class.java.simpleName to reason.message
        }
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @After fun tearDown() {
        InitDelegateFanOut.pendingErrorForTest = null
        InitDelegateFanOut.installReplayForTest = null
        // Drops listeners a failed assertion left behind, so one failure cannot fail the next test too.
        InitDelegateFanOut.resetForTest()
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

    /**
     * The install-time replay is swallowed by SIGNATURE, not by a count.
     *
     * 🔴 Found by CI on the iOS side of this same fan-out, and the Kotlin had the identical defect.
     * `AppDNA.setInitDelegate(this)` makes the SDK replay `lastInitError`, and the fan-out hands the joining
     * forwarder that error directly, so it swallowed one `onInitDegraded` to avoid the duplicate — by COUNT.
     * Whichever arrived first was eaten, so a genuine degradation raised before the replay landed was LOST,
     * and the stale replay was delivered in its place.
     *
     * NEGATIVE CONTROL: restore `private var replaysToSwallow = 0` and the count-based swallow, and the first
     * assertion below reports `[FirebaseConfigMissing]` — the genuine degradation is gone.
     */
    @Test fun aGenuineDegradationBeforeTheInstallReplayIsNotSwallowed() {
        val a = Recorder()
        // Every error this test raises carries this marker, and only marked events are asserted on.
        //
        // 🔴 WHY A FILTER AND NOT AN EXACT LIST. Installing the delegate makes the SDK replay its real
        // `lastInitError`, and this JVM really has one (an IllegalStateException from an unconfigured SDK).
        // Overriding the arming below means that real replay no longer matches what is armed, so it is
        // delivered — it is the process's own state, not this test's subject, so it is filtered out by
        // message rather than raced against. Same reasoning as the iOS RunnerTests twin.
        val marker = "init-replay-race"
        fun marked() = a.events.filter { it.second?.contains(marker) == true }.map { it.first }
        // The pending error the native setter will replay. Delivered by hand below, because the real replay
        // cannot be scheduled from a test.
        val replay = AppDNAInitError.FirebaseConfigMissing("$marker replay")
        InitDelegateFanOut.installReplayForTest = { replay }
        InitDelegateFanOut.pendingErrorForTest = { null }   // the direct hand-off is not what this test is about
        InitDelegateFanOut.join(a)
        idle()

        // The genuine degradation arrives FIRST — the order the counter got wrong.
        InitDelegateFanOut.onInitDegraded(AppDNAInitError.BootstrapFailed("$marker genuine"))
        // ...and the install replay lands second. It is the one that must be dropped.
        InitDelegateFanOut.onInitDegraded(replay)
        assertEquals(
            "the genuine degradation was swallowed in place of the replay",
            listOf("BootstrapFailed"), marked(),
        )

        // A second copy of the same signature is a genuine repeat, not the replay: it must get through.
        InitDelegateFanOut.onInitDegraded(replay)
        assertEquals(
            "the armed signature stayed armed and ate a genuine repeat",
            listOf("BootstrapFailed", "FirebaseConfigMissing"), marked(),
        )

        InitDelegateFanOut.leave(a)
        assertEquals(0, InitDelegateFanOut.listenerCountForTest)
    }
}
