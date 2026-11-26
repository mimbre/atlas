import AtlasControlKit
@testable import BlockViews
import Prism
import XCTest

/// An answer's button by the weight Control gives it (`AnswerLook`), whether or not it
/// asks a note, and "…" after the label of one that opens a note form; an action's icon by
/// the name Control gives it (`ActionIcon`).
final class AnswerLookTests: XCTestCase {
    private func answer(_ label: String, weight: String?, note: Bool? = nil) -> PanelAnswerModel {
        PanelAnswerModel(label: label, key: "x", to: "/k/chore/TD-1/answer/x", note: note, weight: weight)
    }

    func testTheWeightNotTheNoteChoosesThePrismVariantAllInThePrimaryColour() {
        for note in [nil, true] {
            let main = AnswerLook.of(answer("Done", weight: "main", note: note))
            XCTAssertEqual(main.variant, .primary)
            XCTAssertEqual(main.tone, .accent)

            let no = AnswerLook.of(answer("Won't do", weight: "no", note: note))
            XCTAssertEqual(no.variant, .secondary)
            XCTAssertEqual(no.tone, .accent)

            XCTAssertEqual(AnswerLook.of(answer("Update", weight: "other", note: note)).variant, .plain)
        }
        XCTAssertEqual(AnswerLook.of(answer("Retry", weight: nil)).variant, .plain, "no weight: other")
    }

    func testAnAnswerThatOpensANoteFormEndsWithAnEllipsis() {
        XCTAssertEqual(AnswerLook.label(answer("Done", weight: "main", note: true)), "Done…")
        XCTAssertEqual(AnswerLook.label(answer("Won't do", weight: "no", note: true)), "Won't do…")
        XCTAssertEqual(AnswerLook.label(answer("Decline", weight: "no", note: true)), "Decline…")
        XCTAssertEqual(AnswerLook.label(answer("Accept", weight: "main")), "Accept")
        XCTAssertEqual(AnswerLook.label(answer("Decline…", weight: "no", note: true)), "Decline…", "never twice")
    }

    func testAnActionsIconNameMapsToItsSymbolAndAnUnknownOrMissingOneToNone() {
        XCTAssertEqual(ActionIcon.symbol("edit"), "pencil")
        XCTAssertEqual(ActionIcon.symbol("delete"), "trash")
        XCTAssertEqual(ActionIcon.symbol("hand_over"), "person.crop.circle.badge.arrow.right")
        XCTAssertEqual(ActionIcon.symbol("create"), "plus")
        XCTAssertEqual(ActionIcon.symbol("open"), "arrow.up.right.square")
        XCTAssertNil(ActionIcon.symbol("launch_rockets"))
        XCTAssertNil(ActionIcon.symbol(nil))
    }
}
