import Observation
import SwiftUI
import UIKit

/// Pure-UIKit drawer host for 120Hz sidebar dragging with zero SwiftUI body
/// invalidations mid-gesture, lazy sidebar mounting while closed, and cached
/// shadow geometry.
@MainActor
struct SidebarDrawerContainer<Sidebar: View, Main: View>: UIViewControllerRepresentable {
    @Binding var isOpen: Bool
    let reduceMotion: Bool
    let isSwiss: Bool
    let appearanceRaw: String
    let styleRevision: Int
    let composerExcludedHeight: CGFloat
    let sidebarBuilder: () -> Sidebar
    let main: Main

    func makeUIViewController(context: Context) -> Controller {
        Controller(
            isOpen: isOpen,
            isOpenChanged: { open in isOpen = open },
            reduceMotion: reduceMotion,
            isSwiss: isSwiss,
            appearanceRaw: appearanceRaw,
            composerExcludedHeight: composerExcludedHeight,
            sidebarBuilder: sidebarBuilder,
            main: main
        )
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isOpenChanged = { open in isOpen = open }
        controller.reduceMotion = reduceMotion
        controller.composerExcludedHeight = composerExcludedHeight
        controller.sidebarBuilder = sidebarBuilder
        controller.mainHost.rootView = main
        controller.refreshIfNeeded(
            targetOpen: isOpen,
            isSwiss: isSwiss,
            appearanceRaw: appearanceRaw,
            styleRevision: styleRevision
        )
    }

    @MainActor
    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        let mainHost: UIHostingController<Main>
        private var sidebarHost: UIHostingController<Sidebar>?
        var sidebarBuilder: () -> Sidebar
        var isOpenChanged: (Bool) -> Void
        var reduceMotion: Bool
        var composerExcludedHeight: CGFloat

        private var currentOpen: Bool
        private var isSwiss: Bool
        private var appearanceRaw: String
        private var styleRevision: Int = -1
        private var isDragging = false
        private var dragStartOpen = false
        private var hasLaidOut = false
        private var lastBoundsSize: CGSize = .zero
        private var lastShadowCornerRadius: CGFloat = -1
        private var lastShadowSize: CGSize = .zero

        private let backContainerView = UIView()
        private let frontShadowView = UIView()
        private let frontClipView = UIView()
        private let frontTapOverlay = UIView()

        private lazy var pan: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.delegate = self
            recognizer.maximumNumberOfTouches = 1
            return recognizer
        }()

        private lazy var tapOverlayGesture = UITapGestureRecognizer(target: self, action: #selector(handleOverlayTap))

        init(
            isOpen: Bool,
            isOpenChanged: @escaping (Bool) -> Void,
            reduceMotion: Bool,
            isSwiss: Bool,
            appearanceRaw: String,
            composerExcludedHeight: CGFloat,
            sidebarBuilder: @escaping () -> Sidebar,
            main: Main
        ) {
            self.currentOpen = isOpen
            self.isOpenChanged = isOpenChanged
            self.reduceMotion = reduceMotion
            self.isSwiss = isSwiss
            self.appearanceRaw = appearanceRaw
            self.composerExcludedHeight = composerExcludedHeight
            self.sidebarBuilder = sidebarBuilder
            self.mainHost = UIHostingController(rootView: main)
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidLoad() {
            super.viewDidLoad()

            backContainerView.clipsToBounds = true
            backContainerView.layer.cornerCurve = .continuous
            backContainerView.alpha = 0
            view.addSubview(backContainerView)

            frontShadowView.backgroundColor = .clear
            frontShadowView.layer.shadowColor = UIColor.black.cgColor
            frontShadowView.layer.shadowRadius = 14
            frontShadowView.layer.shadowOffset = CGSize(width: -6, height: 0)
            frontShadowView.layer.shadowOpacity = 0
            view.addSubview(frontShadowView)

            frontClipView.clipsToBounds = true
            frontClipView.layer.cornerCurve = .continuous
            frontShadowView.addSubview(frontClipView)

            mainHost.view.backgroundColor = .clear
            addChild(mainHost)
            frontClipView.addSubview(mainHost.view)
            mainHost.didMove(toParent: self)

            frontTapOverlay.backgroundColor = .clear
            frontTapOverlay.isHidden = !currentOpen
            frontTapOverlay.addGestureRecognizer(tapOverlayGesture)
            frontClipView.addSubview(frontTapOverlay)

            view.addGestureRecognizer(pan)

            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: Controller, _) in
                controller.applyThemeColors()
            }

            applyAppearanceStyle()
            applyThemeColors()
        }

        private var drawerWidth: CGFloat {
            let width = view.bounds.width > 0
                ? view.bounds.width
                : (view.window?.windowScene?.screen.bounds.width ?? 390)
            return min(width * 0.82, 360)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }

            let width = min(bounds.width * 0.82, 360)
            if lastBoundsSize != bounds.size {
                lastBoundsSize = bounds.size

                // Use bounds + center instead of frame so active transforms never corrupt layout.
                backContainerView.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: bounds.height))
                backContainerView.center = CGPoint(x: width / 2, y: bounds.midY)
                if let sidebarView = sidebarHost?.view {
                    sidebarView.frame = backContainerView.bounds
                }

                frontShadowView.bounds = bounds
                frontShadowView.center = CGPoint(x: bounds.midX, y: bounds.midY)
                frontClipView.frame = frontShadowView.bounds
                mainHost.view.frame = frontClipView.bounds
                frontTapOverlay.frame = frontClipView.bounds
            }

            if !hasLaidOut {
                hasLaidOut = true
                if currentOpen {
                    ensureSidebarMounted()
                }
                applyProgress(currentOpen ? 1 : 0, revealed: currentOpen)
            } else if !isDragging {
                applyProgress(currentOpen ? 1 : 0, revealed: currentOpen)
            }
        }

        func refreshIfNeeded(targetOpen: Bool, isSwiss: Bool, appearanceRaw: String, styleRevision: Int) {
            let appearanceChanged = self.isSwiss != isSwiss
                || self.appearanceRaw != appearanceRaw
                || self.styleRevision != styleRevision
            self.isSwiss = isSwiss
            self.appearanceRaw = appearanceRaw
            self.styleRevision = styleRevision

            if appearanceChanged {
                applyAppearanceStyle()
                applyThemeColors()
                if !isDragging {
                    applyProgress(currentOpen ? 1 : 0, revealed: currentOpen)
                }
            }

            if let sidebarHost {
                sidebarHost.rootView = sidebarBuilder()
            }

            if !isDragging && targetOpen != currentOpen {
                setOpen(targetOpen, animated: !reduceMotion && hasLaidOut)
            }
        }

        private func applyAppearanceStyle() {
            if InterfaceStyle.isNight {
                overrideUserInterfaceStyle = .dark
            } else {
                switch AppearanceMode(rawValue: appearanceRaw) ?? .system {
                case .system: overrideUserInterfaceStyle = .unspecified
                case .light: overrideUserInterfaceStyle = .light
                case .dark: overrideUserInterfaceStyle = .dark
                }
            }
        }

        private func applyThemeColors() {
            let effectiveStyle: UIUserInterfaceStyle = overrideUserInterfaceStyle != .unspecified
                ? overrideUserInterfaceStyle
                : traitCollection.userInterfaceStyle
            let resolvedTraits = UITraitCollection(userInterfaceStyle: effectiveStyle)
            let sheetColor = UIColor(Ink.sheet)
            view.backgroundColor = sheetColor
            backContainerView.backgroundColor = sheetColor
            let borderColor = UIColor(Ink.line).resolvedColor(with: resolvedTraits).cgColor
            backContainerView.layer.borderColor = borderColor
            frontClipView.layer.borderColor = borderColor
        }

        private func ensureSidebarMounted() {
            guard sidebarHost == nil else { return }
            let host = UIHostingController(rootView: sidebarBuilder())
            host.view.backgroundColor = .clear
            host.view.frame = backContainerView.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addChild(host)
            backContainerView.addSubview(host.view)
            host.didMove(toParent: self)
            sidebarHost = host
        }

        private func detachSidebarIfClosed() {
            guard !currentOpen, !isDragging, let host = sidebarHost else { return }
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            sidebarHost = nil
        }

        private func updateShadowPathIfNeeded(cornerRadius: CGFloat) {
            let size = frontShadowView.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            guard size != lastShadowSize || abs(cornerRadius - lastShadowCornerRadius) > 0.2 else { return }
            lastShadowSize = size
            lastShadowCornerRadius = cornerRadius
            frontShadowView.layer.shadowPath = UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: size),
                cornerRadius: cornerRadius
            ).cgPath
        }

        private func applyProgress(_ progress: CGFloat, revealed: Bool) {
            let p = min(1, max(0, progress))
            let width = drawerWidth
            frontShadowView.transform = CGAffineTransform(translationX: width * p, y: 0)
            backContainerView.transform = CGAffineTransform(translationX: -width * 0.16 * (1 - p), y: 0)
            backContainerView.alpha = revealed ? min(1, max(0.01, p * 2.5)) : 0
            frontShadowView.layer.shadowOpacity = revealed ? Float(0.12 * min(1, p * 3)) : 0

            let frontRadius: CGFloat = (revealed && !isSwiss) ? Radius.pageFront : 0
            let backRadius: CGFloat = (revealed && !isSwiss) ? Radius.pageBack : 0
            frontClipView.layer.cornerRadius = frontRadius
            frontClipView.layer.borderWidth = revealed ? 0.6 : 0
            backContainerView.layer.cornerRadius = backRadius
            backContainerView.layer.borderWidth = revealed ? 0.5 : 0
            updateShadowPathIfNeeded(cornerRadius: frontRadius)

            frontTapOverlay.isHidden = !revealed
            frontClipView.accessibilityElementsHidden = revealed
        }

        func setOpen(_ open: Bool, animated: Bool) {
            currentOpen = open
            if open {
                ensureSidebarMounted()
            }
            let targetProgress: CGFloat = open ? 1 : 0
            if animated && hasLaidOut {
                UIView.animate(
                    withDuration: 0.28,
                    delay: 0,
                    usingSpringWithDamping: 0.92,
                    initialSpringVelocity: 0.35,
                    options: [.allowUserInteraction, .beginFromCurrentState],
                    animations: {
                        // Keep page rounded corners & shadow during the slide; snap to flat once shut.
                        self.applyProgress(targetProgress, revealed: true)
                        if !open {
                            self.backContainerView.alpha = 0
                            self.frontShadowView.layer.shadowOpacity = 0
                        }
                    },
                    completion: { _ in
                        if !self.currentOpen && !self.isDragging {
                            self.applyProgress(0, revealed: false)
                        }
                        self.detachSidebarIfClosed()
                    }
                )
            } else {
                applyProgress(targetProgress, revealed: open)
                detachSidebarIfClosed()
            }
        }

        @objc private func handleOverlayTap() {
            guard currentOpen else { return }
            isOpenChanged(false)
            setOpen(false, animated: !reduceMotion)
        }

        // MARK: - UIGestureRecognizerDelegate

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard presentedViewController == nil,
                  view.window?.rootViewController?.presentedViewController == nil else {
                return false
            }
            var current = touch.view
            while let candidate = current {
                if candidate is UITabBar { return false }
                if candidate is PhotoStackGestureHostView { return false }
                if candidate.isFirstResponder && (candidate is UITextField || candidate is UITextView) {
                    return false
                }
                if let scroll = candidate as? UIScrollView,
                   scroll.isScrollEnabled,
                   scroll.contentSize.width > scroll.bounds.width + 2 {
                    return false
                }
                current = candidate.superview
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard presentedViewController == nil,
                  view.window?.rootViewController?.presentedViewController == nil,
                  let recognizer = gestureRecognizer as? UIPanGestureRecognizer else {
                return false
            }
            let velocity = recognizer.velocity(in: view)
            guard abs(velocity.x) > abs(velocity.y) * 1.4 else { return false }
            if !currentOpen {
                let startY = recognizer.location(in: view).y
                let maxStartY = max(120, view.bounds.height - composerExcludedHeight)
                if startY > maxStartY { return false }
                return velocity.x > 0
            }
            return velocity.x < 0
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let width = drawerWidth
            guard width > 0 else { return }
            let dx = recognizer.translation(in: view).x
            switch recognizer.state {
            case .began:
                isDragging = true
                dragStartOpen = currentOpen
                ensureSidebarMounted()
                cancelVerticalScrollPans(in: mainHost.view)
                if let sidebarView = sidebarHost?.view {
                    cancelVerticalScrollPans(in: sidebarView)
                }
                let position = dragStartOpen ? max(0, width + min(0, dx)) : max(0, min(width, dx))
                applyProgress(position / width, revealed: position > 0 || dragStartOpen)
            case .changed:
                let position = dragStartOpen ? max(0, min(width, width + dx)) : max(0, min(width, dx))
                applyProgress(position / width, revealed: position > 0 || dragStartOpen)
            case .ended:
                isDragging = false
                let prediction = dx + recognizer.velocity(in: view).x * 0.18
                let threshold = min(65, width * 0.18)
                let shouldOpen = dragStartOpen
                    ? !(dx < -threshold || prediction < -width * 0.45)
                    : (dx > threshold || prediction > width * 0.45)
                if shouldOpen {
                    view.window?.endEditing(true)
                }
                currentOpen = shouldOpen
                if shouldOpen {
                    ensureSidebarMounted()
                }
                if shouldOpen != dragStartOpen {
                    isOpenChanged(shouldOpen)
                }
                setOpen(shouldOpen, animated: !reduceMotion)
            case .cancelled, .failed:
                isDragging = false
                setOpen(dragStartOpen, animated: !reduceMotion)
            default:
                break
            }
        }

        private func cancelVerticalScrollPans(in root: UIView) {
            if let scroll = root as? UIScrollView, !(root is UITextView) {
                let pan = scroll.panGestureRecognizer
                if pan.state == .began || pan.state == .changed {
                    pan.isEnabled = false
                    pan.isEnabled = true
                }
            }
            for child in root.subviews {
                cancelVerticalScrollPans(in: child)
            }
        }
    }
}

/// Shared offset holder for Claude-style left-swipe message timestamps so dragging
/// never invalidates `ChatScreen` or `KeyboardChatLayout`.
@MainActor @Observable
final class SwipeTimeRevealModel {
    var offset: CGFloat = 0
}

/// Native UIKit left-pan recognizer scoped to the transcript bounds. Vertical
/// pans fail in `gestureRecognizerShouldBegin` before recognition, so vertical
/// `ScrollView` scrolling never stalls on iOS 18/26.
@MainActor
struct TranscriptLeftSwipePan: UIViewRepresentable {
    let enabled: Bool
    let model: SwipeTimeRevealModel

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        context.coordinator.attachmentView = view
        view.windowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ view: AttachmentView, context: Context) {
        context.coordinator.owner = self
        context.coordinator.attachmentView = view
        context.coordinator.attach(to: view.window)
        if !enabled {
            context.coordinator.cancelAndResetIfNeeded()
        }
    }

    static func dismantleUIView(_ view: AttachmentView, coordinator: Coordinator) {
        coordinator.attach(to: nil)
    }

    final class AttachmentView: UIView {
        var windowChanged: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowChanged?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: TranscriptLeftSwipePan
        weak var attachmentView: AttachmentView?
        private weak var window: UIWindow?
        private var hapticTriggered = false

        private lazy var pan: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.delegate = self
            recognizer.maximumNumberOfTouches = 1
            return recognizer
        }()

        init(owner: TranscriptLeftSwipePan) {
            self.owner = owner
        }

        func attach(to next: UIWindow?) {
            guard window !== next else { return }
            resetOffset(animated: false)
            window?.removeGestureRecognizer(pan)
            window = next
            next?.addGestureRecognizer(pan)
        }

        func cancelAndResetIfNeeded() {
            if pan.state == .began || pan.state == .changed {
                pan.isEnabled = false
                pan.isEnabled = true
            }
            resetOffset(animated: false)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if pan.state == .possible && owner.model.offset != 0 {
                resetOffset(animated: false)
            }
            guard owner.enabled,
                  let window,
                  let host = attachmentView,
                  window.rootViewController?.presentedViewController == nil else {
                return false
            }
            let location = touch.location(in: host)
            guard host.bounds.contains(location) else { return false }

            if hasActiveVerticalScroll(in: host.superview ?? host) {
                return false
            }

            var current = touch.view
            while let candidate = current {
                if candidate is UITabBar { return false }
                if candidate is PhotoStackGestureHostView { return false }
                if candidate.isFirstResponder && (candidate is UITextField || candidate is UITextView) {
                    return false
                }
                if let scroll = candidate as? UIScrollView,
                   scroll.isScrollEnabled,
                   (scroll.isDragging || scroll.isDecelerating || scroll.contentSize.width > scroll.bounds.width + 2) {
                    return false
                }
                current = candidate.superview
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard owner.enabled,
                  let window,
                  let recognizer = gestureRecognizer as? UIPanGestureRecognizer,
                  window.rootViewController?.presentedViewController == nil else {
                return false
            }
            let velocity = recognizer.velocity(in: window)
            return velocity.x < -85 && abs(velocity.x) > abs(velocity.y) * 2.2
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handle(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .ended, .cancelled, .failed:
                resetOffset(animated: true)
            case .began:
                guard let window else { resetOffset(animated: false); return }
                hapticTriggered = false
                if let container = attachmentView?.superview {
                    cancelVerticalScrollPans(in: container)
                }
                updateOffset(for: recognizer.translation(in: window).x)
            case .changed:
                guard let window else { resetOffset(animated: false); return }
                updateOffset(for: recognizer.translation(in: window).x)
            default:
                break
            }
        }

        private func updateOffset(for translationX: CGFloat) {
            // 10pt horizontal deadzone prevents micro-twitches from nudging the page left.
            let effective = min(0, translationX + 10)
            let clamped = max(-68, effective * 0.68)
            owner.model.offset = clamped
            if clamped <= -40 && !hapticTriggered {
                hapticTriggered = true
                Haptic.tap()
            }
        }

        private func resetOffset(animated: Bool) {
            hapticTriggered = false
            guard owner.model.offset != 0 else { return }
            if animated {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                    owner.model.offset = 0
                }
            } else {
                owner.model.offset = 0
            }
        }

        private func hasActiveVerticalScroll(in root: UIView) -> Bool {
            if let scroll = root as? UIScrollView, !(root is UITextView),
               (scroll.isDragging || scroll.isDecelerating) {
                return true
            }
            return root.subviews.contains { hasActiveVerticalScroll(in: $0) }
        }

        private func cancelVerticalScrollPans(in root: UIView) {
            if let scroll = root as? UIScrollView, !(root is UITextView) {
                let scrollPan = scroll.panGestureRecognizer
                if scrollPan.state == .began || scrollPan.state == .changed {
                    scrollPan.isEnabled = false
                    scrollPan.isEnabled = true
                }
            }
            for child in root.subviews {
                cancelVerticalScrollPans(in: child)
            }
        }
    }
}
