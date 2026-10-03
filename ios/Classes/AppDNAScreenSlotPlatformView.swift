import Flutter
import UIKit
import SwiftUI
import AppDNASDK

// Flutter PlatformView bridge for the native
// `AppDNAScreenSlot` SwiftUI view (an inline server-driven screen slot).
//
// viewType: "com.appdna.sdk/screen_slot". Creation params (StandardMessageCodec):
//   { "name": String }  — the slot name to render.
//
// The SwiftUI `AppDNAScreenSlot(name)` is hosted in a `UIHostingController`
// which is RETAINED as a child view controller of a container UIView. A bare
// `UIHostingController` with no owner is deallocated as soon as `create(...)`
// returns — the SwiftUI view's `@State` + `.onAppear` never run and the slot
// renders nothing. We therefore both (a) hold a strong reference to the hosting
// controller for the platform view's lifetime AND (b) attach it as a child VC
// of the nearest ancestor view controller once the container enters the window
// hierarchy, so UIKit drives its appearance lifecycle (viewWillAppear →
// SwiftUI onAppear) correctly.

/// Factory registered on the plugin registrar under the shared viewType.
final class AppDNAScreenSlotFactory: NSObject, FlutterPlatformViewFactory {
    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        let params = args as? [String: Any]
        let name = params?["name"] as? String ?? ""
        return AppDNAScreenSlotPlatformView(frame: frame, name: name)
    }

    /// `creationParams` arrive from Dart encoded with the StandardMessageCodec,
    /// so the factory must decode with the matching standard codec.
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

/// The platform view: a container UIView hosting the SwiftUI slot.
final class AppDNAScreenSlotPlatformView: NSObject, FlutterPlatformView {
    private let container: SlotContainerView
    // Strong ref — this is what keeps the hosting controller (and thus the
    // SwiftUI slot's state) alive. Flutter retains this FlutterPlatformView for
    // the lifetime of the embedded view, so the controller cannot dealloc early.
    private let hostingController: UIHostingController<AppDNAScreenSlot>

    init(frame: CGRect, name: String) {
        self.hostingController = UIHostingController(rootView: AppDNAScreenSlot(name))
        self.container = SlotContainerView(frame: frame)
        super.init()

        let hostView = hostingController.view!
        hostView.backgroundColor = .clear
        hostView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostView)
        NSLayoutConstraint.activate([
            hostView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostView.topAnchor.constraint(equalTo: container.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Once the container is in a window, attach the hosting controller as a
        // child of the nearest ancestor VC so UIKit runs its appearance
        // lifecycle. If no parent VC can be resolved, the strong ref alone still
        // keeps the slot alive and rendering.
        container.onMoveToWindow = { [weak self] in
            self?.attachToParentIfNeeded()
        }
    }

    func view() -> UIView {
        return container
    }

    private func attachToParentIfNeeded() {
        guard hostingController.parent == nil,
              let parentVC = container.nearestViewController() else { return }
        parentVC.addChild(hostingController)
        hostingController.didMove(toParent: parentVC)
    }

    deinit {
        // Detach from the parent VC on dispose. Once attached
        // via addChild, the long-lived FlutterViewController's `children` array
        // retains the hosting controller (+ its SwiftUI state) INDEPENDENTLY of this
        // FlutterPlatformView's strong ref. Flutter releases the platform view on
        // widget dispose but has no dispose() hook on iOS (unlike Android), so
        // without this deinit every slot create/dispose cycle leaks one hosting
        // controller for the app session. Flutter disposes platform views on the
        // main thread, so these UIKit calls run on main.
        hostingController.willMove(toParent: nil)
        hostingController.removeFromParent()
    }
}

/// Container UIView that reports window attachment and resolves the nearest
/// ancestor view controller via the responder chain.
private final class SlotContainerView: UIView {
    var onMoveToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onMoveToWindow?() }
    }

    func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self.next
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }
}
