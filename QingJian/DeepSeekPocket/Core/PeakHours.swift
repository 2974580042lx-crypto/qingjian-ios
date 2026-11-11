import Foundation

// DeepSeek's prices change with the hour (see Pricing.isPeak). These say which band
// it is now and when it ends, for the bookshelf, the sidebar and the model menu (1.10.0).
extension Pricing {
    private static var beijing: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar
    }

    /// The start of the first hour after `date` that falls in the other band.
    static func nextChange(after date: Date) -> Date? {
        let calendar = beijing
        let now = isPeak(date)
        guard var hour = calendar.dateInterval(of: .hour, for: date)?.start else { return nil }
        for _ in 0..<(24 * 8) {
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { return nil }
            hour = next
            if isPeak(hour) != now { return hour }
        }
        return nil
    }

    /// "（高峰）" or "（空闲）" after a price, for the hour the request was made.
    static func bandTag(_ date: Date) -> String { isPeak(date) ? "（高峰）" : "（空闲）" }

    /// "高峰时段 · 到 12:00 结束" or "空闲时段 · 半价，到 周一 09:00".
    static func statusLabel(at date: Date = Date()) -> String {
        let peak = isPeak(date)
        guard let change = nextChange(after: date) else { return peak ? "高峰时段" : "空闲时段 · 半价" }
        let calendar = beijing
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(change, inSameDayAs: date) ? "HH:mm" : "EEE HH:mm"
        let time = formatter.string(from: change)
        return peak ? "高峰时段 · 到 \(time) 结束" : "空闲时段 · 半价，到 \(time)"
    }
}
