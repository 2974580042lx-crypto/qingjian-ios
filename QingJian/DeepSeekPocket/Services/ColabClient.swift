import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class ColabClient: @unchecked Sendable {
    private let configuration: ColabConfiguration
    private let key: String
    init(configuration: ColabConfiguration, key: String) {
        self.configuration = configuration
        self.key = key
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: ColabRedirectDelegate(), delegateQueue: nil)
    }
    private func request(_ url: URL, body: [String: Any]? = nil) throws -> URLRequest {
        guard !key.contains("\n"), !key.contains("\r") else { throw ColabError.invalidKey }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
    func probe() async throws {
        let url = try configuration.url().appendingPathComponent("models")
        let session = session()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(url))
        try ColabError.validate(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["data"] as? [[String: Any]] else { throw ColabError.response }
        guard models.contains(where: { $0["id"] as? String == configuration.model }) else {
            throw ColabError.configuration("接口在线，但没有找到所填模型名，请从 Drive 刷新。")
        }
    }
    private func tokenCount(_ messages: [[String: Any]], tools: Any?, base: URL, session: URLSession,
                            thinking: Bool) async throws -> Int {
        var body: [String: Any] = ["messages": messages, "chat_template_kwargs": ["enable_thinking": thinking]]
        if let tools { body["tools"] = tools }
        let root = base.deletingLastPathComponent()
        do {
            let (template, response) = try await session.data(for: request(root.appendingPathComponent("apply-template"), body: body))
            if let status = (response as? HTTPURLResponse)?.statusCode, [400, 404, 405, 422, 501].contains(status) {
                return try JSONSerialization.data(withJSONObject: body).count + 128
            }
            try ColabError.validate(response)
            guard let object = try JSONSerialization.jsonObject(with: template) as? [String: Any],
                  let prompt = object["prompt"] as? String else { throw ColabError.response }
            let (tokens, tokenResponse) = try await session.data(for: request(root.appendingPathComponent("tokenize"),
                body: ["content": prompt, "add_special": true, "parse_special": true]))
            if let status = (tokenResponse as? HTTPURLResponse)?.statusCode, [404, 405, 501].contains(status) {
                return prompt.utf8.count + 128
            }
            try ColabError.validate(tokenResponse)
            guard let result = try JSONSerialization.jsonObject(with: tokens) as? [String: Any],
                  let ids = result["tokens"] as? [Any] else { throw ColabError.response }
            return ids.count
        } catch { throw error }
    }
    private func payload(_ original: ChatRequest, options: ColabOptions, base: URL, session: URLSession) async throws -> [String: Any] {
        guard var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any],
              var messages = body["messages"] as? [[String: Any]] else { throw ColabError.response }
        body["model"] = configuration.model
        body.removeValue(forKey: "thinking")
        body.removeValue(forKey: "reasoning_effort")
        body["chat_template_kwargs"] = ["enable_thinking": options.thinking]
        if !options.tools { body.removeValue(forKey: "tools"); body.removeValue(forKey: "tool_choice") }
        let context = min(max(options.context, 1024), 262144)
        let output = min(original.maxTokens, max(256, context / 4))
        var count = try await tokenCount(messages, tools: body["tools"], base: base, session: session, thinking: options.thinking)
        while count + output + 64 > context {
            guard let current = messages.lastIndex(where: { $0["role"] as? String == "user" }),
                  let first = messages.firstIndex(where: { $0["role"] as? String != "system" }), first < current else { break }
            let encodedSize = max(1, try JSONSerialization.data(withJSONObject: messages).count)
            let removeBytes = max(1, Int(Double(count + output + 64 - context) * Double(encodedSize) / Double(max(1, count))))
            var removedBytes = 0
            var firstIndex = first, currentIndex = current
            repeat {
                let next = messages.indices.first(where: { $0 > firstIndex && messages[$0]["role"] as? String == "user" }) ?? currentIndex
                let removed = messages.enumerated().filter { $0.offset >= firstIndex && $0.offset < next && $0.element["role"] as? String != "system" }.map(\.element)
                removedBytes += try JSONSerialization.data(withJSONObject: removed).count
                messages = messages.enumerated().filter { $0.offset < firstIndex || $0.offset >= next || $0.element["role"] as? String == "system" }.map(\.element)
                guard let earliest = messages.firstIndex(where: { $0["role"] as? String != "system" }),
                      let newest = messages.lastIndex(where: { $0["role"] as? String == "user" }), earliest < newest else { break }
                firstIndex = earliest; currentIndex = newest
            } while removedBytes < removeBytes
            count = try await tokenCount(messages, tools: body["tools"], base: base, session: session, thinking: options.thinking)
        }
        guard count + 64 < context else { throw ColabError.context }
        body["messages"] = messages
        body["max_tokens"] = min(output, context - count - 64)
        return body
    }
    func stream(_ original: ChatRequest, options: ColabOptions,
                onProgress: (@MainActor (ChatStreamProgress) -> Void)? = nil,
                onEvent: @escaping @MainActor (StreamEvent) -> Void) async throws {
        let base = try configuration.url()
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            let body = try await payload(original, options: options, base: base, session: session)
            if try await supportsRecovery(base: base, session: session) {
                try await recoverableStream(body, base: base, onProgress: onProgress, onEvent: onEvent)
                return
            }
            var request = try request(base.appendingPathComponent("chat/completions"), body: body)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let started = ProcessInfo.processInfo.systemUptime
            var lastProgress = started
            var progress = ChatStreamProgress(phase: .connecting, elapsedSeconds: 0, receivedBytes: 0, httpStatus: nil)
            await onProgress?(progress)
            let (bytes, response) = try await session.bytes(for: request)
            try ColabError.validate(response)
            guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                throw ColabError.response
            }
            progress.httpStatus = (response as? HTTPURLResponse)?.statusCode
            progress.phase = .waiting
            await onProgress?(progress)
            var decoder = SSEByteDecoder()
            var parser = ColabThoughtParser()
            var done = false, finished = false
            for try await byte in bytes {
                try Task.checkCancellation()
                progress.receivedBytes += 1
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastProgress >= 1 {
                    progress.elapsedSeconds = Int(now - started)
                    await onProgress?(progress)
                    lastProgress = now
                }
                guard let raw = try decoder.consume(byte: byte) else { continue }
                let event = parser.consume(raw, finish: raw.isDone || raw.finishReason != nil)
                let previousPhase = progress.phase
                if !event.content.isEmpty { progress.phase = .answering }
                else if !event.reasoning.isEmpty && progress.phase != .answering { progress.phase = .thinking }
                if progress.phase != previousPhase { await onProgress?(progress) }
                await onEvent(event)
                finished = finished || raw.finishReason != nil
                if raw.isDone { done = true; break }
            }
            if !done, let trailing = try decoder.finish() {
                await onEvent(parser.consume(trailing, finish: true))
                done = trailing.isDone
                finished = finished || trailing.finishReason != nil
            }
            try Task.checkCancellation()
            guard done || finished else { throw ColabError.offline }
            await onEvent(parser.consume(StreamEvent(), finish: true))
            progress.phase = .complete
            await onProgress?(progress)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if error is URLError { throw ColabError.offline }
            throw error
        }
    }

    private func supportsRecovery(base: URL, session: URLSession) async throws -> Bool {
        let (_, response) = try await session.data(for: request(base.appendingPathComponent("models")))
        try ColabError.validate(response)
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Sermo-Recovery") == "1"
    }

    private func recoverableStream(_ body: [String: Any], base: URL,
        onProgress: (@MainActor (ChatStreamProgress) -> Void)?,
        onEvent: @escaping @MainActor (StreamEvent) -> Void) async throws {
        let id = UUID().uuidString
        let jobURL = base.appendingPathComponent("requests").appendingPathComponent(id)
        let transport = session(), polling = session()
        let lease = await ColabBackgroundLease { transport.invalidateAndCancel() }
        defer {
            transport.invalidateAndCancel(); polling.invalidateAndCancel()
            Task { @MainActor in lease.end() }
        }
        let started = Date()
        var cursor = 0, done = false, terminal = false
        var parser = ColabThoughtParser()
        var progress = ChatStreamProgress(phase: .connecting, elapsedSeconds: 0, receivedBytes: 0, httpStatus: nil)
        await onProgress?(progress)
        func emit(_ raw: StreamEvent) async {
            let event = parser.consume(raw, finish: raw.isDone || raw.finishReason != nil)
            if !event.content.isEmpty { progress.phase = .answering }
            else if !event.reasoning.isEmpty && progress.phase != .answering { progress.phase = .thinking }
            progress.elapsedSeconds = Int(Date().timeIntervalSince(started))
            await onEvent(event)
            await onProgress?(progress)
            done = done || raw.isDone
            terminal = terminal || raw.finishReason != nil
            cursor += 1
        }
        do {
            // A lost submission response may still mean the server accepted this ID.
            // Recovery below queries the same ID; it never starts another generation.
            do {
                let (_, response) = try await polling.data(for: request(jobURL, body: body))
                try ColabError.validate(response)
                progress.httpStatus = (response as? HTTPURLResponse)?.statusCode
                progress.phase = .waiting
                await onProgress?(progress)
                var streamRequest = try request(jobURL.appendingPathComponent("events"))
                streamRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                let (bytes, streamResponse) = try await transport.bytes(for: streamRequest)
                try ColabError.validate(streamResponse)
                var decoder = SSEByteDecoder()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    progress.receivedBytes += 1
                    if let event = try decoder.consume(byte: byte) { await emit(event) }
                    if done { break }
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // Partial SSE events are deliberately discarded. The cursor counts only
                // fully delivered events, so snapshot recovery cannot duplicate text.
            }
            var failures = 0
            while !(done && terminal) {
                try Task.checkCancellation()
                guard Date().timeIntervalSince(started) < 3600 else {
                    throw ColabRecoveryFailure("恢复等待已超时，已收到的文字已保留。")
                }
                if await !lease.isActive {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                var parts = URLComponents(url: jobURL, resolvingAgainstBaseURL: false)!
                parts.queryItems = [URLQueryItem(name: "after", value: String(cursor))]
                var query = try request(parts.url!)
                query.timeoutInterval = 15
                let snapshot: ColabRecoverySnapshot
                do {
                    let (data, response) = try await polling.data(for: query)
                    if (response as? HTTPURLResponse)?.statusCode == 404 {
                        throw ColabRecoveryFailure("这次回复的云端缓存已过期或服务已重启，已收到的文字已保留。")
                    }
                    try ColabError.validate(response)
                    snapshot = try JSONDecoder().decode(ColabRecoverySnapshot.self, from: data)
                    failures = 0
                } catch let failure as ColabRecoveryFailure { throw failure }
                catch {
                    if Task.isCancelled { throw CancellationError() }
                    failures += 1
                    if failures >= 4 { throw ColabRecoveryFailure("暂时无法恢复云端回复，已收到的文字已保留，请稍后重试。") }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                guard snapshot.nextCursor == cursor + snapshot.events.count else {
                    throw ColabRecoveryFailure("恢复数据次序异常，已收到的文字已保留。")
                }
                for data in snapshot.events {
                    var decoder = SSEDecoder()
                    for line in data.components(separatedBy: "\n") { _ = try decoder.consume(line: "data: " + line) }
                    guard let event = try decoder.consume(line: "") else { throw ColabError.response }
                    await emit(event)
                }
                if snapshot.state == "error" || snapshot.state == "cancelled" {
                    throw ColabRecoveryFailure("云端生成已中断，已收到的文字已保留。")
                }
                if snapshot.state == "completed" && !snapshot.hasMore && !(done && terminal) {
                    throw ColabRecoveryFailure("云端回复缺少完整结束标记，已收到的文字已保留。")
                }
                if !snapshot.hasMore && !(done && terminal) { try await Task.sleep(nanoseconds: 700_000_000) }
            }
            await onEvent(parser.consume(StreamEvent(), finish: true))
            progress.phase = .complete
            await onProgress?(progress)
        } catch {
            // End the detached server job on explicit stop, timeout, or failed recovery.
            // Use an independent session because the parent task may be cancelled.
            let cancel = try? request(jobURL)
            Task.detached {
                guard var cancel else { return }
                cancel.httpMethod = "DELETE"; cancel.timeoutInterval = 10
                let cleanup = URLSession(configuration: .ephemeral)
                defer { cleanup.invalidateAndCancel() }
                _ = try? await cleanup.data(for: cancel)
            }
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let failure = error as? ColabRecoveryFailure { throw failure }
            throw ColabRecoveryFailure("云端回复恢复失败，已收到的文字已保留。")
        }
    }
}

struct ColabRecoveryFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct ColabRecoverySnapshot: Decodable {
    let state: String
    let events: [String]
    let nextCursor: Int
    let hasMore: Bool
    enum CodingKeys: String, CodingKey {
        case state, events
        case nextCursor = "next_cursor", hasMore = "has_more"
    }
}

#if canImport(UIKit)
@MainActor
private final class ColabBackgroundLease {
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private let interrupt: @Sendable () -> Void
    var isActive: Bool { UIApplication.shared.applicationState == .active }
    init(interrupt: @escaping @Sendable () -> Void) {
        self.interrupt = interrupt
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.begin() } })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
                self?.finishLease(); self?.interrupt()
            } })
        if !isActive { begin() }
    }
    private func begin() {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Colab stream recovery") { [weak self] in
            Task { @MainActor in self?.interrupt(); self?.finishLease() }
        }
    }
    private func finishLease() {
        if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
    }
    func end() {
        finishLease()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}
#else
@MainActor
private final class ColabBackgroundLease {
    var isActive: Bool { true }
    init(interrupt: @escaping @Sendable () -> Void) {}
    func end() {}
}
#endif

private final class ColabRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == task.originalRequest?.url?.host ? request : nil)
    }
}
