import Foundation
import Combine

@MainActor
final class CompatibleEndpointStore: ObservableObject {
    @Published private(set) var configuration = CompatibleEndpointConfig()
    @Published private(set) var status = "未测试"
    @Published var issue: String?

    private let storageKey = "qingjian.compatible.configuration"
    private let keyPrefix = "qingjian.compatible.api-key."
    private var keyCache: [String: String] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(CompatibleEndpointConfig.self, from: data) {
            configuration = saved
        }
    }

    func apiKey(for preset: CompatiblePresetID? = nil) -> String {
        let id = (preset ?? configuration.activePreset).rawValue
        if let cached = keyCache[id] { return cached }
        let loaded = (try? KeychainStore.read(service: keyPrefix + id)) ?? ""
        keyCache[id] = loaded
        return loaded
    }

    var activeAPIKey: String { apiKey(for: configuration.activePreset) }

    func save(preset: CompatiblePresetID, baseURL: String, model: String, key: String) throws {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.contains("\n"), !cleanKey.contains("\r") else { throw CompatibleEndpointError.invalidKey }

        var next = configuration
        next.set(CompatiblePresetConfig(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines)
        ), for: preset)
        _ = try next.validatedURL(for: preset)

        let data = try JSONEncoder().encode(next)
        try KeychainStore.save(cleanKey, service: keyPrefix + preset.rawValue)
        keyCache[preset.rawValue] = cleanKey
        UserDefaults.standard.set(data, forKey: storageKey)
        configuration = next
        issue = nil
        status = "已保存"
    }

    func setToolsEnabled(_ enabled: Bool) {
        var next = configuration
        next.toolsEnabled = enabled
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        configuration = next
    }

    func probe(preset: CompatiblePresetID, baseURL: String, model: String, key: String) async {
        issue = nil
        do {
            var temp = configuration
            temp.set(CompatiblePresetConfig(
                baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                model: model.trimmingCharacters(in: .whitespacesAndNewlines)
            ), for: preset)
            let url = try temp.validatedURL(for: preset)
            let cleanModel = temp.settings(for: preset).model
            let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            try await CompatibleEndpointClient(baseURL: url, model: cleanModel, key: cleanKey).probe()
            status = "在线"
        } catch {
            status = "连接失败"
            issue = error.localizedDescription
        }
    }

    func stream(
        _ request: ChatRequest,
        onProgress: (@MainActor (ChatStreamProgress) -> Void)? = nil,
        onEvent: @escaping @MainActor (StreamEvent) -> Void
    ) async throws {
        let url = try configuration.validatedURL()
        let model = configuration.activeModel
        let key = activeAPIKey
        try await CompatibleEndpointClient(
            baseURL: url,
            model: model,
            key: key,
            toolsEnabled: configuration.allowsTools
        ).stream(request, onProgress: onProgress, onEvent: onEvent)
        status = "在线"
        issue = nil
    }
}
