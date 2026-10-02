package com.appdna.flutter

import ai.appdna.sdk.AppDNA
import android.content.Intent
import android.util.Log

/**
 * The push taps the plugin has handed over and that wait for the SDK to become ready, behind ONE native
 * `AppDNA.onReady` callback for the whole process.
 *
 * The plugin used to register one `AppDNA.onReady` closure per intent it handed over. Native keeps those
 * closures until the SDK is ready — across `shutdown()` too — so before `configure` (or in an app that
 * never configures) every intent the activity received (`bindActivity` on each new activity, every
 * `onNewIntent`) added a closure holding a copy of that intent, and the list only grew. Now:
 *  - an intent that is not an AppDNA tap never waits: `routePushTap` answers it at once from its extras;
 *  - at most [MAX_PENDING] taps wait; past that the OLDEST is dropped and forgotten by
 *    [PushTapIntentLedger], so a later Dart `AppDNAPush.handlePushTap()` for it hands it over again;
 *  - one `onReady` closure drains them all; a tap that arrives after the drain started registers the
 *    next one. The closure reads this process-wide queue, never a plugin instance, so a re-attached
 *    engine or a second plugin instance does not add its own;
 *  - Dart's `shutdown()` empties the queue ([clearOnShutdown]) before the native `shutdown()`. A tap that
 *    waited for the session that ended is not delivered to the next `configure` (possibly another user,
 *    after a sign-out) — as the iOS SDK clears its own launch buffer at `shutdown()`. It used to be: the
 *    closure survives `shutdown()` and drained the old taps into the new session. A cleared intent is
 *    recorded NOT_A_TAP in [PushTapIntentLedger]: it is never handed over again, and Dart's
 *    `handlePushTap()` answers `false` for it — the SDK did not handle it, so the host routes it itself.
 *    (Left QUEUED it answered `true` from its extras, telling the host the SDK had it, and the tap was lost.)
 *  - a drain is posted to the main thread by `AppDNA.onReady` the moment the SDK is ready, so a drain posted
 *    before a `shutdown()` runs after it, on a shut-down SDK that would drop the tap. [shutdownGeneration]
 *    counts shutdowns: a drain registered before one hands nothing over and registers a fresh drain, which
 *    runs when the SDK is ready again. The clear and the native `shutdown()` run under [handoverLock]
 *    ([shutdownNative]), as does every hand-over, so no tap reaches native while it shuts down.
 */
internal object PendingPushTaps {
    internal const val MAX_PENDING = 64

    /** Native's `AppDNA.handlePushTap`. `internal var` — a test seam (a throwing native). */
    internal var handle: (Intent) -> Boolean = { AppDNA.handlePushTap(it) }

    /** (the activity's intent, the copy native gets), oldest first. */
    private val pending = ArrayDeque<Pair<Intent, Intent>>()
    private var drainRegistered = false
    /** Bumped by every [shutdownNative]; a drain registered under an older value hands nothing over. */
    private var shutdownGeneration = 0
    /** Held while native is shut down and while a tap is handed to native. */
    private val handoverLock = Any()

    /** Native's `AppDNA.onReady`. `internal var` — a test seam (hold the posted drain). */
    internal var onReady: (() -> Unit) -> Unit = { AppDNA.onReady(it) }

    fun add(original: Intent, copy: Intent) {
        var dropped: Intent? = null
        val register: Int?
        synchronized(this) {
            pending.addLast(original to copy)
            if (pending.size > MAX_PENDING) dropped = pending.removeFirst().first
            register = if (drainRegistered) null else shutdownGeneration
            drainRegistered = true
        }
        dropped?.let {
            PushTapIntentLedger.forget(it)
            Log.w("AppDNA", "More than $MAX_PENDING push taps wait for configure(); the oldest was dropped")
        }
        if (register != null) registerDrain(register)
    }

    private fun registerDrain(generation: Int) {
        onReady { drain(generation) }
    }

    private fun drain(registeredAt: Int) {
        val batch = synchronized(this) {
            if (registeredAt != shutdownGeneration) {
                // Registered before a shutdown: possibly posted while the old session was ready, running now on
                // a shut-down SDK. Hand nothing over; wait for the SDK to be ready again.
                if (pending.isEmpty()) { drainRegistered = false; return }
                null
            } else {
                drainRegistered = false
                ArrayList(pending).also { pending.clear() }
            }
        }
        if (batch == null) {
            registerDrain(synchronized(this) { shutdownGeneration })
            return
        }
        for ((original, copy) in batch) {
            synchronized(handoverLock) {
                if (registeredAt != synchronized(this) { shutdownGeneration }) {
                    // A shutdown after this batch was taken: the tap belongs to the ended session — dropped like
                    // the taps `clearOnShutdown` dropped (not handled: the host routes it).
                    PushTapIntentLedger.record(original, false)
                    return@synchronized
                }
                handOver(original, copy)
            }
        }
    }

    private fun handOver(original: Intent, copy: Intent) {
        val handled = try {
            handle(copy)
        } catch (t: Throwable) {
            // Native threw before answering. Record what the plugin answered while the tap waited (its
            // extras: `AppDNA.isPushTapIntent`), so Dart's `handlePushTap` keeps that answer — it used to
            // flip to `false` (NOT_A_TAP) here for a tap it had answered `true` a moment before.
            Log.w("AppDNA", "handlePushTap threw: ${t.message}")
            AppDNA.isPushTapIntent(original)
        }
        PushTapIntentLedger.record(original, handled)
    }

    /**
     * The wrapper's `shutdown()`: [clearOnShutdown] and [nativeShutdown], both under [handoverLock] and with
     * [shutdownGeneration] bumped — no tap is handed to native while it shuts down, and a drain registered
     * before this hands nothing to the shut-down SDK.
     */
    fun shutdownNative(nativeShutdown: () -> Unit) {
        synchronized(handoverLock) {
            synchronized(this) { shutdownGeneration += 1 }
            clearOnShutdown()
            nativeShutdown()
        }
    }

    /**
     * The wrapper's `shutdown()`: forget every waiting tap. `drainRegistered` is left as it is — the native
     * `onReady` closure that drains this queue outlives `shutdown()` and still fires at the next ready, so a
     * tap queued after this one registers nothing new and is drained by it.
     */
    fun clearOnShutdown() {
        val dropped = synchronized(this) { pending.map { it.first }.also { pending.clear() } }
        // Not handled: Dart's `handlePushTap()` answers `false`, so the host routes the tap itself.
        for (intent in dropped) PushTapIntentLedger.record(intent, false)
        if (dropped.isNotEmpty()) Log.d("AppDNA", "shutdown(): ${dropped.size} push tap(s) waiting for configure() were dropped")
    }

    internal fun pendingCountForTest(): Int = synchronized(this) { pending.size }

    internal fun resetForTest() {
        synchronized(this) {
            pending.clear()
            drainRegistered = false
            shutdownGeneration = 0
        }
        handle = { AppDNA.handlePushTap(it) }
        onReady = { AppDNA.onReady(it) }
    }
}
