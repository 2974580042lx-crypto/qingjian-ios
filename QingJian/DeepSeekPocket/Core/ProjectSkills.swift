import Foundation

// 1.46 固定做法 — a project's saved routines, after Claude Code's Skills. Each has a name and one
// line saying when to use it; only those travel to the router, which picks one when a message
// matches. The full instructions are added to that one message only (progressive disclosure),
// and typing 「/名字」 picks one by hand.
struct ProjectSkill: Identifiable, Codable, Equatable, Sendable {
    static let nameLimit = 24
    static let hintLimit = 120
    static let bodyLimit = 8000
    static let countLimit = 30

    var id = UUID()
    var name: String
    var whenToUse: String
    var body: String
    var updatedAt = Date()

    var isValid: Bool {
        let cleanName = ProjectSkills.cleanName(name)
        return !cleanName.isEmpty && cleanName.count <= Self.nameLimit && cleanName == name
            && whenToUse.count <= Self.hintLimit
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && body.count <= Self.bodyLimit
    }
}

enum ProjectSkills {
    /// A name without the slash, spaces or line breaks, cut to the limit.
    static func cleanName(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("/") || text.hasPrefix("／") { text.removeFirst() }
        text = text.components(separatedBy: .whitespacesAndNewlines).joined()
        return String(text.prefix(ProjectSkill.nameLimit))
    }

    /// Builds a valid routine from what was typed, or nil when the name or the body is empty.
    static func make(name: String, whenToUse: String, body: String, id: UUID = UUID()) -> ProjectSkill? {
        let clean = cleanName(name)
        let hint = whenToUse.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !text.isEmpty else { return nil }
        return ProjectSkill(id: id, name: clean, whenToUse: String(hint.prefix(ProjectSkill.hintLimit)),
                            body: String(text.prefix(ProjectSkill.bodyLimit)))
    }

    /// The routine a message starts with, as in 「/周报 这周做了…」.
    static func explicit(in text: String, skills: [ProjectSkill]) -> ProjectSkill? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("/") || clean.hasPrefix("／") else { return nil }
        let typed = String(clean.dropFirst().prefix(while: { !$0.isWhitespace })).lowercased()
        guard !typed.isEmpty else { return nil }
        return skills.first { $0.name.lowercased() == typed }
    }

    static func hints(_ skills: [ProjectSkill]) -> [TurnRouter.SkillHint] {
        skills.map { TurnRouter.SkillHint(name: $0.name, hint: $0.whenToUse.isEmpty ? $0.name : $0.whenToUse) }
    }

    /// What one message carries when a routine is picked.
    static func note(_ skill: ProjectSkill) -> String {
        """
        <routine name="\(skill.name)">
        这次请按这个项目保存的固定做法「\(skill.name)」来完成，做法如下：
        \(skill.body)
        </routine>
        """
    }
}
