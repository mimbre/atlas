import AppKit
import AtlasControlKit
@testable import BlockViews
import Prism
import SwiftUI
import XCTest

/// An answer's button by the weight Control gives it (`AnswerLook`), whether or not it
/// asks a note, its label what Control says a button shows (never "…"); an action's icon
/// by the name Control gives it (`ActionIcon`).
final class AnswerLookTests: XCTestCase {
    private func answer(_ label: String, weight: String?, note: Bool? = nil, button: String? = nil) -> PanelAnswerModel {
        PanelAnswerModel(label: label, key: "x", to: "/k/chore/TD-1/answer/x", note: note, weight: weight, button: button)
    }
    func testPrimaryAnswersPrecedeOthersWithoutChangingTheirRelativeOrder() {
        let answers = [answer("Ask", weight: "other"), answer("Done", weight: "main"),
                       answer("Decline", weight: "decline"), answer("Accept", weight: "main")]
        XCTAssertEqual(AnswerLook.ordered(answers).map(\.label), ["Done", "Accept", "Ask", "Decline"])
        XCTAssertEqual(AnswerLook.ordered([answers[0]]).map(\.label), ["Ask"])
    }

    @MainActor
    func testAnswerButtonsRenderWithAndWithoutPrimary() throws {
        let main = answer("Done", weight: "main")
        let other = answer("Ask", weight: "other")
        for answers in [[other, main], [other]] {
            let host = NSHostingView(rootView: HStack {
                ForEach(Array(AnswerLook.ordered(answers).enumerated()), id: \.offset) { _, answer in
                    AnswerButton(answer: answer, pending: false, take: {})
                }
            }.padding())
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        }
    }


    func testTheWeightNotTheNoteChoosesThePrismVariantAllInThePrimaryColour() {
        for note in [nil, true] {
            let main = AnswerLook.of(answer("Done", weight: "main", note: note))
            XCTAssertEqual(main.variant, .primary)
            XCTAssertEqual(main.tone, .accent)

            for weight in ["decline", "no"] {
                let decline = AnswerLook.of(answer("Won't do", weight: weight, note: note))
                XCTAssertEqual(decline.variant, .secondary, "\(weight); no is deprecated, the same")
                XCTAssertEqual(decline.tone, .accent)
            }

            XCTAssertEqual(AnswerLook.of(answer("Update", weight: "other", note: note)).variant, .plain)
        }
        XCTAssertEqual(AnswerLook.of(answer("Retry", weight: nil)).variant, .plain, "no weight: other")
    }

    /// Melle: one proposal's Decline is `secondary` next to Accept; Decline all under several
    /// alternatives (icon `decline`) a quiet `plain` button with a blue xmark.circle.
    func testDeclineAllIsAQuietPlainButtonWithItsIconAndOneProposalsDeclineStaysSecondary() {
        let decline = AnswerLook.of(answer("Decline", weight: "decline", note: true))
        XCTAssertEqual(decline.variant, .secondary)
        let all = PanelAnswerModel(label: "Decline all", key: "3", to: "/k/decision/D-7/answer/3", note: true,
                                   weight: "decline", icon: "decline")
        XCTAssertEqual(AnswerLook.of(all).variant, .plain)
        XCTAssertEqual(AnswerLook.of(all).tone, .accent)
        XCTAssertEqual(ActionIcon.symbol(all.icon), "xmark.circle")
    }

    func testAButtonSaysNothingOfWhatFollowsItsClick() {
        XCTAssertEqual(AnswerLook.label(answer("Done", weight: "main", note: true)), "Done")
        XCTAssertEqual(AnswerLook.label(answer("Won't do", weight: "decline", note: true)), "Won't do")
        XCTAssertEqual(AnswerLook.label(answer("Decline", weight: "decline", note: true)), "Decline")
        XCTAssertEqual(AnswerLook.label(answer("Accept", weight: "main")), "Accept")
        XCTAssertEqual(AnswerLook.label(answer("Retry…", weight: "other", button: "Retry")), "Retry", "Control's button")
        XCTAssertEqual(AnswerLook.label(ActionModel(label: "Hand to…", key: "h", to: "/k/x/X-1/links/o", button: "Hand to")),
                       "Hand to")
        XCTAssertEqual(AnswerLook.label(ActionModel(label: "Update to-do", key: "u", to: "/k/x/X-1/edit")), "Update to-do")
    }

    func testAnActionsIconNameMapsToItsSymbolAndAnUnknownOrMissingOneToNone() throws {
        XCTAssertEqual(ActionIcon.symbol("edit"), "pencil")
        XCTAssertEqual(ActionIcon.symbol("delete"), "trash")
        XCTAssertEqual(ActionIcon.symbol("remove"), "trash")
        XCTAssertEqual(ActionIcon.symbol("hand_over"), "person.and.arrow.left.and.arrow.right")
        XCTAssertEqual(ActionIcon.symbol("question"), "questionmark.bubble")
        XCTAssertEqual(ActionIcon.symbol("delegate"), "arrow.uturn.backward")
        XCTAssertEqual(ActionIcon.symbol("decline"), "xmark.circle")
        XCTAssertEqual(ActionIcon.symbol("create"), "plus")
        XCTAssertEqual(ActionIcon.symbol("open"), "arrow.up.right.square")
        XCTAssertEqual(ActionIcon.symbol("faults"), "exclamationmark.triangle")
        XCTAssertNil(ActionIcon.symbol("launch_rockets"))
        XCTAssertNil(ActionIcon.symbol(nil))

        // Every symbol is one the system has: one it lacks would show no icon at all.
        for name in ["edit", "delete", "remove", "hand_over", "question", "delegate", "decline", "create", "open", "faults"] {
            let symbol = try XCTUnwrap(ActionIcon.symbol(name))
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    /// Melle: every button and toolbar item's tooltip says what it does in full: Control's
    /// `help`, else its label (not its short button text).
    func testATooltipIsControlsHelpElseTheLabel() throws {
        let ask = PanelAnswerModel(label: "Ask", key: "q", to: "/k/decision/D-7/answer/q", note: true,
                                   weight: "other", icon: "question", help: "Ask the proposer a question")
        XCTAssertEqual(AnswerLook.tooltip(ask), "Ask the proposer a question")
        XCTAssertEqual(AnswerLook.tooltip(answer("Choose", weight: "main")), "Choose")
        XCTAssertEqual(AnswerLook.tooltip(PanelAnswerModel(label: "Accept", help: " ")), "Accept", "a blank help is none")

        let update = ActionModel(label: "Update decision", key: "u", to: "/k/decision/D-7/edit", icon: "edit",
                                 button: "Update")
        XCTAssertEqual(PageActions.tooltip(update), "Update decision")
        let delete = ActionModel(label: "Delete decision", key: "d", to: "/k/decision/D-7/delete", icon: "delete",
                                 help: "Delete D-7 for good")
        XCTAssertEqual(PageActions.tooltip(delete), "Delete D-7 for good")

        // An answer in the toolbar keeps its help.
        let object: [String: Any] = [
            "op": "page", "reason": "open", "path": "/k/decision/D-7", "title": "D-7", "at": "12:00:00", "position": 1,
            "blocks": [["id": "answers", "type": "answers", "props": ["answers": [
                ["label": "Ask", "key": "q", "to": "/k/decision/D-7/answer/q", "note": true, "weight": "other",
                 "icon": "question", "help": "Ask the proposer a question"],
            ]]]],
        ]
        let line = try JSONSerialization.data(withJSONObject: object)
        guard case .pageOpen(let page) = try WireLine.decode(ControlMessage.self, from: line) else {
            return XCTFail("not a page")
        }
        XCTAssertEqual(PageActions.toolbar(page).map(PageActions.tooltip), ["Ask the proposer a question"])
    }

    /// Melle: a list's own actions (Create to-do) are in the list column's toolbar, above
    /// the list, as a quiet `+` alone, its tooltip Control's help, else its label; its other
    /// actions (a row's) are not.
    func testTheListsCreateIsAQuietPlusInItsToolbar() throws {
        let object: [String: Any] = [
            "op": "page", "reason": "open", "path": "/k/todo", "title": "To-dos", "at": "12:00:00", "position": 1,
            "blocks": [["id": "list", "type": "list", "props": [
                "rows": [["id": "TD-1", "key": "TD-1", "label": "One", "to": "/k/todo/TD-1"]],
                "actions": [
                    ["label": "Create to-do", "key": "c", "to": "/k/todo/new", "icon": "create", "page": true],
                    ["label": "Export", "key": "x", "to": "/k/todo/export"],
                ],
            ]]],
        ]
        let line = try JSONSerialization.data(withJSONObject: object)
        guard case .pageOpen(let page) = try WireLine.decode(ControlMessage.self, from: line) else {
            return XCTFail("not a page")
        }
        let toolbar = PageActions.listToolbar(page)
        XCTAssertEqual(toolbar.map(\.key), ["c"])
        XCTAssertEqual(toolbar.map { ActionIcon.symbol($0.icon) }, ["plus"])
        XCTAssertEqual(toolbar.map(PageActions.tooltip), ["Create to-do"])
        XCTAssertTrue(PageActions.listToolbar(nil).isEmpty)
    }
}
