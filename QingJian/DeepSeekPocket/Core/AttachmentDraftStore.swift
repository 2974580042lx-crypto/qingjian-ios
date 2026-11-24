import Foundation

/// Private, device-local composer state, separate from the chat and backup formats.
struct AttachmentDraft: Codable, Equatable {
    struct Image: Codable, Equatable {
        let id: UUID
        let jpeg: Data
    }
    let lastUserMessage: UUID?
    let images: [Image]
    let documents: [PendingDocument]

    var isEmpty: Bool { images.isEmpty && documents.isEmpty }
}

final class AttachmentDraftStore {
    private let directory: URL
    private let fm = FileManager.default

    init(directory: URL) { self.directory = directory }

    func ids() -> Set<UUID> {
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return Set(urls.filter { $0.pathExtension == "draft" }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".draft") }

    func remove(_ id: UUID) throws {
        do { try fm.removeItem(at: file(id)) }
        catch let e as CocoaError where e.code == .fileNoSuchFile {}
    }

    func save(_ draft: AttachmentDraft, for id: UUID, isPrivate: Bool) throws {
        guard !isPrivate, !draft.isEmpty else { try remove(id); return }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(draft)
        #if os(iOS)
        try data.write(to: file(id), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file(id), options: .atomic)
        #endif
    }

    func load(_ id: UUID, lastUserMessage: UUID?, isPrivate: Bool, isLocked: Bool) throws -> AttachmentDraft? {
        if isPrivate { try remove(id); return nil }
        guard !isLocked else { return nil }
        let data: Data
        do { data = try Data(contentsOf: file(id), options: .mappedIfSafe) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let draft = try PropertyListDecoder().decode(AttachmentDraft.self, from: data)
        guard draft.lastUserMessage == lastUserMessage else { try remove(id); return nil }
        return draft
    }
}
