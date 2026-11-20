import SwiftUI

/// Compact "Other Models (OpenAI-Compatible)" drawer inside Settings -> Models & Services.
struct CompatibleEndpointSettingsView: View {
    @ObservedObject var compatible: CompatibleEndpointStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPreset: CompatiblePresetID = .openAI
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var probing = false
    @State private var notice: String?

    var body: some View {
        Form {
            Section {
                Picker("服务预设", selection: $selectedPreset) {
                    ForEach(CompatiblePresetID.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .onChange(of: selectedPreset) { _, preset in
                    loadPreset(preset)
                }
            } header: {
                Text("选择模型服务")
            } footer: {
                Text("支持 OpenAI、Claude、Gemini 兼容接口及局域网 Ollama / LM Studio，各自的 API Key 分开保存在钥匙串。")
            }

            Section("连接参数") {
                TextField("Base URL", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("模型名称（如 gpt-4o）", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(selectedPreset.keyPlaceholder, text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                HStack {
                    Text("状态")
                    Spacer()
                    Text(probing ? "测试中…" : compatible.status)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        probing = true
                        await compatible.probe(preset: selectedPreset, baseURL: baseURL, model: model, key: apiKey)
                        probing = false
                    }
                } label: {
                    Label("测试连接", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(probing)
            }

            if let issue = compatible.issue {
                Section {
                    Text(issue).font(.footnote).foregroundStyle(.red)
                }
            }
            if let notice {
                Section {
                    Text(notice).font(.footnote).foregroundStyle(.green)
                }
            }
        }
        .claudeGroupedFormStyle()
        .navigationTitle("其他模型（兼容端点）")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    do {
                        try compatible.save(preset: selectedPreset, baseURL: baseURL, model: model, key: apiKey)
                        notice = "已保存「\(selectedPreset.title)」，可在聊天顶部切换「其他模型」使用。"
                    } catch {
                        compatible.issue = error.localizedDescription
                    }
                }
                .fontWeight(.semibold)
            }
        }
        .onAppear {
            selectedPreset = compatible.configuration.activePreset
            loadPreset(selectedPreset)
        }
    }

    private func loadPreset(_ preset: CompatiblePresetID) {
        let cfg = compatible.configuration.settings(for: preset)
        baseURL = cfg.baseURL
        model = cfg.model
        apiKey = compatible.apiKey(for: preset)
        compatible.issue = nil
        notice = nil
    }
}
