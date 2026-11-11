import SwiftUI
import UIKit

// A real UIKit input accessory gives UI tests a deterministic taller keyboard.
// Normal app launches always use the regular SwiftUI text field instead.
@MainActor
struct PreviewKeyboardField: UIViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    let focusChanged: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let field = UITextView()
        field.font = UIFont(name: "NotoSerifSC-Regular", size: 17) ?? .systemFont(ofSize: 17)
        field.textColor = UIColor(Ink.ink)
        field.backgroundColor = .clear
        field.textContainerInset = .zero
        field.textContainer.lineFragmentPadding = 0
        field.delegate = context.coordinator
        field.accessibilityIdentifier = "chat-composer"
        context.coordinator.installAccessory(on: field)
        return field
    }
    func updateUIView(_ field: UITextView, context: Context) {
        context.coordinator.owner = self
        if field.text != text { field.text = text }
        if isFocused && !field.isFirstResponder {
            DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
                if coordinator?.owner.isFocused == true { field?.becomeFirstResponder() }
            }
        } else if !isFocused && field.isFirstResponder { field.resignFirstResponder() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 340
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(max(25, height), (uiView.font?.lineHeight ?? 25) * 5))
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var owner: PreviewKeyboardField
        private var expanded = false
        init(_ owner: PreviewKeyboardField) { self.owner = owner }
        func installAccessory(on field: UITextView) {
            let accessory = PreviewKeyboardAccessory(height: expanded ? 180 : 100)
            accessory.changed = { [weak self, weak field] in
                guard let self, let field else { return }
                self.expanded.toggle()
                self.installAccessory(on: field)
                field.reloadInputViews()
            }
            field.inputAccessoryView = accessory
        }
        func textViewDidChange(_ textView: UITextView) { owner.text = textView.text }
        func textViewDidBeginEditing(_ textView: UITextView) { owner.focusChanged(true) }
        func textViewDidEndEditing(_ textView: UITextView) { owner.focusChanged(false) }
    }
}

@MainActor
private final class PreviewKeyboardAccessory: UIInputView {
    var changed: (() -> Void)?
    private let desiredHeight: CGFloat
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: desiredHeight) }
    init(height: CGFloat) {
        desiredHeight = height
        super.init(frame: CGRect(x: 0, y: 0, width: 402, height: height), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        accessibilityIdentifier = "preview-keyboard-accessory"
        backgroundColor = .secondarySystemBackground
        heightAnchor.constraint(equalToConstant: height).isActive = true
        let marker = UIView()
        marker.isAccessibilityElement = true
        marker.accessibilityIdentifier = "preview-keyboard-top"
        marker.accessibilityLabel = "测试键盘上边缘"
        marker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(marker)
        NSLayoutConstraint.activate([
            marker.topAnchor.constraint(equalTo: topAnchor),
            marker.leadingAnchor.constraint(equalTo: leadingAnchor),
            marker.widthAnchor.constraint(equalToConstant: 2),
            marker.heightAnchor.constraint(equalToConstant: 2)
        ])
        let button = UIButton(type: .system)
        button.setTitle("加高测试键盘", for: .normal)
        button.accessibilityIdentifier = "expand-preview-keyboard"
        button.addTarget(self, action: #selector(expand), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func expand() {
        changed?()
    }
}
