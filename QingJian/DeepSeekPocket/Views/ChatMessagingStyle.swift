import Observation
import SwiftUI
import UIKit

// 1.47: one layout (your bubble on the right, the answer as open text); the 信息气泡 and
// 智能 layouts and their bubble rules were removed.

@MainActor
struct QuotedReplyCard: View {
    let quote: QuotedMessage
    let alignTrailing: Bool

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.25, style: .continuous)
                .fill(Ink.seal.opacity(0.8))
                .frame(width: 2.5)
            VStack(alignment: .leading, spacing: 2) {
                Text("回复 \(quote.author)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.seal)
                    .lineLimit(1)
                Text(quote.excerpt)
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.ink3)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Ink.raised.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Ink.line.opacity(0.55), lineWidth: 0.6)
        )
        .frame(maxWidth: 265, alignment: alignTrailing ? .trailing : .leading)
    }
}

enum MessageTimeDivider {
    private static let todayFormatter: DateFormatter = make("'今天' HH:mm")
    private static let yesterdayFormatter: DateFormatter = make("'昨天' HH:mm")
    private static let sameYearFormatter: DateFormatter = make("M月d日 HH:mm")
    private static let otherYearFormatter: DateFormatter = make("yyyy年M月d日 HH:mm")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter
    }

    static func shouldShow(previous: ChatMessage?, current: ChatMessage) -> Bool {
        guard current.directive == nil else { return false }
        guard let previous else { return false }
        let gap = current.createdAt.timeIntervalSince(previous.createdAt)
        return gap >= 1800 || !Calendar.current.isDate(previous.createdAt, inSameDayAs: current.createdAt)
    }

    static func label(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return todayFormatter.string(from: date) }
        if calendar.isDateInYesterday(date) { return yesterdayFormatter.string(from: date) }
        return (calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? sameYearFormatter : otherYearFormatter)
            .string(from: date)
    }
}
