import SwiftUI
import UIKit

enum HighlightStyle {
    static let key = "qingjian.reading.highlightHex"
    static func color(_ hex: String, scheme: ColorScheme) -> Color {
        // The Swiss look has no highlighter; its selection wash is part of the look.
        if InterfaceStyle.isSwiss { return Ink.mark }
        // 夜江 draws emphasis as moonlight on the water, whatever colour is picked here.
        if InterfaceStyle.isNight { return Ink.mark }
        guard let rgb = HighlightHex.rgb(hex) else { return Ink.mark }
        return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255,
                     opacity: scheme == .dark ? 0.36 : 0.55)
    }
    static func solid(_ hex: String) -> Color {
        let rgb = HighlightHex.rgb(hex) ?? 0xFFE169
        return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

struct HighlightColorSettings: View {
    @AppStorage(HighlightStyle.key) private var storedHex = ""
    @State private var hexInput = ""
    private let presets = ["#FFE169", "#A8E6A1", "#9EDCF2", "#C7B5F5", "#FFB7CB", "#FFBD86"]
    private var selection: Binding<Color> {
        Binding(get: { HighlightStyle.solid(storedHex) }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            func channel(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
            storedHex = String(format: "#%02X%02X%02X", channel(r), channel(g), channel(b))
        })
    }
    var body: some View {
        Section {
            ColorPicker("调色盘与取色器", selection: selection, supportsOpacity: false)
                .accessibilityIdentifier("highlight-color-picker")
            HStack(spacing: 12) {
                ForEach(presets, id: \.self) { hex in
                    Button { storedHex = hex } label: {
                        Circle().fill(HighlightStyle.solid(hex)).frame(width: 28, height: 28)
                            .overlay(Circle().stroke(storedHex == hex ? Ink.ink : Color.clear, lineWidth: 2))
                    }.buttonStyle(.borderless).accessibilityLabel("高光颜色 \(hex)")
                }
            }
            HStack {
                TextField("#FFCC00", text: $hexInput)
                    .font(.system(.body, design: .monospaced)).textInputAutocapitalization(.characters)
                    .autocorrectionDisabled().keyboardType(.asciiCapable)
                    .accessibilityLabel("高光 HEX 色值").accessibilityIdentifier("highlight-hex-input")
                    .onSubmit(applyHex)
                Button("应用", action: applyHex).disabled(HighlightHex.normalized(hexInput) == nil)
                    .accessibilityIdentifier("highlight-hex-apply")
            }
            if !hexInput.isEmpty && HighlightHex.normalized(hexInput) == nil {
                Text("请输入3位或6位十六进制色值，例如 #FC0 或 #FFCC00。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            MarkdownParagraph(text: "这里是**重点文字**的高光预览。")
                .padding(.vertical, 8)
            Button("恢复默认黄色") { storedHex = ""; hexInput = "#FFE169" }
        } header: { Text("文字高光") } footer: {
            Text("即时保存，应用到回答中的粗体重点（每条回答最多两处，其余保持粗体）和侧栏选中标记。深色模式自动降低高光浓度。瑞士风格不画高光，粗体改为蓝色；夜江固定用月光色。")
        }
        .onAppear { hexInput = storedHex.isEmpty ? "#FFE169" : storedHex }
        .onChange(of: storedHex) { _, value in hexInput = value.isEmpty ? "#FFE169" : value }
    }
    private func applyHex() {
        guard let valid = HighlightHex.normalized(hexInput) else { return }
        storedHex = valid
        hexInput = valid
    }
}
