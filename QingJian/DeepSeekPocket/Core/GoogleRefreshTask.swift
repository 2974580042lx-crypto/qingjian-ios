import Foundation

/// Shares an in-flight refresh only within one sign-in generation.
/// Kept outside the UI/network store so late, cancellation-ignoring responses
/// can be tested without OAuth, a real account, or the Keychain.
@MainActor
final class GoogleRefreshTask {
    private(set) var generation = 0
    private var task: Task<String, Error>?

    func invalidate() {
        generation += 1
        task?.cancel()
        task = nil
    }

    func value(operation: @escaping @MainActor (Int) async throws -> String) async throws -> String {
        if let task { return try await task.value }
        let started = generation
        let next = Task { @MainActor in
            let result = try await operation(started)
            guard self.generation == started else { throw CancellationError() }
            return result
        }
        task = next
        // An old response must not clear a newer generation's refresh.
        defer { if generation == started { task = nil } }
        return try await next.value
    }
}
