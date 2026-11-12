import UIKit
import UniformTypeIdentifiers

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
    static func presentMany(_ types: [UTType], asCopy: Bool = false,
                            onCancel: (() -> Void)? = nil, onError: ((String) -> Void)? = nil,
                            pick: @escaping ([URL]) -> Void) -> Bool {
        show(types, asCopy: asCopy, multiple: true, onCancel: onCancel, onError: onError, pick: pick)
    }

    @discardableResult
    static func presentFolder(onCancel: (() -> Void)? = nil, onError: ((String) -> Void)? = nil,
                              pick: @escaping (URL) -> Void) -> Bool {
        show([.folder], asCopy: false, multiple: false, onCancel: onCancel, onError: onError) { urls in
            if let url = urls.first { pick(url) }
        }
    }

    private static func show(_ types: [UTType], asCopy: Bool, multiple: Bool,
                             onCancel: (() -> Void)?, onError: ((String) -> Void)?,
                             pick: @escaping ([URL]) -> Void) -> Bool {
        if let open = current, open.picker == nil || (open.picker?.presentingViewController == nil && open.picker?.isBeingPresented == false) {
            current = nil
            open.cancel?()
        }
        guard current == nil else { onError?("文件选择器已经打开，请先完成或取消当前选择。"); return false }
        if let top = topViewController(), top.viewIfLoaded?.window != nil, !top.isBeingPresented, !top.isBeingDismissed {
            presentNow(on: top, types: types, asCopy: asCopy, multiple: multiple, onCancel: onCancel, pick: pick)
            return true
        }
        // When triggered from a Menu item, the context menu's dismissal is still in flight for ~150ms.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard current == nil, let top = topViewController(), top.viewIfLoaded?.window != nil,
                  !top.isBeingPresented, !top.isBeingDismissed else {
                onCancel?()
                onError?("当前页面还在切换，暂时无法打开文件选择器，请稍后再试。")
                return
            }
            presentNow(on: top, types: types, asCopy: asCopy, multiple: multiple, onCancel: onCancel, pick: pick)
        }
        return true
    }

    private static func presentNow(on top: UIViewController, types: [UTType], asCopy: Bool, multiple: Bool,
                                   onCancel: (() -> Void)?, pick: @escaping ([URL]) -> Void) {
        let coordinator = Coordinator(pick: pick, cancel: onCancel)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.allowsMultipleSelection = multiple
        picker.delegate = coordinator
        picker.shouldShowFileExtensions = true
        coordinator.picker = picker
        current = coordinator
        top.view.endEditing(true)
        top.present(picker, animated: true) {
            coordinator.startDismissWatchdog()
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
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
