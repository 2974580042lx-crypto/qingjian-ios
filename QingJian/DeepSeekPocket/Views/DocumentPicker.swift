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

    private static func show(_ types: [UTType], asCopy: Bool, multiple: Bool,
                             onCancel: (() -> Void)?, onError: ((String) -> Void)?,
                             pick: @escaping ([URL]) -> Void) -> Bool {
        // A picker closed without telling us (swiped away mid-transition) must not block the next one.
        if let open = current, open.picker?.presentingViewController == nil { current = nil; open.cancel?() }
        guard current == nil else { onError?("文件选择器已经打开，请先完成或取消当前选择。"); return false }
        guard let top = topViewController(), top.viewIfLoaded?.window != nil,
              !top.isBeingPresented, !top.isBeingDismissed else {
            onError?("当前页面还在切换，暂时无法打开文件选择器，请稍后再试。")
            return false
        }
        let coordinator = Coordinator(pick: pick, cancel: onCancel)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.allowsMultipleSelection = multiple
        picker.delegate = coordinator
        picker.shouldShowFileExtensions = true
        coordinator.picker = picker
        current = coordinator
        top.view.endEditing(true)
        // The picker keeps its own presentation delegate; replacing it could leave 「打开」 unusable.
        top.present(picker, animated: true)
        return true
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes.filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    @MainActor private final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let pick: ([URL]) -> Void
        let cancel: (() -> Void)?
        weak var picker: UIDocumentPickerViewController?
        private var completed = false
        init(pick: @escaping ([URL]) -> Void, cancel: (() -> Void)?) { self.pick = pick; self.cancel = cancel }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(controller, urls: urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(controller, urls: [])
        }
        private func finish(_ controller: UIViewController?, urls: [URL]) {
            guard !completed else { return }
            completed = true
            let deliver = { [self] in
                if DocumentPicker.current === self { DocumentPicker.current = nil }
                if urls.isEmpty { cancel?() } else { pick(urls) }
            }
            if let controller, controller.presentingViewController != nil {
                controller.dismiss(animated: true, completion: deliver)
            } else {
                deliver()
            }
        }
    }
}
