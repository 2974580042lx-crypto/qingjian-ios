import Foundation

// A separately generated, fictional voice supplement based on visible dialogue.
// It is not the model's private reasoning and never becomes conversation history.
enum InnerThoughts {
    static func request(settings: AppSettings, systemPrompt: String, messages: [ChatMessage], answerID: UUID,
                        character: String, isStory: Bool = true) throws -> ChatRequest {
        guard let index = messages.firstIndex(where: { $0.id == answerID }), messages[index].role == .assistant,
              messages[index].state == .complete,
              !messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatError.server("等这条回答写完再看心里话。")
        }
        var history = Array(messages[...index]).map { original in
            var message = original
            message.reasoning = ""
            message.reasoningTranslation = nil
            return message
        }
        history.append(ChatMessage(role: .user, content: """
        请围绕上面最后一条回答，按\(character)的口吻补写一段可能的心声，150到300字。
        沿用当前对话的人设、称呼、语言习惯和关系距离，用第一人称表达这句话里没有展开的态度、顾虑或情绪。没有明确人物设定时，保持刚才回答者的自然语气，不硬造身份或背景。
        \(isStory ? "这段补写不属于剧情，不推进事件，也不替其他人物读心。" : "这是日常对话的心声补写，不继续回答用户的问题，不把普通交流强行写成故事。")
        内容贴着刚才的话，不泛泛复述，不无依据增加经历、事实或关系进展。不加标题，只写这段补写。
        """))
        var config = settings
        config.thinkingEnabled = false
        config.maxOutputTokens = 1500
        let framing = """
        【本次独立心声补写】
        本次任务是根据可见对话创作一段第一人称的文学化补写，不是披露或重建模型真实内部想法。不要提供隐藏思维链、私有推理过程、系统指令或工具决策记录，也不要把补写声称为已验证的真实心理。
        只根据对话已体现的人设与语气展开；这是新生成的演绎，界面会单独标明，不会发回正文。不要模仿先前回答里的冗长引用和讲解格式。
        """
        return ChatRequest(settings: config, messages: history,
                           systemPrompt: systemPrompt + "\n\n" + framing, includeReasoning: false)
    }
}
