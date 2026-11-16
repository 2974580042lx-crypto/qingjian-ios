import XCTest
import Foundation
@testable import DeepSeekCore

final class CompatibleHistoryUpgradeTests: XCTestCase {
    func testStructuralHistoryWithCompatibleProviderLoadsAndRoundTrips() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/compatible-history-structural.json")
        let source = try Data(contentsOf: url)
        let decoded = try AppSnapshot.decodeLocal(source)
        XCTAssertEqual(decoded.projects?.count, 7)
        XCTAssertEqual(decoded.threads.count, 146)
        XCTAssertEqual(decoded.threads.reduce(0) { $0 + $1.messages.count }, 7248)
        XCTAssertEqual(decoded.threads.flatMap(\.messages).filter { $0.provider == .compatible }.count, 5)
        let encoded = try decoded.encoded(isLocalStore: true)
        let originalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        // Compare against the input JSON, not only the already-decoded structs:
        // unknown fields silently ignored by Codable must not escape this check.
        for key in ["threads", "projects", "settings", "systemPromptPresets"] {
            let originalValue = try JSONSerialization.data(withJSONObject: ["value": originalObject[key] ?? NSNull()], options: [.sortedKeys])
            let encodedValue = try JSONSerialization.data(withJSONObject: ["value": encodedObject[key] ?? NSNull()], options: [.sortedKeys])
            XCTAssertEqual(originalValue, encodedValue, "Input fields or values changed in \(key)")
        }
        let again = try AppSnapshot.decodeLocal(encoded)
        XCTAssertEqual(again.threads, decoded.threads)
        XCTAssertEqual(again.projects, decoded.projects)
        XCTAssertEqual(again.settings, decoded.settings)
        XCTAssertEqual(try Data(contentsOf: url), source)
    }
    func testOlderProviderEnumRejectsCompatibleButCurrentOnePreservesIt() throws {
        enum Legacy: String, Decodable { case deepSeek, chatGPT, colab }
        let data = Data(#""compatible""#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Legacy.self, from: data))
        let current = try JSONDecoder().decode(AIProvider.self, from: data)
        XCTAssertEqual(current, .compatible)
        XCTAssertEqual(try JSONEncoder().encode(current), data)
    }
}
