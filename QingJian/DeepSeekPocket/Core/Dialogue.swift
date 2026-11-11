import Foundation

// The book's dialogue, taken from the text on the phone without the model (1.11.0):
// every quoted line with who said it (a known name just before or after the quote),
// how ("冷笑道", "哭道" …) and in which chapter. Before each answer a few lines of the
// character in a similar situation are put next to the newest message, which keeps a
// voice far closer to the book than a description of it does.

enum DialogueMood: String, Sendable, CaseIterable {
    case angry, sad, cold, teasing, worried, happy, calm

    var label: String {
        switch self {
        case .angry: return "生气"
        case .sad: return "伤心"
        case .cold: return "冷淡"
        case .teasing: return "打趣"
        case .worried: return "着急"
        case .happy: return "高兴"
        case .calm: return "平常"
        }
    }

    // Checked in this order, so 冷笑 counts as cold before 笑 counts as happy.
    private static let cues: [(DialogueMood, [String])] = [
        (.cold, ["冷笑", "冷冷", "淡淡", "哼", "冷声", "嗤"]),
        (.angry, ["怒", "喝道", "骂", "恼", "生气", "气死", "气得", "厉声", "大怒", "急了", "混账", "滚"]),
        (.sad, ["哭", "泣", "哽咽", "泪", "叹", "伤心", "难过", "委屈"]),
        (.teasing, ["啐", "嗔", "打趣", "取笑", "戏道", "促狭"]),
        (.worried, ["急道", "忙道", "慌", "惊", "怕", "担心", "不好了"]),
        (.happy, ["笑", "喜", "乐", "高兴", "好啊", "哈哈"]),
    ]

    static func detect(_ text: String) -> DialogueMood? {
        cues.first(where: { entry in entry.1.contains(where: { text.contains($0) }) })?.0
    }
}

struct DialogueLine: Sendable, Equatable {
    let speaker: String
    // The words between the name and the quote, e.g. "冷笑道"; may be empty.
    let manner: String
    let mood: DialogueMood
    let text: String
    // The paragraph around the line (clipped), to see who else is in the scene.
    let context: String
    let chapter: Int
}

enum DialogueIndex {
    private static let quote = try? NSRegularExpression(pattern: "[“「]([^”」“「]{2,200})[”」]")
    private static let speechEnds: Set<Character> = ["道", "说", "问", "答", "笑", "叫", "喊", "骂", "叹", "啐", "嚷"]

    /// `names` maps every name and alias (two characters or more) to the character's main name.
    static func build(paragraphs: [BookPassages.Paragraph], names: [String: String]) -> [DialogueLine] {
        guard let quote else { return [] }
        let keys = names.keys.filter { $0.count >= 2 }.sorted { $0.count > $1.count }
        var lines: [DialogueLine] = []
        for paragraph in paragraphs {
            let text = paragraph.text
            guard text.contains("“") || text.contains("「") else { continue }
            let ns = text as NSString
            let matches = quote.matches(in: text, range: NSRange(location: 0, length: ns.length))
            var previousEnd = 0
            for match in matches {
                let spoken = ns.substring(with: match.range(at: 1))
                // The lead-in: from the end of the last quote (or sentence) up to this one.
                let before = ns.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd))
                let after = ns.substring(with: NSRange(location: match.range.upperBound,
                                                       length: min(14, ns.length - match.range.upperBound)))
                previousEnd = match.range.upperBound
                let found = speaker(before: before, after: after, keys: keys)
                guard let found, let main = names[found.name] else { continue }
                let mood = DialogueMood.detect(found.manner) ?? DialogueMood.detect(String(before.suffix(12))) ?? .calm
                lines.append(DialogueLine(speaker: main, manner: found.manner, mood: mood, text: spoken,
                                          context: String(text.prefix(240)), chapter: paragraph.chapter))
            }
        }
        return lines
    }

    // "黛玉冷笑道：“…”" or "宝玉听了，便笑道：“…”" (the subject of the lead-in: the first
    // name in the nearest clause that has one), or "“…”宝玉笑道。" (a name right after).
    private static func speaker(before: String, after: String, keys: [String]) -> (name: String, manner: String)? {
        let sentence = String(before.split(whereSeparator: { "。！？；…\n".contains($0) }).last ?? Substring(before))
        let lead = sentence.trimmingCharacters(in: CharacterSet(charactersIn: " 　：:，,“「"))
        if let last = lead.last, speechEnds.contains(last) {
            let clauses = lead.split(whereSeparator: { "，,、".contains($0) }).map(String.init)
            for clause in clauses.reversed().prefix(3) {
                guard let name = firstName(in: clause, keys: keys) else { continue }
                let lastClause = clauses.last ?? clause
                var manner = lastClause
                if let range = lastClause.range(of: name) { manner = String(lastClause[range.upperBound...]) }
                return (name, String(manner.suffix(8)))
            }
        }
        let tail = after.trimmingCharacters(in: CharacterSet(charactersIn: " ，,。"))
        for key in keys where tail.hasPrefix(key) {
            let rest = tail.dropFirst(key.count)
            if let end = rest.firstIndex(where: { speechEnds.contains($0) }), rest.distance(from: rest.startIndex, to: end) <= 6 {
                return (key, String(rest[...end]))
            }
        }
        return nil
    }

    // The earliest name in the text; at the same place the longer one ("林黛玉" over "黛玉").
    private static func firstName(in text: String, keys: [String]) -> String? {
        var best: (name: String, offset: Int)?
        for key in keys {
            guard let range = text.range(of: key) else { continue }
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            if best.map({ offset < $0.offset || (offset == $0.offset && key.count > $0.name.count) }) ?? true {
                best = (key, offset)
            }
        }
        return best?.name
    }

    /// A few lines of `speaker` for the moment: said to the same people, in the mood the
    /// conversation is in, from near the time point, varied in mood, never after `chapter`.
    static func pick(_ lines: [DialogueLine], speaker: String, recent: String, partners: [String], upTo chapter: Int,
                     limit: Int = 5) -> [DialogueLine] {
        let own = lines.filter { $0.speaker == speaker && $0.chapter <= chapter && (2...90).contains($0.text.count) }
        guard !own.isEmpty else { return [] }
        let wanted = DialogueMood.detect(recent)
        let nearby = max(5, chapter / 5)
        let scored = own.enumerated().map { index, line -> (score: Int, index: Int, line: DialogueLine) in
            var score = 0
            if partners.contains(where: { !$0.isEmpty && line.context.contains($0) }) { score += 3 }
            if let wanted, line.mood == wanted { score += 2 }
            if line.chapter >= chapter - nearby { score += 1 }
            if !line.manner.isEmpty { score += 1 }
            return (score, index, line)
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index > $1.index }
        var picked: [DialogueLine] = []
        var perMood: [DialogueMood: Int] = [:]
        for item in scored where picked.count < limit {
            guard perMood[item.line.mood, default: 0] < 2, !picked.contains(where: { $0.text == item.line.text }) else { continue }
            picked.append(item.line)
            perMood[item.line.mood, default: 0] += 1
        }
        return picked
    }

    static func note(_ lines: [DialogueLine], speaker: String) -> String? {
        guard !lines.isEmpty else { return nil }
        var out = ["（\(speaker)在原著里类似情形下是这样说话的，照这个语气、用词和长短来写，不要照搬原句：）"]
        for line in lines {
            let how = line.manner.isEmpty ? "" : "（\(line.manner)）"
            out.append("\(how)「\(line.text)」")
        }
        return out.joined(separator: "\n")
    }
}
