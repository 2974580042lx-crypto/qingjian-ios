import SwiftUI

// 1.46 固定做法: a project's saved routines, after Claude Code's Skills. Name and one line of
// "when to use" are all the router sees; the body is added only to the message that needs it.
@MainActor
struct ProjectSkillsView: View {
    @EnvironmentObject private var store: AppStore
    let projectID: UUID
    @State private var editing: ProjectSkillDraft?

    private var skills: [ProjectSkill] { store.project(projectID)?.skills ?? [] }

    var body: some View {
        List {
            if skills.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有固定做法")
                            .font(TypeScale.ui(16, weight: .medium))
                            .foregroundStyle(Ink.ink)
                        Text("把常做的事写成一套做法，比如「周报：按 本周完成 / 下周计划 / 风险 三段写，每段不超过五条」。聊到相关的事时会自动用上，也可以在输入框打「/周报」直接调用。")
                            .font(TypeScale.ui(14))
                            .foregroundStyle(Ink.ink3)
                            .lineSpacing(3)
                    }
                    .padding(.vertical, 6)
                }
                .claudeCardRow()
            } else {
                Section {
                    ForEach(skills) { skill in
                        Button { editing = ProjectSkillDraft(skill) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("/" + skill.name)
                                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Ink.ink)
                                Text(skill.whenToUse.isEmpty ? String(skill.body.prefix(60)) : skill.whenToUse)
                                    .font(TypeScale.ui(13))
                                    .foregroundStyle(Ink.ink3)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("删除", role: .destructive) { store.deleteSkill(skill.id, in: projectID) }
                        }
                    }
                } footer: {
                    Text("左滑删除。最多 \(ProjectSkill.countLimit) 个。")
                }
                .claudeCardRow()
            }
        }
        .claudeGroupedListStyle()
        .navigationTitle("固定做法")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = ProjectSkillDraft() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建固定做法")
                    .disabled(skills.count >= ProjectSkill.countLimit)
            }
        }
        .sheet(item: $editing) { draft in
            ProjectSkillEditor(projectID: projectID, draft: draft).environmentObject(store)
        }
    }
}

/// What the editor starts from: an existing routine, or a new one (possibly prefilled).
struct ProjectSkillDraft: Identifiable {
    var id: UUID
    var isNew: Bool
    var name: String
    var whenToUse: String
    var body: String

    init(_ skill: ProjectSkill) {
        id = skill.id; isNew = false
        name = skill.name; whenToUse = skill.whenToUse; body = skill.body
    }
    init(name: String = "", whenToUse: String = "", body: String = "") {
        id = UUID(); isNew = true
        self.name = name; self.whenToUse = whenToUse; self.body = body
    }
}

@MainActor
struct ProjectSkillEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let draft: ProjectSkillDraft
    @State private var name = ""
    @State private var whenToUse = ""
    @State private var bodyText = ""
    @State private var loaded = false

    private var candidate: ProjectSkill? {
        ProjectSkills.make(name: name, whenToUse: whenToUse, body: bodyText, id: draft.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：周报", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: { Text("名字") } footer: {
                    Text("输入框里打「/\(ProjectSkills.cleanName(name).isEmpty ? "名字" : ProjectSkills.cleanName(name))」就能直接调用。不超过 \(ProjectSkill.nameLimit) 个字，不含空格。")
                }
                .claudeCardRow()
                Section {
                    TextField("例如：我让你写周报或总结这周工作时", text: $whenToUse, axis: .vertical)
                        .lineLimit(1...3)
                } header: { Text("什么时候用") } footer: {
                    Text("一句话就够。平时只有这句话会被拿去判断要不要用这套做法。")
                }
                .claudeCardRow()
                Section {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 200)
                        .font(TypeScale.ui(15))
                } header: { Text("做法") } footer: {
                    Text("写清楚步骤、格式和注意事项。用上的那一次才会带上全文。\(bodyText.count.formatted()) / \(ProjectSkill.bodyLimit.formatted()) 字")
                }
                .claudeCardRow()
                if !draft.isNew {
                    Section {
                        Button("删除这个做法", role: .destructive) {
                            store.deleteSkill(draft.id, in: projectID)
                            dismiss()
                        }
                    }
                    .claudeCardRow()
                }
            }
            .claudeGroupedFormStyle()
            .navigationTitle(draft.isNew ? "新建固定做法" : "编辑固定做法")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ClaudeSheetCloseButton(label: "取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        guard let skill = candidate else { return }
                        if store.saveSkill(skill, in: projectID) { dismiss() }
                    }
                    .fontWeight(.semibold)
                    .disabled(candidate == nil)
                }
            }
        }
        .tint(Ink.ink)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = draft.name
            whenToUse = draft.whenToUse
            bodyText = draft.body
        }
    }
}
