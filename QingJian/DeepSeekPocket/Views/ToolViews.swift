import SwiftUI
import UIKit

// One quiet line per tool the answer used: what it did and how it went.
struct ToolActivityList: View {
    let items: [ToolActivity]
    let signIn: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(items) { item in
                HStack(alignment: .center, spacing: 8) {
                    icon(for: item.status).frame(width: 15, height: 15)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(item.status == .running ? Ink.seal : Ink.ink2)
                            .lineLimit(2)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Ink.ink3)
                                .lineLimit(2)
                        }
                        if item.status == .needsSignIn && item.kind != "github" {
                            Button("登录谷歌云盘", action: signIn)
                                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.seal)
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(Ink.paper, in: InkCapsule())
                                .buttonStyle(.plain)
                                .padding(.top, 2)
                        }
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6.5)
                .background(Ink.raised, in: InkRounded(radius: 12))
                .overlay(InkRounded(radius: 12).stroke(Ink.seal.opacity(item.status == .running ? 0.30 : 0.14), lineWidth: 0.8))
                .accessibilityElement(children: .combine)
                if let report = item.studyReport {
                    DisclosureGroup("学习周报 · 第\(report.revision)版快照") {
                        Text(report.text).font(TypeScale.body).foregroundStyle(Ink.ink).textSelection(.enabled)
                        Text("生成于 \(report.createdAt.formatted(date: .abbreviated, time: .shortened))。后续记录有变化时，请在项目记忆页生成最新报告。")
                            .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                    }
                    .font(TypeScale.caption).tint(Ink.ink)
                }
                if item.status == .done, let excerpts = item.studyExcerpts {
                    ForEach(Array(excerpts.enumerated()), id: \.offset) { _, excerpt in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("资料原文 · " + excerpt.title).font(TypeScale.caption.weight(.semibold)).foregroundStyle(Ink.seal)
                            Text(excerpt.text).font(TypeScale.body).foregroundStyle(Ink.ink).textSelection(.enabled)
                            Text(excerpt.source).font(TypeScale.caption).foregroundStyle(Ink.ink3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .background(Ink.raised, in: InkRounded(radius: 14))
                        .overlay(InkRounded(radius: 14).stroke(Ink.seal.opacity(0.25), lineWidth: 1))
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("tool-activity")
    }

    @ViewBuilder private func icon(for status: ToolActivity.Status) -> some View {
        switch status {
        case .running: ProgressView().controlSize(.mini).tint(Ink.seal)
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Ink.seal)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Ink.seal)
        case .declined: Image(systemName: "hand.raised").font(.system(size: 12)).foregroundStyle(Ink.ink3)
        case .needsSignIn: Image(systemName: "person.crop.circle.badge.exclamationmark").font(.system(size: 12)).foregroundStyle(Ink.seal)
        }
    }
}

// Asks before the model changes anything in Drive. Shows exactly what would happen.
struct ToolApprovalSheet: View {
    let approval: ToolApproval
    let answer: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sermo 想要").font(TypeScale.caption).foregroundStyle(Ink.ink3)
            Text(approval.title).font(TypeScale.heavy(20, relativeTo: .title3)).foregroundStyle(Ink.ink)
            if !approval.detail.isEmpty {
                ScrollView {
                    Text(approval.detail).font(TypeScale.serif(14)).foregroundStyle(Ink.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .padding(14)
                }
                .background(Ink.raised, in: InkRounded(radius: 16))
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button { answer(false) } label: {
                    Text("不允许").frame(maxWidth: .infinity).frame(height: 50)
                        .background(Ink.raised, in: InkCapsule())
                }
                .accessibilityIdentifier("tool-decline")
                Button { answer(true) } label: {
                    Text("允许").foregroundStyle(Ink.onSolid).frame(maxWidth: .infinity).frame(height: 50)
                        .background(Ink.solid, in: InkCapsule())
                }
                .accessibilityIdentifier("tool-allow")
            }
            .font(TypeScale.serif(16).weight(.semibold)).foregroundStyle(Ink.ink).buttonStyle(.plain)
        }
        .padding(22)
        .background(Ink.paper)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// The whole message as selectable text, for copying part of an answer.
struct SelectableTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("qingjian.reading.size") private var size = 17.0
    // Markdown marks (**, #) are dropped so what you copy is the words themselves.
    private var plain: String {
        let rendered = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return String(rendered.characters)
    }
    var body: some View {
        NavigationStack {
            // A real text view: SwiftUI's text selection only copies a whole block on
            // iPhone, so part of an answer could never be picked out before.
            SelectableTextView(text: plain, size: size)
                .background(Ink.paper)
                .navigationTitle("选择文字")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("全部复制") { UIPasteboard.general.string = plain; dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
                }
        }
        .presentationDragIndicator(.visible)
    }
}

/// Read-only text with the system's handles: press and drag to pick any part, then 「拷贝」.
struct SelectableTextView: UIViewRepresentable {
    let text: String
    var size: Double = 18
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 32, right: 16)
        view.alwaysBounceVertical = true
        view.dataDetectorTypes = []
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let font: UIFont = FontLibrary.usesSystemFace
            ? UIFont.systemFont(ofSize: size)
            : (UIFont(name: FontLibrary.regularFace, size: size) ?? UIFont.systemFont(ofSize: size))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFontMetrics(forTextStyle: .body).scaledFont(for: font),
            .foregroundColor: UIColor(Ink.ink), .paragraphStyle: paragraph
        ])
        if view.attributedText != attributed { view.attributedText = attributed }
        view.tintColor = UIColor(Ink.seal)
    }
}
