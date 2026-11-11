import Foundation

enum ChatStreamPhase: String, Sendable {
    case connecting, waiting, thinking, answering, complete
    var title: String {
        switch self {
        case .connecting: return "正在连接"
        case .waiting: return "已连接，等待模型开始"
        case .thinking: return "正在思考"
        case .answering: return "正在回答"
        case .complete: return "已完成"
        }
    }
}

struct ChatStreamProgress: Sendable {
    var phase: ChatStreamPhase
    var elapsedSeconds: Int
    var receivedBytes: Int
    var httpStatus: Int?
    func diagnostic(model: String) -> String {
        "服务：api.deepseek.com\n模型：\(model)\n阶段：\(phase.rawValue)\n等待：\(elapsedSeconds) 秒\n接收：\(receivedBytes) 字节\nHTTP：\(httpStatus.map(String.init) ?? "尚未收到")"
    }
}

struct ChatConnectionFailure: LocalizedError, Sendable {
    let code: Int
    let progress: ChatStreamProgress
    let model: String
    var diagnostic: String { progress.diagnostic(model: model) + "\n网络错误码：\(code)" }
    var errorDescription: String? {
        if code == URLError.timedOut.rawValue {
            if progress.httpStatus == nil { return "连接服务器超时，尚未收到响应。消息已保留，可在设置中运行实际对话测试。" }
            if progress.phase == .waiting { return "已连接，但等待模型开始超时。可以停止后关闭思考再试，原消息已保留。" }
            return "回答传输超时，已经收到的内容已保留。"
        }
        if code == URLError.notConnectedToInternet.rawValue { return "当前没有联网，请连接网络后重试。" }
        return "连接中断，已收到的内容已保留。可在设置中复制连接诊断。"
    }
}
