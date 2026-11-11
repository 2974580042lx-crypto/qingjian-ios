import SwiftUI

// Every feature and where to find it, from the same text as the manual project.
// Reading this costs nothing; asking the manual project goes to the model.
@MainActor
struct FeatureOverviewView: View {
    @EnvironmentObject private var store: AppStore
    @State private var search = ""

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matchingSections: [AppManual.Section] {
        guard !query.isEmpty else { return AppManual.sections }
        return AppManual.sections.compactMap { section in
            if section.title.localizedStandardContains(query) { return section }
            let items = section.items.filter {
                $0.name.localizedStandardContains(query) || $0.how.localizedStandardContains(query)
            }
            return items.isEmpty ? nil : AppManual.Section(title: section.title, items: items)
        }
    }

    var body: some View {
        List {
            Section {
                if store.manualDismissed {
                    Button("恢复「\(AppManual.projectName)」项目") { store.restoreManualProject() }
                } else {
                    Text("想用聊天的方式问，可以在侧栏的项目里打开「\(AppManual.projectName)」。")
                        .font(TypeScale.serif(14)).foregroundStyle(Ink.ink2)
                }
            }
            if !query.isEmpty {
                Section {
                    HStack {
                        Text("找到 \(matchingSections.reduce(0) { $0 + $1.items.count }) 项功能")
                            .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                        Spacer()
                        Button("清空") { search = "" }.font(TypeScale.caption)
                    }
                }
            }
            if matchingSections.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("没有找到相关功能", systemImage: "magnifyingglass")
                    } description: {
                        Text("试试「备份」「图片」「项目」等关键词。")
                    }
                }
            }
            ForEach(matchingSections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.items, id: \.name) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(TypeScale.serif(16).weight(.semibold)).foregroundStyle(Ink.ink)
                            Text(item.how).font(TypeScale.serif(14)).foregroundStyle(Ink.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .listRowBackground(Color.clear)
        .navigationTitle("功能一览")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索功能、入口或用法")
    }
}
