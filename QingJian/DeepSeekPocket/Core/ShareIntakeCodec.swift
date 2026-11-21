import Foundation

/// Unified representation of content arriving from outside Sermo:
/// - "用 Sermo 打开" / Files / WeChat documents & images
/// - `sermo://inbox?...` / `sermo://share?...` URL schemes
/// - Single-bundle `AppIntents` (iOS Shortcuts Share Sheet actions)
enum ShareIntakeKind: String, Codable, Equatable, Sendable {
    case file
    case image
    case webLink
    case text
}

struct ShareIntakeItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var kind: ShareIntakeKind
    var title: String
    var bodyText: String?
    var urlString: String?
    var localFilePath: String?
    var preferredProjectName: String?
    var createdAt: Date = Date()

    var localFileURL: URL? {
        guard let localFilePath, !localFilePath.isEmpty else { return nil }
        return URL(fileURLWithPath: localFilePath)
    }

    var webURL: URL? {
        guard let urlString, !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }

    /// Clean composer prefill text when user chooses "放进当前对话待发送".
    func composerPrefillText() -> String {
        switch kind {
        case .webLink:
            let link = urlString ?? ""
            let note = (bodyText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                return "\(note)\n\n相关链接：\(link)"
            }
            if !title.isEmpty && title != link {
                return "请帮我阅读并整理这篇网页《\(title)》的核心内容：\n\(link)"
            }
            return "请帮我阅读并整理这个网页的核心内容：\n\(link)"
        case .text:
            let body = (bodyText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty && !body.hasPrefix(title) {
                return "【\(title)】\n\(body)"
            }
            return body
        case .file, .image:
            return ""
        }
    }

    /// Document title & text payload when user chooses "存入指定项目百万字文献库".
    func libraryTextPayload() -> (name: String, text: String)? {
        switch kind {
        case .text:
            let body = (bodyText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (cleanTitle.isEmpty ? "外部收藏笔记" : cleanTitle, body)
        case .webLink:
            let link = (urlString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !link.isEmpty else { return nil }
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = (bodyText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var parts = ["【收藏网页】", "标题：\(cleanTitle.isEmpty ? link : cleanTitle)", "链接：\(link)"]
            if !note.isEmpty {
                parts.append("\n摘录与备注：\n\(note)")
            }
            return (cleanTitle.isEmpty ? "网页收藏" : cleanTitle, parts.joined(separator: "\n"))
        case .file, .image:
            return nil
        }
    }
}

enum ShareIntakeRoute: Equatable, Sendable {
    case backup(URL)
    case intake(ShareIntakeItem)
    case ignored
}

enum ShareIntakeURLParser {
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tif", "tiff"
    ]

    static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func parse(_ url: URL) -> ShareIntakeRoute {
        if url.isFileURL {
            if url.pathExtension.lowercased() == "sermobackup" {
                return .backup(url)
            }
            let fileName = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = fileName.isEmpty ? "外部文件" : fileName
            let kind: ShareIntakeKind = isImageFile(url) ? .image : .file
            return .intake(ShareIntakeItem(
                kind: kind,
                title: title,
                localFilePath: url.path
            ))
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "sermo" else {
            return .ignored
        }

        let host = (url.host ?? "").lowercased()
        guard host == "inbox" || host == "share" || host == "import" || host.isEmpty else {
            return .ignored
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        func param(_ names: String...) -> String? {
            for name in names {
                if let val = queryItems.first(where: { $0.name.lowercased() == name })?.value {
                    let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }

        let sharedURL = param("url", "link", "href")
        let sharedText = param("text", "body", "content", "note")
        let sharedTitle = param("title", "name")
        let preferredProject = param("project", "proj")

        if let sharedURL, let parsed = URL(string: sharedURL),
           let s = parsed.scheme?.lowercased(), s == "http" || s == "https" {
            let title = sharedTitle ?? parsed.host ?? sharedURL
            return .intake(ShareIntakeItem(
                kind: .webLink,
                title: title,
                bodyText: sharedText,
                urlString: sharedURL,
                preferredProjectName: preferredProject
            ))
        }

        if let sharedText {
            let fallbackTitle = String(sharedText.prefix(28))
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .intake(ShareIntakeItem(
                kind: .text,
                title: sharedTitle ?? (fallbackTitle.isEmpty ? "分享文字" : fallbackTitle),
                bodyText: sharedText,
                preferredProjectName: preferredProject
            ))
        }

        return .ignored
    }
}

/// Single-bundle disk queue under `Application Support/QingJian/ShareInbox/pending.json`
/// so iOS `AppIntents` (Shortcuts Share Sheet actions) can hand items to the live app
/// with ZERO extra App Group entitlement or Share Extension target (100% self-sign friendly).
final class ShareInboxQueue: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    init(rootDirectory: URL = ShareInboxQueue.defaultDirectory()) {
        self.fileURL = rootDirectory.appendingPathComponent("pending.json")
    }

    static func defaultDirectory() -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("QingJian/ShareInbox", isDirectory: true)
    }

    func enqueue(_ item: ShareIntakeItem) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var existing = loadLocked()
        existing.append(item)
        if existing.count > 40 {
            existing = Array(existing.suffix(40))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(existing)
        try data.write(to: fileURL, options: [.atomic])
    }

    func drainPending() -> [ShareIntakeItem] {
        lock.lock()
        defer { lock.unlock() }
        let items = loadLocked()
        if !items.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return items
    }

    func peekCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().count
    }

    private func loadLocked() -> [ShareIntakeItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ShareIntakeItem].self, from: data)) ?? []
    }
}
