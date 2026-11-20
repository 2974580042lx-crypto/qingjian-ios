import SwiftUI
import UIKit

/// UIKit owns the keyboard attachment; SwiftUI owns the content. This avoids
/// safe-area height lag when an input accessory grows and shrinks in one focus,
/// while letting the transcript scroll cleanly behind both the Liquid Glass
/// composer and the Home Indicator on iPhone Air (420×912pt) and all iPhones.
@MainActor
struct KeyboardChatLayout<Transcript: View, Composer: View>: UIViewControllerRepresentable {
    let layoutSignature: Int
    let onBottomObstructionChange: (CGFloat) -> Void
    let transcript: Transcript
    let composer: Composer

    init(
        layoutSignature: Int = 0,
        onBottomObstructionChange: @escaping (CGFloat) -> Void = { _ in },
        @ViewBuilder transcript: () -> Transcript,
        @ViewBuilder composer: () -> Composer
    ) {
        self.layoutSignature = layoutSignature
        self.onBottomObstructionChange = onBottomObstructionChange
        self.transcript = transcript()
        self.composer = composer()
    }

    func makeUIViewController(context: Context) -> Controller {
        Controller(
            layoutSignature: layoutSignature,
            onBottomObstructionChange: onBottomObstructionChange,
            transcript: transcript,
            composer: composer
        )
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onBottomObstructionChange = onBottomObstructionChange
        controller.transcriptHost.rootView = transcript
        controller.composerHost.rootView = composer
        let width = controller.view.bounds.width
        if width > 0 {
            // Only measure composer intrinsic height when composer layout inputs or width changed (PERF-7).
            if controller.lastLayoutSignature != layoutSignature || abs(width - controller.lastMeasuredWidth) > 0.5 {
                controller.lastLayoutSignature = layoutSignature
                controller.lastMeasuredWidth = width
                let fitHeight = controller.composerHost.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
                if abs(fitHeight - controller.lastComposerFitHeight) > 0.5 {
                    controller.lastComposerFitHeight = fitHeight
                    controller.composerHost.view.invalidateIntrinsicContentSize()
                    controller.view.setNeedsLayout()
                }
            }
        } else {
            controller.composerHost.view.invalidateIntrinsicContentSize()
            controller.view.setNeedsLayout()
        }
    }

    final class Controller: UIViewController {
        let transcriptHost: UIHostingController<Transcript>
        let composerHost: UIHostingController<Composer>
        var onBottomObstructionChange: (CGFloat) -> Void
        fileprivate var lastLayoutSignature: Int
        fileprivate var lastMeasuredWidth: CGFloat = -1
        fileprivate var lastComposerFitHeight: CGFloat = -1
        private var lastReportedObstruction: CGFloat = -1
        private var composerBottom: NSLayoutConstraint!

        init(
            layoutSignature: Int,
            onBottomObstructionChange: @escaping (CGFloat) -> Void,
            transcript: Transcript,
            composer: Composer
        ) {
            self.lastLayoutSignature = layoutSignature
            self.onBottomObstructionChange = onBottomObstructionChange
            transcriptHost = UIHostingController(rootView: transcript)
            composerHost = UIHostingController(rootView: composer)
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.keyboardLayoutGuide.usesBottomSafeArea = true
            // Do not let either hosting controller apply keyboard/safe-area avoidance a
            // second time: explicit constraints + reported obstruction own vertical geometry.
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
            // Transcript extends to the true bottom of the screen so scrolled prose gently
            // passes behind the Liquid Glass composer and Home Indicator; composer sits on
            // `keyboardLayoutGuide.topAnchor` (= safeAreaLayoutGuide.bottomAnchor when idle).
            composerBottom = composerHost.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
            NSLayoutConstraint.activate([
                transcriptHost.view.topAnchor.constraint(equalTo: view.topAnchor),
                transcriptHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                transcriptHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                transcriptHost.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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

        private weak var transcriptScroll: UIScrollView?
        private func configureTranscriptScroll() {
            if transcriptScroll == nil || transcriptScroll?.window == nil {
                transcriptScroll = firstScrollView(in: transcriptHost.view)
            }
            guard let scroll = transcriptScroll else { return }
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.topEdgeEffect.isHidden = false
            scroll.topEdgeEffect.style = .soft
            scroll.bottomEdgeEffect.isHidden = false
            scroll.bottomEdgeEffect.style = .soft
            scroll.alwaysBounceHorizontal = false
            scroll.showsHorizontalScrollIndicator = false
            if abs(scroll.contentOffset.x) > 0.5,
               !scroll.isTracking,
               !scroll.isDragging,
               scroll.contentSize.width <= scroll.bounds.width + 2 {
                scroll.contentOffset.x = 0
            }
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
            configureTranscriptScroll()
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
                view.setNeedsLayout()
            }

            if view.bounds.height > 0 {
                let guideTop = view.keyboardLayoutGuide.layoutFrame.minY - correction
                let obstructed = max(0, view.bounds.height - guideTop)
                if abs(obstructed - lastReportedObstruction) > 0.5 {
                    lastReportedObstruction = obstructed
                    let callback = onBottomObstructionChange
                    DispatchQueue.main.async { callback(obstructed) }
                }
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
