import SwiftUI
import UIKit

/// UIKit owns the keyboard attachment; SwiftUI owns the content. This avoids
/// safe-area height lag when an input accessory grows and shrinks in one focus.
@MainActor
struct KeyboardChatLayout<Transcript: View, Composer: View>: UIViewControllerRepresentable {
    let transcript: Transcript
    let composer: Composer

    init(@ViewBuilder transcript: () -> Transcript, @ViewBuilder composer: () -> Composer) {
        self.transcript = transcript()
        self.composer = composer()
    }

    func makeUIViewController(context: Context) -> Controller {
        Controller(transcript: transcript, composer: composer)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.transcriptHost.rootView = transcript
        controller.composerHost.rootView = composer
        controller.composerHost.view.invalidateIntrinsicContentSize()
        controller.view.setNeedsLayout()
    }

    final class Controller: UIViewController {
        let transcriptHost: UIHostingController<Transcript>
        let composerHost: UIHostingController<Composer>
        private var composerBottom: NSLayoutConstraint!
        private var transcriptBottom: NSLayoutConstraint!

        init(transcript: Transcript, composer: Composer) {
            transcriptHost = UIHostingController(rootView: transcript)
            composerHost = UIHostingController(rootView: composer)
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            // Do not let either hosting controller apply keyboard avoidance a
            // second time: the constraints below are the sole vertical owner.
            transcriptHost.safeAreaRegions = []
            composerHost.safeAreaRegions = []
            composerHost.sizingOptions = [.intrinsicContentSize]
            for host in [transcriptHost as UIViewController, composerHost as UIViewController] {
                addChild(host)
                host.view.backgroundColor = .clear
                host.view.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(host.view)
                host.didMove(toParent: self)
            }
            composerHost.view.setContentHuggingPriority(.required, for: .vertical)
            composerHost.view.setContentCompressionResistancePriority(.required, for: .vertical)
            transcriptBottom = transcriptHost.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
            composerBottom = composerHost.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
            NSLayoutConstraint.activate([
                transcriptHost.view.topAnchor.constraint(equalTo: view.topAnchor),
                transcriptHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                transcriptHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                transcriptBottom,
                composerHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                composerHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                composerBottom
            ])
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func keyboardChanged() {
            view.setNeedsLayout()
            DispatchQueue.main.async { [weak self] in self?.view.layoutIfNeeded() }
        }

        // The navigation bar's iOS 26 edge effect lays a paper-coloured scrim over the
        // chat under the top buttons. SwiftUI's own switch did not reach it, because the
        // transcript lives in this separate host, so it is turned off on the scroll view.
        private weak var transcriptScroll: UIScrollView?
        private func hideTopEdgeEffect() {
            if let scroll = transcriptScroll, scroll.window != nil { return }
            transcriptScroll = firstScrollView(in: transcriptHost.view)
            transcriptScroll?.topEdgeEffect.isHidden = true
        }
        private func firstScrollView(in root: UIView) -> UIScrollView? {
            if let scroll = root as? UIScrollView, !(root is UITextView) { return scroll }
            for child in root.subviews {
                if let found = firstScrollView(in: child) { return found }
            }
            return nil
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            hideTopEdgeEffect()
            // reloadInputViews can leave the keyboard guide below an actual
            // app-owned accessory. Compare both in THIS view's coordinate space,
            // never add an offset back to an already-adjusted composer frame.
            var correction: CGFloat = 0
            if let field = firstResponder(in: composerHost.view),
               let accessory = field.inputAccessoryView,
               accessory.window != nil, !accessory.isHidden {
                let frame = accessory.convert(accessory.bounds, to: view)
                if frame.height > 0, frame.intersects(view.bounds), frame.width > view.bounds.width / 2 {
                    correction = max(0, view.keyboardLayoutGuide.layoutFrame.minY - frame.minY)
                }
            }
            if abs(composerBottom.constant + correction) > 0.5 {
                composerBottom.constant = -correction
                transcriptBottom.constant = -correction
                view.setNeedsLayout()
            }
        }

        private func firstResponder(in root: UIView) -> UIView? {
            if root.isFirstResponder { return root }
            for child in root.subviews {
                if let found = firstResponder(in: child) { return found }
            }
            return nil
        }
    }
}
