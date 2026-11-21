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
    let dismiss: () -> Void

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
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .background(Ink.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Ink.line, lineWidth: 0.6))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .contain)
    }
}
