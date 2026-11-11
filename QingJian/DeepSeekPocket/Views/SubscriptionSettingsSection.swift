import SwiftUI

// Ported from 研习. Signing in, the model list and the credits confirmation act at once;
// the chosen model is part of the settings and saves with the rest.
@MainActor
struct SubscriptionSettingsSection: View {
    @ObservedObject var connection: SubscriptionStore
    @Binding var model: String?
    var requestInProgress: Bool
    private var selected: String { model ?? SubscriptionModel.fallbackSlug }
    var body: some View {
        Section {
            LabeledContent("账号", value: connection.accountLabel)
                .accessibilityIdentifier("subscription-account")
            if connection.signingIn {
                HStack { ProgressView(); Text(connection.loginStage).font(TypeScale.serif(16)) }
                Button("取消登录") { connection.cancelSignIn() }
            } else {
                Button(connection.connected ? (connection.planAllowed ? "重新登录 ChatGPT" : "授权使用 ChatGPT 套餐") : "Continue with ChatGPT") { connection.signIn() }
                    .accessibilityIdentifier("subscription-sign-in")
                    .disabled(connection.busy || requestInProgress)
            }
            if connection.connected {
                LabeledContent("套餐权限", value: connection.planAllowed ? "已授权" : "尚未授权")
                Button {
                    Task { await connection.refreshModels() }
                } label: {
                    HStack { Text(connection.loadingModels ? "正在读取模型…" : "刷新账号模型"); Spacer(); if connection.loadingModels { ProgressView() } }
                }.disabled(connection.busy || requestInProgress)
                if !connection.models.isEmpty {
                    Picker("默认模型", selection: Binding(get: { selected }, set: { model = $0 })) {
                        if !connection.models.contains(where: { $0.slug == selected }) { Text("请选择可用模型").tag(selected) }
                        ForEach(connection.models) { item in Text(item.displayName).tag(item.slug) }
                    }.accessibilityIdentifier("subscription-model-picker")
                        .disabled(connection.busy || requestInProgress)
                }
                Toggle("我已关闭额外 credits 使用", isOn: Binding(get: { connection.includedUsageConfirmed }, set: { connection.confirmIncludedUsage($0) }))
                    .accessibilityIdentifier("subscription-included-usage")
                    .disabled(connection.busy || requestInProgress)
                Text("请在 ChatGPT「设置 → 用量」关闭额度用完后允许其他应用使用 credits，再在这里确认。这是你的确认记录，不会替你更改 ChatGPT 的开关。")
                    .font(TypeScale.serif(12)).foregroundStyle(.secondary)
                Button(connection.testing ? "正在测试…" : "发送一句连接测试") {
                    Task { await connection.test(model: selected) }
                }.disabled(!connection.ready || connection.busy || requestInProgress || !connection.models.contains(where: { $0.slug == selected }))
                    .accessibilityIdentifier("subscription-test")
                if let result = connection.testResult { Text(result).font(TypeScale.serif(12)).textSelection(.enabled) }
                Button("退出本机账号", role: .destructive) { connection.disconnect() }
                    .disabled(connection.busy || requestInProgress)
            }
            if let issue = connection.issue { Text(issue).font(TypeScale.serif(15)).accessibilityIdentifier("subscription-issue") }
            Link("打开 ChatGPT 用量设置", destination: URL(string: "https://chatgpt.com/settings/usage")!)
        } header: { Text("ChatGPT 订阅") } footer: {
            Text("用你已有的 ChatGPT 套餐额度回答，不按次扣钱，回答下方只显示 token 数。在项目「⋯ → 服务」里选 ChatGPT 订阅，这个项目就用它。登录凭证保存在本机钥匙串，不进入聊天备份。退出本机账号后，可到 ChatGPT 设置中撤销 Sermo 的授权。")
        }
        .task { if connection.connected && connection.models.isEmpty { await connection.refreshModels() } }
    }
}
