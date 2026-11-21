import SwiftUI

struct AgentTimelineTarget: Identifiable, Equatable {
    let threadID: UUID?
    let messageID: UUID
    var id: UUID { messageID }
}

/// 1:1 Claude V3 quiet 1-line working summary row inside the chat stream.
/// Frameless grey text + inline chevron immediately after text; tapping opens `AgentWorkingTimelineSheet`.
@MainActor
struct AgentWorkingSummaryRow: View {
    let record: AgentRunRecord
    let toolItems: [ToolActivity]
    let signInDrive: () -> Void
    let openTimeline: () -> Void

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var needsDriveSignIn: Bool {
        toolItems.contains { $0.status == .needsSignIn && $0.kind != "github" }
    }

    private var studyReports: [StudyWeeklyReport] {
        toolItems.compactMap(\.studyReport)
    }

    private var studyExcerpts: [StudyExcerpt] {
        toolItems.filter { $0.status == .done }.flatMap { $0.studyExcerpts ?? [] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptic.tap()
                openTimeline()
            } label: {
                HStack(alignment: .center, spacing: 6) {
                    if record.isActive {
                        Circle()
                            .fill(Ink.seal)
                            .frame(width: 7, height: 7)
                            .scaleEffect(record.phase == .running && pulse && !reduceMotion ? 0.82 : 1.0)
                            .opacity(record.phase == .running && pulse && !reduceMotion ? 0.38 : 1.0)
                            .onAppear {
                                guard !reduceMotion else { return }
                                withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                                    pulse = true
                                }
                            }
                    }
                    Text(record.summaryLine)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Ink.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Ink.ink3.opacity(0.85))
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressFeedback)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("工作过程：\(record.summaryLine)")
            .accessibilityHint("点按查看完整工作步骤时间线")

            if needsDriveSignIn {
                Button("登录谷歌云盘", action: signInDrive)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.seal)
                    .padding(.vertical, 2)
                    .buttonStyle(.pressFeedback)
            }

            ForEach(Array(studyReports.enumerated()), id: \.offset) { _, report in
                DisclosureGroup("学习周报 · 第\(report.revision)版快照") {
                    Text(report.text)
                        .font(TypeScale.body)
                        .foregroundStyle(Ink.ink)
                        .textSelection(.enabled)
                    Text("生成于 \(report.createdAt.formatted(date: .abbreviated, time: .shortened))。后续记录有变化时，请在项目记忆页生成最新报告。")
                        .font(TypeScale.caption)
                        .foregroundStyle(Ink.ink3)
                }
                .font(TypeScale.caption)
                .tint(Ink.ink)
            }

            ForEach(Array(studyExcerpts.enumerated()), id: \.offset) { _, excerpt in
                VStack(alignment: .leading, spacing: 8) {
                    Text("资料原文 · " + excerpt.title)
                        .font(TypeScale.caption.weight(.medium))
                        .foregroundStyle(Ink.seal)
                    Text(excerpt.text)
                        .font(TypeScale.body)
                        .foregroundStyle(Ink.ink)
                        .textSelection(.enabled)
                    Text(excerpt.source)
                        .font(TypeScale.caption)
                        .foregroundStyle(Ink.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Ink.line).frame(width: 2)
                }
            }
        }
        .accessibilityIdentifier("tool-activity")
    }
}

/// 1:1 Claude V3 native bottom Sheet rendering the pure single-axis vertical working timeline.
/// Zero nested rounded cards, zero grey tool capsules, 16.5pt primary body, on-demand plain tech details.
@MainActor
struct AgentWorkingTimelineSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let target: AgentTimelineTarget
    @State private var expandedIDs: Set<String> = []
    @State private var livePulse = false

    private static let sheetSurface = Color.adaptive(light: 0xFAFAFA, dark: 0x1F1F1F)
    private static let axisLineColor = Color.adaptive(light: 0xDDDDDB, dark: 0x3C3C3A)
    private static let dotColor = Color.adaptive(light: 0x8C8C89, dark: 0x8E8E8B)

    private var currentMessage: ChatMessage? {
        if let tid = target.threadID,
           let thread = store.threads.first(where: { $0.id == tid }),
           let msg = thread.messages.first(where: { $0.id == target.messageID }) {
            return msg
        }
        for thread in store.threads {
            if let msg = thread.messages.first(where: { $0.id == target.messageID }) {
                return msg
            }
        }
        return nil
    }

    private var currentRecord: AgentRunRecord {
        if let msg = currentMessage,
           let resolved = store.agentRunRecord(for: msg, threadID: target.threadID) {
            return resolved
        }
        return store.agentRunStore.record(for: target.messageID)
            ?? AgentRunRecord(messageID: target.messageID, threadID: target.threadID ?? UUID(), phase: .completed)
    }

    private var isLiveRunForThisMessage: Bool {
        store.isGenerating(in: target.threadID) && (store.live.messageID == target.messageID || currentMessage?.state == .streaming)
    }

    private var renderedSteps: [AgentTimelineStep] {
        var list = currentRecord.visibleSteps
        if isLiveRunForThisMessage {
            let hasRunningNode = list.contains { $0.status == .running || $0.kind == .live }
            if !hasRunningNode {
                let liveText = store.isAgentPaused
                    ? "已暂停执行，已完成步骤已安全保存"
                    : "正在整理结果并继续撰写回答…"
                list.append(AgentTimelineStep(id: "live-tail", kind: .live, text: liveText, status: .running))
            }
        }
        return list
    }

    var body: some View {
        let record = currentRecord
        let steps = renderedSteps
        VStack(spacing: 0) {
            headerBar(record: record)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        timelineRow(step: step, isLast: index == steps.count - 1)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
        }
        .background(Self.sheetSurface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
    }

    private func headerBar(record: AgentRunRecord) -> some View {
        HStack(spacing: 12) {
            Button {
                Haptic.tap()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .frame(width: 38, height: 38)
                    .background(Ink.card, in: Circle())
                    .overlay(Circle().stroke(Ink.line, lineWidth: 0.8))
                    .contentShape(Circle())
            }
            .buttonStyle(.pressFeedback)
            .accessibilityLabel("关闭工作过程")

            Text(record.sheetHeaderTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Ink.ink)
                .lineLimit(1)

            Spacer(minLength: 4)

            if isLiveRunForThisMessage {
                HStack(spacing: 16) {
                    Button {
                        Haptic.tap()
                        if store.isAgentPaused {
                            store.resumeAgentRun()
                        } else {
                            store.pauseAgentRun()
                        }
                    } label: {
                        Text(store.isAgentPaused ? "继续" : "暂停")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Ink.ink2)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.pressFeedback)

                    Button {
                        Haptic.tap()
                        store.stopGeneration()
                    } label: {
                        Text("停止")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Ink.seal)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.pressFeedback)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func timelineRow(step: AgentTimelineStep, isLast: Bool) -> some View {
        let hasTech = (step.tech?.isEmpty == false)
        let isExpanded = expandedIDs.contains(step.id)
        let isActivelyRunning = (step.kind == .live || step.status == .running) && isLiveRunForThisMessage

        HStack(alignment: .top, spacing: 14) {
            // Strict single X-axis column (width: 20pt, centered on x = 10pt)
            VStack(spacing: 0) {
                axisMarker(for: step, isActivelyRunning: isActivelyRunning)
                if !isLast {
                    Rectangle()
                        .fill(Self.axisLineColor)
                        .frame(width: 1)
                        .frame(minHeight: 18, maxHeight: .infinity)
                        .padding(.vertical, 5)
                }
            }
            .frame(width: 20)

            // Right content column: plain natural prose first, optional plain technical details on tap
            VStack(alignment: .leading, spacing: 6) {
                if hasTech {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            if expandedIDs.contains(step.id) {
                                expandedIDs.remove(step.id)
                            } else {
                                expandedIDs.insert(step.id)
                            }
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text(step.text)
                                .font(.system(size: 16.5, weight: isActivelyRunning ? .medium : .regular))
                                .foregroundStyle(primaryTextColor(for: step))
                                .lineSpacing(4)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Ink.ink3.opacity(0.65))
                                .padding(.top, 5)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(step.text)
                        .font(.system(size: 16.5, weight: isActivelyRunning ? .medium : .regular))
                        .foregroundStyle(primaryTextColor(for: step))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isExpanded, let tech = step.tech, !tech.isEmpty {
                    Text(tech)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(Ink.ink3)
                        .lineSpacing(3.5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 1)
                }
            }
            .padding(.bottom, isLast ? 6 : 20)
        }
    }

    private func primaryTextColor(for step: AgentTimelineStep) -> Color {
        if step.icon == .steer || step.status == .failed || step.status == .needsSignIn {
            return Ink.seal
        }
        return Ink.ink
    }

    @ViewBuilder
    private func axisMarker(for step: AgentTimelineStep, isActivelyRunning: Bool) -> some View {
        if step.kind == .dot {
            Circle()
                .fill(Self.dotColor)
                .frame(width: 6.5, height: 6.5)
                .padding(.top, 8)
        } else if step.kind == .live || isActivelyRunning {
            Circle()
                .fill(Ink.seal)
                .frame(width: 7.5, height: 7.5)
                .scaleEffect(!store.isAgentPaused && livePulse && !reduceMotion ? 0.82 : 1.0)
                .opacity(!store.isAgentPaused && livePulse && !reduceMotion ? 0.35 : 1.0)
                .padding(.top, 7.5)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                        livePulse = true
                    }
                }
        } else {
            AgentTimelineEventGlyph(kind: step.icon ?? .task)
                .foregroundStyle(primaryGlyphColor(for: step))
                .frame(width: 16, height: 16)
                .padding(.top, 3.5)
        }
    }

    private func primaryGlyphColor(for step: AgentTimelineStep) -> Color {
        if step.icon == .steer || step.status == .failed || step.status == .needsSignIn {
            return Ink.seal
        }
        return Ink.ink3
    }
}

/// Custom geometric linear event icons aligned cleanly on the 20pt vertical timeline axis.
private struct AgentTimelineEventGlyph: View {
    let kind: AgentTimelineStep.IconKind

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let stroke = StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round)

            switch kind {
            case .search:
                var circle = Path()
                circle.addEllipse(in: CGRect(x: w * 0.17, y: h * 0.17, width: w * 0.52, height: h * 0.52))
                context.stroke(circle, with: .foreground, style: stroke)
                var handle = Path()
                handle.move(to: CGPoint(x: w * 0.63, y: h * 0.63))
                handle.addLine(to: CGPoint(x: w * 0.85, y: h * 0.85))
                context.stroke(handle, with: .foreground, style: stroke)

            case .doc:
                let rect = CGRect(x: w * 0.20, y: h * 0.12, width: w * 0.60, height: h * 0.76)
                let rounded = Path(roundedRect: rect, cornerRadius: 2.0)
                context.stroke(rounded, with: .foreground, style: stroke)
                var lines = Path()
                lines.move(to: CGPoint(x: w * 0.35, y: h * 0.36))
                lines.addLine(to: CGPoint(x: w * 0.65, y: h * 0.36))
                lines.move(to: CGPoint(x: w * 0.35, y: h * 0.55))
                lines.addLine(to: CGPoint(x: w * 0.65, y: h * 0.55))
                context.stroke(lines, with: .foreground, style: stroke)

            case .task:
                var check = Path()
                check.move(to: CGPoint(x: w * 0.14, y: h * 0.29))
                check.addLine(to: CGPoint(x: w * 0.24, y: h * 0.40))
                check.addLine(to: CGPoint(x: w * 0.41, y: h * 0.19))
                context.stroke(check, with: .foreground, style: stroke)
                var bar1 = Path()
                bar1.move(to: CGPoint(x: w * 0.53, y: h * 0.30))
                bar1.addLine(to: CGPoint(x: w * 0.86, y: h * 0.30))
                context.stroke(bar1, with: .foreground, style: stroke)
                var dot = Path()
                dot.addEllipse(in: CGRect(x: w * 0.18, y: h * 0.64, width: w * 0.16, height: h * 0.16))
                context.stroke(dot, with: .foreground, style: stroke)
                var bar2 = Path()
                bar2.move(to: CGPoint(x: w * 0.53, y: h * 0.72))
                bar2.addLine(to: CGPoint(x: w * 0.86, y: h * 0.72))
                context.stroke(bar2, with: .foreground, style: stroke)

            case .steer:
                var turn = Path()
                turn.move(to: CGPoint(x: w * 0.24, y: h * 0.18))
                turn.addLine(to: CGPoint(x: w * 0.24, y: h * 0.54))
                turn.addQuadCurve(
                    to: CGPoint(x: w * 0.38, y: h * 0.66),
                    control: CGPoint(x: w * 0.24, y: h * 0.66)
                )
                turn.addLine(to: CGPoint(x: w * 0.78, y: h * 0.66))
                context.stroke(turn, with: .foreground, style: stroke)
                var arrow = Path()
                arrow.move(to: CGPoint(x: w * 0.60, y: h * 0.49))
                arrow.addLine(to: CGPoint(x: w * 0.78, y: h * 0.66))
                arrow.addLine(to: CGPoint(x: w * 0.60, y: h * 0.83))
                context.stroke(arrow, with: .foreground, style: stroke)

            case .warning:
                var tri = Path()
                tri.move(to: CGPoint(x: w * 0.50, y: h * 0.16))
                tri.addLine(to: CGPoint(x: w * 0.86, y: h * 0.82))
                tri.addLine(to: CGPoint(x: w * 0.14, y: h * 0.82))
                tri.closeSubpath()
                context.stroke(tri, with: .foreground, style: stroke)
                var mark = Path()
                mark.move(to: CGPoint(x: w * 0.50, y: h * 0.42))
                mark.addLine(to: CGPoint(x: w * 0.50, y: h * 0.60))
                context.stroke(mark, with: .foreground, style: stroke)
                let dotRect = CGRect(x: w * 0.46, y: h * 0.68, width: w * 0.08, height: h * 0.08)
                context.fill(Path(ellipseIn: dotRect), with: .foreground)
            }
        }
    }
}
