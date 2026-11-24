import Foundation
import XCTest
@testable import DeepSeekCore

final class ComposerDraftTests: XCTestCase {
    func testRoundTripIsolationAndRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = UUID(), b = UUID(), marker = UUID()
        let images = (0..<3).map { AttachmentDraft.Image(id: UUID(), jpeg: Data([UInt8($0)])) }
        let docs = (1...2).map { PendingDocument(name: "文档\($0)", fileExtension: "txt", text: "正文") }
        let value = AttachmentDraft(lastUserMessage: marker, images: images, documents: docs)
        let disk = AttachmentDraftStore(directory: root)
        try disk.save(value, for: a, isPrivate: false)
        let restarted = AttachmentDraftStore(directory: root)
        XCTAssertNil(try restarted.load(b, lastUserMessage: marker, isPrivate: false, isLocked: false))
        XCTAssertNil(try restarted.load(a, lastUserMessage: marker, isPrivate: false, isLocked: true))
        XCTAssertEqual(try restarted.load(a, lastUserMessage: marker, isPrivate: false, isLocked: false), value)
        try restarted.save(.init(lastUserMessage: marker, images: [], documents: []), for: a, isPrivate: false)
        XCTAssertTrue(restarted.ids().isEmpty)
        try restarted.remove(a)
    }

    func testPrivacyAndCommittedSendInvalidateDiskCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = AttachmentDraftStore(directory: root), id = UUID()
        let value = AttachmentDraft(lastUserMessage: nil, images: [.init(id: UUID(), jpeg: Data([7]))], documents: [])
        try disk.save(value, for: id, isPrivate: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try disk.save(value, for: id, isPrivate: false)
        try disk.save(value, for: id, isPrivate: true)
        XCTAssertFalse(disk.ids().contains(id))
        try disk.save(value, for: id, isPrivate: false)
        XCTAssertNil(try disk.load(id, lastUserMessage: UUID(), isPrivate: false, isLocked: false))
        XCTAssertTrue(disk.ids().isEmpty)
    }

    func testUnavailableDraftDirectoryLeavesSourceUntouched() throws {
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: blocked) }
        let original = Data([5, 7])
        try original.write(to: blocked)
        let disk = AttachmentDraftStore(directory: blocked)
        let draft = AttachmentDraft(lastUserMessage: nil, images: [], documents: [PendingDocument(name: "笔记", fileExtension: "txt", text: "原文")])
        XCTAssertThrowsError(try disk.save(draft, for: UUID(), isPrivate: false))
        XCTAssertEqual(try Data(contentsOf: blocked), original)
        XCTAssertEqual(draft.documents.first?.text, "原文")
    }

    func testVersionAllocationAndColdReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectDeliverableStore(rootDirectory: root)
        let thread = UUID(), message = UUID()
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            do {
                _ = try store.saveDeliverable(projectID: nil, threadID: thread, messageID: message, title: "同一稿", format: .pdf,
                                              data: Data([UInt8(index)]), sourcePreview: "", summary: "")
            } catch { XCTFail(String(describing: error)) }
        }
        let items = ProjectDeliverableStore(rootDirectory: root).allDeliverables()
        XCTAssertEqual(items.map(\.version).sorted(), Array(1...12))
        XCTAssertEqual(Set(items.map(\.groupID)).count, 1)
    }

    func testFailedCatalogReadNeverOverwritesOlderFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = root.appendingPathComponent("manifest.json")
        let damaged = Data("incomplete".utf8)
        try damaged.write(to: manifest)
        let store = ProjectDeliverableStore(rootDirectory: root)
        XCTAssertThrowsError(try store.saveDeliverable(projectID: nil, threadID: UUID(), messageID: UUID(), title: "草稿",
                                                       format: .pdf, data: Data([1]), sourcePreview: "", summary: ""))
        XCTAssertThrowsError(try store.exportBackupBundle())
        XCTAssertEqual(try Data(contentsOf: manifest), damaged)
    }

    func testOnlyRemovedAttachmentsDisappearAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = AttachmentDraftStore(directory: root), a = UUID(), b = UUID()
        let retained = PendingDocument(name: "资料", fileExtension: "txt", text: "正文")
        let original = AttachmentDraft(lastUserMessage: nil, images: [.init(id: UUID(), jpeg: Data([1]))], documents: [retained])
        let edited = AttachmentDraft(lastUserMessage: nil, images: [], documents: [retained])
        try disk.save(original, for: a, isPrivate: false)
        try disk.save(original, for: b, isPrivate: false)
        try disk.save(edited, for: a, isPrivate: false)
        try disk.remove(b)
        let reopened = AttachmentDraftStore(directory: root)
        XCTAssertEqual(reopened.ids(), [a])
        XCTAssertEqual(try reopened.load(a, lastUserMessage: nil, isPrivate: false, isLocked: false), edited)
    }

    func testSheetNamesSurviveSanitizationCollisions() throws {
        let tables = ["A/B", "AB", "ab"].map { XlsxSheetSpec(name: $0, headers: ["列"], rows: [["值"]]) }
        let workbook = try DocumentStudioCompiler.compileXLSX(XlsxWorkbookSpec(sheets: tables))
        let text = try OfficeAndDocumentExtractor.extractXLSX(workbook.data)
        for expected in ["## AB", "## AB (2)", "## ab (3)"] { XCTAssertTrue(text.contains(expected)) }
    }

    func testTooManySheetsFailWithoutTruncatingTheWorkbook() {
        let sheet = XlsxSheetSpec(name: "原始数据", headers: ["值"], rows: [["1"]])
        XCTAssertThrowsError(try DocumentStudioCompiler.compileXLSX(.init(sheets: Array(repeating: sheet, count: 21))))
    }

    func testCompatibleToolArgumentAliasesPreserveIntegerIDsAndFragments() throws {
        let json = #"{"index":0,"function":{"name":"lookup","args":{"record":9007199254740993}}}"#
        let delta = try JSONDecoder().decode(ToolCallDelta.self, from: Data(json.utf8))
        var collector = ToolCallCollector()
        collector.consume([delta])
        let call = try XCTUnwrap(collector.calls.first)
        XCTAssertEqual(try call.argumentObject()["record"] as? Int64, 9007199254740993)
        let malformed = ToolCall(id: "test", name: "lookup", arguments: "{")
        XCTAssertThrowsError(try malformed.argumentObject())
    }

    func testOversizedToolFragmentsDoNotProduceAnExecutableCall() throws {
        var collector = ToolCallCollector()
        collector.consume([ToolCallDelta(index: 0, name: "sample", arguments: "{}"), ToolCallDelta(index: 0, arguments: String(repeating: " ", count: 400_001))])
        let call = try XCTUnwrap(collector.calls.first)
        XCTAssertLessThan(call.arguments.utf8.count, 100)
        XCTAssertThrowsError(try call.argumentObject())
    }
}
