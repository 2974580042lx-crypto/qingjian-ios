import SwiftUI
import UIKit

// No bottom tab bar any more: settings open from the sidebar.
enum FloatingChrome { static let navigationHeight: CGFloat = 0 }

extension Color {
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(UIColor { trait in
            let isDark = trait.userInterfaceStyle == .dark
            let hex = isDark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

// 纸笺 (after the Claude app): warm paper, near-black at night, one terracotta accent,
// and the gamboge highlighter kept from the earlier design.
// 瑞士: cool grey-white, true black ink, one ultramarine accent, a black send button.
// Every value is read through `InterfaceStyle`, so switching the look redraws in place.
// 夜江: night-river blue-black, moon-white text and one pale gold moon. The same in
// light and dark mode (the app is held in dark mode while it is chosen). Colours were
// set in oklch: ground L .17 C .02 H 232, moon L .88 C .075 H 88.
enum Ink {
    private static var swiss: Bool { InterfaceStyle.isSwiss }
    private static var night: Bool { InterfaceStyle.isNight }
    private static func fixed(_ hex: UInt32, alpha: CGFloat = 1) -> Color {
        Color.adaptive(light: hex, dark: hex, lightAlpha: alpha, darkAlpha: alpha)
    }
    static var paper: Color {
        if night { return fixed(0x051117) }
        return swiss ? Color.adaptive(light: 0xF2F2EF, dark: 0x111214) : Personal.paper
    }
    static var sheet: Color {
        if night { return fixed(0x071419) }
        // One step from the page in the same hue: the sidebar had read as a separate, yellow sheet.
        return swiss ? Color.adaptive(light: 0xE7E7E3, dark: 0x0A0A0B) : Personal.sheet
    }
    static var raised: Color {
        if night { return fixed(0x0F1D24) }
        return swiss ? Color.adaptive(light: 0xFFFFFF, dark: 0x1D1E21) : Color.adaptive(light: 0xF2EFE6, dark: 0x262522)
    }
    static var ink: Color {
        if night { return fixed(0xDBEBEF) }
        return swiss ? Color.adaptive(light: 0x111111, dark: 0xEDEDE9) : Personal.ink
    }
    static var ink2: Color {
        if night { return fixed(0xB4C3C9) }
        return swiss ? Color.adaptive(light: 0x3B3B3B, dark: 0xC6C6C1) : Color.adaptive(light: 0x35322D, dark: 0xD6D2C9)
    }
    static var ink3: Color {
        if night { return fixed(0x92A1A8) }
        return swiss ? Color.adaptive(light: 0x5E5E5E, dark: 0x9B9B96) : Color.adaptive(light: 0x6D685F, dark: 0xA6A299)
    }
    static var line: Color {
        if night { return fixed(0xDBEBEF, alpha: 0.13) }
        return swiss ? Color.adaptive(light: 0x111111, dark: 0xEDEDE9, lightAlpha: 0.16, darkAlpha: 0.18)
            : Color.adaptive(light: 0x24211C, dark: 0xECE9E1, lightAlpha: 0.11, darkAlpha: 0.13)
    }
    static var seal: Color {
        if night { return fixed(0xECD59F) }
        return swiss ? Color.adaptive(light: 0x2B3DE0, dark: 0x6B79FF) : Personal.accent
    }
    static var onSeal: Color { night ? fixed(0x051117) : Color.adaptive(light: 0xFFFFFF, dark: 0xFFFFFF) }
    // Highlighter stroke behind emphasised words (纸笺); a pale blue wash for the
    // sidebar's selected row in the Swiss look, which has no highlighter in answers;
    // moonlight on the water in 夜江.
    static var mark: Color {
        if night { return fixed(0xECD59F, alpha: 0.26) }
        return swiss ? Color.adaptive(light: 0x2B3DE0, dark: 0x6B79FF, lightAlpha: 0.14, darkAlpha: 0.28)
            : Color.adaptive(light: 0xFFE169, dark: 0xF7C81E, darkAlpha: 0.36)
    }
    static var solid: Color { ink }
    static var onSolid: Color { paper }
    static var sendFill: Color { swiss ? ink : seal }
    static var sendGlyph: Color { swiss ? paper : onSeal }
}

enum Palette {
    static var green: Color { Ink.ink }
    static var paper: Color { Ink.paper }
    static var surface: Color { Ink.raised }
    static var softGreen: Color { Ink.line }
    static var secondary: Color { Ink.ink3 }
}

enum Space {
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16
    static let xl: CGFloat = 24, xxl: CGFloat = 32, section: CGFloat = 40
}

enum Radius {
    static let control: CGFloat = 14, field: CGFloat = 20, sheet: CGFloat = 34
    // The page corners while the sidebar is open; the Swiss look keeps them square.
    static var pageFront: CGFloat { InterfaceStyle.isSwiss ? 0 : 42 }
    static var pageBack: CGFloat { InterfaceStyle.isSwiss ? 0 : 32 }
}

enum TypeScale {
    // Chosen in Settings (built-in Georgia+NotoSerifSC editorial cascade, system PingFang, or an imported font).
    static var serifName: String { FontLibrary.regularFace }
    static func serif(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        // "系统字体" means the real system font: SF for Latin and digits, PingFang for
        // Chinese. Naming PingFang alone drew Latin and digits thin and narrow.
        if FontLibrary.usesSystemFace { return .system(size: scaled(size, style)) }
        if FontLibrary.usesEditorialSerif {
            // Editorial serif for body/headings (>= 17pt); crisp SF+PingFang sans for small chrome/labels (< 17pt).
            if size >= 17 {
                return Font(FontLibrary.editorialUIFont(size: scaled(size, style), bold: false, italic: false))
            }
            return .system(size: scaled(size, style))
        }
        return .custom(serifName, size: size, relativeTo: style)
    }
    /// A point size grown or shrunk with the reader's text size setting.
    static func scaled(_ size: CGFloat, _ style: Font.TextStyle) -> CGFloat {
        UIFontMetrics(forTextStyle: uiStyle(style)).scaledValue(for: size)
    }
    static func uiStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
    // The bold cut is optional: without the font file, headings fall back to the system heavy weight.
    static var heavyName: String { FontLibrary.boldFace }
    static var hasHeavy: Bool { UIFont(name: heavyName, size: 12) != nil }
    static func heavy(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        if InterfaceStyle.isSwiss { return .system(size: size, weight: .heavy) }
        if FontLibrary.usesSystemFace { return .system(size: scaled(size, style), weight: .semibold) }
        if FontLibrary.usesEditorialSerif {
            return Font(FontLibrary.editorialUIFont(size: scaled(size, style), bold: true, italic: false))
        }
        return hasHeavy ? .custom(heavyName, size: size, relativeTo: style) : .system(size: size, weight: .heavy)
    }
    /// Numbers and small labels in the Swiss look: Q.01, COPY, 2026.10.20.
    static func mono(_ size: CGFloat, relativeTo style: Font.TextStyle = .caption) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
    static var pageTitle: Font { serif(32, relativeTo: .largeTitle) }
    static var hero: Font { serif(30, relativeTo: .title) }
    static var subject: Font { serif(20, relativeTo: .title3) }
    static var answer: Font { serif(18) }
    static var note: Font { serif(15, relativeTo: .callout) }
    static var body: Font { serif(18) }
    static var label: Font { serif(13, relativeTo: .footnote) }
    static var caption: Font { serif(13, relativeTo: .caption) }
    static var tiny: Font { serif(11, relativeTo: .caption2) }
}

enum InkAppearance {
    @MainActor static func apply() {
        let ink = UIColor(Ink.ink)
        let system = FontLibrary.usesSystemFace
        let editorial = FontLibrary.usesEditorialSerif
        let large: UIFont? = editorial
            ? FontLibrary.editorialUIFont(size: 32, bold: true)
            : (system ? UIFont.systemFont(ofSize: 32, weight: .bold) : UIFont(name: TypeScale.serifName, size: 32))
        let inline: UIFont? = (system || editorial)
            ? UIFont.systemFont(ofSize: 17, weight: .semibold)
            : UIFont(name: TypeScale.serifName, size: 17)
        func update(_ bar: UINavigationBar) {
            if let large {
                bar.largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large), .foregroundColor: ink]
            }
            if let inline {
                bar.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline), .foregroundColor: ink]
            }
        }
        update(UINavigationBar.appearance())
        // Appearance proxies affect future bars. Refresh existing bars in place
        // as well, without recreating their screens or discarding settings drafts.
        func visit(_ view: UIView) {
            if let bar = view as? UINavigationBar { update(bar) }
            for child in view.subviews { visit(child) }
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { visit(window) }
        }
    }
}

struct AppBackground: View { var body: some View { Ink.paper.ignoresSafeArea() } }

// Liquid glass in the paper look; a white box with a black frame in the Swiss look.
struct ClearGlass: ViewModifier {
    var radius: CGFloat = 28
    @ViewBuilder func body(content: Content) -> some View {
        if InterfaceStyle.isSwiss {
            content.background(Ink.raised).overlay(Rectangle().stroke(Ink.ink, lineWidth: 1.5).allowsHitTesting(false))
        } else {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: radius))
        }
    }
}

extension View {
    /// A small control floating over the page: liquid glass in its own shape on paper
    /// and 夜江, a white box with a black frame in the Swiss look.
    @ViewBuilder func floatingGlass(in shape: AnyShape) -> some View {
        if InterfaceStyle.isSwiss {
            self.background(Ink.raised).overlay(Rectangle().stroke(Ink.ink, lineWidth: 1.5).allowsHitTesting(false))
        } else {
            self.glassEffect(.regular.interactive(), in: shape)
        }
    }
}

/// Small controls dim and shrink a touch while pressed, so a tap is felt as well as seen.
struct PressFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}
extension ButtonStyle where Self == PressFeedbackStyle { static var pressFeedback: PressFeedbackStyle { PressFeedbackStyle() } }

/// A light tap felt in the hand, unless haptics are switched off in Settings.
enum Haptic {
    @MainActor static func tap() {
        guard UserDefaults.standard.object(forKey: "qingjian.haptics") as? Bool ?? true else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
    }
}

/// Chinese reading text: Chinese punctuation (full-width quotes) even in the system font,
/// whose Latin quotes left odd gaps. No extra letter spacing: Apple sets Chinese without
/// it, and the 0.3 pt tried in 1.28 made the page read like Android.
extension View {
    func chineseReading() -> some View {
        self.typesettingLanguage(Locale.Language(identifier: "zh-Hans"))
    }
}

struct PageContour: Shape {
    var radius: CGFloat
    var topInset: CGFloat
    var bottomInset: CGFloat
    var animatableData: CGFloat { get { radius } set { radius = newValue } }
    func path(in rect: CGRect) -> Path {
        let page = CGRect(x: rect.minX, y: rect.minY - topInset, width: rect.width,
                          height: rect.height + topInset + bottomInset)
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: page)
    }
}

enum ReadingFont {
    static func resolve(baseSize: CGFloat, bold: Bool = false, italic: Bool = false) -> Font {
        let scaled = TypeScale.scaled(baseSize, .body)
        if FontLibrary.usesSystemFace {
            let weight: Font.Weight = bold ? .bold : (Personal.mediumBody ? .medium : .regular)
            let base = Font.system(size: scaled, weight: weight)
            return italic ? base.italic() : base
        }
        if FontLibrary.usesEditorialSerif {
            return Font(FontLibrary.editorialUIFont(size: scaled, bold: bold, italic: italic))
        }
        if bold {
            let base: Font = TypeScale.hasHeavy
                ? .custom(TypeScale.heavyName, size: baseSize, relativeTo: .body)
                : .custom(TypeScale.serifName, size: baseSize, relativeTo: .body).bold()
            return italic ? base.italic() : base
        }
        let base = Font.custom(TypeScale.serifName, size: baseSize, relativeTo: .body)
        return italic ? base.italic() : base
    }
}

struct ReadingStyle: ViewModifier {
    // Observed so text redraws as soon as the font is changed in Settings.
    @AppStorage(FontLibrary.choiceKey) private var choice = ""
    @AppStorage(FontLibrary.revisionKey) private var revision = 0
    @AppStorage("qingjian.reading.size") private var size = 18.0
    var adjustment: Double = 0
    var heavy = false
    func body(content: Content) -> some View {
        let _ = (choice, revision, StyleAppearance.shared.revision, FontAppearance.shared.revision)
        let applyCustomMedium = !heavy && Personal.mediumBody && FontLibrary.choice == .custom && !InterfaceStyle.isSwiss
        content.font(font).fontWeight(applyCustomMedium ? .medium : nil)
    }
    private var font: Font {
        ReadingFont.resolve(baseSize: size + adjustment, bold: heavy, italic: false)
    }
}

/// Clean sans-serif for user chat bubbles and composer input, contrasting with AI's editorial serif answers.
struct UserMessageStyle: ViewModifier {
    @AppStorage(FontLibrary.choiceKey) private var choice = ""
    @AppStorage(FontLibrary.revisionKey) private var revision = 0
    @AppStorage("qingjian.reading.size") private var size = 18.0
    func body(content: Content) -> some View {
        let _ = (choice, revision, StyleAppearance.shared.revision, FontAppearance.shared.revision)
        if FontLibrary.choice == .custom && !InterfaceStyle.isSwiss {
            content.modifier(ReadingStyle(adjustment: -1))
        } else {
            let weight: Font.Weight = (FontLibrary.usesSystemFace && Personal.mediumBody) ? .medium : .regular
            content.font(.system(size: TypeScale.scaled(max(16, size - 1), .body), weight: weight))
        }
    }
}

extension View {
    func readingStyle(adjustment: Double = 0, heavy: Bool = false) -> some View {
        modifier(ReadingStyle(adjustment: adjustment, heavy: heavy))
    }
    func userMessageStyle() -> some View {
        modifier(UserMessageStyle())
    }
    func clearGlass(radius: CGFloat = 28) -> some View { modifier(ClearGlass(radius: radius)) }
}

struct SealStamp: View {
    var text = "V"
    var size: CGFloat = 30
    var body: some View {
        Text(text).font(TypeScale.serif(size * 0.57)).fontWeight(.semibold)
            .foregroundStyle(Ink.onSeal).frame(width: size, height: size)
            .background(Ink.seal, in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityHidden(true)
    }
}

// Sermo's own mark: a terracotta disc. Breathes while an answer is on its way.
struct PulseDot: View {
    var size: CGFloat = 9
    var pulsing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    var body: some View {
        // A disc on paper, a small square in the Swiss look, the moon in 夜江.
        Group {
            if InterfaceStyle.isNight {
                MoonDisc(size: size, glow: pulsing && !dim)
            } else {
                RoundedRectangle(cornerRadius: InterfaceStyle.isSwiss ? 0 : size / 2, style: .continuous)
                    .fill(Ink.seal).frame(width: size, height: size)
            }
        }
            .opacity(dim ? 0.35 : 1).scaleEffect(dim ? 0.72 : 1)
            .onAppear {
                guard pulsing && !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

struct InkRule: View { var body: some View { Rectangle().fill(Ink.line).frame(height: 0.5).accessibilityHidden(true) } }

struct InkSectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(TypeScale.label.weight(.semibold)).foregroundStyle(Ink.ink2)
            .frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader)
    }
}

struct InkRow: View {
    let title: String
    var detail: String? = nil
    var value: String? = nil
    var divider = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(TypeScale.subject).foregroundStyle(Ink.ink)
                    if let detail { Text(detail).font(TypeScale.caption).foregroundStyle(Ink.ink3).lineLimit(2) }
                }
                Spacer(minLength: Space.s)
                if let value { Text(value).font(TypeScale.label).foregroundStyle(Ink.ink2).monospacedDigit() }
            }
            .padding(.vertical, Space.l).frame(minHeight: 58).contentShape(Rectangle())
            if divider { InkRule() }
        }
    }
}

struct InkPrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 52
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(TypeScale.serif(16).weight(.semibold)).foregroundStyle(Ink.onSolid)
            .padding(.horizontal, 22).frame(maxWidth: .infinity).frame(height: height)
            .background(Ink.solid, in: RoundedRectangle(cornerRadius: InterfaceStyle.isSwiss ? 0 : height / 2, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
    }
}

struct InkGlassButtonStyle: ButtonStyle {
    var height: CGFloat = 48
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(TypeScale.serif(15)).foregroundStyle(Ink.ink)
            .padding(.horizontal, 18).frame(height: height)
            .clearGlass(radius: height / 2).opacity(configuration.isPressed ? 0.84 : 1)
    }
}

extension ButtonStyle where Self == InkPrimaryButtonStyle { static var inkPrimary: InkPrimaryButtonStyle { InkPrimaryButtonStyle() } }
extension ButtonStyle where Self == InkGlassButtonStyle { static var inkGlass: InkGlassButtonStyle { InkGlassButtonStyle() } }

struct GlassCircle: View {
    let symbol: String
    let label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(Ink.ink).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain).clearGlass(radius: 22)
        .accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityIdentifier(label).accessibilityAddTraits(.isButton)
    }
}

struct SidebarGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule().frame(width: 16, height: 1.8)
            Capsule().frame(width: 10, height: 1.8)
        }
        .foregroundStyle(Ink.ink)
        .frame(width: 22, height: 22, alignment: .center)
        .accessibilityHidden(true)
    }
}

/// 个性化: the few things you can tune yourself, each changing the look as a set so it
/// cannot drift out of tune. They apply to the 纸笺 look; 瑞士 and 夜江 keep their own.
/// A value is a preset name, or "#RRGGBB" for a colour picked by hand (used in light
/// mode; dark mode keeps a matching default so text stays readable).
enum Personal {
    static let textKey = "sermo.personal.text"
    static let accentKey = "sermo.personal.accent"
    static let paperKey = "sermo.personal.paper"
    static let bubbleKey = "sermo.personal.bubble"
    static let spacingKey = "sermo.personal.spacing"
    static let marginKey = "sermo.personal.margin"
    static let mediumKey = "sermo.personal.medium"
    static let boldAccentKey = "sermo.personal.boldAccent"
    static let allKeys = [textKey, accentKey, paperKey, bubbleKey, spacingKey, marginKey, mediumKey, boldAccentKey]

    struct Preset: Identifiable { let id: String; let title: String; let light: UInt32; let dark: UInt32 }
    static let textPresets = [
        Preset(id: "black", title: "近黑", light: 0x1F1E1B, dark: 0xECE9E1),
        Preset(id: "warm", title: "暖深灰", light: 0x2B2925, dark: 0xE8E5DD),
        Preset(id: "brown", title: "深棕", light: 0x382920, dark: 0xEADACE),
    ]
    static let accentPresets = [
        Preset(id: "clay", title: "陶土", light: 0xC96442, dark: 0xD97757),
        Preset(id: "indigo", title: "靛蓝", light: 0x3F5BA9, dark: 0x8EA6E6),
        Preset(id: "green", title: "墨绿", light: 0x2F6E57, dark: 0x7CC2A6),
        Preset(id: "plum", title: "梅紫", light: 0x7A4A8C, dark: 0xC3A2D6),
        Preset(id: "graphite", title: "石墨", light: 0x3A3936, dark: 0xD8D6CF),
    ]
    static let paperPresets = [
        Preset(id: "ivory", title: "柔白", light: 0xFAF9F5, dark: 0x191918),
        Preset(id: "white", title: "纯白", light: 0xFFFFFF, dark: 0x0C0C0C),
        Preset(id: "grey", title: "浅灰", light: 0xF3F3F1, dark: 0x1C1C1E),
    ]
    private static let sheetFor: [String: (UInt32, UInt32)] = [
        "ivory": (0xF3F0E8, 0x131312), "white": (0xF4F4F4, 0x050505), "grey": (0xEAEAE7, 0x141416),
    ]

    // Read from UserDefaults once per change, not once per paragraph per redraw.
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    nonisolated(unsafe) private static var cachedRevision = -1
    private static let cacheLock = NSLock()
    private static func stored(_ key: String) -> String {
        let revision = StyleAppearance.shared.revision
        cacheLock.lock(); defer { cacheLock.unlock() }
        if revision != cachedRevision { cache = [:]; cachedRevision = revision }
        if let hit = cache[key] { return hit }
        let value = UserDefaults.standard.string(forKey: key) ?? ""
        cache[key] = value
        return value
    }
    static func value(_ key: String) -> String { stored(key) }
    @MainActor static func set(_ value: String, for key: String) {
        UserDefaults.standard.set(value, forKey: key)
        StyleAppearance.shared.bump()
        InkAppearance.apply()
    }
    @MainActor static func resetAll() {
        for key in allKeys { UserDefaults.standard.removeObject(forKey: key) }
        StyleAppearance.shared.bump()
        InkAppearance.apply()
    }
    static func hex(_ value: String) -> UInt32? {
        guard value.hasPrefix("#"), value.count == 7 else { return nil }
        return UInt32(value.dropFirst(), radix: 16)
    }
    private static func pick(_ key: String, _ presets: [Preset], fallback: String, darkForCustom: UInt32) -> Color {
        let raw = stored(key)
        if let custom = hex(raw) { return Color.adaptive(light: custom, dark: darkForCustom) }
        let preset = presets.first { $0.id == raw } ?? presets.first { $0.id == fallback }!
        return Color.adaptive(light: preset.light, dark: preset.dark)
    }

    // Near-black by default: 1.28's softer grey made strokes read thinner than the Claude app.
    static var ink: Color { pick(textKey, textPresets, fallback: "black", darkForCustom: 0xECE9E1) }
    static var accent: Color { pick(accentKey, accentPresets, fallback: "clay", darkForCustom: 0xD97757) }
    static var paper: Color { pick(paperKey, paperPresets, fallback: "ivory", darkForCustom: 0x191918) }
    static var sheet: Color {
        let raw = stored(paperKey)
        let pair = sheetFor[raw] ?? sheetFor["ivory"]!
        return Color.adaptive(light: pair.0, dark: pair.1)
    }
    /// Your message bubble: warm oat-milk cream by default, a wash of the accent, or a picked colour.
    static var bubble: Color {
        let raw = stored(bubbleKey)
        if InterfaceStyle.isSwiss || InterfaceStyle.isNight { return Ink.raised }
        if raw == "accent" { return accent.opacity(0.14) }
        if let custom = hex(raw) { return Color.adaptive(light: custom, dark: 0x2A2926) }
        return Color.adaptive(light: 0xEFECE4, dark: 0x2A2926)
    }
    @MainActor static func setMediumBody(_ on: Bool) {
        UserDefaults.standard.set(on ? "1" : "0", forKey: mediumKey)
        StyleAppearance.shared.bump()
    }
    static var mediumBody: Bool { stored(mediumKey) != "0" }
    @MainActor static func setBoldUsesAccent(_ on: Bool) {
        UserDefaults.standard.set(on ? "1" : "0", forKey: boldAccentKey)
        StyleAppearance.shared.bump()
    }
    static var boldUsesAccent: Bool { stored(boldAccentKey) == "1" }
    /// Line spacing inside a paragraph and the gap between paragraphs.
    static var lineSpacing: CGFloat {
        switch stored(spacingKey) { case "compact": return 4.5; case "loose": return 10.5; default: return 7.5 }
    }
    static var paragraphGap: CGFloat {
        switch stored(spacingKey) { case "compact": return 13; case "loose": return 24; default: return 18 }
    }
    /// Left and right margin of the chat text.
    static var margin: CGFloat {
        switch stored(marginKey) { case "narrow": return 12; case "wide": return 26; default: return 18 }
    }
    /// "#RRGGBB" for a colour, read in light mode.
    static func hexString(_ color: Color) -> String {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
