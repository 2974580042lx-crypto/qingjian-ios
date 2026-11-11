import SwiftUI

@MainActor
struct ColabSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var colab: ColabStore
    @State private var baseURL = ""
    @State private var key = ""
    @State private var model = ""
    @State private var options = ColabOptions()
    @State private var saved = false
    @State private var busy = false
    @State private var refreshError = ""
    @State private var showRefreshError = false
    var body: some View {
        Form {
            Section("连接 Colab") {
                TextField("Base URL（https://…/v1）", text: $baseURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("API Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("模型名", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    Button("测试连接") {
                        busy = true
                        Task {
                            await colab.probe(configuration: ColabConfiguration(baseURL: baseURL, model: model), key: key)
                            busy = false
                        }
                    }.disabled(busy)
                    Spacer()
                    Text(colab.status).font(TypeScale.caption).foregroundStyle(Ink.ink3)
                }
            }
            Section {
                Button {
                    Task {
                        do { try await colab.refresh(from: store.drive); loadEndpoint() }
                        catch {
                            refreshError = error.localizedDescription
                            showRefreshError = true
                        }
                    }
                } label: {
                    HStack {
                        Text(colab.refreshing ? "正在从 Drive 刷新…" : "从 Drive 刷新")
                        Spacer()
                        if colab.refreshing { ProgressView().controlSize(.small) }
                    }
                }.disabled(colab.refreshing)
                if let updated = colab.configuration.updatedAt {
                    LabeledContent("上次更新时间", value: updated.formatted(date: .abbreviated, time: .standard))
                } else { Text("尚未从 Drive 更新").foregroundStyle(Ink.ink3) }
            } footer: { Text("自动读取 Google Drive 中的 /EasyColab/endpoint.json。API Key 只保存在本机钥匙串，聊天备份不包含密钥。") }
            Section {
                Toggle("思考", isOn: $options.thinking)
                Picker("最大上下文", selection: $options.context) {
                    ForEach([4096, 8192, 16384, 32768, 65536, 131072, 262144], id: \.self) { value in
                        Text("\(value) Tokens").tag(value)
                    }
                }
                Toggle("工具调用（实验性）", isOn: $options.tools)
            } header: { Text("回答方式") } footer: { Text("上下文应与 llama-server 的配置一致。开启工具后，还需要启用项目里的相应 GitHub、Drive 工具。") }
            if let issue = colab.issue {
                Section { Text(issue).font(TypeScale.caption).foregroundStyle(Ink.ink3) }
            }
        }
        .font(TypeScale.body).scrollContentBackground(.hidden).background(AppBackground())
        .listRowSeparatorTint(Ink.line).foregroundStyle(Ink.ink).tint(Ink.ink)
        .navigationTitle("Colab").navigationBarTitleDisplayMode(.inline)
        .alert("从 Drive 刷新失败", isPresented: $showRefreshError) {
            Button("好", role: .cancel) { }
        } message: { Text(refreshError) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(saved ? "已保存" : "保存") {
                    saved = store.saveColab(configuration: ColabConfiguration(baseURL: baseURL, model: model,
                        updatedAt: colab.configuration.updatedAt), key: key, options: options)
                }.fontWeight(.semibold)
            }
        }
        .onAppear { loadEndpoint(); options = store.settings.colabOptions }
        .onChange(of: baseURL) { _, _ in saved = false }
        .onChange(of: key) { _, _ in saved = false }
        .onChange(of: model) { _, _ in saved = false }
        .onChange(of: options) { _, _ in saved = false }
    }
    private func loadEndpoint() {
        baseURL = colab.configuration.baseURL
        model = colab.configuration.model
        key = colab.apiKey
    }
}
