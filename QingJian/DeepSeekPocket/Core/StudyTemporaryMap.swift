import Foundation

struct StudyTemporaryMap: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let url: String
        let year: String
        let note: String
    }
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let block: String
        let status: String
        let sourceIDs: [String]
        let differences: [String]
        let relatedChapterIDs: [String]
        let relatedTermIDs: [String]
    }
    let schema: String
    let id: String
    let status: String
    let sources: [Source]
    let entries: [Entry]
    let differences: [String]
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8 * 1024 * 1024 else { throw StudyMemoryError.invalid("临时学习地图不能超过8MB。") }
        let map = try StudyCoding.decode(Self.self, from: data)
        let ids = Set(map.sources.map(\.id))
        guard map.schema == "sermo.temporary-history-map.v1", !map.id.isEmpty, map.id.count <= 100,
              map.status == "网络整理、待核", (1...5000).contains(map.entries.count), (2...50).contains(map.sources.count),
              ids.count == map.sources.count, Set(map.entries.map(\.id)).count == map.entries.count,
              map.sources.allSatisfy({ source in
                  guard let url = URL(string: source.url) else { return false }
                  return ["https", "http"].contains(url.scheme ?? "") && url.host != nil && url.user == nil && !source.title.isEmpty && source.note.count <= 2000
              }), map.entries.allSatisfy({ entry in
                  entry.id.range(of: #"^netmap:[a-z0-9_-]{1,100}$"#, options: .regularExpression) != nil && !entry.title.isEmpty && entry.title.count <= 200
                  && StudyLessonTools.historyAreas.contains(entry.block) && entry.status == map.status && !entry.sourceIDs.isEmpty
                  && entry.sourceIDs.allSatisfy(ids.contains) && entry.differences.allSatisfy({ $0.count <= 2000 })
                  && entry.relatedChapterIDs.count <= 50 && entry.relatedTermIDs.count <= 100
              }) else { throw StudyMemoryError.invalid("临时地图需要完整来源，所有条目必须标为“网络整理、待核”。") }
        return map
    }
}

extension StudyMemoryStore {
    func temporaryHistoryMap(projectID: UUID) throws -> StudyTemporaryMap? {
        try transaction { try read(StudyTemporaryMap.self, projectID: projectID, kind: "temporary_map", id: "network") }
    }
    func importTemporaryHistoryMap(_ map: StudyTemporaryMap, scope: StudyScope) throws {
        guard scope.subject == .history else { throw StudyMemoryError.invalid("请在313历史项目中导入临时地图。") }
        _ = try StudyTemporaryMap.decode(StudyCoding.encode(map))
        try transaction {
            if let old = try read(StudyTemporaryMap.self, projectID: scope.projectID, kind: "temporary_map", id: "network"), old != map {
                throw StudyMemoryError.invalid("临时地图已有不同内容，未覆盖原地图和进度。版本核对迁移仍待后续确认。")
            }
            try write(map, projectID: scope.projectID, kind: "temporary_map", id: "network")
        }
    }
}
