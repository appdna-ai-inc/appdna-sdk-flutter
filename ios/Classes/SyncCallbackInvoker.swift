import Flutter
import Foundation

/// SPEC-070-C Phase 2a — native → Dart bridge for the onboarding delegate's
/// async return-value hooks (and, later, the D10 host-veto decisions) over the
/// `com.appdna.sdk/sync_callbacks` `FlutterMethodChannel`.
///
/// The Dart side (`AppDNA._handleSyncCallback`) registers a
/// `setMethodCallHandler` on this same channel name; native `invokeMethod`s a
/// hook and awaits the reply. The MethodChannel reply IS the correlation. A
/// timeout resolves the awaited value to `nil` so the native caller can fall
/// back to its SDK default — a slow or absent Flutter host never deadlocks the
/// onboarding engine.
///
/// §5 observability: a timeout emits a diagnostic `NSLog` line so field issues
/// are visible in device logs / Console.app.
final class SyncCallbackInvoker {
    private let channel: FlutterMethodChannel
    /// The configured wait. Internal so a caller can compute a per-call floor against it
    /// (SPEC-496 §5b C5.5).
    let timeout: TimeInterval

    init(channel: FlutterMethodChannel, timeout: TimeInterval = 5.0) {
        self.channel = channel
        self.timeout = timeout
    }

    /// Invoke a Dart sync-callback and await its reply.
    ///
    /// Returns the raw decoded reply (a `[String: Any]?` for the onboarding
    /// hooks, or a scalar for the vetos) on success, or `nil` on timeout /
    /// channel error / `FlutterError`. The native caller converts the reply
    /// into the concrete return DTO and substitutes its default on `nil`.
    ///
    /// `timeout` — SPEC-496 §5b C5.5: an optional PER-CALL wait, defaulting to the configured one. Only
    /// `onElementInteraction` passes it (a `refresh` has an 8 s SDK deadline the 5 s default would
    /// cut short); every other hook keeps the configured value.
    func invokeDart(_ method: String, _ args: [String: Any], timeout: TimeInterval? = nil) async -> Any? {
        let wait = timeout ?? self.timeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<Any?, Never>) in
            // All continuation access is funnelled onto the main queue so the
            // `resumed` guard needs no additional locking: the invoke-reply,
            // the timeout, and the initial dispatch are all serialized there.
            DispatchQueue.main.async {
                var resumed = false
                let resumeOnce: (Any?) -> Void = { value in
                    if resumed { return }
                    resumed = true
                    continuation.resume(returning: value)
                }

                self.channel.invokeMethod(method, arguments: args) { reply in
                    let normalized: Any? = (reply is FlutterError) ? nil : reply
                    if Thread.isMainThread {
                        resumeOnce(normalized)
                    } else {
                        DispatchQueue.main.async { resumeOnce(normalized) }
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    if !resumed {
                        NSLog("[AppDNA] sync_callbacks timeout: \(method)")
                        resumeOnce(nil)
                    }
                }
            }
        }
    }
}
