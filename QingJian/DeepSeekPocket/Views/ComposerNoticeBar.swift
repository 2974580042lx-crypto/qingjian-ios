import SwiftUI

// A single quiet line that sits right on top of the composer, the way Claude shows
// 「记忆已更新。查看记忆 ×」: plain words, one underlined action, a small close mark.
// No icon, no colour, no capsule.
struct ComposerNoticeBar: View {
    let text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var secondTitle: String? = nil
    var second: (() -> Void)? = nil
    /// Without it the line has no close mark (it goes away on its own).
    var dismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Group {
                Text(text).foregroundStyle(Ink.ink2)
                if let actionTitle, let action {
                    Button(action: { Haptic.tap(); action() }) {
                        Text(actionTitle).underline().foregroundStyle(Ink.ink)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 6)
                }
                if let secondTitle, let second {
                    Button(action: { Haptic.tap(); second() }) {
                        Text(secondTitle).underline().foregroundStyle(Ink.ink)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 10)
                }
            }
            .font(TypeScale.ui(14.5, relativeTo: .subheadline))
            .lineLimit(2)
            Spacer(minLength: 10)
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Ink.ink3)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, dismiss == nil ? 16 : 6)
        .padding(.vertical, 10)
        .background(Ink.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Ink.line, lineWidth: 0.6))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .contain)
    }
}

extension View {
    func inlineFeedback(_ message: String?, dismiss: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if let message {
                HStack(alignment: .top) {
                    ViewThatFits(in: .vertical) {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                        ScrollView { Text(message).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: 112, alignment: .leading)
                    Button(action: dismiss) { Image(systemName: "xmark").padding(6) }
                        .buttonStyle(.plain).accessibilityLabel("关闭提示")
                }
                .font(.footnote)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }
        }
    }

    func inlineName(_ title: String, shown: Binding<Bool>, text: Binding<String>,
                    placeholder: String, submit: String, save: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom) {
            if shown.wrappedValue {
                VStack(alignment: .leading) {
                    Text(title).font(.headline)
                    TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("取消") { shown.wrappedValue = false }
                        Button(submit) { save(); shown.wrappedValue = false }
                    }
                }.padding().background(.regularMaterial)
            }
        }
    }
}
