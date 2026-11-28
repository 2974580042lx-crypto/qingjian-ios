import SwiftUI

// One quiet line under an answer that is still coming: Sermo's flower breathing, and
// while nothing is written yet, what is happening (with light passing over the words)
// and for how long (the seconds roll over rather than jump).
struct StreamActivityView: View {
    @EnvironmentObject private var store: AppStore
    let message: ChatMessage

    private var phase: ChatStreamPhase {
        if !message.content.isEmpty { return .answering }
        if !message.reasoning.isEmpty { return .thinking }
        return store.generationProgress?.phase ?? .connecting
    }

    var body: some View {
        let currentPhase = phase
        Group {
            if currentPhase == .connecting || currentPhase == .waiting {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let seconds = max(0, Int(timeline.date.timeIntervalSince(message.createdAt)))
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            ThinkingMark(live: true, size: 14)
                            HStack(spacing: 0) {
                                Text(currentPhase.title).shimmering()
                                Text(" · ")
                                Text("\(seconds)").contentTransition(.numericText(countsDown: false))
                                Text(" 秒")
                            }
                            .font(TypeScale.caption).monospacedDigit()
                            .animation(Motion.snappy.motionSafe, value: seconds)
                        }
                        if seconds >= 30 {
                            Text(currentPhase == .connecting
                                 ? "尚未收到服务器响应，可以停止，或到设置运行实际对话测试。"
                                 : "连接已建立，模型还没有开始返回内容。你可以停止后关闭思考再试。")
                            .font(TypeScale.tiny)
                            .transition(.rise)
                        }
                    }
                }
                .transition(.opacity)
            } else if currentPhase != .thinking {
                // Words are arriving: only the flower, small, at the foot of the text.
                // (While it thinks, the thinking line above already carries the flower.)
                ThinkingMark(live: true, size: 12)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(Ink.ink3)
        .padding(.vertical, 4)
        .animation(Motion.fade.motionSafe, value: currentPhase == .answering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(currentPhase.title)
        .accessibilityIdentifier("stream-activity")
    }
}

// Shows one message with the live text laid over it, redrawing on its own.
struct LiveMessageRow<Row: View>: View {
    @ObservedObject var live: LiveStream
    let message: ChatMessage
    var onGrow: () -> Void = {}
    @ViewBuilder let row: (ChatMessage) -> Row
    var body: some View {
        row(live.applied(to: message))
            .onChange(of: live.content) { _, _ in onGrow() }
    }
}
