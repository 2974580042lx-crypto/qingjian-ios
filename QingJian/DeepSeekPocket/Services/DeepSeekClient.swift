import Foundation

final class DeepSeekClient: @unchecked Sendable {
    static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    static let balanceEndpoint = URL(string: "https://api.deepseek.com/user/balance")!
    private let chatEndpoint: URL
    private let suppliedConfiguration: URLSessionConfiguration?
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval

    init(endpoint: URL = DeepSeekClient.endpoint, configuration: URLSessionConfiguration? = nil,
         requestTimeout: TimeInterval = 600, resourceTimeout: TimeInterval = 1800) {
        self.chatEndpoint = endpoint
        self.suppliedConfiguration = configuration
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }

    func checkConnection(key: String) async throws -> AccountBalance {
        let cleanKey = try validatedKey(key)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: SameHostRedirectDelegate(host: "api.deepseek.com"), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: Self.balanceEndpoint, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try validateHTTPResponse(response)
        guard let balance = try? JSONDecoder().decode(AccountBalance.self, from: data) else { throw ChatError.invalidResponse }
        return balance
    }

    func stream(request payload: ChatRequest, key: String,
                onProgress: (@MainActor (ChatStreamProgress) -> Void)? = nil,
                onEvent: @escaping @MainActor (StreamEvent) -> Void) async throws {
        let cleanKey = try validatedKey(key)
        let configuration = suppliedConfiguration.map { $0.copy() as! URLSessionConfiguration } ?? .ephemeral
        // DeepSeek may send only keep-alive comments while a request is queued.
        // Explicit request and session intervals avoid an implicit request default.
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration,
            delegate: SameHostRedirectDelegate(host: chatEndpoint.host ?? "api.deepseek.com"), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: chatEndpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)
        let started = ProcessInfo.processInfo.systemUptime
        var lastProgress = started
        var progress = ChatStreamProgress(phase: .connecting, elapsedSeconds: 0, receivedBytes: 0, httpStatus: nil)
        await onProgress?(progress)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            progress.httpStatus = (response as? HTTPURLResponse)?.statusCode
            progress.phase = .waiting
            progress.elapsedSeconds = Int(ProcessInfo.processInfo.systemUptime - started)
            await onProgress?(progress)
            try validateHTTPResponse(response)
            guard let http = response as? HTTPURLResponse,
                  http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                throw ChatError.invalidResponse
            }
            var decoder = SSEByteDecoder()
            var done = false
            for try await byte in bytes {
                try Task.checkCancellation()
                progress.receivedBytes += 1
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastProgress >= 1 {
                    progress.elapsedSeconds = Int(now - started)
                    await onProgress?(progress)
                    lastProgress = now
                }
                guard let event = try decoder.consume(byte: byte) else { continue }
                let previous = progress.phase
                if !event.content.isEmpty { progress.phase = .answering }
                else if !event.reasoning.isEmpty && progress.phase != .answering { progress.phase = .thinking }
                if progress.phase != previous {
                    progress.elapsedSeconds = Int(now - started)
                    await onProgress?(progress)
                }
                await onEvent(event)
                if event.isDone { done = true; break }
            }
            if !done, let trailing = try decoder.finish() {
                await onEvent(trailing)
                done = trailing.isDone
            }
            try Task.checkCancellation()
            guard done else { throw ChatError.incompleteStream }
            progress.phase = .complete
            progress.elapsedSeconds = Int(ProcessInfo.processInfo.systemUptime - started)
            await onProgress?(progress)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let error = error as? URLError {
                progress.elapsedSeconds = Int(ProcessInfo.processInfo.systemUptime - started)
                throw ChatConnectionFailure(code: error.code.rawValue, progress: progress, model: payload.model)
            }
            throw error
        }
    }

    private func validatedKey(_ key: String) throws -> String {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { throw ChatError.missingKey }
        guard !cleanKey.contains("\n"), !cleanKey.contains("\r") else { throw ChatError.invalidKey }
        return cleanKey
    }
    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ChatError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw ChatError.invalidKey
        case 402: throw ChatError.insufficientBalance
        case 429: throw ChatError.rateLimited
        default: throw ChatError.http(http.statusCode)
        }
    }
}

private final class SameHostRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String
    init(host: String) { self.host = host }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == host ? request : nil)
    }
}
