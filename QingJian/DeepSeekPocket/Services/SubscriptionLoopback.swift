import Foundation
import Network

/// Listens only on the device's IPv4 loopback interface for one OAuth attempt.
final class SubscriptionLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.xiaolong.qingjian.oauth.loopback")
    private let expectedState: String
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var callback: CheckedContinuation<URL, Error>?
    private var outcome: Result<URL, Error>?
    private var connections: [UUID: NWConnection] = [:]
    init(state: String) { expectedState = state }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.ready = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.newConnectionHandler = { [weak self] in self?.receive($0) }
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port else { self.finish(.failure(SubscriptionError.invalidCallback)); return }
                            self.ready?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!)
                            self.ready = nil
                        case .failed(let error): self.finish(.failure(error))
                        case .cancelled:
                            if self.outcome == nil { self.finish(.failure(SubscriptionError.cancelled)) }
                        default: break
                        }
                    }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 600) { [weak self] in self?.finish(.failure(SubscriptionError.timeout)) }
                } catch { self.finish(.failure(error)) }
            }
        }
    }
    func result() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let outcome = self.outcome { continuation.resume(with: outcome) }
                else { self.callback = continuation }
            }
        }
    }
    func cancel() { queue.async { self.finish(.failure(SubscriptionError.cancelled)) } }

    private func finish(_ result: Result<URL, Error>) {
        guard outcome == nil else { return }
        outcome = result
        if let ready { ready.resume(with: result); self.ready = nil }
        callback?.resume(with: result); callback = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }
    private func receive(_ connection: NWConnection) {
        guard outcome == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        read(connection, id: id, buffer: Data())
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in connection?.cancel(); self?.connections.removeValue(forKey: id) }
    }
    private func read(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer; if let data { buffer.append(data) }
            guard buffer.count <= 32768, error == nil else { self.close(connection, id: id); return }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { self.close(connection, id: id) } else { self.read(connection, id: id, buffer: buffer) }
                return
            }
            let text = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let lines = text.components(separatedBy: "\r\n")
            let request = lines.first?.split(separator: " ") ?? []
            let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
            let port = self.listener?.port?.rawValue ?? 0
            let host = "127.0.0.1:\(port)"
            guard request.count == 3, request[0] == "GET", hosts.count == 1,
                  hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == host,
                  request[1].hasPrefix("/auth/callback?"),
                  let url = URL(string: "http://\(host)\(request[1])"),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.path == "/auth/callback",
                  components.queryItems?.filter({ $0.name == "state" }).count == 1,
                  components.queryItems?.first(where: { $0.name == "state" })?.value == self.expectedState else {
                self.reply(connection, id: id, status: 400, body: "Invalid callback.", result: nil); return
            }
            self.reply(connection, id: id, status: 200, body: "<!doctype html><meta charset='utf-8'><title>返回 Sermo</title><h2>登录结果已收到</h2><p>请返回 Sermo，正在核验授权。</p>", result: url)
        }
    }
    private func close(_ connection: NWConnection, id: UUID) { connection.cancel(); connections.removeValue(forKey: id) }
    private func reply(_ connection: NWConnection, id: UUID, status: Int, body: String, result: URL?) {
        let data = Data(body.utf8)
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }; self.close(connection, id: id)
            if let result { self.finish(.success(result)) }
        })
    }
}
