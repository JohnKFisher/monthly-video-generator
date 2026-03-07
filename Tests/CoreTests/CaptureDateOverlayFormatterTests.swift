@testable import Core
import Foundation
import XCTest

final class CaptureDateOverlayFormatterTests: XCTestCase {
    func testFormatterUsesExactRequestedPatternInCurrentTimezoneStyle() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    timeZone: timeZone,
                    year: 2023,
                    month: 6,
                    day: 14,
                    hour: 14,
                    minute: 33
                )
            )
        )

        XCTAssertEqual(
            CaptureDateOverlayFormatter.string(from: date, timeZone: timeZone),
            "June 14, 2023 2:33 PM"
        )
    }
}
