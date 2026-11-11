import XCTest
@testable import DeepSeekCore

final class GoogleRefreshTaskTests: XCTestCase {
    @MainActor
    func testReauthenticationDiscardsLateOldResponseAndAllowsFreshRefresh() async throws {
        let cache = GoogleRefreshTask()
        let transport = MockRefreshTransport()
        let old = Task { try await cache.value { _ in try await transport.fetch("old") } }
        try await transport.waitUntilStarted("old")

        // The same invalidation the store performs after a successful sign-in.
        cache.invalidate()
        // Deliberately ignore cancellation, as a response can already be in flight.
        transport.succeed("old", with: "old-token")
        do {
            _ = try await old.value
            XCTFail("A response from the old sign-in must be discarded")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }

        let fresh = Task { try await cache.value { _ in try await transport.fetch("fresh") } }
        try await transport.waitUntilStarted("fresh")
        transport.succeed("fresh", with: "new-token")
        let token = try await fresh.value
        XCTAssertEqual(token, "new-token")
        XCTAssertEqual(transport.requests, ["old", "fresh"])
    }

    @MainActor
    func testOldCompletionDoesNotClearNewInFlightRefresh() async throws {
        let cache = GoogleRefreshTask()
        let transport = MockRefreshTransport()
        let old = Task { try await cache.value { _ in try await transport.fetch("old") } }
        try await transport.waitUntilStarted("old")
        cache.invalidate()
        let fresh = Task { try await cache.value { _ in try await transport.fetch("fresh") } }
        try await transport.waitUntilStarted("fresh")
        transport.succeed("old", with: "old-token")
        _ = try? await old.value

        let entered = expectation(description: "second waiter entered the cache")
        let joined = Task { @MainActor in
            entered.fulfill()
            return try await cache.value { _ in
                XCTFail("The new in-flight refresh should be shared")
                return "unexpected-token"
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        transport.succeed("fresh", with: "new-token")
        let firstToken = try await fresh.value
        let secondToken = try await joined.value
        XCTAssertEqual(firstToken, "new-token")
        XCTAssertEqual(secondToken, "new-token")
        XCTAssertEqual(transport.requests, ["old", "fresh"])
    }

    @MainActor
    func testFailedRefreshDoesNotPoisonTheNextAttempt() async throws {
        let cache = GoogleRefreshTask()
        let transport = MockRefreshTransport()
        let failed = Task { try await cache.value { _ in try await transport.fetch("failed") } }
        try await transport.waitUntilStarted("failed")
        transport.fail("failed")
        do {
            _ = try await failed.value
            XCTFail("Expected the mocked failure")
        } catch MockRefreshTransport.Failure.unavailable {} catch { XCTFail("Unexpected error: \(error)") }

        let retry = Task { try await cache.value { _ in try await transport.fetch("retry") } }
        try await transport.waitUntilStarted("retry")
        transport.succeed("retry", with: "retry-token")
        let token = try await retry.value
        XCTAssertEqual(token, "retry-token")
        XCTAssertEqual(transport.requests, ["failed", "retry"])
    }
}

/// A controllable transport that never opens a URL or reads credentials.
@MainActor
private final class MockRefreshTransport {
    enum Failure: Error { case unavailable, didNotStart }
    private(set) var requests: [String] = []
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var started: [String: XCTestExpectation] = [:]

    func fetch(_ id: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(id)
            pending[id] = continuation
            started.removeValue(forKey: id)?.fulfill()
        }
    }

    func waitUntilStarted(_ id: String) async throws {
        guard pending[id] == nil else { return }
        let expectation = XCTestExpectation(description: "mock refresh started: \(id)")
        started[id] = expectation
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        guard result == .completed else { throw Failure.didNotStart }
    }

    func succeed(_ id: String, with token: String) {
        pending.removeValue(forKey: id)!.resume(returning: token)
    }

    func fail(_ id: String) {
        pending.removeValue(forKey: id)!.resume(throwing: Failure.unavailable)
    }
}
