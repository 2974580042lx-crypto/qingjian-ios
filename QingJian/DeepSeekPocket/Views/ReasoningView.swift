import SwiftUI

// Thinking, after the Claude app: one quiet pill in the conversation, and the
// full thinking in a half-height sheet, laid out as a timeline of paragraphs.
enum ThinkingSteps {
    static func split(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    // Longer paragraphs are cut to four lines in the timeline and open in full.
    static func isLong(_ step: String) -> Bool { step.count > 70 }
}

// Holds no store, so finished messages do not redraw while another answer streams.
struct ThinkingRow: View {
    let message: ChatMessage
    let open: () -> Void
    private var live: Bool { message.state == .streaming && message.content.isEmpty }
    private var snippet: String {
        let tail = String(message.reasoning.suffix(400))
        let last = tail.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.last { !$0.isEmpty } ?? ""
        return String((last.components(separatedBy: .newlines).first ?? last).prefix(80))
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                ThinkingMark(live: live, size: 15)
                if live {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        line(head: "思考中 · \(max(0, Int(timeline.date.timeIntervalSince(message.createdAt)))) 秒")
                    }
                } else {
                    line(head: message.thinkingSeconds.map { "已思考 \($0) 秒" } ?? "思考过程")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Ink.seal.opacity(0.75))
            }
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Ink.raised, in: InkCapsule())
            .overlay(InkCapsule().stroke(Ink.seal.opacity(live ? 0.30 : 0.14), lineWidth: 0.8))
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(live ? "正在思考，打开思考过程" : "打开思考过程")
        .accessibilityIdentifier("thinking-row")
    }

    private func line(head: String) -> some View {
        Text(head).foregroundStyle(Ink.ink2).monospacedDigit()
    }
}

/// Sermo's thinking mark: five small terracotta petals round a seed.
struct ThinkingMark: View {
    var live: Bool
    var size: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false
    private var animated: Bool { live && !reduceMotion }

    var body: some View {
        let dot = size * 0.26
        let ring = size * 0.34
        ZStack {
            ForEach(0..<5, id: \.self) { index in
                Circle().fill(Ink.seal)
                    .frame(width: dot, height: dot)
                    .scaleEffect(animated && moving ? 0.72 : 1)
                    .opacity(animated && moving ? 0.6 : 0.9)
                    .animation(animated
                               ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(Double(index) * 0.18)
                               : .easeOut(duration: 0.3), value: moving)
                    .offset(y: -ring)
                    .rotationEffect(.degrees(Double(index) * 72))
            }
            Circle().fill(Ink.seal).frame(width: dot * 0.7, height: dot * 0.7)
        }
        .rotationEffect(.degrees(animated && moving ? 360 : 0))
        .animation(animated ? .linear(duration: 5.2).repeatForever(autoreverses: false) : .easeOut(duration: 0.3), value: moving)
        .frame(width: size, height: size)
        .onAppear { if animated { moving = true } }
        .onChange(of: animated) { _, now in moving = now }
        .accessibilityHidden(true)
    }
}

struct ThinkingTarget: Identifiable, Equatable {
    let threadID: UUID
    let messageID: UUID
    var id: UUID { messageID }
}

@MainActor
struct ThinkingSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let target: ThinkingTarget
    @State private var display: Display = ProcessInfo.processInfo.arguments.contains("--preview-reasoning-bilingual") ? .bilingual : .translated
    private enum Display: String, CaseIterable { case original = "原文", translated = "中文", bilingual = "双语" }
    private var message: ChatMessage? {
        store.threads.first(where: { $0.id == target.threadID })?.messages.first(where: { $0.id == target.messageID })
    }
    private var busy: Bool { store.isTranslating(threadID: target.threadID, messageID: target.messageID) }

    var body: some View {
        NavigationStack {
            Group {
                if let stored = message {
                  LiveMessageRow(live: store.live, message: stored) { message in
                    let live = message.state == .streaming && message.content.isEmpty
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if message.state != .streaming { tools(message) }
                            content(message, live: live)
                        }
                        .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 32)
                    }
                    .background(Ink.paper)
                    .defaultScrollAnchor(live ? .bottom : nil, for: .sizeChanges)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Text(status(message, live: live)).font(TypeScale.tiny).foregroundStyle(Ink.ink3).monospacedDigit()
                        }
                    }
                  }
                } else {
                    Text("这条回答已经不在了。").font(TypeScale.caption).foregroundStyle(Ink.ink3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Ink.paper)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭思考过程")
                }
                ToolbarItem(placement: .principal) {
                    Text("思考过程").font(TypeScale.serif(17).weight(.semibold)).foregroundStyle(Ink.ink)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ThinkingStepPage.self) { page in
                ScrollView {
                    Text(page.text).readingStyle(adjustment: -2).lineSpacing(7).foregroundStyle(Ink.ink)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.vertical, 10)
                }
                .background(Ink.paper)
                .navigationTitle("第 \(page.index + 1) 段").navigationBarTitleDisplayMode(.inline)
            }
        }
        .tint(Ink.ink)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("thinking-sheet")
        .onChange(of: message?.reasoningTranslation) { old, new in
            if old == nil && new != nil { display = .translated }
        }
    }

    private func status(_ message: ChatMessage, live: Bool) -> String {
        if live { return "思考中" }
        return message.thinkingSeconds.map { "已思考 \($0) 秒" } ?? ""
    }

    @ViewBuilder private func tools(_ message: ChatMessage) -> some View {
        HStack(spacing: 12) {
            if message.reasoningTranslation != nil {
                Picker("显示方式", selection: $display) {
                    ForEach(Display.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 220)
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.mini)
                Text("翻译中")
                Button("取消") { store.cancelTranslation() }
            } else if message.reasoningTranslation == nil {
                Button {
                    store.translateReasoning(threadID: target.threadID, messageID: target.messageID)
                } label: {
                    Label(store.translationError(threadID: target.threadID, messageID: target.messageID) == nil ? "翻译" : "重试", systemImage: "translate")
                }
                .disabled(store.isTranslating || !store.canPersist)
                .accessibilityLabel("将思考过程翻译成中文")
            }
        }
        .font(TypeScale.caption).foregroundStyle(Ink.ink3).buttonStyle(.plain)
        .frame(minHeight: 36).padding(.bottom, 14)
        if let error = store.translationError(threadID: target.threadID, messageID: target.messageID) {
            Text(error).font(TypeScale.tiny).foregroundStyle(Ink.ink3).padding(.bottom, 12)
        }
    }

    @ViewBuilder private func content(_ message: ChatMessage, live: Bool) -> some View {
        if let translated = message.reasoningTranslation, display != .original {
            if display == .bilingual {
                caption("原文")
                ThinkingTimeline(steps: ThinkingSteps.split(message.reasoning), live: false)
                caption("中文译文").padding(.top, 8)
            }
            ThinkingTimeline(steps: ThinkingSteps.split(translated), live: false)
        } else {
            ThinkingTimeline(steps: ThinkingSteps.split(message.reasoning), live: live)
        }
    }

    private func caption(_ value: String) -> some View {
        Text(value).font(TypeScale.tiny.weight(.medium)).foregroundStyle(Ink.ink2).padding(.bottom, 10)
    }
}

struct ThinkingStepPage: Hashable {
    let index: Int
    let text: String
}

// Paragraphs joined by a hairline down the left, each with a small terracotta dot.
struct ThinkingTimeline: View {
    let steps: [String]
    let live: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let last = index == steps.count - 1
                Group {
                    if ThinkingSteps.isLong(step) {
                        NavigationLink(value: ThinkingStepPage(index: index, text: step)) { row(step, last: last, chevron: true) }
                    } else {
                        row(step, last: last, chevron: false)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thinking-timeline")
    }

    private func row(_ step: String, last: Bool, chevron: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if live && last { PulseDot(size: 9) } else { Circle().fill(Ink.seal.opacity(0.36)).frame(width: 8, height: 8) }
            }
            .frame(width: 9).padding(.top, 8)
            Text(step).font(TypeScale.serif(15)).lineSpacing(6).foregroundStyle(Ink.ink)
                .lineLimit(4).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.ink3)
                    .padding(.top, 8)
            }
        }
        .padding(.bottom, last ? 0 : 20)
        .background(alignment: .topLeading) {
            if !last { Rectangle().fill(Ink.line).frame(width: 1).padding(.top, 20).padding(.leading, 4) }
        }
        .contentShape(Rectangle())
    }
}
