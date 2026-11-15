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
struct MessageDocumentAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let fileExtension: String
    let characterCount: Int
    let text: String

    init(id: UUID = UUID(), name: String, fileExtension: String, characterCount: Int, text: String) {
        self.id = id
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

        var attachments: [MessageDocumentAttachment] = []
        var remaining = content[...]
        var userParts: [String] = []

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
                name: name,
                fileExtension: ext,
                characterCount: declaredCount ?? body.count,
                text: body
            ))

            remaining = remaining[endRange.upperBound...]
        }

        let tail = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            userParts.append(tail)
        }

        return (userParts.joined(separator: "\n\n"), attachments)
    }
}

enum IncomingURLRoute: Equatable, Sendable {
    case backup
    case chatDocument

    static func classify(_ url: URL) -> IncomingURLRoute {
        url.pathExtension.lowercased() == "sermobackup" ? .backup : .chatDocument
    }
}
