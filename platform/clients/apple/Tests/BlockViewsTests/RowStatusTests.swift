import AtlasControlKit
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

/// What a list row's card says on its top line, and how long its title may be.
final class RowCardTextTests: XCTestCase {
    func testTheTopLineNamesTheKindInCapitalsThenTheKey() {
        XCTAssertEqual(RowCardText.kindAndKey(kind: "Decision", id: "D-0104"), "DECISION · D-0104")
        XCTAssertEqual(RowCardText.kindAndKey(kind: "To-Do", id: "TD-09"), "TO-DO · TD-09")
        // An older Control sends no kind: the key alone; neither: nothing.
        XCTAssertEqual(RowCardText.kindAndKey(kind: nil, id: "D-0104"), "D-0104")
        XCTAssertEqual(RowCardText.kindAndKey(kind: "Decision", id: nil), "DECISION")
        XCTAssertNil(RowCardText.kindAndKey(kind: nil, id: nil))
    }

    func testTheTopLineLeadsWithTheKindsIconNeverADot() {
        let decision = RowModel(id: "D-1", label: "Pick", tone: "attention", kind: "Decision", icon: "scales")
        XCTAssertEqual(RowCardText.top(decision), .init(symbol: SidebarLook.symbol("scales"), text: "DECISION · D-1"))
        XCTAssertNotNil(RowCardText.top(decision).symbol)
        XCTAssertNotEqual(RowCardText.top(RowModel(id: "TD-1", kind: "To-Do", icon: "checklist")).symbol,
                          RowCardText.top(decision).symbol)

        // Where it stands is not on it: every tone, or none, gives the same top line.
        for tone in ["attention", "active", "waiting", "done", nil] {
            var row = decision
            row.tone = tone
            XCTAssertEqual(RowCardText.top(row), RowCardText.top(decision))
        }

        // An icon this app does not know, or none: no symbol, the words unchanged.
        XCTAssertEqual(RowCardText.top(RowModel(id: "X-1", kind: "Odd", icon: "nonsense")),
                       .init(symbol: nil, text: "ODD · X-1"))
        XCTAssertNil(RowCardText.top(RowModel(id: "X-1")).symbol)
    }

    func testAStateIsShownOnlyWhenControlSendsOne() {
        XCTAssertEqual(RowCardText.state("waiting for you"), "waiting for you")
        // A list whose rows all share it: Control sends none, and the card says none.
        XCTAssertNil(RowCardText.state(nil))
        XCTAssertNil(RowCardText.state(""))
    }

    func testATitleTakesUpToTwoLines() {
        XCTAssertEqual(RowCardText.titleLines, 2)
    }
}
