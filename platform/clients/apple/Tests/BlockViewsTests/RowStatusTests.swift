@testable import BlockViews
import Foundation
import XCTest

/// A list row's age, from Control's `since`, as the TUI says it, and its tone.
final class RowStatusTests: XCTestCase {
    private let now = try! Date("2026-11-26T12:00:00Z", strategy: .iso8601)

    func testTheAgeIsInWholeDaysHoursOrMinutes() {
        XCTAssertEqual(RowAge.text(since: "2026-11-11T09:00:00Z", now: now), "15d")
        XCTAssertEqual(RowAge.text(since: "2026-11-25T12:00:00Z", now: now), "1d")
        XCTAssertEqual(RowAge.text(since: "2026-11-26T05:30:00Z", now: now), "6h")
        XCTAssertEqual(RowAge.text(since: "2026-11-26T11:14:00Z", now: now), "46m")
    }

    func testUnderAMinuteIsToday() {
        XCTAssertEqual(RowAge.text(since: "2026-11-26T11:59:30Z", now: now), "today")
        // A time ahead of the clock is no time at all ago.
        XCTAssertEqual(RowAge.text(since: "2026-11-26T12:05:00Z", now: now), "today")
    }

    func testFractionsOfASecondAndOffsetsAreRead() {
        XCTAssertEqual(RowAge.text(since: "2026-11-26T05:30:00.123456Z", now: now), "6h")
        XCTAssertEqual(RowAge.text(since: "2026-11-26T08:00:00+02:00", now: now), "6h")
    }

    func testNoOrAnUnreadableTimeHasNoAge() {
        XCTAssertNil(RowAge.text(since: nil, now: now))
        XCTAssertNil(RowAge.text(since: "", now: now))
        XCTAssertNil(RowAge.text(since: "yesterday", now: now))
    }

    func testOnlyTheFourTonesAreKnown() {
        XCTAssertEqual(RowTone("attention"), .attention)
        XCTAssertEqual(RowTone("done"), .done)
        XCTAssertNil(RowTone("urgent"))
        XCTAssertNil(RowTone(nil))
    }
}
