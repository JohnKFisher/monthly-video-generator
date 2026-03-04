import Core
import Foundation
import XCTest

final class MonthYearBoundaryTests: XCTestCase {
    func testDateIntervalIsStartInclusiveEndExclusive() {
        let monthYear = MonthYear(month: 2, year: 2026)
        let tz = TimeZone(identifier: "America/New_York")!
        let interval = monthYear.dateInterval(in: tz)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz

        let expectedStart = calendar.date(from: DateComponents(year: 2026, month: 2, day: 1))!
        let expectedEnd = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!

        XCTAssertEqual(interval.start, expectedStart)
        XCTAssertEqual(interval.end, expectedEnd)
        XCTAssertTrue(interval.contains(expectedStart))
        XCTAssertFalse(expectedEnd < interval.end)
    }
}
