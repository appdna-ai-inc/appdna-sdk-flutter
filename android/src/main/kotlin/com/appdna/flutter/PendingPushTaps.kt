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
 */
internal object PendingPushTaps {
    internal const val MAX_PENDING = 64

    /** Native's `AppDNA.handlePushTap`. `internal var` — a test seam (a throwing native). */
    internal var handle: (Intent) -> Boolean = { AppDNA.handlePushTap(it) }

    /** (the activity's intent, the copy native gets), oldest first. */
    private val pending = ArrayDeque<Pair<Intent, Intent>>()
    private var drainRegistered = false

    fun add(original: Intent, copy: Intent) {
        var dropped: Intent? = null
        val register: Boolean
        synchronized(this) {
            pending.addLast(original to copy)
            if (pending.size > MAX_PENDING) dropped = pending.removeFirst().first
            register = !drainRegistered
            drainRegistered = true
        }
        dropped?.let {
            PushTapIntentLedger.forget(it)
            Log.w("AppDNA", "More than $MAX_PENDING push taps wait for configure(); the oldest was dropped")
        }
        if (register) AppDNA.onReady { drain() }
    }

    private fun drain() {
        val batch = synchronized(this) {
            drainRegistered = false
            ArrayList(pending).also { pending.clear() }
        }
        for ((original, copy) in batch) {
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
        }
        handle = { AppDNA.handlePushTap(it) }
    }
}
