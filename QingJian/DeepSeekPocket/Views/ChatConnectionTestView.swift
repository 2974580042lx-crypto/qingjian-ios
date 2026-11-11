import SwiftUI
import UIKit

@MainActor
struct ChatConnectionTestView: View {
    @EnvironmentObject private var store: AppStore
    let key: String
    @State private var running = false
    @State private var result: String?
    @State private var progress: ChatStreamProgress?
    @State private var started = Date()
    @State private var task: Task<Void, Never>?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: run) {
                Label(running ? "正在测试实际对话…" : "实际对话测试", systemImage: "bubble.left.and.text.bubble")
            }.buttonStyle(.borderless).disabled(running || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if running {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(progress?.phase.title ?? "正在连接") · \(max(0, Int(timeline.date.timeIntervalSince(started)))) 秒")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("停止") { cancel() }.buttonStyle(.borderless)
                    }
                }
            }
            if let result { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Text("使用当前 Key 向 Flash 发送一条不带思考的测试消息，会产生少量 Token 用量；不发送聊天记录。")
                .font(.caption).foregroundStyle(.secondary)
            if store.lastConnectionDiagnostic != nil {
                Button(copied ? "诊断已复制" : "复制最近连接诊断") {
                    UIPasteboard.general.string = store.lastConnectionDiagnostic; copied = true
                }.font(.caption).buttonStyle(.borderless)
                Text("诊断只含模型、连接阶段、等待时间和错误码，不含 Key 或聊天正文。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: key) { _, _ in cancel(); result = nil; copied = false }
        .onDisappear { cancel() }
    }

    private func cancel() {
        if let task { task.cancel() } else { running = false }
    }
    private func run() {
        guard !running else { return }
        if store.isPreview { result = "预览模式不发出网络请求。"; return }
        var settings = AppSettings()
        settings.model = .flash
        settings.thinkingEnabled = false
        settings.maxOutputTokens = 1024
        settings.systemPrompt = "这是连接测试。只回复 OK。"
        let request = ChatRequest(settings: settings, messages: [ChatMessage(role: .user, content: "请只回复 OK。")])
        let apiKey = key
        running = true; result = nil; copied = false; started = Date(); progress = nil
        task = Task { @MainActor in
            defer { running = false; task = nil }
            let buffer = ProbeBuffer()
            do {
                try await DeepSeekClient(requestTimeout: 45, resourceTimeout: 90).stream(request: request, key: apiKey, onProgress: { value in
                    progress = value
                    store.recordConnectionDiagnostic(value.diagnostic(model: request.model) + "\n" + request.diagnosticSummary)
                }) { event in buffer.text += event.content }
                try Task.checkCancellation()
                guard !buffer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatError.invalidResponse }
                result = "实际对话已成功，收到回复：\(String(buffer.text.prefix(160)))"
            } catch {
                guard !Task.isCancelled else { return }
                if let failure = error as? ChatConnectionFailure { store.recordConnectionDiagnostic(failure.diagnostic + "\n" + request.diagnosticSummary) }
                result = "实际对话未完成：\(error.localizedDescription)"
            }
        }
    }
}

@MainActor
private final class ProbeBuffer { var text = "" }
