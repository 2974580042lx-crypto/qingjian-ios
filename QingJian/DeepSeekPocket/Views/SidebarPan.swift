import SwiftUI
import UIKit

// A window-attached recognizer keeps tracking while SwiftUI moves the page and
// suspends its scroll view. Reject vertical pans before recognition begins.
@MainActor
struct SidebarPan: UIViewRepresentable {
    var enabled: Bool
    var isOpen: Bool
    var maximumStartY: CGFloat
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void
    let cancelled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.windowChanged = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }
    func updateUIView(_ view: AttachmentView, context: Context) {
        context.coordinator.owner = self
        context.coordinator.attach(to: view.window)
    }
    static func dismantleUIView(_ view: AttachmentView, coordinator: Coordinator) { coordinator.attach(to: nil) }

    final class AttachmentView: UIView {
        var windowChanged: ((UIWindow?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); windowChanged?(window) }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: SidebarPan
        private weak var window: UIWindow?
        private lazy var pan: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.delegate = self
            recognizer.maximumNumberOfTouches = 1
            return recognizer
        }()
        init(_ owner: SidebarPan) { self.owner = owner }
        func attach(to next: UIWindow?) {
            guard window !== next else { return }
            window?.removeGestureRecognizer(pan)
            window = next
            next?.addGestureRecognizer(pan)
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard owner.enabled, let window, let recognizer = gestureRecognizer as? UIPanGestureRecognizer,
                  window.rootViewController?.presentedViewController == nil else { return false }
            let velocity = recognizer.velocity(in: window)
            guard abs(velocity.x) > abs(velocity.y) * 1.4 else { return false }
            if !owner.isOpen && recognizer.location(in: window).y > owner.maximumStartY { return false }
            return owner.isOpen ? velocity.x < 0 : velocity.x > 0
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard owner.enabled, window?.rootViewController?.presentedViewController == nil else { return false }
            if let root = window?.rootViewController?.view,
               let target = touch.view,
               !target.isDescendant(of: root) { return false }
            var view = touch.view
            while let current = view {
                if current is UITabBar { return false }
                if current.isFirstResponder && (current is UITextField || current is UITextView) { return false }
                view = current.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc private func handle(_ recognizer: UIPanGestureRecognizer) {
            let dx = recognizer.translation(in: window).x
            switch recognizer.state {
            case .began, .changed: owner.changed(dx)
            case .ended: owner.ended(dx, dx + recognizer.velocity(in: window).x * 0.18)
            case .cancelled, .failed: owner.cancelled()
            default: break
            }
        }
    }
}
