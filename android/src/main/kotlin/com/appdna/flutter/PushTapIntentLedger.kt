package com.appdna.flutter

import android.content.Intent
import java.util.WeakHashMap

/**
 * The intents the plugin has handed to the native `AppDNA.handlePushTap`, and native's answer for each.
 *
 * Native gets a COPY of every intent, and makes only that copy inert, so the activity's own intent keeps
 * its extras (`appdna`, `push_id`, `delivery_id`, …) and a host that reads them still recognises the tap.
 * That left the activity's intent a live tap: every `configure` re-ran the launch intent, and only the
 * persisted tap claim — the last 32 tap keys — kept it from being tracked and routed again. After 32 later
 * taps the claim was gone and a re-`configure` fired the launch tap again. A tap on a notification the
 * previous SDK version posted has no key at all, so it was routed again on every re-run.
 *
 * The ledger remembers each intent OBJECT for as long as it lives (the activity's lifetime): `Intent` does
 * not override `equals` / `hashCode`, so this weak map compares by identity, and an intent the plugin has
 * seen is never handed to native again — by the new-intent listener, by `configure`, or by Dart's
 * `AppDNAPush.handlePushTap()`. Process-wide, so a second engine or plugin instance shares it.
 */
internal object PushTapIntentLedger {

    internal enum class State {
        /** Never handed to native. */
        UNSEEN,
        /** Handed over and waiting for the SDK to become ready. */
        QUEUED,
        /** Native handled it as an AppDNA tap. */
        HANDLED,
        /** Native answered that it is not an AppDNA tap. */
        NOT_A_TAP,
    }

    /** `null` = queued until the SDK is ready. */
    private val answers = WeakHashMap<Intent, Boolean?>()

    /** True the first time [intent] is seen (it is now queued); false when it was handed over before. */
    @Synchronized
    fun claim(intent: Intent): Boolean {
        if (answers.containsKey(intent)) return false
        answers[intent] = null
        return true
    }

    /** Forget [intent]: it is UNSEEN again ([PendingPushTaps] dropped it before the SDK was ready). */
    @Synchronized
    fun forget(intent: Intent) {
        answers.remove(intent)
    }

    @Synchronized
    fun record(intent: Intent, handled: Boolean) {
        answers[intent] = handled
    }

    @Synchronized
    fun state(intent: Intent): State = when {
        !answers.containsKey(intent) -> State.UNSEEN
        answers[intent] == null -> State.QUEUED
        answers[intent] == true -> State.HANDLED
        else -> State.NOT_A_TAP
    }
}
