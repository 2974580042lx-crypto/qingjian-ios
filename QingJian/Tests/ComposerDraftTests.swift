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

    func testSheetNamesSurviveSanitizationCollisions() throws {
        let tables = ["A/B", "AB", "ab"].map { XlsxSheetSpec(name: $0, headers: ["列"], rows: [["值"]]) }
        let workbook = try DocumentStudioCompiler.compileXLSX(XlsxWorkbookSpec(sheets: tables))
        let text = try OfficeAndDocumentExtractor.extractXLSX(workbook.data)
        for expected in ["## AB", "## AB (2)", "## ab (3)"] { XCTAssertTrue(text.contains(expected)) }
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
