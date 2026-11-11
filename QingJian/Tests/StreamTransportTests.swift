import XCTest
@testable import DeepSeekCore

final class StreamTransportTests: XCTestCase {
    private func decode(_ wire: String) throws -> [StreamEvent] {
        var decoder = SSEByteDecoder()
        var events: [StreamEvent] = []
        for byte in wire.utf8 {
            if let event = try decoder.consume(byte: byte) { events.append(event) }
        }
        if let event = try decoder.finish() { events.append(event) }
        return events
    }

    func testMultipleRawEventsAreDeliveredBeforeEOF() throws {
        var decoder = SSEByteDecoder()
        let frames = [
            #"data: {"choices":[{"delta":{"reasoning_content":"想一想"}}]}"# + "\n\n",
            #"data: {"choices":[{"delta":{"content":"你好"}}]}"# + "\n\n",
            #"data: {"choices":[{"delta":{"content":"，小龙"}}]}"# + "\n\n",
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":8}}"# + "\n\n",
            "data: [DONE]\n\n"
        ]
        var events: [StreamEvent] = []
        for (index, frame) in frames.enumerated() {
            for byte in frame.utf8 {
                if let event = try decoder.consume(byte: byte) { events.append(event) }
            }
            // Each complete event must arrive now, while the connection is open.
            XCTAssertEqual(events.count, index + 1)
        }
        XCTAssertEqual(events.map(\.content).joined(), "你好，小龙")
        XCTAssertEqual(events.map(\.reasoning).joined(), "想一想")
        XCTAssertEqual(events[3].finishReason, "stop")
        XCTAssertEqual(events[3].usage?.totalTokens, 13)
        XCTAssertTrue(events[4].isDone)
        XCTAssertNil(try decoder.finish())
    }

    func testLFCRLFAndCRPreserveEventBoundaries() throws {
        for ending in ["\n", "\r\n", "\r"] {
            let wire = ": keep-alive" + ending + ending
                + #"data: {"choices":[{"delta":{"content":"第一段"}}]}"# + ending + ending
                + #"data: {"choices":[{"delta":{"content":"第二段"}}]}"# + ending + ending
                + "data: [DONE]" + ending + ending
            let events = try decode(wire)
            XCTAssertEqual(events.count, 3, "line ending: \(ending.debugDescription)")
            XCTAssertEqual(events.map(\.content).joined(), "第一段第二段")
            XCTAssertTrue(events.last?.isDone == true)
        }
    }

    func testChineseAndEmojiSurviveOneByteAtATime() throws {
        let wire = "\u{FEFF}" + #"data: {"choices":[{"delta":{"content":"中文🌿\n第二行"}}]}"# + "\n\n"
        let events = try decode(wire)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.content, "中文🌿\n第二行")
    }

    func testUnterminatedDoneIsFlushedAtEOF() throws {
        let events = try decode(#"data: {"choices":[{"delta":{"content":"回答"}}]}"# + "\n\n"
            + "data: [DONE]")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.content, "回答")
        XCTAssertTrue(events.last?.isDone == true)
    }

    func testMultilineEventStillUsesSSEDataJoining() throws {
        let events = try decode("data: {\"choices\": [\n"
            + "data: {\"delta\":{\"content\":\"多行事件\"}}]}\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.content, "多行事件")
    }

    func testInvalidUTF8AndMalformedJSONAreRejected() throws {
        var decoder = SSEByteDecoder()
        XCTAssertNil(try decoder.consume(byte: 0xFF))
        XCTAssertThrowsError(try decoder.consume(byte: 0x0A))
        XCTAssertThrowsError(try decode("data: not JSON\n\n"))
    }

    #if canImport(Darwin)
    func testFoundationLineAdapterDiagnostic() async throws {
        let wire = #"data: {"choices":[{"delta":{"content":"一"}}]}"# + "\n\n"
            + #"data: {"choices":[{"delta":{"content":"二"}}]}"# + "\n\n"
            + "data: [DONE]\n\n"
        let source = AsyncStream<UInt8> { continuation in
            for byte in wire.utf8 { continuation.yield(byte) }
            continuation.finish()
        }
        var lines: [String] = []
        for try await line in source.lines { lines.append(line) }
        print("Foundation line adapter: \(lines.count) lines, \(lines.filter(\.isEmpty).count) empty SSE separators")
        // Exercise the old reader too, recording its behavior on this OS.
        var legacy = SSEDecoder()
        var legacyEvents: [StreamEvent] = []
        do {
            for line in lines {
                if let event = try legacy.consume(line: line) { legacyEvents.append(event) }
            }
            if let event = try legacy.flush() { legacyEvents.append(event) }
            print("Legacy line-based transport: \(legacyEvents.count) decoded events")
        } catch {
            print("Legacy line-based transport reproduced: \(error.localizedDescription)")
        }
        let events = try decode(wire)
        XCTAssertEqual(events.map(\.content).joined(), "一二")
        XCTAssertTrue(events.last?.isDone == true)
    }
    #endif
}
