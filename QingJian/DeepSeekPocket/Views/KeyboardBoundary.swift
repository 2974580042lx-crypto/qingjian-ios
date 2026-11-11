import SwiftUI
import UIKit
import Combine

@MainActor
final class KeyboardBoundary: NSObject, ObservableObject {
    @Published private(set) var top: CGFloat?
    private weak var window: UIWindow?
    private var screenFrame: CGRect?
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    func attach(_ window: UIWindow?) {
        guard self.window !== window else { return }
        self.window = window
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    @objc private func changed(_ notification: Notification) {
        screenFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        refresh()
    }
    func refresh() {
        guard let window, let screenFrame else { publish(nil); return }
        let frame = window.convert(screenFrame, from: window.screen.coordinateSpace)
        let overlap = window.bounds.intersection(frame)
        guard !overlap.isNull, overlap.height > 0, overlap.width > window.bounds.width / 2 else { publish(nil); return }
        var boundary = frame.minY
        if let input = firstResponder(in: window), let accessory = input.inputAccessoryView,
           let source = accessory.window, !accessory.isHidden {
            let sourceFrame = accessory.convert(accessory.bounds, to: source)
            let visibleFrame = source.convert(sourceFrame, to: window)
            if visibleFrame.height > 0 && visibleFrame.intersects(window.bounds) { boundary = min(boundary, visibleFrame.minY) }
        }
        publish(boundary)
    }
    private func publish(_ next: CGFloat?) {
        if top != next { top = next }
    }
    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews { if let result = firstResponder(in: child) { return result } }
        return nil
    }
}

@MainActor
struct KeyboardWindowProbe: UIViewRepresentable {
    let boundary: KeyboardBoundary
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.moved = { [weak boundary] in boundary?.attach($0) }
        return view
    }
    func updateUIView(_ view: ProbeView, context: Context) { boundary.attach(view.window) }
    final class ProbeView: UIView {
        var moved: ((UIWindow?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); moved?(window) }
    }
}
