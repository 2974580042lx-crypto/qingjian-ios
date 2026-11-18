import SwiftUI

// One quiet line under an answer that is still coming: the breathing mark,
// and while nothing is written yet, what is happening and for how long.
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
                        HStack(spacing: 9) {
                            PulseDot()
                            Text("\(currentPhase.title) · \(seconds) 秒").font(TypeScale.caption).monospacedDigit()
                        }
                        if seconds >= 30 {
                            Text(currentPhase == .connecting
                                 ? "尚未收到服务器响应，可以停止，或到设置运行实际对话测试。"
                                 : "连接已建立，模型还没有开始返回内容。你可以停止后关闭思考再试。")
                            .font(TypeScale.tiny)
                        }
                    }
                }
            } else {
                HStack(spacing: 9) {
                    PulseDot()
                }
            }
        }
        .foregroundStyle(Ink.ink3)
        .padding(.vertical, 4)
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
