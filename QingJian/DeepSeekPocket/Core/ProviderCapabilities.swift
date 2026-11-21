import Foundation

/// Explicit capability boundary metadata for each AI provider so the user
/// sees what works (vision, web search, thinking, tools) before sending.
struct ProviderCapabilities: Equatable, Sendable {
    let provider: AIProvider
    let supportsVision: Bool
    let visionNote: String
    let supportsWebSearch: Bool
    let supportsThinking: Bool
    let supportsTools: Bool

    var summaryLabel: String {
        let vision = supportsVision ? "识图 ✓" : "识图 \(visionNote)"
        let web = supportsWebSearch ? "联网 ✓" : "联网 —"
        let think = supportsThinking ? "思考 ✓" : "思考 —"
        let tools = supportsTools ? "工具 ✓" : "工具 —"
        return "\(vision) · \(web) · \(think) · \(tools)"
    }

    static func forProvider(_ provider: AIProvider) -> ProviderCapabilities {
        switch provider {
        case .deepSeek:
            return ProviderCapabilities(
                provider: .deepSeek,
                supportsVision: true,
                visionNote: "经 Flash 识图桥接",
                supportsWebSearch: WebSearchRouting.channel(for: .deepSeek) != .directLinksOnly,
                supportsThinking: true,
                supportsTools: true
            )
        case .chatGPT:
            return ProviderCapabilities(
                provider: .chatGPT,
                supportsVision: true,
                visionNote: "原生支持",
                supportsWebSearch: WebSearchRouting.channel(for: .chatGPT) != .directLinksOnly,
                supportsThinking: true,
                supportsTools: true
            )
        case .colab:
            return ProviderCapabilities(
                provider: .colab,
                supportsVision: true,
                visionNote: "直接上传",
                supportsWebSearch: WebSearchRouting.channel(for: .colab) != .directLinksOnly,
                supportsThinking: true,
                supportsTools: false
            )
        case .compatible:
            return ProviderCapabilities(
                provider: .compatible,
                supportsVision: true,
                visionNote: "直接上传",
                supportsWebSearch: WebSearchRouting.channel(for: .compatible) != .directLinksOnly,
                supportsThinking: true,
                supportsTools: true
            )
        }
    }
}
