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
                // The flower breathes while it thinks, and slows to rest, grey, when it is done.
                ThinkingMark(live: live, size: 14, tint: live ? Ink.seal : Ink.ink3.opacity(0.8))
                if live {
                    line(head: snippet.isEmpty ? "正在思考…" : snippet)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .shimmering()
                        .transition(.opacity)
                } else {
                    line(head: message.thinkingSeconds.map { "已思考 \($0) 秒" } ?? "思考过程")
                        .transition(.opacity)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(Ink.ink3.opacity(0.75))
            }
            .font(.system(size: 13.5, weight: .regular))
            .padding(.vertical, 3)
            .frame(minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressFeedback)
        .animation(Motion.fade.motionSafe, value: live)
        .accessibilityLabel(live ? "正在思考，打开思考过程" : "打开思考过程")
        .accessibilityIdentifier("thinking-row")
    }

    private func line(head: String) -> some View {
        Text(head).foregroundStyle(Ink.ink3).monospacedDigit()
    }
}

/// Sermo's mark: five small terracotta petals round a seed (the app icon's flower).
///
/// 1.47: drawn in a Canvas from a clock, so it can do more than spin.
/// - While `live`, a breath runs round the petals one after another and the flower turns slowly.
/// - When `live` ends, the turning slows to a stop and the petals settle back to full size,
///   instead of snapping still.
/// - With `blooms`, it unfolds once when it appears: the seed first, then each petal out from
///   the middle with a little overshoot.
struct ThinkingMark: View {
    var live: Bool
    var size: CGFloat = 18
    var blooms = false
    var tint: Color = Ink.seal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var born = Date()
    @State private var stoppedAt: Date?
    @State private var restAngle: Double = 0
    // Bumped once the flower is at rest, so the clock below stops ticking.
    @State private var restTick = 0

    private static let turn: Double = 360 / 5.6        // degrees a second while thinking
    private static let settle: Double = 0.42            // seconds to come to rest
    private static let bloom: Double = 0.95             // seconds to unfold

    var body: some View {
        let _ = restTick
        Group {
            if reduceMotion {
                canvas(at: Date(), still: true)
            } else if needsClock {
                TimelineView(.animation) { frame in canvas(at: frame.date) }
            } else {
                canvas(at: Date())
            }
        }
        .frame(width: size, height: size)
        .onChange(of: live) { _, now in
            let at = Date()
            if now {
                // Pick up turning from where it stopped.
                restAngle = angle(at: at)
                stoppedAt = nil
                born = at.addingTimeInterval(-restAngle / Self.turn)
            } else {
                restAngle = angle(at: at)
                stoppedAt = at
            }
        }
        // Stop the clock once the flower is at rest.
        .task(id: TaskKey(live: live, stopped: stoppedAt, blooms: blooms)) {
            guard !live else { return }
            let remaining = max(blooms ? Self.bloom - Date().timeIntervalSince(born) : 0,
                                stoppedAt.map { Self.settle - Date().timeIntervalSince($0) } ?? 0)
            guard remaining > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64((remaining + 0.05) * 1_000_000_000))
            if !Task.isCancelled { restTick &+= 1 }
        }
        .accessibilityHidden(true)
    }

    private struct TaskKey: Equatable { let live: Bool; let stopped: Date?; let blooms: Bool }

    private var needsClock: Bool {
        if live { return true }
        let now = Date()
        if blooms && now.timeIntervalSince(born) < Self.bloom { return true }
        if let stoppedAt, now.timeIntervalSince(stoppedAt) < Self.settle { return true }
        return false
    }

    /// 1 while thinking, easing to 0 as it comes to rest.
    private func liveness(at date: Date) -> Double {
        if live { return 1 }
        guard let stoppedAt else { return 0 }
        let d = date.timeIntervalSince(stoppedAt) / Self.settle
        return d >= 1 ? 0 : (1 - d) * (1 - d)
    }

    private func angle(at date: Date) -> Double {
        if live { return date.timeIntervalSince(born) * Self.turn }
        guard let stoppedAt else { return restAngle }
        // Decelerate evenly to a stop over `settle`.
        let d = min(Self.settle, max(0, date.timeIntervalSince(stoppedAt)))
        return restAngle + Self.turn * (d - d * d / (2 * Self.settle))
    }

    private func canvas(at date: Date, still: Bool = false) -> some View {
        let t: Double = still ? 10 : date.timeIntervalSince(born)
        let alive: Double = still ? 0 : liveness(at: date)
        let rotation: Double = still ? 0 : angle(at: date)
        return Canvas { context, canvasSize in
            let side = min(canvasSize.width, canvasSize.height)
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let dot: CGFloat = side * 0.26
            let ring: CGFloat = side * 0.34
            // The seed, a touch smaller, arrives first when blooming.
            let seedGrow: CGFloat = blooms ? Self.overshoot(t / 0.32) : 1
            let seed: CGFloat = dot * 0.7 * seedGrow
            if seed > 0.1 {
                context.fill(Path(ellipseIn: CGRect(x: center.x - seed / 2, y: center.y - seed / 2, width: seed, height: seed)),
                             with: .color(tint))
            }
            for index in 0..<5 {
                let grow: CGFloat = blooms ? Self.overshoot((t - 0.12 - Double(index) * 0.07) / 0.62) : 1
                guard grow > 0.01 else { continue }
                // A breath running round the ring: each petal a fifth of a cycle behind.
                let phase: Double = (t / 1.25 - Double(index) / 5).truncatingRemainder(dividingBy: 1)
                let breath: Double = 0.5 - 0.5 * cos(phase * 2 * Double.pi)
                let shrink = CGFloat(1 - 0.30 * breath * alive)
                let opacity: Double = 0.92 - 0.38 * breath * alive
                let theta: Double = (rotation + Double(index) * 72 - 90) * Double.pi / 180
                let swell = CGFloat(1 + 0.06 * breath * alive)
                let reach: CGFloat = ring * min(CGFloat(1.08), grow) * swell
                let x: CGFloat = center.x + CGFloat(cos(theta)) * reach
                let y: CGFloat = center.y + CGFloat(sin(theta)) * reach
                let d: CGFloat = dot * shrink * grow
                var petal = context
                petal.opacity = opacity
                petal.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)), with: .color(tint))
            }
        }
    }

    /// 0 → 1 with a small overshoot (easeOutBack), clamped outside 0…1 of `x`.
    private static func overshoot(_ x: Double) -> CGFloat {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        let c1 = 1.70158, c3 = c1 + 1
        let p = x - 1
        return CGFloat(1 + c3 * p * p * p + c1 * p * p)
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
                    ClaudeSheetCloseButton(label: "关闭思考过程") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Text("思考过程").font(TypeScale.ui(17, weight: .semibold)).foregroundStyle(Ink.ink)
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
                if live && last { ThinkingMark(live: true, size: 12) } else { Circle().fill(Ink.seal.opacity(0.36)).frame(width: 8, height: 8) }
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
