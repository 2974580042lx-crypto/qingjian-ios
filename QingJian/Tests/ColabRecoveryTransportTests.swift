import XCTest
import Foundation
@testable import DeepSeekCore

private final class RecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var submissions = 0
    static var snapshots = 0
    static var cursors: [Int] = []
    static let events = [
        #"{"choices":[{"delta":{"content":"<thi"},"finish_reason":null}]}"#,
        #"{"choices":[{"delta":{"content":"nk>推理</think>你"},"finish_reason":null}]}"#,
        #"{"choices":[{"delta":{"content":"好。"},"finish_reason":"stop"}]}"#,
        "[DONE]"
    ]
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "recovery.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    private func send(_ value: Any, status: Int = 200, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"].merging(headers) { _, new in new })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func startLoading() {
        let path = request.url!.path
        if path == "/apply-template" { send(["prompt": "synthetic"]); return }
        if path == "/tokenize" { send(["tokens": [1, 2]]); return }
        if path == "/v1/models" { send(["data": [["id": "test"]]], headers: ["X-Sermo-Recovery": "1"]); return }
        if request.httpMethod == "POST", path.hasPrefix("/v1/requests/") {
            Self.lock.lock(); Self.submissions += 1; Self.lock.unlock()
            send(["state": "generating"], status: 202); return
        }
        if path.hasSuffix("/events") {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let text = Self.events.prefix(2).map { "data: \($0)\n\n" }.joined() + "data: {\"choices\":"
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            // A stream can end between events; recovery must neither lose nor repeat them.
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
        }
        if path.hasPrefix("/v1/requests/") {
            let after = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems?.first(where: { $0.name == "after" })?.value ?? "0")!
            Self.lock.lock(); Self.snapshots += 1; Self.cursors.append(after); Self.lock.unlock()
            send(["state": "completed", "events": Array(Self.events.dropFirst(after)),
                  "next_cursor": Self.events.count, "has_more": false]); return
        }
        send(["error": "unexpected route"], status: 404)
    }
}

final class ColabRecoveryTransportTests: XCTestCase {
    @MainActor
    func testInterruptedSSERecoversTextAndThinkingWithoutResubmitting() async throws {
        RecoveryURLProtocol.submissions = 0
        RecoveryURLProtocol.snapshots = 0
        RecoveryURLProtocol.cursors = []
        let client = ColabClient(configuration: ColabConfiguration(baseURL: "https://recovery.test/v1", model: "test"),
            key: "synthetic-only", sessionConfiguration: {
                let value = URLSessionConfiguration.ephemeral
                value.protocolClasses = [RecoveryURLProtocol.self]
                return value
            })
        let request = ChatRequest(settings: AppSettings(), messages: [ChatMessage(role: .user, content: "你好")])
        var text = "", reasoning = "", finished = false
        try await client.stream(request, options: ColabOptions(), onProgress: { _ in }) { event in
            text += event.content; reasoning += event.reasoning
            finished = finished || event.isDone
        }
        XCTAssertEqual(text, "你好。")
        XCTAssertEqual(reasoning, "推理")
        XCTAssertTrue(finished)
        XCTAssertEqual(RecoveryURLProtocol.submissions, 1)
        XCTAssertGreaterThan(RecoveryURLProtocol.snapshots, 0)
        XCTAssertTrue(RecoveryURLProtocol.cursors.allSatisfy { (0...2).contains($0) })
    }
}
