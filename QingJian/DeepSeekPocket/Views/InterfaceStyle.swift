import SwiftUI
import Observation

/// The whole look of the app, chosen in Settings → 个性化 → 界面风格.
/// 纸笺: warm paper, Songti, highlighter strokes, liquid glass.
/// 瑞士: grey-white sheet, black sans, blue bold emphasis, ruled grid, square edges.
/// 夜江 (千江有水千江月): night river, moonlight the only colour, Songti, liquid glass.
///   Always dark. It shares the paper look's layout; only colours, the moon mark,
///   the sidebar's moon phases, reply capsules and the bookshelf's spines differ.
/// Colours and fonts read it through `StyleAppearance`, so a switch redraws the
/// app in place, keeping open sheets and unsaved drafts, the way a font change does.
enum InterfaceStyle: String, CaseIterable, Identifiable, Sendable {
    case paper, swiss, night

    static let key = "sermo.interface.style"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .paper: return "纸笺"
        case .swiss: return "瑞士"
        case .night: return "夜江"
        }
    }
    var detail: String {
        switch self {
        case .paper: return "暖纸色、重点加粗、液态玻璃"
        case .swiss: return "灰白底、黑体、蓝色粗体、网格线与方角"
        case .night: return "千江有水千江月：夜色江水、重点加粗，始终是深色"
        }
    }

    /// The look views draw with. Reading it inside a view's body subscribes that view to changes.
    static var current: InterfaceStyle { StyleAppearance.shared.style }
    static var isSwiss: Bool { current == .swiss }
    static var isNight: Bool { current == .night }

    /// What is saved in Settings.
    static var stored: InterfaceStyle {
        InterfaceStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .paper
    }
}

/// Observable holder for the current look; `reload()` after the setting changes.
@Observable
final class StyleAppearance {
    static let shared = StyleAppearance()
    private(set) var style: InterfaceStyle
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-preview") {
            // Preview runs start from their launch flag, so a value left in the
            // simulator never changes a screenshot; the picker can still switch.
            let flagged: InterfaceStyle = arguments.contains("--preview-swiss") ? .swiss
                : (arguments.contains("--preview-night") ? .night : .paper)
            UserDefaults.standard.set(flagged.rawValue, forKey: InterfaceStyle.key)
        }
        style = InterfaceStyle.stored
    }
    func reload() {
        let value = InterfaceStyle.stored
        if value != style { style = value }
    }
    /// Bumped whenever a 个性化 setting changes; colours and spacing read it, so every
    /// screen redraws at once.
    private(set) var revision = 0
    func bump() { revision += 1 }
}

/// Light or dark for 纸笺 and 瑞士: with the system by default, or held on one side.
/// 夜江 is a night scene and always stays dark.
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
    /// The scheme the window should use for a stored mode in the current look.
    static func scheme(_ raw: String) -> ColorScheme? {
        if InterfaceStyle.isNight { return .dark }
        switch AppearanceMode(rawValue: raw) ?? .system {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Settings row: pick the look. Saved at once; the app redraws in place.
@MainActor
struct InterfaceStylePicker: View {
    @AppStorage(InterfaceStyle.key) private var stored = InterfaceStyle.paper.rawValue
    @AppStorage(AppearanceMode.key) private var appearance = AppearanceMode.system.rawValue
    var body: some View {
        Picker("界面风格", selection: $stored) {
            ForEach(InterfaceStyle.allCases) { style in
                Text(style.title).tag(style.rawValue)
            }
        }
        .accessibilityIdentifier("interface-style")
        .accessibilityValue((InterfaceStyle(rawValue: stored) ?? .paper).title)
        // The app also listens for this key; reloading here as well makes the switch immediate.
        .onChange(of: stored) { _, _ in StyleAppearance.shared.reload(); InkAppearance.apply() }
        Picker("白天与夜晚", selection: $appearance) {
            ForEach(AppearanceMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
        }
        .disabled(InterfaceStyle(rawValue: stored) == .night)
        .accessibilityIdentifier("appearance-mode")
        Text((InterfaceStyle(rawValue: stored) ?? .paper).detail + "。切换后整个 App 立刻换样式，对话和设置都不受影响。纸笺和瑞士默认跟着手机的浅色、深色模式自动切换，也可以固定一边；瑞士风格固定使用系统字体；夜江始终是深色。")
            .font(TypeScale.serif(13)).foregroundStyle(.secondary)
    }
}

// MARK: - Swiss pieces shared by several screens

/// Small monospaced label: Q.01, A.01, COPY, FLASH / HIGH.
struct MonoLabel: View {
    let text: String
    var color: Color = Ink.ink3
    var size: CGFloat = 11
    var body: some View {
        Text(text).font(TypeScale.mono(size)).tracking(0.4).foregroundStyle(color)
    }
}

/// Full-width rule; the Swiss look separates with lines instead of space and shadow.
struct SwissRule: View {
    var weight: CGFloat = 1
    var strong = false
    var body: some View {
        Rectangle().fill(strong ? Ink.ink : Ink.line).frame(height: weight).accessibilityHidden(true)
    }
}

/// The big title block that opens a conversation in the Swiss look.
struct SwissThreadHeader: View {
    let title: String
    let date: Date
    let model: String
    let rounds: Int
    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(TypeScale.heavy(30, relativeTo: .largeTitle))
                .tracking(-0.4).lineSpacing(2)
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack {
                MonoLabel(text: Self.dateFormat.string(from: date))
                Spacer(minLength: 8)
                MonoLabel(text: model.uppercased()).lineLimit(1)
                Spacer(minLength: 8)
                MonoLabel(text: String(format: "%02d 轮", rounds))
            }
            SwissRule(weight: 2, strong: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A capsule in the paper look, a plain rectangle in the Swiss look.
/// The look is captured when the view is built, so a switch redraws the shape.
struct InkCapsule: Shape {
    var swiss = InterfaceStyle.isSwiss
    func path(in rect: CGRect) -> Path {
        swiss ? Path(rect) : Capsule(style: .continuous).path(in: rect)
    }
}

/// Rounded corners in the paper look, square in the Swiss look.
struct InkRounded: Shape {
    var radius: CGFloat
    var swiss = InterfaceStyle.isSwiss
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: swiss ? 0 : radius, style: .continuous).path(in: rect)
    }
}

// MARK: - 夜江 pieces shared by several screens

/// Sermo's mark in the 夜江 look: a pale gold moon with a soft halo.
/// `glow` brightens it while an answer is on its way ("月出").
struct MoonDisc: View {
    var size: CGFloat = 20
    var glow = false
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 1, green: 0.965, blue: 0.867), Ink.seal,
                                          Color(red: 0.80, green: 0.68, blue: 0.45)],
                                 center: UnitPoint(x: 0.38, y: 0.36), startRadius: 0, endRadius: size * 0.62))
            .frame(width: size, height: size)
            .shadow(color: Ink.seal.opacity(glow ? 0.75 : 0.35), radius: glow ? size * 0.9 : size * 0.55)
            .shadow(color: Ink.seal.opacity(glow ? 0.35 : 0.16), radius: glow ? size * 2.6 : size * 1.6)
            .accessibilityHidden(true)
    }
}

/// The lit part of a waxing moon: 0 is a new moon, 1 a full moon, lit on the right.
struct MoonLitShape: Shape {
    var phase: Double
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let p = CGFloat(min(1, max(0, phase)))
        var path = Path()
        guard p > 0.02 else { return path }
        // Right half of the disc, top to bottom.
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        // Back up along the terminator: an ellipse whose width shrinks to zero at half moon.
        let rx = abs(1 - 2 * p) * r
        let steps = 24
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let angle = CGFloat.pi / 2 - t * CGFloat.pi       // 90° → -90°, bottom to top
            let x = p < 0.5 ? c.x + rx * cos(angle) : c.x - rx * cos(angle)
            path.addLine(to: CGPoint(x: x, y: c.y + r * sin(angle)))
        }
        path.closeSubpath()
        return path
    }
}

/// A conversation's moon phase in the 夜江 sidebar: the longer the talk, the fuller the moon.
struct MoonPhaseIcon: View {
    var phase: Double
    var size: CGFloat = 18
    var body: some View {
        ZStack {
            Circle().stroke(Ink.line, lineWidth: 1)
            MoonLitShape(phase: phase).fill(Ink.seal)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// One full moon at about thirty of your messages; a sliver as soon as a talk starts.
    static func phase(for thread: ChatThread) -> Double {
        let turns = thread.messages.reduce(0) { $0 + ($1.role == .user ? 1 : 0) }
        guard turns > 0 else { return 0.06 }
        return min(1, 0.1 + Double(turns) / 30)
    }
}

/// A faint water line between exchanges in the 夜江 look.
struct WaveRule: View {
    var body: some View {
        WaveShape().stroke(Ink.line, lineWidth: 1).frame(height: 8).accessibilityHidden(true)
    }
}

struct WaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY, w = rect.width
        path.move(to: CGPoint(x: rect.minX, y: mid))
        let segments = 4
        for index in 0..<segments {
            let x0 = rect.minX + w * Double(index) / Double(segments)
            let x1 = rect.minX + w * Double(index + 1) / Double(segments)
            let lift: Double = index % 2 == 0 ? -3 : 3
            path.addCurve(to: CGPoint(x: x1, y: mid),
                          control1: CGPoint(x: x0 + (x1 - x0) / 3, y: mid + lift),
                          control2: CGPoint(x: x0 + (x1 - x0) * 2 / 3, y: mid - lift))
        }
        return path
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
    @AppStorage("qingjian.reading.size") private var readingSize = 18.0
    @AppStorage("qingjian.reading.aiBubble") private var aiBubble = false
    @AppStorage("qingjian.haptics") private var hapticsEnabled = true
    @State private var confirmReset = false
    private var appliesHere: Bool { !InterfaceStyle.isSwiss && !InterfaceStyle.isNight }

    var body: some View {
        Form {
            Section { PersonalPreview() }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            Section {
                InterfaceStylePicker()
            } header: { Text("界面") }
            Section {
                FontSettingsRows()
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("正文字号"); Spacer(); Text("\(Int(readingSize))").foregroundStyle(Ink.ink3).monospacedDigit() }
                    Slider(value: $readingSize, in: 15...23, step: 1)
                }
                Toggle("正文稍粗", isOn: Binding(get: { Personal.mediumBody }, set: { Personal.setMediumBody($0) }))
                Toggle("加粗使用强调色", isOn: Binding(get: { Personal.boldUsesAccent }, set: { Personal.setBoldUsesAccent($0) }))
                choice("行距", key: Personal.spacingKey, fallback: "standard",
                       options: [("compact", "紧凑"), ("standard", "标准"), ("loose", "宽松")])
            } header: { Text("文字") } footer: {
                Text("「正文稍粗」用于系统字体与自定义字体；「加粗使用强调色」默认开启，若想对齐纯墨黑加粗可在此关闭，反引号重点词仍保持陶土色标签。行距会连同段距一起变。")
            }
            Section {
                SwatchRow(title: "正文颜色", key: Personal.textKey, presets: Personal.textPresets, fallback: "black")
                SwatchRow(title: "强调色", key: Personal.accentKey, presets: Personal.accentPresets, fallback: "clay")
                SwatchRow(title: "背景", key: Personal.paperKey, presets: Personal.paperPresets, fallback: "ivory", allowsCustom: false)
                BubbleSwatchRow()
            } header: { Text("颜色") } footer: {
                Text(appliesHere
                     ? "强调色用在发送键、思考小花、「换一条」和链接上。自选的颜色用于浅色模式，深色模式自动换成相配的深色。"
                     : "颜色只用于「纸笺」风格；瑞士和夜江保持自己的配色。")
            }
            Section {
                choice("左右留白", key: Personal.marginKey, fallback: "standard",
                       options: [("narrow", "窄"), ("standard", "标准"), ("wide", "宽")])
                Toggle("AI 回答使用气泡", isOn: $aiBubble)
                Toggle("触感反馈", isOn: $hapticsEnabled)
            } header: { Text("布局与手感") }
            Section {
                Button("恢复默认", role: .destructive) { confirmReset = true }
            } footer: {
                Text("恢复本页的颜色、字重、行距和留白，字号回到 18；字体、界面风格和白天夜晚设置不变。")
            }
        }
        .font(TypeScale.body)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .foregroundStyle(Ink.ink)
        .tint(Ink.seal)
        .navigationTitle("个性化")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("恢复个性化默认设置？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) { Personal.resetAll(); readingSize = 18 }
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
            HStack(spacing: 12) {
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
                    Personal.hex(raw).map { Color.adaptive(light: $0, dark: $0) } ?? Color.adaptive(light: 0xF0EFEB, dark: 0x292927)
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
/// thinking mark and a send key, so every change shows at once.
@MainActor
private struct PersonalPreview: View {
    @AppStorage("qingjian.reading.size") private var readingSize = 18.0
    var body: some View {
        VStack(alignment: .leading, spacing: Personal.paragraphGap * 0.6) {
            HStack {
                Spacer(minLength: 40)
                Text("帮我想想周末去哪儿玩？").userMessageStyle().foregroundStyle(Ink.ink)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(Personal.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            HStack(spacing: 5) {
                Text("已思考 2 秒").font(.system(size: 13, weight: .regular)).foregroundStyle(Ink.ink3).monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Ink.ink3.opacity(0.75))
            }
            MarkdownParagraph(text: "天气好的话，可以下午 3 点去**城郊的湖边**走走，顺便复习 15 个 `English` 单词。")
            HStack {
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
