import SwiftUI

// One quiet line under an answer that is still coming: the breathing mark,
// and while nothing is written yet, what is happening and for how long.
struct StreamActivityView: View {
    @EnvironmentObject private var store: AppStore
    let message: ChatMessage
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let seconds = max(0, Int(timeline.date.timeIntervalSince(message.createdAt)))
            let phase = !message.content.isEmpty ? ChatStreamPhase.answering :
                (!message.reasoning.isEmpty ? .thinking : (store.generationProgress?.phase ?? .connecting))
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    // One flower is enough: the animated one lives in the thinking row.
                    PulseDot()
                    // The reasoning header above already says it is thinking and for how long.
                    if phase == .connecting || phase == .waiting {
                        Text("\(phase.title) · \(seconds) 秒").font(TypeScale.caption).monospacedDigit()
                    }
                }
                if seconds >= 30 && (phase == .connecting || phase == .waiting) {
                    Text(phase == .connecting ? "尚未收到服务器响应，可以停止，或到设置运行实际对话测试。" :
                        "连接已建立，模型还没有开始返回内容。你可以停止后关闭思考再试。")
                        .font(TypeScale.tiny)
                }
            }.foregroundStyle(Ink.ink3).padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(phase.title)
                .accessibilityIdentifier("stream-activity")
        }
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
