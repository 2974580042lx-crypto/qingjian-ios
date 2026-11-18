import Foundation

struct QuotedMessage: Equatable, Sendable {
    let author: String
    let excerpt: String
}

/// Encodes and decodes quoted-reply metadata inside `ChatMessage.content` so
/// `ChatMessage` Codable persistence fields stay 100% backward-compatible.
enum MessageQuoteCodec {
    private static let startPrefix = "[[SERMO_QUOTE_START:"
    private static let startSuffix = "]]"
    private static let endTag = "[[SERMO_QUOTE_END]]"
    private static let escapedEndTag = "[ [/SERMO_QUOTE_END] ]"

    static func encode(quote: QuotedMessage?, userText: String) -> String {
        guard let quote else { return userText }
        let safeAuthor = quote.author
            .replacingOccurrences(of: "]]", with: "］］")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeExcerpt = quote.excerpt
            .replacingOccurrences(of: endTag, with: escapedEndTag)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeExcerpt.isEmpty else { return userText }
        let block = "\(startPrefix)\(safeAuthor.isEmpty ? "消息" : safeAuthor)\(startSuffix)\n\(safeExcerpt)\n\(endTag)"
        let trimmedUser = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUser.isEmpty { return block }
        return "\(block)\n\n\(trimmedUser)"
    }

    static func decode(_ content: String) -> (quote: QuotedMessage?, userText: String) {
        guard content.contains(startPrefix),
              let startRange = content.range(of: startPrefix) else {
            return (nil, content)
        }
        let afterPrefix = content[startRange.upperBound...]
        guard let headerEnd = afterPrefix.range(of: startSuffix),
              let endRange = content.range(of: endTag, range: headerEnd.upperBound..<content.endIndex) else {
            return (nil, content)
        }
        let author = String(afterPrefix[..<headerEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        var bodyStart = headerEnd.upperBound
        if bodyStart < endRange.lowerBound, content[bodyStart] == "\n" {
            bodyStart = content.index(after: bodyStart)
        }
        var bodyEnd = endRange.lowerBound
        if bodyEnd > bodyStart {
            let prev = content.index(before: bodyEnd)
            if content[prev] == "\n" { bodyEnd = prev }
        }
        let excerpt = String(content[bodyStart..<bodyEnd])
            .replacingOccurrences(of: escapedEndTag, with: endTag)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixText = String(content[..<startRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixText = String(content[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = [prefixText, suffixText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !excerpt.isEmpty else { return (nil, combined) }
        return (QuotedMessage(author: author.isEmpty ? "消息" : author, excerpt: excerpt), combined)
    }

    static func cleanExcerpt(from rawContent: String, hasImages: Bool = false, maxLength: Int = 90) -> String {
        let docFree = PendingDocumentCodec.decode(rawContent).userText
        let quoteFree = decode(docFree).userText
        let collapsed = quoteFree
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.isEmpty {
            return hasImages ? "[图片]" : "附带的文件"
        }
        if collapsed.count <= maxLength { return collapsed }
        return String(collapsed.prefix(maxLength)) + "…"
    }
}
