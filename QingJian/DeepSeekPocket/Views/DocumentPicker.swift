import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class PickerWindowAnchor {
    weak var view: UIView?
    var window: UIWindow? { view?.window }
}

struct PickerWindowReader: UIViewRepresentable {
    let anchor: PickerWindowAnchor
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        anchor.view = view
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

@MainActor
enum SystemPickerPresentation {
    private static weak var waiting: UIViewController?

    static func isWaiting(_ picker: UIViewController?) -> Bool {
        picker != nil && waiting === picker
    }

    @discardableResult
    static func open(_ picker: UIViewController, window anchor: UIWindow? = nil,
                     onError: @escaping (String) -> Void, shown: @escaping () -> Void = {}) -> Bool {
        guard waiting == nil else { onError("选择器正在打开，请稍候。"); return false }
        // Sermo declares single-scene support. Prefer the actual chat host for composer actions.
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
            .filter { !$0.isHidden && $0.windowLevel == .normal && $0.rootViewController?.viewIfLoaded?.window != nil }
        guard let window = anchor ?? windows.first(where: \.isKeyWindow) ?? windows.first else {
            onError("找不到当前页面，请返回后重试。")
            return false
        }
        waiting = picker
        Task { @MainActor in
            defer { if waiting === picker { waiting = nil } }
            // Menu and sheet transitions can briefly overlap. Never present on a dismissing host.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while clock.now < deadline, window.windowScene?.activationState == .foregroundActive {
                guard var top = window.rootViewController else { break }
                while let next = top.presentedViewController { top = next }
                if !top.isBeingPresented, !top.isBeingDismissed, top.transitionCoordinator == nil,
                   top.viewIfLoaded?.window === window {
                    guard !(top is UIAlertController || top is UIDocumentPickerViewController ||
                            top is PHPickerViewController || top is UIImagePickerController) else {
                        onError("请先完成或取消当前选择。")
                        return
                    }
                    // UIKit can establish the presenting relationship on a later run-loop turn,
                    // especially for the out-of-process Photos picker. Keep its delegate alive.
                    var presented = false
                    top.present(picker, animated: true) {
                        presented = true
                        shown()
                    }
                    let presentationDeadline = clock.now.advanced(by: .seconds(4))
                    while !presented, picker.presentingViewController == nil, picker.viewIfLoaded?.window == nil,
                          clock.now < presentationDeadline {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if !presented, picker.presentingViewController == nil, picker.viewIfLoaded?.window == nil {
                        onError("系统选择器未能打开，请重试。")
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            onError("页面已离开或暂时无法打开选择器，请重试。")
        }
        return true
    }
}

// Presents the system file picker straight from UIKit. SwiftUI's .fileImporter
// does not nest: inside Settings, which already has one for .json backups, a
// second importer opened with the outer one's file types, so a folder or a font
// could never be accepted and "打开" did nothing.
@MainActor
enum DocumentPicker {
    private static var current: Coordinator?

    // asCopy hands over a private copy instead of the original, for files that are
    // only read once (a novel to import) and may still be downloading from a cloud drive.
    @discardableResult
    static func present(_ types: [UTType], asCopy: Bool = false,
                        onCancel: (() -> Void)? = nil, onError: ((String) -> Void)? = nil,
                        pick: @escaping (URL) -> Void) -> Bool {
        show(types, asCopy: asCopy, multiple: false, onCancel: onCancel, onError: onError) { urls in
            if let url = urls.first { pick(url) }
        }
    }

    // With multiple selection the picker shows a circle on every file and a confirm
    // button, which is what people expect; a single-file tap did not pick on every system.
    @discardableResult
    static func presentMany(_ types: [UTType], asCopy: Bool = false, window: UIWindow? = nil,
                            onCancel: (() -> Void)? = nil, onError: ((String) -> Void)? = nil,
                            pick: @escaping ([URL]) -> Void) -> Bool {
        show(types, asCopy: asCopy, multiple: true, window: window, onCancel: onCancel, onError: onError, pick: pick)
    }

    // A folder is chosen with the tick beside it plus 「打开」, the same way as files. In
    // single-choice mode the picker only lets you tap into a folder, and on recent iOS
    // 「打开」 often stayed grey even inside it, so no folder could ever be chosen.
    @discardableResult
    static func presentFolder(onCancel: (() -> Void)? = nil, onError: ((String) -> Void)? = nil,
                              pick: @escaping (URL) -> Void) -> Bool {
        show([.folder], asCopy: false, multiple: true, onCancel: onCancel, onError: onError) { urls in
            if let url = urls.first { pick(url) }
        }
    }

    // Native "Save to Files" exporter: lets the user navigate INSIDE any folder and tap
    // top-right 「存储」 (Save), avoiding the folder-open picker's greyed-out files confusion.
    @discardableResult
    static func presentExport(_ fileURL: URL, onCancel: (() -> Void)? = nil,
                              onError: ((String) -> Void)? = nil,
                              onSaved: ((URL) -> Void)? = nil) -> Bool {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        return open(picker, onCancel: onCancel, onError: onError) { urls in
            if let url = urls.first { onSaved?(url) }
        }
    }

    private static func show(_ types: [UTType], asCopy: Bool, multiple: Bool, window: UIWindow? = nil,
                             onCancel: (() -> Void)?, onError: ((String) -> Void)?,
                             pick: @escaping ([URL]) -> Void) -> Bool {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.allowsMultipleSelection = multiple
        return open(picker, window: window, onCancel: onCancel, onError: onError, pick: pick)
    }

    private static func open(_ picker: UIDocumentPickerViewController, window: UIWindow? = nil,
                             onCancel: (() -> Void)?, onError: ((String) -> Void)?,
                             pick: @escaping ([URL]) -> Void) -> Bool {
        guard current == nil else { onError?("文件选择器已经打开。"); return false }
        let coordinator = Coordinator(pick: pick, cancel: onCancel)
        coordinator.picker = picker
        picker.delegate = coordinator
        picker.shouldShowFileExtensions = true
        current = coordinator
        return SystemPickerPresentation.open(picker, window: window, onError: { issue in
            if current === coordinator { current = nil }
            onCancel?()
            onError?(issue)
        }) { coordinator.startDismissWatchdog() }
    }

    @MainActor private final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let pick: ([URL]) -> Void
        let cancel: (() -> Void)?
        weak var picker: UIDocumentPickerViewController?
        private var completed = false
        private var watchdogTask: Task<Void, Never>?
        init(pick: @escaping ([URL]) -> Void, cancel: (() -> Void)?) { self.pick = pick; self.cancel = cancel }

        func startDismissWatchdog() {
            watchdogTask = Task { @MainActor [weak self] in
                while let self, !self.completed {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !self.completed else { break }
                    if self.picker == nil || (self.picker?.presentingViewController == nil && self.picker?.isBeingPresented == false) {
                        self.finish(nil, urls: [])
                        break
                    }
                }
            }
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(controller, urls: urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(controller, urls: [])
        }
        private func finish(_ controller: UIViewController?, urls: [URL]) {
            guard !completed else { return }
            completed = true
            watchdogTask?.cancel()
            watchdogTask = nil
            // UIDocumentPickerViewController dismisses itself when the user taps Open/Cancel.
            // Calling controller.dismiss(completion:) while UIKit is already dismissing it causes
            // UIKit to drop the completion callback. Instead, wait briefly for dismissal to settle
            // and then unconditionally invoke the callback on the main actor.
            Task { @MainActor [self] in
                for _ in 0..<20 {
                    guard let controller, controller.presentingViewController != nil else { break }
                    if !controller.isBeingDismissed {
                        controller.dismiss(animated: true)
                    }
                    try? await Task.sleep(for: .milliseconds(35))
                }
                if DocumentPicker.current === self { DocumentPicker.current = nil }
                if urls.isEmpty { cancel?() } else { pick(urls) }
            }
        }
    }
}
