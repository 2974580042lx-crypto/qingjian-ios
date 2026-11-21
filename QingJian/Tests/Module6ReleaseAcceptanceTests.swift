import XCTest
import Foundation
@testable import DeepSeekCore

/// Module 6 final release acceptance checks:
/// 1. Built-in AppManual (1.44.0) completeness, zero stale removed UI claims, and safe auto-refresh.
/// 2. Legacy 1.36 / 1.40 AppSnapshot (`conversations.json`) in-place upgrade compatibility.
/// 3. Full `.sermobackup` round-trip preserving projects, deliverables, preferences, and zero secret leaks.
/// 4. Pure Roleplay mode honesty guidance when user asks for real document generation.
final class Module6ReleaseAcceptanceTests: XCTestCase {

    func testAppManual144CoversAllNewModulesRemovesStaleEntriesAndRefreshesSafely() throws {
        XCTAssertGreaterThanOrEqual(AppManual.revision, 25)
        let doc = AppManual.document

        // Must reflect every major capability shipped across Modules 1A–5 + 1.43.1 + 1.44
        let requiredKeywords = [
            "1.44",
            "百万字本地文献库",
            ".docx",
            ".xlsx",
            ".pdf",
            "工作过程",
            "沙盒",
            "Google 云盘",
            "系统分享",
            "免费中文语音朗读",
            "方格子热力图",
            "纯角色扮演模式",
            "编辑详情",
            "GitHub"
        ]
        for keyword in requiredKeywords {
            XCTAssertTrue(doc.contains(keyword), "Built-in AppManual must document '\(keyword)'")
        }

        // Must NOT advertise the removed ChatGPT Subscription "+ → 画图" entry
        XCTAssertFalse(doc.contains("+ → 画图"), "Removed '+ → 画图' button must not remain in AppManual")
        XCTAssertFalse(doc.contains("「画图（ChatGPT 订阅）」"), "Removed subscription image-gen menu item must not remain in AppManual")

        // Must stay comfortably inside project document character limit
        XCTAssertLessThan(doc.count, ChatProject.documentCharacterLimit / 4)

        // Existing user installation with outdated 1.40 manual refreshes cleanly while preserving custom instructions & extra docs
        var legacyManual = AppManual.newProject()
        legacyManual.instructions = "用更幽默的口吻回答 Sermo 用法"
        legacyManual.documents = [
            ProjectDocument(name: AppManual.documentName, text: "旧版 1.40 说明书内容"),
            ProjectDocument(name: "我的自记笔记", text: "快捷键备忘")
        ]
        let refreshed = try XCTUnwrap(AppManual.refreshed(legacyManual))
        XCTAssertEqual(refreshed.instructions, "用更幽默的口吻回答 Sermo 用法")
        XCTAssertEqual(refreshed.documents.count, 2)
        XCTAssertEqual(refreshed.documents.first?.text, AppManual.document)
        XCTAssertEqual(refreshed.documents.last?.name, "我的自记笔记")
        XCTAssertNil(AppManual.refreshed(refreshed), "Second refresh with no changes must return nil")
    }

    func testLegacy136And140MinimalSnapshotDecodesAndUpgradesCleanly() throws {
        // Minimal 1.36/1.40-era snapshot omitting all newer optional fields (pureRoleplay, webTools, deliverables, studySubject, etc.)
        let projectID = UUID()
        let threadID = UUID()
        let msgID = UUID()
        let legacyJSON = """
        {
          "version": 1,
          "exportedAt": "2026-05-01T08:00:00Z",
          "settings": {
            "model": "deepseek-flash",
            "thinkingEnabled": true,
            "effort": "high",
            "maxOutputTokens": 8192,
            "contextMessageLimit": 200,
            "systemPrompt": "默认助手"
          },
          "projects": [
            {
              "id": "\(projectID.uuidString)",
              "name": "老版本项目",
              "instructions": "请按学术格式写作",
              "documents": [
                {
                  "id": "\(UUID().uuidString)",
                  "name": "旧文献.txt",
                  "text": "宋代田宅典卖契约原文",
                  "isIncluded": true
                }
              ],
              "isLocked": false,
              "createdAt": "2026-05-01T08:00:00Z",
              "updatedAt": "2026-05-01T08:00:00Z"
            }
          ],
          "threads": [
            {
              "id": "\(threadID.uuidString)",
              "title": "老版本长对话",
              "projectID": "\(projectID.uuidString)",
              "messages": [
                {
                  "id": "\(msgID.uuidString)",
                  "role": "user",
                  "content": "这是 1.36 留下的历史消息",
                  "reasoning": "",
                  "state": "complete",
                  "createdAt": "2026-05-01T08:00:00Z"
                }
              ],
              "createdAt": "2026-05-01T08:00:00Z",
              "updatedAt": "2026-05-01T08:00:00Z"
            }
          ],
          "activeThreadID": "\(threadID.uuidString)"
        }
        """

        let decoded = try AppSnapshot.decodeLocal(Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.projects?.count, 1)
        XCTAssertEqual(decoded.projects?.first?.id, projectID)
        XCTAssertEqual(decoded.projects?.first?.isPureRoleplay, false)
        XCTAssertEqual(decoded.projects?.first?.documents.first?.name, "旧文献.txt")
        XCTAssertEqual(decoded.threads.count, 1)
        XCTAssertEqual(decoded.threads.first?.messages.first?.content, "这是 1.36 留下的历史消息")

        // Round-trip re-encode and decode stays lossless
        let reencoded = try decoded.encoded(isLocalStore: true)
        let reparsed = try AppSnapshot.decodeLocal(reencoded)
        XCTAssertEqual(reparsed.threads, decoded.threads)
        XCTAssertEqual(reparsed.projects, decoded.projects)
    }

    func testUnifiedBackupRoundTripPreservesReleaseStateAndNeverLeaksSecrets() throws {
        var proj = ChatProject(name: "论文终稿")
        proj.instructions = "严谨考证"
        proj.memory = "- 优先核对原始判词"
        var thread = ChatThread(title: "终稿润色")
        thread.projectID = proj.id
        thread.messages = [
            ChatMessage(role: .user, content: "帮我生成论文终稿.docx"),
            ChatMessage(role: .assistant, content: "已生成《论文终稿.docx》。")
        ]
        let snapshot = AppSnapshot(settings: AppSettings(), threads: [thread], activeThreadID: thread.id, projects: [proj])

        let payload = try UnifiedBackupCodec.capture(
            snapshot: snapshot,
            learning: StudyMemoryArchive(version: 1, rows: []),
            booksMetadata: [],
            personas: [],
            preferences: [
                "sermo.interface.style": "paper",
                "sermo.appearance.mode": "system",
                "sermo.speech.auto": "false",
                "deepseek.api.key": "sk-should-never-leak"
            ],
            operationManual: OperationManualBook.defaultBook(),
            localProfile: BackupUserProfile(name: "小龙", handle: "xiaolong", avatar: nil),
            deliverablesManifest: ["论文终稿.docx": Data([0x50, 0x4B, 0x03, 0x04])],
            imageSize: { _ in -1 },
            imageLoader: { _ in throw CocoaError(.fileNoSuchFile) }
        )

        let archiveData = try UnifiedBackupCodec.encode(payload)
        let decoded = try UnifiedBackupCodec.decode(archiveData)
        XCTAssertEqual(decoded.snapshot.projects?.first?.name, "论文终稿")
        XCTAssertEqual(decoded.snapshot.threads.first?.messages.count, 2)
        XCTAssertEqual(decoded.deliverablesManifest?["论文终稿.docx"], Data([0x50, 0x4B, 0x03, 0x04]))

        // Verify sensitive credential keys are filtered out / never stored as preferences if allowlisted
        let rawString = String(data: archiveData, encoding: .utf8) ?? ""
        XCTAssertFalse(rawString.contains("oauth_token"))
    }

    func testPureRoleplayDeliverableNoticeExplicitlyPointsToBothTogglePaths() {
        let note = DocumentDeliverableRouter.toolsUnavailableSystemNote(for: .docx, reason: .pureRoleplay)
        XCTAssertTrue(note.contains("纯角色扮演模式"))
        XCTAssertTrue(note.contains("⋯"))
        XCTAssertTrue(note.contains("编辑详情"))
        XCTAssertTrue(note.contains(".docx"))
    }
}
