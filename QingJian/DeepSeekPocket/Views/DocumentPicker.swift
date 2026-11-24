import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Owned by the screen that requested the picker. The next action runs only after
/// SwiftUI has finished dismissing the sheet, including an interactive cancellation.
@MainActor
final class DocumentPicker: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let content: AnyView
    }
    @Published fileprivate var request: Request?
    @Published fileprivate var cameraRequest: Request?
    private var afterDismiss: (() -> Void)?
    private var active = false

    private func open(onCancel: (() -> Void)?, onError: ((String) -> Void)?,
                      fullscreen: Bool = false, content: () -> AnyView) -> Bool {
        guard !active else { onError?("请先完成当前选择。"); return false }
        active = true
        afterDismiss = onCancel
        let next = Request(content: content())
        if fullscreen { cameraRequest = next } else { request = next }
        return true
    }

    private func finish(_ action: (() -> Void)? = nil) {
        guard request != nil || cameraRequest != nil else { return }
        if let action { afterDismiss = action }
        request = nil
        cameraRequest = nil
    }

    fileprivate func dismissed() {
        let action = afterDismiss
        afterDismiss = nil
        active = false
        action?()
    }

    @discardableResult
    func present(_ types: [UTType], asCopy: Bool = false,
                 onCancel: (() -> Void)? = nil, onError: ((String) -> Void)? = nil,
                 pick: @escaping (URL) -> Void) -> Bool {
        files(UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy),
              multiple: false, onCancel: onCancel, onError: onError) { urls in
            if let first = urls.first { pick(first) }
        }
    }

    @discardableResult
    func presentMany(_ types: [UTType], asCopy: Bool = false,
                     onCancel: (() -> Void)? = nil, onError: ((String) -> Void)? = nil,
                     pick: @escaping ([URL]) -> Void) -> Bool {
        files(UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy),
              multiple: true, onCancel: onCancel, onError: onError, pick: pick)
    }

    @discardableResult
    func presentFolder(onCancel: (() -> Void)? = nil, onError: ((String) -> Void)? = nil,
                       pick: @escaping (URL) -> Void) -> Bool {
        presentMany([.folder], onCancel: onCancel, onError: onError) { urls in
            if let first = urls.first { pick(first) }
        }
    }

    @discardableResult
    func presentExport(_ fileURL: URL, onCancel: (() -> Void)? = nil,
                       onError: ((String) -> Void)? = nil, onSaved: ((URL) -> Void)? = nil) -> Bool {
        files(UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true),
              multiple: false, onCancel: onCancel, onError: onError) { urls in
            if let first = urls.first { onSaved?(first) }
        }
    }

    private func files(_ controller: UIDocumentPickerViewController, multiple: Bool,
                       onCancel: (() -> Void)?, onError: ((String) -> Void)?,
                       pick: @escaping ([URL]) -> Void) -> Bool {
        open(onCancel: onCancel, onError: onError) {
            controller.allowsMultipleSelection = multiple
            controller.shouldShowFileExtensions = true
            return AnyView(FileSheet(controller: controller) { [weak self] urls in
                if urls.isEmpty { self?.finish() } else { self?.finish { pick(urls) } }
            }.ignoresSafeArea())
        }
    }

    @discardableResult
    func photos(limit: Int, onError: @escaping (String) -> Void,
                picked: @escaping ([PHPickerResult]) -> Void) -> Bool {
        open(onCancel: { picked([]) }, onError: onError) {
            AnyView(ChatPhotoLibrarySheet(limit: limit) { [weak self] results in
                self?.finish { picked(results) }
            }.ignoresSafeArea())
        }
    }

    func camera(onError: @escaping (String) -> Void, picked: @escaping (UIImage) -> Void) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            onError("当前设备没有可用相机，请选择照片。")
            return
        }
        _ = open(onCancel: nil, onError: onError, fullscreen: true) {
            AnyView(CameraSheet { [weak self] image in
                if let image { self?.finish { picked(image) } } else { self?.finish() }
            }.ignoresSafeArea())
        }
    }
}

private struct FileSheet: UIViewControllerRepresentable {
    let controller: UIDocumentPickerViewController
    let selected: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: ([URL]) -> Void
        init(selected: @escaping ([URL]) -> Void) { self.selected = selected }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { selected(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { selected([]) }
    }
}

private struct CameraSheet: UIViewControllerRepresentable {
    let selected: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.mediaTypes = ["public.image"]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    @MainActor final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let selected: (UIImage?) -> Void
        init(selected: @escaping (UIImage?) -> Void) { self.selected = selected }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { selected(nil) }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            selected(info[.originalImage] as? UIImage)
        }
    }
}

private struct SystemPickerModifier: ViewModifier {
    @ObservedObject var picker: DocumentPicker
    func body(content: Content) -> some View {
        content
            .sheet(item: $picker.request, onDismiss: picker.dismissed) { $0.content }
            .fullScreenCover(item: $picker.cameraRequest, onDismiss: picker.dismissed) { $0.content }
    }
}

extension View {
    func systemPickerHost(_ picker: DocumentPicker) -> some View { modifier(SystemPickerModifier(picker: picker)) }
}
