import XCTest
@testable import DeepSeekCore

/// 1.47 removed the bookshelf. Backups made by 1.46 and older still carry books, persona
/// cards and story fields on conversations; they must restore, with those parts ignored.
final class RetiredShelfBackupTests: XCTestCase {
    private func payload() throws -> UnifiedBackupPayload {
        var thread = ChatThread(title: "旧对话")
        thread.messages = [ChatMessage(role: .user, content: "你好"), ChatMessage(role: .assistant, content: "你好呀")]
        let snapshot = AppSnapshot(settings: AppSettings(), threads: [thread], activeThreadID: thread.id, projects: [])
        return try UnifiedBackupCodec.capture(
            snapshot: snapshot,
            learning: StudyMemoryArchive(version: 1, rows: []),
            imageSize: { _ in -1 },
            imageLoader: { _ in throw CocoaError(.fileNoSuchFile) }
        )
    }

    func testNewBackupsKeepEmptyShelfKeysForOlderBuilds() throws {
        let json = try StudyCoding.encode(try payload())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        // 1.46 decodes these two keys as required arrays, so they must be present.
        XCTAssertEqual((object["booksMetadata"] as? [Any])?.count, 0)
        XCTAssertEqual((object["personas"] as? [Any])?.count, 0)
    }

    func testOldBackupWithBooksAndStoriesStillRestores() throws {
        let json = try StudyCoding.encode(try payload())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        object["booksMetadata"] = [["id": UUID().uuidString, "title": "红楼梦", "characterCount": 900_000,
                                    "chapterTitles": ["第一回"], "segments": [], "notes": []]]
        object["personas"] = [["id": UUID().uuidString, "name": "我", "detail": "路人"]]
        var snapshot = try XCTUnwrap(object["snapshot"] as? [String: Any])
        var threads = try XCTUnwrap(snapshot["threads"] as? [[String: Any]])
        threads[0]["story"] = ["bookID": UUID().uuidString, "bookTitle": "红楼梦", "character": "黛玉"]
        threads[0]["storyCheckpoints"] = []
        var messages = try XCTUnwrap(threads[0]["messages"] as? [[String: Any]])
        messages[1]["innerThoughts"] = "她心里想的是……"
        messages[1]["discussionCharacter"] = "宝玉"
        threads[0]["messages"] = messages
        snapshot["threads"] = threads
        object["snapshot"] = snapshot
        let old = try JSONSerialization.data(withJSONObject: object)

        let restored = try UnifiedBackupCodec.decode(old)
        XCTAssertEqual(restored.booksMetadata.count, 1)
        XCTAssertEqual(restored.snapshot.threads.count, 1)
        XCTAssertEqual(restored.snapshot.threads[0].messages.map(\.content), ["你好", "你好呀"])
        guard case .unified = try UnifiedBackupCodec.decodeAny(old) else {
            return XCTFail("An old full backup must still be recognised as a full backup")
        }
    }
}
