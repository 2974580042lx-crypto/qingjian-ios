import Foundation

/// A file staged above the chat composer without occupying the text input box.
struct PendingDocument: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let fileExtension: String
    let text: String
    let warnings: [String]

    var characterCount: Int { text.count }

    init(id: UUID = UUID(), name: String, fileExtension: String, text: String, warnings: [String] = []) {
        self.id = id
        self.name = name
        self.fileExtension = fileExtension
        self.text = text
        self.warnings = warnings
    }
}

/// A folded file attachment parsed from a persisted `ChatMessage.content` string,
/// keeping `ChatMessage` Codable schema 100% unchanged.
/// Uses a deterministic `id` so SwiftUI `ForEach` never destroys/recreates cards on redraw.
struct MessageDocumentAttachment: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let fileExtension: String
    let characterCount: Int
    let text: String

    init(id: String? = nil, index: Int = 0, name: String, fileExtension: String, characterCount: Int, text: String) {
        self.id = id ?? "\(index)|\(name)|\(fileExtension)|\(characterCount)"
        self.name = name
        self.fileExtension = fileExtension
        self.characterCount = characterCount
        self.text = text
    }
}

enum PendingDocumentCodec {
    private static let startPrefix = "[[SERMO_FILE_START:"
    private static let startSuffix = "]]"
    private static let endTag = "[[SERMO_FILE_END]]"
    private static let escapedEndTag = "[ [/SERMO_FILE_END] ]"

    private struct DecodedEntry {
        let userText: String
        let attachments: [MessageDocumentAttachment]
    }

    nonisolated(unsafe) private static var decodeCache: [String: DecodedEntry] = [:]
    private static let decodeCacheLock = NSLock()

    static func encode(userText: String, documents: [PendingDocument]) -> String {
        let trimmedUser = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !documents.isEmpty else { return userText }

        let blocks = documents.map { doc -> String in
            let safeName = doc.name
                .replacingOccurrences(of: "|", with: "｜")
                .replacingOccurrences(of: "]]", with: "］］")
                .replacingOccurrences(of: "\n", with: " ")
            let safeExt = doc.fileExtension
                .replacingOccurrences(of: "|", with: "")
                .replacingOccurrences(of: "]]", with: "")
                .replacingOccurrences(of: "\n", with: "")
            let safeBody = doc.text.replacingOccurrences(of: endTag, with: escapedEndTag)
            return "\(startPrefix)\(safeName)|\(safeExt)|\(doc.characterCount)\(startSuffix)\n\(safeBody)\n\(endTag)"
        }.joined(separator: "\n\n")

        if trimmedUser.isEmpty {
            return blocks
        }
        return "\(blocks)\n\n\(trimmedUser)"
    }

    static func decode(_ content: String) -> (userText: String, attachments: [MessageDocumentAttachment]) {
        guard content.contains(startPrefix) else {
            return (content, [])
        }

        if content.utf8.count <= 8 * 1024 * 1024 {
            decodeCacheLock.lock()
            if let hit = decodeCache[content] {
                decodeCacheLock.unlock()
                return (hit.userText, hit.attachments)
            }
            decodeCacheLock.unlock()
        }

        var attachments: [MessageDocumentAttachment] = []
        var remaining = content[...]
        var userParts: [String] = []
        var attachmentIndex = 0

        while let startRange = remaining.range(of: startPrefix) {
            let before = String(remaining[..<startRange.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                userParts.append(before.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            let afterPrefix = remaining[startRange.upperBound...]
            guard let headerEnd = afterPrefix.range(of: startSuffix),
                  let endRange = remaining.range(of: endTag, range: headerEnd.upperBound..<remaining.endIndex) else {
                // Malformed block: keep the rest as plain text so nothing is lost.
                let tail = String(remaining[startRange.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { userParts.append(tail) }
                remaining = remaining[remaining.endIndex...]
                break
            }

            let header = String(afterPrefix[..<headerEnd.lowerBound])
            let parts = header.split(separator: "|", omittingEmptySubsequences: false)
            let name = parts.count >= 1 ? String(parts[0]) : "附件"
            let ext = parts.count >= 2 ? String(parts[1]) : ""
            let declaredCount = parts.count >= 3 ? Int(parts[2]) : nil

            var bodyStart = headerEnd.upperBound
            if bodyStart < endRange.lowerBound, remaining[bodyStart] == "\n" {
                bodyStart = remaining.index(after: bodyStart)
            }
            var bodyEnd = endRange.lowerBound
            if bodyEnd > bodyStart {
                let prev = remaining.index(before: bodyEnd)
                if remaining[prev] == "\n" { bodyEnd = prev }
            }
            let body = String(remaining[bodyStart..<bodyEnd])
                .replacingOccurrences(of: escapedEndTag, with: endTag)

            attachments.append(MessageDocumentAttachment(
                index: attachmentIndex,
                name: name,
                fileExtension: ext,
                characterCount: declaredCount ?? body.count,
                text: body
            ))
            attachmentIndex += 1

            remaining = remaining[endRange.upperBound...]
        }

        let tail = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            userParts.append(tail)
        }

        let joinedUser = userParts.joined(separator: "\n\n")
        if content.utf8.count <= 8 * 1024 * 1024 {
            decodeCacheLock.lock()
            if decodeCache.count >= 64 {
                decodeCache.removeAll(keepingCapacity: true)
            }
            decodeCache[content] = DecodedEntry(userText: joinedUser, attachments: attachments)
            decodeCacheLock.unlock()
        }
        return (joinedUser, attachments)
    }

    /// Extracts only the human-authored message text (stripping document blocks and quote headers) for clean editing.
    static func extractEditableUserText(_ rawContent: String) -> String {
        let docFree = decode(rawContent).userText
        return MessageQuoteCodec.decode(docFree).userText
    }

    /// Re-combines edited user text with any existing quote header and attached documents so edits never expose raw tags or drop attachments.
    static func replaceEditableUserText(in rawContent: String, with newUserText: String) -> String {
        let docDecoded = decode(rawContent)
        let quoteDecoded = MessageQuoteCodec.decode(docDecoded.userText)
        let withQuote = MessageQuoteCodec.encode(quote: quoteDecoded.quote, userText: newUserText)
        guard !docDecoded.attachments.isEmpty else { return withQuote }
        let preservedDocs = docDecoded.attachments.map {
            PendingDocument(name: $0.name, fileExtension: $0.fileExtension, text: $0.text)
        }
        return encode(userText: withQuote, documents: preservedDocs)
    }
}

enum IncomingURLRoute: Equatable, Sendable {
    case backup
    case chatDocument

    static func classify(_ url: URL) -> IncomingURLRoute {
        url.pathExtension.lowercased() == "sermobackup" ? .backup : .chatDocument
    }
}
