import SwiftUI
import UIKit

/// Compact Claude-style voice dictation & 313/Politics oral-drill ("口述抽背") sheet.
@MainActor
struct VoiceDictationSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var controller = VoiceDictationController()
    @State private var mode: VoiceInputMode
    @State private var hasAutoStarted = false

    let activeProject: ChatProject?
    let onInsertDraft: (String) -> Void
    let onSendDirectly: (String) -> Void

    init(
        activeProject: ChatProject?,
        onInsertDraft: @escaping (String) -> Void,
        onSendDirectly: @escaping (String) -> Void
    ) {
        self.activeProject = activeProject
        self.onInsertDraft = onInsertDraft
        self.onSendDirectly = onSendDirectly
        _mode = State(initialValue: OralDrillPromptBuilder.defaultMode(for: activeProject))
    }

    private var cleanTranscript: String {
        controller.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Picker("模式", selection: $mode) {
                    ForEach(VoiceInputMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18)
                .padding(.top, 6)

                if mode == .oralDrill {
                    HStack(spacing: 6) {
                        Image(systemName: "graduationcap")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Ink.seal)
                        Text(oralDrillBannerText)
                            .font(TypeScale.tiny)
                            .foregroundStyle(Ink.ink2)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Ink.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 18)
                }

                // Editable live transcript area so minor homophones can be fixed in one tap
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $controller.transcript)
                        .font(TypeScale.ui(16))
                        .foregroundStyle(Ink.ink)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                    if controller.transcript.isEmpty {
                        Text(mode == .oralDrill
                             ? "对着手机直接口述背诵答案（例如：两税法背景、内容与影响），说完点「发给 Sermo 判分」…"
                             : "对着手机说话，识别后的文字会实时出现在这里，也可以手动微调…")
                            .font(TypeScale.ui(15))
                            .foregroundStyle(Ink.ink3)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 118, maxHeight: 180)
                .background(Color.adaptive(light: 0xF6F6F5, dark: 0x202020), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Ink.line, lineWidth: 0.8))
                .padding(.horizontal, 18)

                if let error = controller.errorMessage {
                    VStack(spacing: 8) {
                        Text(error)
                            .font(TypeScale.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                        if controller.authState == .microphoneDenied || controller.authState == .speechDenied {
                            Button("前往系统设置开启权限") {
                                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(settingsURL)
                                }
                            }
                            .font(TypeScale.ui(13.5, weight: .medium))
                            .foregroundStyle(Ink.seal)
                        }
                    }
                    .padding(.horizontal, 18)
                } else {
                    Text(controller.statusMessage)
                        .font(TypeScale.caption)
                        .foregroundStyle(controller.isListening ? Ink.seal : Ink.ink3)
                }

                // Calm mic toggle button with live audio level halo
                Button {
                    Haptic.tap()
                    if controller.isListening {
                        controller.stopListening()
                        controller.statusMessage = cleanTranscript.isEmpty ? "点击话筒重新开始说话" : "已暂停收音，可编辑或发送"
                    } else {
                        Task {
                            await controller.startListening(beforeStart: { store.speech.stop() })
                        }
                    }
                } label: {
                    ZStack {
                        if controller.isListening {
                            Circle()
                                .fill(Ink.seal.opacity(0.18))
                                .frame(
                                    width: 68 + CGFloat(controller.audioLevel * 24),
                                    height: 68 + CGFloat(controller.audioLevel * 24)
                                )
                                .animation(.easeOut(duration: 0.12), value: controller.audioLevel)
                        }
                        Circle()
                            .fill(controller.isListening ? Ink.seal : Ink.solid)
                            .frame(width: 62, height: 62)
                        Image(systemName: controller.isListening ? "stop.fill" : "mic.fill")
                            .font(.system(size: controller.isListening ? 20 : 24, weight: .medium))
                            .foregroundStyle(controller.isListening ? Ink.onSeal : Ink.onSolid)
                    }
                    .frame(width: 92, height: 84)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(controller.isListening ? "停止语音收音" : "开始语音收音")

                // Bottom action row
                HStack(spacing: 10) {
                    Button {
                        Haptic.tap()
                        controller.clear()
                    } label: {
                        Text("重说")
                            .font(TypeScale.ui(14.5, weight: .medium))
                            .foregroundStyle(Ink.ink2)
                            .frame(height: 44)
                            .padding(.horizontal, 16)
                            .background(Ink.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.pressFeedback)
                    .disabled(cleanTranscript.isEmpty)

                    Button {
                        Haptic.tap()
                        controller.stopListening()
                        let payload = preparedText
                        dismiss()
                        onInsertDraft(payload)
                    } label: {
                        Text("填入输入框")
                            .font(TypeScale.ui(14.5, weight: .medium))
                            .foregroundStyle(Ink.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Ink.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Ink.line, lineWidth: 0.8))
                    }
                    .buttonStyle(.pressFeedback)
                    .disabled(cleanTranscript.isEmpty)

                    Button {
                        Haptic.tap()
                        controller.stopListening()
                        let payload = preparedText
                        dismiss()
                        onSendDirectly(payload)
                    } label: {
                        Text(mode.sendButtonTitle)
                            .font(TypeScale.ui(14.5, weight: .medium))
                            .foregroundStyle(Ink.onSeal)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(cleanTranscript.isEmpty ? Ink.line : Ink.seal, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.pressFeedback)
                    .disabled(cleanTranscript.isEmpty || !store.canChat)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(mode == .oralDrill ? "口述抽背" : "语音输入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ClaudeSheetCloseButton(label: "关闭") {
                        controller.stopListening()
                        dismiss()
                    }
                }
            }
        }
        .tint(Ink.ink)
        .presentationDetents([.fraction(0.56), .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            guard !hasAutoStarted else { return }
            hasAutoStarted = true
            Task {
                await controller.startListening(beforeStart: { store.speech.stop() })
            }
        }
        .onDisappear {
            controller.stopListening()
        }
    }

    private var preparedText: String {
        switch mode {
        case .dictation:
            return cleanTranscript
        case .oralDrill:
            return OralDrillPromptBuilder.buildOralDrillSubmission(spoken: cleanTranscript, project: activeProject)
        }
    }

    private var oralDrillBannerText: String {
        switch activeProject?.studySubject {
        case .history:
            return "已自动匹配 313 历史学考研采分点批改，口述完一键判分与纠偏。"
        case .politics:
            return "已自动匹配考研政治采分点批改，口述完一键核对原理与关键词。"
        case .english:
            return "已进入英语口述复述/翻译核对模式。"
        case nil:
            return "口述抽背模式：发送后 Sermo 会按采分点批改遗漏并给出考场表述。"
        }
    }
}
