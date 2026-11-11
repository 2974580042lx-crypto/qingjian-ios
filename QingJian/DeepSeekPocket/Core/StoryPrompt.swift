import Foundation

// A character from another book, brought into this conversation as a guest (1.9.0).
struct StoryGuest: Codable, Equatable, Hashable, Sendable {
    var bookID: UUID
    var bookTitle: String
    var character: String
}

// A conversation started from the bookshelf: one character from one book.
// Optional on ChatThread, so conversations from earlier releases still load.
// Fields added after 1.8.0 are optional, because saved sessions lack their keys.
struct StorySession: Codable, Equatable, Sendable {
    var bookID: UUID
    var bookTitle: String
    var character: String
    // Who you are in the scene: a person from the book, or your own description. Empty means yourself.
    var userRole = ""
    // Your own note for the opening, e.g. where and when it starts.
    var opening = ""
    // The chapter the story starts at (index). Nil: the character knows the whole book.
    var chapter: Int?
    var chapterTitle: String?
    // What happened up to that chapter and where everyone stands, written at the start.
    var briefing: String?
    // Your own rules for this game: a play style, a status bar, anything. Editable while playing.
    var instruction: String?
    // The card of your own character, when you play one saved on the bookshelf.
    var userCard: String?
    var guests: [StoryGuest]?
    // Paragraphs of the original where the character speaks, picked once at the start (1.10.0),
    // so every request carries the same text and DeepSeek's cache keeps it cheap.
    var characterPassages: [String]?
    // 「跟着原著走」(1.12.0): nil is a free game. canonSegment is the reading segment the
    // story is in; startChapter the chapter the game began at; canonBridge what was
    // skipped, told once in the next answer.
    var canon: CanonMode?
    var canonSegment: Int?
    var startChapter: Int?
    var canonBridge: String?

    // Optional additions keep all pre-1.13 saves decodable.
    var sceneStart: StorySceneStart?
    var direction: StoryDirection?
    var memory: StoryMemory?
    var automaticMemory: Bool?
    var fixedEvents: String?
    var sceneNote: String?
    var presentCharacters: [String]?
    var nextSpeaker: String?
    var ended: Bool?
    var originThreadID: UUID?
    var branchLabel: String?
    var profileSnapshot: BookProfile?
    var guestProfileSnapshots: [StoryGuestProfile]?
    var plotDirection: StoryDirection { direction ?? (canon == nil ? .free : .canon) }
    var isTimeLocked: Bool { chapter != nil }
}

// One of your own characters, kept on the bookshelf to play in any book.
struct PersonaCard: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var detail: String
}

enum StoryPrompt {
    /// The system prompt for a bookshelf conversation. Without the book's profile
    /// (deleted from the shelf) the conversation keeps going on what it said so far.
    static func compose(_ session: StorySession, book: Book?, guestBooks: [Book] = []) -> String {
        guard let profile = book?.profile,
              let character = profile.characters.first(where: { $0.name == session.character }) else {
            return "你在扮演小说《\(session.bookTitle)》里的\(session.character)。这本书已从书架移除，请按照目前为止的对话保持人物的性格和说话方式，继续扮演。"
                + "\n\n" + StoryPlay.context(session) + instructionPart(session)
        }
        let limit = session.chapter
        func known(_ chapter: Int?) -> Bool { limit == nil || (chapter ?? 0) <= limit! }
        let guests = (session.guests ?? []).compactMap { guest -> (StoryGuest, BookCharacter)? in
            guard let card = guestBooks.first(where: { $0.id == guest.bookID })?.profile?.characters
                .first(where: { $0.name == guest.character }) else { return nil }
            return (guest, card)
        }
        var parts: [String] = []
        let role = session.userRole.trimmingCharacters(in: .whitespacesAndNewlines)
        let played = ([character.name] + guests.map { $0.1.name }).joined(separator: "、")
        parts.append("""
        你在和用户进行基于小说《\(session.bookTitle)》的角色扮演。你扮演\(played)，用户扮演\(role.isEmpty ? "他自己" : role)。
        - 始终以人物的身份说话和行动，性格、说话方式、见识都要和原著一致，不要出戏，不要提到自己是 AI，也不要解释设定。
        - 对白直接写出来，必要的动作、神态用（）简短交代；书里其他人物可以自然出现，由你来写，但他们也要像原著。
        - 不替用户扮演的人物说话、做决定或描写其内心，把回应的机会留给用户。
        - 每次回复篇幅适中，停在需要用户回应的地方。
        """)
        if let limit {
            let title = session.chapterTitle ?? book?.chapterLabel(limit) ?? "第 \(limit + 1) 章"
            parts.append("""
            【时间点】故事现在到了原著「\(title)」（第 \(limit + 1) 章）。人物只知道这之前发生的事：不提及、不暗示、不预言之后的剧情，也不按之后才有的关系和身份行事。\(session.canon == nil ? "从这里起，剧情跟着用户的选择走。" : "从这里起，剧情顺着下面的原著主线走。")
            """)
            if let briefing = session.briefing?.trimmingCharacters(in: .whitespacesAndNewlines), !briefing.isEmpty {
                let moved = session.canon != nil && session.startChapter != nil && session.startChapter != limit
                parts.append((moved ? "【开局时的前情提要】（之后发生的事见对话和原著主线）\n" : "【前情提要】\n") + briefing)
            }
        }
        if let canon = CanonPlan.section(session, book: book) { parts.append(canon) }
        let opening = session.opening.trimmingCharacters(in: .whitespacesAndNewlines)
        if !opening.isEmpty { parts.append("【开场设定】\n" + opening) }

        parts.append(card(character, known: known, fullBook: limit == nil))
        if let passages = session.characterPassages, !passages.isEmpty {
            parts.append("【原著里的\(character.name)】以下是原文里他说话、做事的片段，按这个感觉来演（不要照抄）：\n"
                         + passages.map { "「\($0)」" }.joined(separator: "\n"))
        }
        for (guest, guestCard) in guests {
            parts.append("""
            【客串人物：\(guestCard.name)（来自《\(guest.bookTitle)》）】
            \(guestCard.name)原本是《\(guest.bookTitle)》里的人物，这一局被带进了《\(session.bookTitle)》的故事。保持他原本的性格、说话方式和见识；他不了解这个世界的人和事，除非剧情让他知道。由你一并扮演。
            """ + "\n" + card(guestCard, known: { _ in true }, fullBook: false, heading: false))
        }

        // The user's side: a person from the book, or a saved card of their own.
        if let card = session.userCard?.trimmingCharacters(in: .whitespacesAndNewlines), !card.isEmpty {
            parts.append("【用户扮演的\(role.isEmpty ? "人物" : role)】\n" + card)
        } else if let user = profile.characters.first(where: { $0.name != character.name && $0.allNames.contains(role) }) {
            let lines = [user.identity, user.personality, limit == nil ? user.relationships : ""].filter { !$0.isEmpty }
            parts.append("【用户扮演的\(user.name)】\n" + lines.joined(separator: "\n"))
        }
        let others = profile.characters.filter {
            $0.name != character.name && !$0.allNames.contains(role) && known($0.firstChapter)
        }.prefix(12)
        if !others.isEmpty {
            parts.append("【书中其他人物】\n" + others.map { "- \($0.name)：\($0.identity.isEmpty ? $0.personality : $0.identity)" }.joined(separator: "\n"))
        }
        if limit == nil, !profile.summary.isEmpty { parts.append("【全书梗概】\n" + profile.summary) }
        if !profile.style.description.isEmpty || !profile.style.excerpts.isEmpty {
            var style = ["【原著笔触】描写和叙述要贴近原著的语感："]
            if !profile.style.description.isEmpty { style.append(profile.style.description) }
            if let signatures = profile.style.signatures, !signatures.isEmpty {
                style.append("标志性写法：\n" + signatures.map { "- " + $0 }.joined(separator: "\n"))
            }
            if let avoid = profile.style.avoid, !avoid.isEmpty {
                style.append("原著不会这样写，避免：\n" + avoid.map { "- " + $0 }.joined(separator: "\n"))
            }
            if !profile.style.excerpts.isEmpty {
                style.append("原文片段（体会笔触，不要照抄）：")
                style.append(contentsOf: profile.style.excerpts.prefix(5).map { "「\($0)」" })
            }
            parts.append(style.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n") + "\n\n" + StoryPlay.context(session) + instructionPart(session)
    }

    private static func card(_ character: BookCharacter, known: (Int?) -> Bool, fullBook: Bool, heading: Bool = true) -> String {
        var lines = heading ? ["【\(character.name)】"] : []
        if !character.aliases.isEmpty { lines.append("又称：" + character.aliases.joined(separator: "、")) }
        // Relationships and the life story cover the whole book; with a time point the
        // briefing says where things stand instead.
        var fields = [("身份", character.identity), ("性格", character.personality), ("说话方式", character.speech),
                      ("不同情境下的反应", character.behavior ?? ""), ("对不同人的态度", character.attitudes ?? ""),
                      ("绝不会说或做的事", character.taboos ?? "")]
        if fullBook { fields += [("人物关系", character.relationships), ("经历", character.arc)] }
        for (label, value) in fields where !value.isEmpty { lines.append("\(label)：\(value)") }
        let quotes = character.quotes.filter { known($0.chapter) }.prefix(6)
        if !quotes.isEmpty {
            lines.append("原著台词（体会语气，不要照搬）：")
            lines.append(contentsOf: quotes.map { "「\($0.text)」" })
        }
        if let corrections = character.corrections, !corrections.isEmpty {
            lines.append("用户纠正过的地方（务必遵守）：")
            lines.append(contentsOf: corrections.suffix(20).map { "- " + $0 })
        }
        return lines.joined(separator: "\n")
    }

    // Last, so it reads as the final word on how to play.
    private static func instructionPart(_ session: StorySession) -> String {
        guard let text = session.instruction?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return "" }
        return "\n\n【本局玩法】以下是用户为这一局定的规矩，与上面冲突时以这里为准：\n" + text
    }

    /// Names and terms worth looking up in the text when the conversation mentions them.
    static func vocabulary(of profile: BookProfile, upTo chapter: Int? = nil) -> [String] {
        var words = profile.terms.filter { chapter == nil || $0.chapter <= chapter! }.map(\.term)
        for character in profile.characters where chapter == nil || (character.firstChapter ?? 0) <= chapter! {
            words += character.allNames
        }
        return Array(Set(words.filter { $0.count >= 2 }))
    }

    /// What the newest user message gets in front of it, for this request only.
    static func passageNote(terms: [String], passages: [String], profile: BookProfile) -> String? {
        guard !passages.isEmpty else { return nil }
        var lines = ["（以下是原著里和这句话相关的段落与名词，供你保持设定一致，不要照抄，也不要提到这段说明。）"]
        for term in terms {
            if let entry = profile.terms.first(where: { $0.term == term }) { lines.append("· \(entry.term)：\(entry.note)") }
        }
        lines.append(contentsOf: passages.map { "「\($0)」" })
        lines.append("（以上为参考。）")
        return lines.joined(separator: "\n")
    }
}
