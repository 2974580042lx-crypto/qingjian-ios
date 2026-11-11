import Foundation

enum ConversationEditing {
    static func editedCopy(of original: ChatThread, messageID: UUID, text: String, resend: Bool = false) throws -> ChatThread {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 100000,
              let index = original.messages.firstIndex(where: { $0.id == messageID }) else {
            throw ChatError.server("请填写有效的消息内容。")
        }
        var copy = original
        if resend && copy.messages[index].role == .user {
            copy.messages = Array(copy.messages.prefix(index + 1))
        }
        copy.messages[index].content = clean
        copy.messages[index].reasoning = ""
        copy.messages[index].reasoningTranslation = nil
        copy.messages[index].translationUsage = nil
        copy.messages[index].replySuggestions = nil
        copy.messages[index].innerThoughts = nil
        copy.messages[index].usage = nil
        copy.messages[index].state = .complete
        copy.messages[index].note = "已手动编辑"
        copy.updatedAt = Date()
        return copy
    }

    static func retryCopy(of original: ChatThread) throws -> ChatThread {
        guard original.messages.last?.role == .assistant,
              let index = original.messages.lastIndex(where: { $0.role == .user }) else {
            throw ChatError.server("这个对话还没有可以重新生成的回答。")
        }
        var copy = original
        copy.messages = Array(copy.messages.prefix(index + 1))
        copy.updatedAt = Date()
        return copy
    }
}
