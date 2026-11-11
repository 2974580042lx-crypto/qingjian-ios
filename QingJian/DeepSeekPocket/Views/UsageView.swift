import SwiftUI

// Daily use as a grid of weeks, darker on busier days, like the Claude Code and Codex stats.
@MainActor
struct UsageCalendarView: View {
    let ledger: UsageLedger
    @State private var selected = Date()
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.firstWeekday = 2
        return value
    }()
    private let cell: CGFloat = 13, gap: CGFloat = 3, labelWidth: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                stat("今天", ledger.day(Date(), calendar: calendar))
                Rectangle().fill(Ink.line).frame(width: 0.5, height: 34).padding(.horizontal, 14)
                stat("本月", ledger.month(containing: Date(), calendar: calendar))
            }
            GeometryReader { proxy in
                grid(weeks: max(8, min(26, Int((proxy.size.width - labelWidth) / (cell + gap)))))
            }
            .frame(height: 16 + 7 * cell + 6 * gap)
            HStack(spacing: 3) {
                Spacer()
                Text("少")
                ForEach(0..<5, id: \.self) { shade($0).frame(width: 10, height: 10).clipShape(RoundedRectangle(cornerRadius: 2)) }
                Text("多")
            }.font(TypeScale.serif(10)).foregroundStyle(Ink.ink3)
            let day = ledger.day(selected, calendar: calendar)
            HStack(spacing: 8) {
                Text(selected.formatted(.dateTime.month().day().weekday(.abbreviated))).fontWeight(.semibold)
                Text("\(day.tokens.formatted()) tokens · \(Pricing.label(day.cost)) · \(day.requests) 次").foregroundStyle(Ink.ink2)
            }
            .font(TypeScale.serif(13)).monospacedDigit()
            .padding(.top, 10).overlay(alignment: .top) { InkRule() }
            .accessibilityIdentifier("usage-selected-day")
            HStack(alignment: .top) {
                fact("连续使用", "\(ledger.streak(endingAt: Date(), calendar: calendar)) 天")
                Spacer()
                fact("最多的一天", ledger.busiestDay.map(shortDay) ?? "—")
                Spacer()
                fact("常用模型", ledger.favouriteModel?.title ?? "—")
            }
            NavigationLink {
                UsageDetailsView(ledger: ledger)
            } label: {
                Label("查看明细与导出", systemImage: "list.bullet.rectangle")
                    .font(TypeScale.serif(14).weight(.semibold))
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-calendar")
    }

    private func grid(weeks: Int) -> some View {
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let starts = (0..<weeks).compactMap { calendar.date(byAdding: .day, value: -7 * (weeks - 1 - $0), to: thisWeek) }
        let peak = starts.flatMap { start in (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) } }
            .map { ledger.day($0, calendar: calendar).tokens }.max() ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: gap) {
                Color.clear.frame(width: labelWidth - gap, height: 12)
                ForEach(Array(starts.enumerated()), id: \.offset) { index, start in
                    let month = calendar.component(.month, from: start)
                    let previous = index > 0 ? calendar.component(.month, from: starts[index - 1]) : nil
                    Text(previous != month ? "\(month)月" : "").font(TypeScale.serif(9)).foregroundStyle(Ink.ink3)
                        .fixedSize().frame(width: cell, height: 12, alignment: .leading)
                }
            }
            HStack(alignment: .top, spacing: gap) {
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(Array(["一", "", "三", "", "五", "", "日"].enumerated()), id: \.offset) { _, label in
                        Text(label).font(TypeScale.serif(9)).foregroundStyle(Ink.ink3).frame(height: cell)
                    }
                }.frame(width: labelWidth - gap, alignment: .leading)
                ForEach(starts, id: \.self) { start in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { offset in
                            let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                            if date > today {
                                Color.clear.frame(width: cell, height: cell)
                            } else {
                                let tokens = ledger.day(date, calendar: calendar).tokens
                                shade(UsageLedger.level(tokens, peak: peak))
                                    .frame(width: cell, height: cell)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                    .overlay {
                                        if calendar.isDate(date, inSameDayAs: selected) {
                                            RoundedRectangle(cornerRadius: 3).stroke(Ink.ink, lineWidth: 1.5).padding(-1.5)
                                        }
                                    }
                                    .onTapGesture { selected = date }
                                    .accessibilityLabel("\(date.formatted(date: .abbreviated, time: .omitted))，\(tokens) tokens")
                            }
                        }
                    }
                }
            }
        }
    }

    private func shade(_ level: Int) -> Color {
        switch level {
        case 0: return Ink.ink.opacity(0.07)
        case 1: return Ink.seal.opacity(0.25)
        case 2: return Ink.seal.opacity(0.48)
        case 3: return Ink.seal.opacity(0.72)
        default: return Ink.seal
        }
    }

    private func stat(_ title: String, _ usage: DayUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(TypeScale.tiny).foregroundStyle(Ink.ink3)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(compact(usage.tokens)).font(TypeScale.serif(20).weight(.semibold)).monospacedDigit()
                Text(Pricing.label(usage.cost)).font(TypeScale.tiny).foregroundStyle(Ink.ink3).monospacedDigit()
            }
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(TypeScale.tiny).foregroundStyle(Ink.ink3)
            Text(value).font(TypeScale.serif(13).weight(.semibold))
        }
    }

    private func compact(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.2fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return "\(tokens)"
    }

    private func shortDay(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return key }
        return "\(month) 月 \(day) 日"
    }
}

// A local view of the existing daily ledger; exporting never sends a request.
@MainActor
private struct UsageDetailsView: View {
    let ledger: UsageLedger
    @State private var period = UsagePeriod.month
    @State private var now = Date()
    @State private var exportURL: URL?
    @State private var showingExport = false
    @State private var exportError: String?

    private enum UsagePeriod: String, CaseIterable, Identifiable {
        case month = "本月", recent = "近30天", all = "全部"
        var id: String { rawValue }
    }

    private struct Record: Identifiable {
        let key: String
        let usage: DayUsage
        var id: String { key }
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .autoupdatingCurrent
        return value
    }

    private var records: [Record] {
        let today = calendar.startOfDay(for: now)
        let start: Date?
        switch period {
        case .month: start = calendar.dateInterval(of: .month, for: today)?.start
        case .recent: start = calendar.date(byAdding: .day, value: -29, to: today)
        case .all: start = nil
        }
        return ledger.days.compactMap { key, usage -> Record? in
            let parts = key.split(separator: "-")
            guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  UsageLedger.key(for: date, calendar: calendar) == key,
                  date <= today, start.map({ date >= $0 }) ?? true else { return nil }
            return Record(key: key, usage: usage)
        }.sorted { $0.key > $1.key }
    }

    private var total: DayUsage { records.map(\.usage).reduce(DayUsage(), +) }

    var body: some View {
        List {
            Section {
                Picker("日期范围", selection: $period) {
                    ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("usage-period")
            }
            Section("\(period.rawValue)合计") {
                LabeledContent("总用量", value: "\(total.tokens.formatted()) tokens")
                LabeledContent("请求数", value: "\(total.requests.formatted()) 次")
                LabeledContent("估算花费", value: Pricing.label(total.cost))
                LabeledContent("有记录的日期", value: "\(records.count) 天")
            }
            .monospacedDigit()
            Section {
                LabeledContent("Flash", value: "\(total.flashTokens.formatted()) tokens")
                LabeledContent("Pro", value: "\(total.proTokens.formatted()) tokens")
                if let tokens = total.colabTokens, tokens > 0 {
                    LabeledContent("Colab · 免费", value: "\(tokens.formatted()) tokens")
                }
                LabeledContent("未归类", value: "\(unclassified(total).formatted()) tokens")
            } header: { Text("模型用量") } footer: {
                Text("未归类包含 ChatGPT 订阅、独立搜索和未记录模型的旧用量，无法据此分别计费。花费只汇总已有的人民币估算，实际扣费以服务平台为准。")
            }
            .monospacedDigit()
            Section {
                if records.isEmpty {
                    ContentUnavailableView("这段时间还没有记录", systemImage: "calendar", description: Text("可以切换到「全部」查看更早的用量。"))
                } else {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(record.key).fontWeight(.semibold)
                                Spacer()
                                Text(Pricing.label(record.usage.cost)).foregroundStyle(Ink.ink2)
                            }
                            Text("\(record.usage.tokens.formatted()) tokens · \(record.usage.requests.formatted()) 次请求")
                                .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                        }
                        .monospacedDigit()
                        .padding(.vertical, 3)
                    }
                }
            } header: { Text("逐日明细") } footer: {
                Text("按记录时的本地日期统计，仅显示已有记录。导出当前范围的逐日汇总，不含聊天正文、API Key 或登录信息。")
            }
            Section {
                Button(action: exportCSV) { Label("导出当前范围 CSV", systemImage: "square.and.arrow.up") }
                    .disabled(records.isEmpty)
                    .accessibilityIdentifier("usage-export-csv")
            }
        }
        .font(TypeScale.body)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .listRowBackground(Color.clear)
        .foregroundStyle(Ink.ink)
        .tint(Ink.ink)
        .navigationTitle("用量明细")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { now = Date() }
        .sheet(isPresented: $showingExport) {
            if let url = exportURL { ShareSheet(items: [url]) }
        }
        .alert("暂时无法导出", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("知道了") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private func unclassified(_ usage: DayUsage) -> Int {
        max(0, usage.tokens - usage.flashTokens - usage.proTokens - (usage.colabTokens ?? 0))
    }

    private func exportCSV() {
        let rows = records
        guard !rows.isEmpty else { return }
        let aggregate = rows.map(\.usage).reduce(DayUsage(), +)
        var lines = ["日期,总 tokens,请求数,估算花费（CNY）,Flash tokens,Pro tokens,未归类 tokens,Colab tokens"]
        lines += rows.reversed().map { csvLine($0.key, usage: $0.usage) }
        lines.append(csvLine("合计", usage: aggregate))
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Sermo-usage-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let day = UsageLedger.key(for: now, calendar: calendar)
            let url = folder.appendingPathComponent("Sermo-用量-\(period.rawValue)-\(day).csv")
            // BOM lets Excel recognize Chinese headers; CRLF keeps each day on one row.
            try ("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
            showingExport = true
        } catch {
            exportError = "未能生成用量文件：\(error.localizedDescription)"
        }
    }

    private func csvLine(_ label: String, usage: DayUsage) -> String {
        let cost = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), usage.cost)
        return "\(label),\(usage.tokens),\(usage.requests),\(cost),\(usage.flashTokens),\(usage.proTokens),\(unclassified(usage)),\(usage.colabTokens ?? 0)"
    }
}
