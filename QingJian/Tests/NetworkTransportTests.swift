import Foundation
import XCTest
@testable import DeepSeekCore

final class NetworkTransportTests: XCTestCase {
    private func client(_ mode: String) -> DeepSeekClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamFixtureProtocol.self]
        return DeepSeekClient(endpoint: URL(string: "https://fixture.invalid/\(mode)")!, configuration: configuration)
    }
    private var request: ChatRequest {
        ChatRequest(settings: AppSettings(), messages: [ChatMessage(role: .user, content: "private-message-sentinel")])
    }

    @MainActor func testHeartbeatThinkingAndAnswerTravelThroughURLSession() async throws {
        let record = NetworkRecord()
        try await client("success").stream(request: request, key: "fixture-key", onProgress: { record.progress.append($0) }) { record.events.append($0) }
        XCTAssertEqual(record.events.map(\.content).joined(), "OK")
        XCTAssertEqual(record.events.map(\.reasoning).joined(), "思考中")
        let transitions = record.progress.map(\.phase).reduce(into: [ChatStreamPhase]()) { result, phase in
            if result.last != phase { result.append(phase) }
        }
        XCTAssertEqual(transitions, [.connecting, .waiting, .thinking, .answering, .complete])
        let sent = try XCTUnwrap(StreamFixtureProtocol.recorded("/success"))
        XCTAssertEqual(sent.timeoutInterval, 600)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
    }

    @MainActor func testTimeoutBeforeHeadersIsDiagnosedWithoutSecrets() async throws {
        do {
            try await client("connect-timeout").stream(request: request, key: "private-key-sentinel") { _ in }
            XCTFail("Expected a connection timeout")
        } catch let error as ChatConnectionFailure {
            XCTAssertEqual(error.code, URLError.timedOut.rawValue)
            XCTAssertEqual(error.progress.phase, .connecting)
            XCTAssertNil(error.progress.httpStatus)
            XCTAssertFalse(error.diagnostic.contains("private-key-sentinel"))
            XCTAssertFalse(error.diagnostic.contains("private-message-sentinel"))
        }
    }

    @MainActor func testHeartbeatThenTimeoutIsWaitingForModel() async throws {
        do {
            try await client("waiting-timeout").stream(request: request, key: "fixture-key") { _ in }
            XCTFail("Expected a timeout after connecting")
        } catch let error as ChatConnectionFailure {
            XCTAssertEqual(error.progress.phase, .waiting)
            XCTAssertEqual(error.progress.httpStatus, 200)
            XCTAssertGreaterThan(error.progress.receivedBytes, 0)
        }
    }

    @MainActor func testInvalidKeyIsNotReportedAsTimeout() async throws {
        do {
            try await client("unauthorized").stream(request: request, key: "fixture-key") { _ in }
            XCTFail("Expected authentication failure")
        } catch let error as ChatError {
            guard case .invalidKey = error else { return XCTFail("Wrong error classification") }
        }
    }

    @MainActor func testInterruptedStreamPreservesReceivedText() async throws {
        let record = NetworkRecord()
        do {
            try await client("incomplete").stream(request: request, key: "fixture-key") { record.events.append($0) }
            XCTFail("Expected an incomplete stream")
        } catch let error as ChatError {
            guard case .incompleteStream = error else { return XCTFail("Wrong error classification") }
            XCTAssertEqual(record.events.map(\.content).joined(), "partial")
        }
    }

    @MainActor func testPendingStreamCanBeCancelled() async throws {
        let client = client("cancel")
        let payload = request
        let task = Task { try await client.stream(request: payload, key: "fixture-key") { _ in } }
        try await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
}

@MainActor private final class NetworkRecord {
    var events: [StreamEvent] = []
    var progress: [ChatStreamProgress] = []
}

private final class StreamFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests: [String: URLRequest] = [:]
    private let workLock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "qingjian.network-fixture.delivery")
    private var stopped = false
    private var work: [DispatchWorkItem] = []
    static func recorded(_ path: String) -> URLRequest? {
        lock.lock(); defer { lock.unlock() }; return requests[path]
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests[request.url!.path] = request; Self.lock.unlock()
        let mode = request.url!.lastPathComponent
        if mode == "connect-timeout" { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let status = mode == "unauthorized" ? 401 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        if status == 401 { client?.urlProtocolDidFinishLoading(self); return }
        emit(": keep-alive\r\n\r\n")
        if mode == "waiting-timeout" {
            schedule(after: 0.05) { self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
        } else if mode == "incomplete" {
            schedule(after: 0.03) {
                self.emit("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n")
                self.client?.urlProtocolDidFinishLoading(self)
            }
        } else if mode == "cancel" {
            schedule(after: 0.6) { self.client?.urlProtocolDidFinishLoading(self) }
        } else {
            schedule(after: 0.03) {
                let data = Data("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"思考中\"}}]}\n\n".utf8)
                for byte in data { self.client?.urlProtocol(self, didLoad: Data([byte])) }
            }
            schedule(after: 0.08) {
                self.emit("data: {\"choices\":[{\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\n")
                self.emit("data: [DONE]\n\n")
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    private func emit(_ string: String) { client?.urlProtocol(self, didLoad: Data(string.utf8)) }
    private func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.workLock.lock(); let stopped = self.stopped; self.workLock.unlock()
            if !stopped { action() }
        }
        workLock.lock(); work.append(item); workLock.unlock()
        // A real transport delivers ordered bytes. Keep EOF from overtaking
        // fragmented UTF-8 callbacks while Foundation processes their queue.
        deliveryQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }
    override func stopLoading() {
        workLock.lock(); stopped = true; work.forEach { $0.cancel() }; workLock.unlock()
    }
}
