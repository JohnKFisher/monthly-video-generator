import Foundation

public struct MonthYear: Equatable, Hashable, Codable, Sendable {
    public let month: Int
    public let year: Int

    public init(month: Int, year: Int) {
        self.month = min(max(month, 1), 12)
        self.year = year
    }

    public var displayLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: startDate(in: .current))
    }

    public func dateInterval(in timeZone: TimeZone) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let startComponents = DateComponents(year: year, month: month, day: 1)
        let start = calendar.date(from: startComponents) ?? Date.distantPast
        let end = calendar.date(byAdding: DateComponents(month: 1), to: start) ?? Date.distantFuture
        return DateInterval(start: start, end: end)
    }

    public func startDate(in timeZone: TimeZone) -> Date {
        dateInterval(in: timeZone).start
    }
}
