import Foundation

struct DayUsage: Codable, Equatable, Sendable {
    var tokens = 0
    var cost = 0.0
    var requests = 0
    var flashTokens = 0
    var proTokens = 0
    var colabTokens: Int?
    var colabRequests: Int?

    static func + (lhs: DayUsage, rhs: DayUsage) -> DayUsage {
        DayUsage(tokens: lhs.tokens + rhs.tokens, cost: lhs.cost + rhs.cost, requests: lhs.requests + rhs.requests,
                 flashTokens: lhs.flashTokens + rhs.flashTokens, proTokens: lhs.proTokens + rhs.proTokens,
                 colabTokens: (lhs.colabTokens ?? 0) + (rhs.colabTokens ?? 0),
                 colabRequests: (lhs.colabRequests ?? 0) + (rhs.colabRequests ?? 0))
    }
}

// Daily totals kept apart from the conversations, so deleting a chat never
// changes what was already spent. Keys are local calendar days, "yyyy-MM-dd".
struct UsageLedger: Codable, Equatable, Sendable {
    var days: [String: DayUsage] = [:]

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // Answers saved before the model was recorded count tokens but no price.
    mutating func record(_ usage: TokenUsage, model: DeepSeekModel?, at date: Date, calendar: Calendar = .current, provider: AIProvider? = nil) {
        let key = Self.key(for: date, calendar: calendar)
        var day = days[key] ?? DayUsage()
        day.tokens += usage.totalTokens
        day.requests += 1
        if provider == .colab {
            day.colabTokens = (day.colabTokens ?? 0) + usage.totalTokens
            day.colabRequests = (day.colabRequests ?? 0) + 1
        }
        if let model, provider != .colab {
            day.cost += Pricing.cost(model: model, usage: usage, at: date)
            if model == .flash { day.flashTokens += usage.totalTokens } else { day.proTokens += usage.totalTokens }
        }
        days[key] = day
    }

    // First run of this version: count what the saved conversations already used.
    static func rebuilt(from threads: [ChatThread], calendar: Calendar = .current) -> UsageLedger {
        var ledger = UsageLedger()
        for thread in threads {
            for message in thread.messages {
                if let usage = message.usage { ledger.record(usage, model: message.provider == .colab ? nil : message.model, at: message.createdAt, calendar: calendar, provider: message.provider) }
                // Search uses a separate native model; count its tokens without
                // pretending the chat model's price is its billing rate.
                if let usage = message.searchUsage { ledger.record(usage, model: nil, at: message.createdAt, calendar: calendar) }
                if let usage = message.translationUsage {
                    ledger.record(usage, model: message.translatedBy == .chatGPT || message.translatedBy == .colab ? nil : .flash, at: message.createdAt, calendar: calendar, provider: message.translatedBy)
                }
                if let batch = message.replySuggestions, let usage = batch.usage {
                    ledger.record(usage, model: batch.provider == .chatGPT || batch.provider == .colab ? nil : batch.pricedModel, at: batch.createdAt, calendar: calendar, provider: batch.provider)
                }
            }
        }
        return ledger
    }

    // An imported backup only fills days this phone has no record of, so nothing is counted twice.
    mutating func merge(missingDaysFrom other: UsageLedger) {
        for (key, value) in other.days where days[key] == nil { days[key] = value }
    }

    func day(_ date: Date, calendar: Calendar = .current) -> DayUsage {
        days[Self.key(for: date, calendar: calendar)] ?? DayUsage()
    }

    func month(containing date: Date, calendar: Calendar = .current) -> DayUsage {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let prefix = String(format: "%04d-%02d-", parts.year ?? 0, parts.month ?? 0)
        return days.filter { $0.key.hasPrefix(prefix) }.values.reduce(DayUsage(), +)
    }

    var total: DayUsage { days.values.reduce(DayUsage(), +) }

    // Consecutive days with use, ending today; a quiet today does not break yesterday's run.
    func streak(endingAt date: Date, calendar: Calendar = .current) -> Int {
        var current = date
        if day(current, calendar: calendar).tokens == 0 {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: current) else { return 0 }
            current = yesterday
        }
        var count = 0
        while day(current, calendar: calendar).tokens > 0, count < 3660 {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: current) else { break }
            current = previous
        }
        return count
    }

    var busiestDay: String? {
        days.filter { $0.value.tokens > 0 }.max { $0.value.tokens == $1.value.tokens ? $0.key > $1.key : $0.value.tokens < $1.value.tokens }?.key
    }

    var favouriteModel: DeepSeekModel? {
        let sum = total
        guard sum.flashTokens + sum.proTokens > 0 else { return nil }
        return sum.proTokens > sum.flashTokens ? .pro : .flash
    }

    // Shade 0 (unused) to 4 (busiest), relative to the busiest day on screen.
    static func level(_ tokens: Int, peak: Int) -> Int {
        guard tokens > 0, peak > 0 else { return 0 }
        let ratio = Double(tokens) / Double(peak)
        return ratio > 0.75 ? 4 : (ratio > 0.5 ? 3 : (ratio > 0.25 ? 2 : 1))
    }
}
