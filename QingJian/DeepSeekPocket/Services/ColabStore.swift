import Foundation
import Combine

@MainActor
final class ColabStore: ObservableObject {
    @Published private(set) var configuration = ColabConfiguration()
    @Published private(set) var apiKey = ""
    @Published private(set) var status = "未开机"
    @Published private(set) var refreshing = false
    @Published var issue: String?
    private var refreshTask: Task<Void, Error>?
    private var revision = 0
    private var sourceAccount = ""
    private let storageKey = "qingjian.colab.configuration"
    private let keyService = "qingjian.colab.api-key"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(ColabConfiguration.self, from: data) { configuration = saved }
        sourceAccount = UserDefaults.standard.string(forKey: "qingjian.colab.driveAccount") ?? ""
        do { apiKey = try KeychainStore.read(service: keyService) }
        catch { issue = error.localizedDescription }
    }
    func save(_ next: ColabConfiguration, key: String, account: String = "") throws {
        _ = try next.url()
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.contains("\n"), !clean.contains("\r") else { throw ColabError.invalidKey }
        if next == configuration, clean == apiKey, account == sourceAccount { issue = nil; return }
        let data = try JSONEncoder().encode(next)
        try KeychainStore.save(clean, service: keyService)
        UserDefaults.standard.set(data, forKey: storageKey)
        UserDefaults.standard.set(account, forKey: "qingjian.colab.driveAccount")
        revision += 1
        configuration = next
        apiKey = clean
        sourceAccount = account
        issue = nil
        status = "未开机"
    }
    func refresh(from drive: GoogleDriveStore) async throws {
        if let refreshTask { return try await refreshTask.value }
        let version = revision, account = drive.accountLabel
        refreshing = true
        let task = Task { @MainActor in
            let data = try await drive.readColabEndpoint()
            try Task.checkCancellation()
            let endpoint = try JSONDecoder().decode(ColabEndpoint.self, from: data)
            guard let date = endpoint.date else { throw ColabError.configuration("endpoint.json 的 updated_at 不是有效的 ISO 时间。") }
            guard account == drive.accountLabel else { throw CancellationError() }
            guard version == self.revision else { return }
            if self.sourceAccount == account, let existing = self.configuration.updatedAt, date < existing { return }
            let next = ColabConfiguration(baseURL: endpoint.baseURL, model: endpoint.model, updatedAt: date)
            try self.save(next, key: endpoint.apiKey, account: account)
        }
        refreshTask = task
        defer { refreshTask = nil; refreshing = false }
        do { try await task.value }
        catch { issue = error.localizedDescription; throw error }
    }
    func probe(configuration: ColabConfiguration? = nil, key: String? = nil) async {
        issue = nil
        do {
            try await ColabClient(configuration: configuration ?? self.configuration, key: key ?? apiKey).probe()
            status = "在线"
        } catch {
            status = "未开机"
            issue = (error is URLError) ? ColabError.offline.localizedDescription : error.localizedDescription
        }
    }
    func stream(_ request: ChatRequest, options: ColabOptions, drive: GoogleDriveStore,
                onProgress: (@MainActor (ChatStreamProgress) -> Void)? = nil,
                onRestart: @escaping @MainActor () -> Void,
                onEvent: @escaping @MainActor (StreamEvent) -> Void) async throws {
        if (try? configuration.url()) == nil || (!sourceAccount.isEmpty && sourceAccount != drive.accountLabel) {
            try await refresh(from: drive)
        }
        for attempt in 0...1 {
            try Task.checkCancellation()
            do {
                try await ColabClient(configuration: configuration, key: apiKey)
                    .stream(request, options: options, onProgress: onProgress, onEvent: onEvent)
                status = "在线"
                issue = nil
                return
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                status = "未开机"
                issue = error.localizedDescription
                guard attempt == 0 else { throw error }
                do { try await refresh(from: drive) }
                catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    // A transient Drive failure may still leave a usable manually entered endpoint.
                }
                try Task.checkCancellation()
                onRestart()
            }
        }
    }
}
