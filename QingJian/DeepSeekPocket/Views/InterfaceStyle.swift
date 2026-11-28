import SwiftUI
import Observation

/// 1.47: Sermo has one look (the Claude-like page). 瑞士 and 夜江 were retired in 1.45
/// and their code removed in 1.47; a value either left in settings is simply ignored.

/// Bumped whenever a 个性化 setting changes; colours and spacing read it, so every
/// screen redraws at once, keeping open sheets and unsaved drafts.
@Observable
final class StyleAppearance {
    static let shared = StyleAppearance()
    private(set) var revision = 0
    func bump() { revision += 1 }
}

/// Light or dark: with the system by default, or held on one side.
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    static let key = "sermo.appearance.mode"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "始终浅色"
        case .dark: return "始终深色"
        }
    }
    /// The scheme the window should use for a stored mode.
    static func scheme(_ raw: String) -> ColorScheme? {
        switch AppearanceMode(rawValue: raw) ?? .system {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Settings row: day and night. Saved at once; the app redraws in place.
@MainActor
struct AppearancePicker: View {
    @AppStorage(AppearanceMode.key) private var appearance = AppearanceMode.system.rawValue
    var body: some View {
        Picker("白天与夜晚", selection: $appearance) {
            ForEach(AppearanceMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
        }
        .accessibilityIdentifier("appearance-mode")
        .onChange(of: appearance) { _, _ in InkAppearance.apply() }
    }
}

/// The app's capsule and rounded card shapes, continuous corners throughout.
struct InkCapsule: Shape {
    func path(in rect: CGRect) -> Path { Capsule(style: .continuous).path(in: rect) }
}

struct InkRounded: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
    }
}

/// Lays children out in rows, wrapping to the next row when one is full (reply capsules).
struct FlowRows: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { y += rowHeight + spacing; x = 0; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : widest, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + size.width > bounds.maxX { y += rowHeight + spacing; x = bounds.minX; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: 个性化

/// Everything about how Sermo looks, in one page, with a live sample on top.
@MainActor
struct PersonalizationView: View {
    @AppStorage("qingjian.reading.size") private var readingSize = 16.0
    @AppStorage(Haptic.enabledKey) private var hapticsEnabled = true
    @AppStorage(Haptic.writingKey) private var writingHaptics = 2
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section { PersonalPreview() }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            Section {
                AppearancePicker()
            } header: { Text("界面") }
            .claudeCardRow()
            Section {
                FontSettingsRows()
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("正文字号"); Spacer(); Text("\(Int(readingSize))").foregroundStyle(Ink.ink3).monospacedDigit() }
                    Slider(value: $readingSize, in: 14...22, step: 1).tint(Ink.seal)
                }
                Toggle("正文稍粗", isOn: Binding(get: { Personal.mediumBody }, set: { Personal.setMediumBody($0) })).tint(Ink.seal)
                Toggle("加粗使用强调色", isOn: Binding(get: { Personal.boldUsesAccent }, set: { Personal.setBoldUsesAccent($0) })).tint(Ink.seal)
                choice("行距", key: Personal.spacingKey, fallback: "standard",
                       options: [("compact", "紧凑"), ("standard", "标准"), ("loose", "宽松")])
            } header: { Text("文字") } footer: {
                Text("字体与字号只作用于聊天正文，不改变菜单与设置界面。「正文稍粗」默认关闭以保持清晰粗细对比；「加粗使用强调色」默认关闭以对齐纯黑加粗。行距会连同段距一起变。")
            }
            .claudeCardRow()
            Section {
                SwatchRow(title: "正文颜色", key: Personal.textKey, presets: Personal.textPresets, fallback: "black")
                SwatchRow(title: "强调色", key: Personal.accentKey, presets: Personal.accentPresets, fallback: "clay")
                SwatchRow(title: "背景", key: Personal.paperKey, presets: Personal.paperPresets, fallback: "ivory", allowsCustom: false)
                BubbleSwatchRow()
            } header: { Text("颜色") } footer: {
                Text("强调色用在发送键、思考的小花与激活开关上。自选的颜色用于浅色模式，深色模式自动换成相配的深色。")
            }
            .claudeCardRow()
            Section {
                choice("左右留白", key: Personal.marginKey, fallback: "standard",
                       options: [("narrow", "窄"), ("standard", "标准"), ("wide", "宽")])
                Toggle("触感反馈", isOn: $hapticsEnabled).tint(Ink.seal)
                if hapticsEnabled {
                    Picker("出字震动", selection: $writingHaptics) {
                        Text("关").tag(0)
                        Text("轻").tag(1)
                        Text("中").tag(2)
                        Text("重").tag(3)
                    }
                    // Feel the new strength the moment you pick it.
                    .onChange(of: writingHaptics) { _, level in StreamHaptics.shared.sample(level: level) }
                }
            } header: { Text("布局与手感") } footer: {
                Text("「出字震动」跟着回答出字的节奏轻轻地震，句子结尾稍重；只在你停在对话底部看着时才震。换档时会震一下给你试。动效跟随 iOS「设置 → 辅助功能 → 动态效果 → 减弱动态效果」：打开后只淡入淡出，不再移动或循环。")
            }
            .claudeCardRow()
            Section {
                Button("恢复默认", role: .destructive) { confirmReset = true }
            } footer: {
                Text("恢复本页的颜色、字重、行距和留白，字号回到 16；字体和白天夜晚设置不变。")
            }
            .claudeCardRow()
        }
        .claudeGroupedFormStyle()
        .navigationTitle("个性化")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("恢复个性化默认设置？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) { Personal.resetAll(); readingSize = 16 }
        }
    }

    private func choice(_ title: String, key: String, fallback: String, options: [(String, String)]) -> some View {
        Picker(title, selection: Binding(get: {
            let raw = Personal.value(key)
            return options.contains { $0.0 == raw } ? raw : fallback
        }, set: { Personal.set($0, for: key) })) {
            ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
        }
    }
}

/// A row of colour dots plus, where allowed, the system colour picker for any colour.
@MainActor
struct SwatchRow: View {
    let title: String
    let key: String
    let presets: [Personal.Preset]
    let fallback: String
    var allowsCustom = true

    private var raw: String { Personal.value(key) }
    private var selectedID: String { Personal.hex(raw) != nil ? "custom" : (presets.contains { $0.id == raw } ? raw : fallback) }
    private var currentTitle: String {
        selectedID == "custom" ? "自选" : (presets.first { $0.id == selectedID }?.title ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title); Spacer(); Text(currentTitle).foregroundStyle(Ink.ink3) }
            FlowRows(spacing: 12) {
                ForEach(presets) { preset in
                    Button { Personal.set(preset.id, for: key) } label: {
                        Swatch(color: Color.adaptive(light: preset.light, dark: preset.dark), selected: selectedID == preset.id)
                    }
                    .buttonStyle(.pressFeedback)
                    .accessibilityLabel("\(title)：\(preset.title)")
                    .accessibilityAddTraits(selectedID == preset.id ? .isSelected : [])
                }
                if allowsCustom {
                    ColorPicker("", selection: Binding(get: {
                        Personal.hex(raw).map { Color.adaptive(light: $0, dark: $0) }
                            ?? Color.adaptive(light: presets.first { $0.id == selectedID }?.light ?? 0, dark: 0)
                    }, set: { Personal.set(Personal.hexString($0), for: key) }), supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel("自选\(title)")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Your bubble: soft grey, a wash of the accent, or any colour.
@MainActor
struct BubbleSwatchRow: View {
    private var raw: String { Personal.value(Personal.bubbleKey) }
    private var selected: String { Personal.hex(raw) != nil ? "custom" : (raw == "accent" ? "accent" : "grey") }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("你的气泡"); Spacer()
                Text(selected == "custom" ? "自选" : (selected == "accent" ? "强调色淡底" : "浅灰")).foregroundStyle(Ink.ink3)
            }
            HStack(spacing: 12) {
                Button { Personal.set("grey", for: Personal.bubbleKey) } label: {
                    Swatch(color: Ink.raised, selected: selected == "grey")
                }.buttonStyle(.pressFeedback).accessibilityLabel("你的气泡：浅灰")
                Button { Personal.set("accent", for: Personal.bubbleKey) } label: {
                    Swatch(color: Ink.seal.opacity(0.14), selected: selected == "accent")
                }.buttonStyle(.pressFeedback).accessibilityLabel("你的气泡：强调色淡底")
                ColorPicker("", selection: Binding(get: {
                    Personal.hex(raw).map { Color.adaptive(light: $0, dark: $0) } ?? Color.adaptive(light: 0xF1F1F0, dark: 0x292928)
                }, set: { Personal.set(Personal.hexString($0), for: Personal.bubbleKey) }), supportsOpacity: false)
                .labelsHidden().accessibilityLabel("自选气泡颜色")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct Swatch: View {
    let color: Color
    let selected: Bool
    var body: some View {
        Circle().fill(color).frame(width: 30, height: 30)
            .overlay(Circle().stroke(Ink.line, lineWidth: 1))
            .padding(3)
            .overlay(Circle().stroke(selected ? Ink.ink : Color.clear, lineWidth: 2))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }
}

/// The sample at the top of 个性化: your bubble, a short answer with a bold phrase, the
/// thinking flower and a send key, so every change shows at once.
@MainActor
private struct PersonalPreview: View {
    @AppStorage("qingjian.reading.size") private var readingSize = 16.0
    var body: some View {
        VStack(alignment: .leading, spacing: Personal.paragraphGap * 0.6) {
            HStack {
                Spacer(minLength: 40)
                Text("帮我想想周末去哪儿玩？")
                    .userMessageStyle()
                    .foregroundStyle(Ink.ink)
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .background(Personal.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            HStack(spacing: 7) {
                ThinkingMark(live: false, size: 14, tint: Ink.ink3.opacity(0.8))
                Text("已思考 2 秒").font(.system(size: 13, weight: .regular)).foregroundStyle(Ink.ink3).monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Ink.ink3.opacity(0.75))
            }
            MarkdownParagraph(text: "天气好的话，可以下午 3 点去**城郊的湖边**走走，顺便复习 15 个 `English` 单词。")
            HStack {
                ThinkingMark(live: true, size: 14)
                Spacer()
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(Ink.seal, in: Circle())
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Personal.margin).padding(.vertical, 18)
        .background(Ink.paper, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Ink.line, lineWidth: 1))
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("个性化预览")
    }
}
