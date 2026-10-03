package com.appdna.flutter

import ai.appdna.sdk.screens.AppDNAScreenSlot
import android.content.Context
import android.view.View
import androidx.compose.ui.platform.ComposeView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Flutter PlatformView bridge for the native
 * `@Composable AppDNAScreenSlot(name)` (an inline server-driven screen slot).
 *
 * viewType: `com.appdna.sdk/screen_slot`. Creation args (StandardMessageCodec):
 *   `{ "name": String }` — the console slot name to render.
 *
 * The Dart `AppDNAScreenSlot` widget embeds an `AndroidView` with this same
 * viewType; this factory hosts the Composable in a `ComposeView`.
 */
class AppDNAScreenSlotViewFactory :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any?>
        val name = params?.get("name") as? String ?: ""
        return AppDNAScreenSlotPlatformView(context, name)
    }
}

/**
 * Hosts the `@Composable AppDNAScreenSlot(name)` in a [ComposeView].
 *
 * CRITICAL: Flutter's default `FlutterActivity` is a bare `android.app.Activity`
 * (NOT a `ComponentActivity`), so the ComposeView finds no
 * `ViewTreeLifecycleOwner` / `ViewTreeSavedStateRegistryOwner` /
 * `ViewTreeViewModelStoreOwner` in its view tree and `setContent {}` crashes
 * with "ViewTreeLifecycleOwner not found". We back the ComposeView with a small
 * plugin-owned owner (driven to RESUMED) and set all three ViewTree owners
 * manually before calling `setContent`.
 */
private class AppDNAScreenSlotPlatformView(
    context: Context,
    name: String,
) : PlatformView {

    private val lifecycleOwner = SlotViewTreeOwner()

    private val composeView: ComposeView = ComposeView(context).apply {
        // Restore + drive the backing owner to RESUMED, then wire the three
        // ViewTree owners onto the ComposeView BEFORE setContent.
        lifecycleOwner.start()
        setViewTreeLifecycleOwner(lifecycleOwner)
        setViewTreeViewModelStoreOwner(lifecycleOwner)
        setViewTreeSavedStateRegistryOwner(lifecycleOwner)
        setContent {
            AppDNAScreenSlot(name = name)
        }
    }

    override fun getView(): View = composeView

    override fun dispose() {
        composeView.disposeComposition()
        lifecycleOwner.destroy()
    }
}

/**
 * Minimal [LifecycleOwner] + [ViewModelStoreOwner] + [SavedStateRegistryOwner]
 * that backs a [ComposeView] hosted outside a `ComponentActivity`. Driven to
 * RESUMED so Compose composes + runs effects; torn down to DESTROYED on dispose.
 */
private class SlotViewTreeOwner :
    LifecycleOwner,
    ViewModelStoreOwner,
    SavedStateRegistryOwner {

    private val lifecycleRegistry = LifecycleRegistry(this)
    private val store = ViewModelStore()
    private val savedStateController = SavedStateRegistryController.create(this)

    override val lifecycle: Lifecycle get() = lifecycleRegistry
    override val viewModelStore: ViewModelStore get() = store
    override val savedStateRegistry: SavedStateRegistry
        get() = savedStateController.savedStateRegistry

    /** Restore saved state (none) then move to RESUMED. */
    fun start() {
        // performRestore must run while the lifecycle is still INITIALIZED.
        savedStateController.performRestore(null)
        lifecycleRegistry.currentState = Lifecycle.State.RESUMED
    }

    fun destroy() {
        lifecycleRegistry.currentState = Lifecycle.State.DESTROYED
        store.clear()
    }
}
