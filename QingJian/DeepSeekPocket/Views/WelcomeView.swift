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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private static let swissDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy.MM.dd · EEEE"
        return formatter
    }()

    var body: some View {
        if InterfaceStyle.isSwiss { swissBody } else { paperBody }
    }

    // Swiss: flush left, a black heavy line, the date in small monospaced type.
    private var swissBody: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let line = WelcomeLine.pick(hour: Calendar.current.component(.hour, from: timeline.date), name: name, seed: page.uuid.0)
            VStack(alignment: .leading, spacing: 16) {
                PulseDot(size: 14, pulsing: false)
                    .modifier(Arrive(shown: shown, delay: 0.05))
                Text(line.before + line.marked + line.after)
                    .font(TypeScale.heavy(34, relativeTo: .largeTitle)).tracking(-0.5)
                    .foregroundStyle(Ink.ink)
                    .lineLimit(2).minimumScaleFactor(0.6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("time-greeting")
                    .modifier(Arrive(shown: shown, delay: 0.18))
                SwissRule(weight: 2, strong: true)
                    .modifier(Arrive(shown: shown, delay: 0.24))
                HStack {
                    MonoLabel(text: Self.swissDate.string(from: timeline.date))
                    Spacer(minLength: 8)
                    if let projectName { MonoLabel(text: projectName, color: Ink.seal).lineLimit(1) }
                }
                .modifier(Arrive(shown: shown, delay: 0.3))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .onAppear { shown = true }
    }

    private var paperBody: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let line = WelcomeLine.pick(hour: Calendar.current.component(.hour, from: timeline.date), name: name, seed: page.uuid.0)
            VStack(spacing: 20) {
                PulseDot(size: 20, pulsing: false)
                    .modifier(Arrive(shown: shown, delay: 0.05))
                // Plain, without the highlighter: on the opening line it read oddly.
                Text(line.before + line.marked + line.after)
                .font(TypeScale.serif(28, relativeTo: .title))
                .foregroundStyle(Ink.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("time-greeting")
                .modifier(Arrive(shown: shown, delay: 0.18))
                if let projectName {
                    Text("在「\(projectName)」里").font(TypeScale.label).foregroundStyle(Ink.ink3)
                        .modifier(Arrive(shown: shown, delay: 0.3))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 32)
        .onAppear { shown = true }
    }
}

private struct Arrive: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let shown: Bool
    let delay: Double
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y: shown ? 0 : 12)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(delay), value: shown)
    }
}
