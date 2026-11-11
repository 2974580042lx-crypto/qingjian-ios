import Foundation

// 「跟着原著走」(1.12.0): the story moves along the book's own plot, a stretch of
// chapters (one reading segment) at a time. The model is shown this stretch and a
// glimpse of the next, never told to reveal them, steers your choices towards the
// stretch's events, and ends its answer with a hidden mark once they have happened;
// then the app moves on. Stretches without your character are either played with you
// drawn into them, or skipped with a short narration of what happened meanwhile.
enum CanonMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case involve, skip
    var id: String { rawValue }
    var title: String { self == .involve ? "把我卷进去" : "跳到有我的地方" }
}

enum CanonPlan {
    static let marker = "〔本段完〕"
    private static let markerPattern = #"\n?\s*[〔【\[［(（]\s*本段完\s*[〕】\]］)）]\s*"#

    /// The answer without the mark, and whether the mark was there.
    static func strip(_ text: String) -> (text: String, finished: Bool) {
        guard let range = text.range(of: markerPattern, options: .regularExpression) else { return (text, false) }
        var clean = text
        clean.removeSubrange(range)
        while let more = clean.range(of: markerPattern, options: .regularExpression) { clean.removeSubrange(more) }
        return (clean.trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    static func segment(containing chapter: Int, in book: Book) -> Int {
        book.segments.firstIndex { $0.first <= chapter && chapter <= $0.last } ?? max(0, book.segments.count - 1)
    }

    /// The stretch after `index`. In skip mode, stretches whose notes do not mention any
    /// of `userNames` are passed over; what happened in them comes back as `bridge`.
    static func advance(from index: Int, book: Book, userNames: [String], mode: CanonMode) -> (next: Int, bridge: String?) {
        var next = index + 1
        var skipped: [String] = []
        let names = userNames.filter { $0.count >= 2 }
        if mode == .skip, !names.isEmpty {
            while next < book.segments.count, let note = book.notes[next],
                  !note.characters.contains(where: { !Set([$0.name] + $0.aliases).isDisjoint(with: names) }),
                  !names.contains(where: { note.plot.contains($0) }) {
                skipped.append("第 \(note.segment.first + 1)–\(note.segment.last + 1) 章：" + String(note.plot.prefix(500)))
                next += 1
            }
        }
        return (next, skipped.isEmpty ? nil : skipped.joined(separator: "\n"))
    }

    /// The part of the system prompt that carries the plot. Nil when the game is free.
    static func section(_ session: StorySession, book: Book?) -> String? {
        guard let mode = session.canon, let book, let index = session.canonSegment else { return nil }
        guard book.notes.indices.contains(index), let current = book.notes[index] else {
            return "【原著主线】原著的剧情已经走完了。接下来自由发挥，人物和世界保持原著的样子。"
        }
        let start = max(current.segment.first, (session.startChapter ?? current.segment.first))
        var lines = ["【原著主线（只给你看，绝不向用户透露、预告或暗示）】",
                     "现在这一段：原著第 \(start + 1)–\(current.segment.last + 1) 章" +
                        (start > current.segment.first ? "（这一段从第 \(start + 1) 章之后算起，之前的已经发生过）" : "") + "。",
                     current.plot]
        if !current.scenes.isEmpty {
            lines.append("这一段的名场面：" + current.scenes.map { "\($0.title)（\($0.summary)）" }.joined(separator: "；"))
        }
        if book.notes.indices.contains(index + 1), let next = book.notes[index + 1] {
            lines.append("下一段大意（只用来铺垫，不要提前发生）：" + String(next.plot.prefix(300)))
        }
        let involve = mode == .involve || session.userRole.isEmpty
        if session.plotDirection == .adapted {
            lines.append("""
            怎么走：把上述原著事件当作可能发生的背景，不是必须完成的任务。用户的选择可以改变结局；以本局已经发生的事实为准，沿着原因和后果往下演。
            已改变的命运不要强行拉回原著，不复活已死的人、不让已解决的危机原样重演。保留用户明确锁定的大事件。
            这一阶段已得到合理结果（包括与原著不同的结果）之后，在末尾单独写\(marker)，再进入下一个阶段。
            """)
        } else {
        lines.append("""
        怎么走：顺着用户的选择，把故事自然地引向这一段原著里的事件。细节、顺序和说法可以随用户改变，但这一段的大事要发生，人物照原著的性格去做原著里的决定；不要让剧情停在原地打转。
        \(involve ? "用户的人物如果在原著这一段里不在场，就让他以旁观者、知情人、帮忙或被卷入的人的身份参与进来，原著里的事在他身边发生。" : "用户的人物在原著这一段里也许戏份不多，可以让他从旁经历，但不要硬加大戏。")
        这一段的大事都已经在故事里发生过以后，在那条回复的最后单独一行写\(marker)（用户看不到这一行）。还没到就不要写。
        """)
        }
        if let bridge = session.canonBridge?.trimmingCharacters(in: .whitespacesAndNewlines), !bridge.isEmpty {
            lines.append("""
            【刚刚跳过的原著】用户的人物没有亲历下面这些事。请在下一条回复的开头，用一小段旁白交代时间过去了多久、这期间发生了什么（用户的人物可能只是听说），再接到现在这一段：
            \(bridge)
            """)
        }
        return lines.joined(separator: "\n")
    }
}
