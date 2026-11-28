import SwiftUI

// One short line for the time of day, as the Claude app does.
struct WelcomeLine: Equatable {
    let before: String
    let marked: String
    let after: String

    static func pick(hour: Int, name: String, seed: UInt8) -> WelcomeLine {
        let options: [WelcomeLine]
        switch hour {
        case 5..<11: options = [.init(before: "早上好，", marked: name, after: ""),
                                .init(before: "早安，", marked: name, after: ""),
                                .init(before: "新的一天，", marked: "慢慢来", after: "。")]
        case 11..<17: options = [.init(before: "下午好，", marked: name, after: ""),
                                 .init(before: "午后，", marked: "喝杯茶", after: "吧。"),
                                 .init(before: "下午想", marked: "聊点什么", after: "？")]
        case 17..<23: options = [.init(before: "晚上好，", marked: name, after: ""),
                                 .init(before: "今晚想", marked: "聊点什么", after: "？"),
                                 .init(before: "忙完了吗，", marked: name, after: "？")]
        default: options = [.init(before: "夜深了，", marked: name, after: ""),
                            .init(before: "深夜", marked: "即兴", after: "时刻。"),
                            .init(before: "还没睡呀，", marked: name, after: "？")]
        }
        return options[Int(seed) % options.count]
    }
}

struct WelcomeView: View {
    let name: String
    // The page this greets: the same page keeps its line, a new page may get another.
    let page: UUID
    var projectName: String?
    // 1.46: a 无痕 chat says so under the greeting.
    var incognito = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var greeting: Double = 0

    // 1.47: the flower unfolds petal by petal, then the greeting rises in one character
    // after another, then the project line. About a second in all, once per page.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let line = WelcomeLine.pick(hour: Calendar.current.component(.hour, from: timeline.date), name: name, seed: page.uuid.0)
            VStack(spacing: 18) {
                ThinkingMark(live: false, size: 30, blooms: true)
                // Clean system sans-serif greeting matching Claude iOS welcome page.
                Text(line.before + line.marked + line.after)
                    .font(TypeScale.ui(28, weight: .regular, relativeTo: .title))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .textRenderer(GreetingRenderer(progress: greeting))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("time-greeting")
                if let projectName {
                    Text("在「\(projectName)」里" + (incognito ? " · 无痕，不进记忆" : "")).font(TypeScale.label).foregroundStyle(Ink.ink3)
                        .modifier(Arrive(shown: shown, delay: 0.55))
                } else if incognito {
                    Label("无痕，不进记忆", systemImage: "eye.slash").font(TypeScale.label).foregroundStyle(Ink.ink3)
                        .modifier(Arrive(shown: shown, delay: 0.55))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 32)
        .onAppear {
            shown = true
            if reduceMotion {
                greeting = 1
            } else {
                withAnimation(.linear(duration: GreetingRenderer.duration).delay(0.22)) { greeting = 1 }
            }
        }
    }
}

/// Each character of the greeting rises a few points and inks in, a beat after the one before.
private struct GreetingRenderer: TextRenderer {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    static let duration: Double = 0.9
    private static let each: Double = 0.42      // share of the whole time one character takes
    private static let rise: CGFloat = 7

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        if progress >= 1 {
            for line in layout { context.draw(line) }
            return
        }
        var total = 0
        for line in layout { for run in line { total += run.count } }
        let spread = max(0.001, 1 - Self.each)
        var index = 0
        for line in layout {
            for run in line {
                for slice in run {
                    let start = total > 1 ? spread * Double(index) / Double(total - 1) : 0
                    let local = min(1, max(0, (progress - start) / Self.each))
                    // Ease out, so each character arrives quickly and settles gently.
                    let eased = 1 - (1 - local) * (1 - local) * (1 - local)
                    if eased > 0.003 {
                        var copy = context
                        copy.opacity = eased
                        copy.translateBy(x: 0, y: CGFloat(1 - eased) * Self.rise)
                        copy.draw(slice)
                    }
                    index += 1
                }
            }
        }
    }
}

private struct Arrive: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let shown: Bool
    let delay: Double
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y: shown ? 0 : 10)
            .animation(reduceMotion ? nil : Motion.gentle.delay(delay), value: shown)
    }
}
