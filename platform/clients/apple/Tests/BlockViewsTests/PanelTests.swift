import AtlasControlKit
@testable import BlockViews
import Foundation
import XCTest

/// A `panel` block as Control sends it where its owner decides (`AtlasControl.Pages`,
/// `panel_block/7`): to accept (items, a yes and a no) and to merge (checks, actions,
/// links). An answer is the page's action of its key: a yes submits its call, a no opens
/// the form that asks its note.
@MainActor
final class PanelTests: XCTestCase {
    private static func call(_ answer: String) -> [String: Any] {
        ["endpoint": "answer", "params": ["kind": "widget", "key": "IS-1", "answer": answer]]
    }

    private static func item(_ key: String, _ label: String) -> [String: Any] {
        ["key": key, "label": label, "to": "/k/widget/\(key)",
         "details": [["label": "What", "value": "\(label)."], ["label": "Done", "value": "—"]]]
    }

    /// To accept: three items, Accept at once, Not accepted with a note; the page's item
    /// carries the same answers as the page's actions, and one more.
    private static let accept: [String: Any] = ["id": "panel", "type": "panel", "props": [
        "heading": "TO ACCEPT", "title": "Plan for UC-1", "aside": "3 widgets",
        "byline": [["text": "Proposed by IN-2"], ["text": "", "since": "2026-11-26T09:00:00Z"]],
        "items": [item("IS-1", "One"), item("IS-2", "Two"), item("IS-3", "Three")],
        "answers": [
            ["label": "Accept", "key": "a", "to": "/k/gadget/UC-1/answer/a", "submit_to": call("accept")],
            ["label": "Not accepted", "key": "n", "to": "/k/gadget/UC-1/answer/n", "note": true],
        ],
        "actions": [["label": "Full proposal", "key": "i", "to": "/k/inspection/IN-2"]],
        "links": [["label": "Open on GitHub", "key": "o", "url": "https://github.com/mimbre/atlas/pull/605"],
                  ["label": "Elsewhere", "key": "e", "url": "file:///etc/passwd"]],
    ]]

    private static let itemBlock: [String: Any] = ["id": "item", "type": "item", "props": [
        "title": "Gadget UC-1", "fields": [],
        "actions": [
            ["label": "Accept", "key": "a", "to": "/k/gadget/UC-1/answer/a", "submit_to": call("accept"), "page": true],
            ["label": "Not accepted", "key": "n", "to": "/k/gadget/UC-1/answer/n", "page": true],
            ["label": "More…", "key": "m", "to": "/k/gadget/UC-1/more", "page": true],
        ],
    ]]

    private static func page(_ blocks: [[String: Any]]) throws -> PageMessage {
        let object: [String: Any] = ["op": "page", "reason": "open", "path": "/k/gadget/UC-1", "title": "Page",
                                     "at": "12:00:00", "position": 1, "blocks": blocks, "markup": []]
        let line = try JSONSerialization.data(withJSONObject: object)
        guard case .pageOpen(let page) = try WireLine.decode(ControlMessage.self, from: line) else {
            return try XCTUnwrap(nil, "not a page")
        }
        return page
    }

    private static func panel(_ block: [String: Any]) throws -> PanelBlock {
        let page = try page([block])
        guard case .panel(let panel)? = PagePresentation(page).entries.first?.item else {
            return try XCTUnwrap(nil, "not shown as a panel: \(PagePresentation(page).entries)")
        }
        return panel
    }

    private static let acceptCall = CallModel(endpoint: "answer", params: ["kind": "widget", "key": "IS-1", "answer": "accept"])

    func testTheArrowsMoveTheItemSelectionAndReturnOpensTheSelectedItem() throws {
        var panel = Panel(try Self.panel(Self.accept))

        XCTAssertEqual(panel.selectedItem?.key, "IS-1")
        XCTAssertEqual(panel.selectedItem?.details?.first?.value, "One.")
        XCTAssertEqual(panel.press(.up), .nothing)
        XCTAssertEqual(panel.selectedItem?.key, "IS-1")
        _ = panel.press(.down)
        _ = panel.press(.down)
        XCTAssertEqual(panel.press(.down), .nothing)
        XCTAssertEqual(panel.selectedItem?.key, "IS-3")
        _ = panel.press(.up)
        XCTAssertEqual(panel.selectedItem?.details?.first?.value, "Two.")
        XCTAssertEqual(panel.press(.enter), .open("/k/widget/IS-2"))
    }

    func testAClickSelectsAnItemAndAClickOnTheSelectedOneOpensIt() throws {
        var panel = Panel(try Self.panel(Self.accept))
        let third = panel.items[2]

        XCTAssertEqual(panel.click(item: third), .nothing)
        XCTAssertEqual(panel.selectedItem, third)
        XCTAssertEqual(panel.click(item: third), .open("/k/widget/IS-3"))
    }

    func testAYesSubmitsItsCallAndANoOpensItsNoteFormInstead() throws {
        let panel = Panel(try Self.panel(Self.accept))

        guard case .act(let yes) = panel.answer(panel.answers[0]) else { return XCTFail("not an action") }
        XCTAssertEqual(yes.submitTo, Self.acceptCall)
        guard case .act(let no) = panel.answer(panel.answers[1]) else { return XCTFail("not an action") }
        XCTAssertNil(no.submitTo)
        XCTAssertEqual(no.to, "/k/gadget/UC-1/answer/n")
        XCTAssertTrue(PageActions.doable(no))
    }

    func testTheKeysAnswerAsThePanelSaysAndThePanelsAnswersAreNotInTheHeaderTwice() throws {
        let page = try Self.page([Self.accept, Self.itemBlock])

        XCTAssertEqual(PageActions.action(key: "a", on: [page])?.submitTo, Self.acceptCall)
        let no = try XCTUnwrap(PageActions.action(key: "n", on: [page]))
        XCTAssertNil(no.submitTo)
        XCTAssertEqual(no.to, "/k/gadget/UC-1/answer/n")
        XCTAssertEqual(PageActions.action(key: "i", on: [page])?.to, "/k/inspection/IN-2")
        XCTAssertEqual(PageActions.ofPage(page).map(\.key), ["m"])
        XCTAssertEqual(PageActions.label(of: Self.acceptCall, on: [page]), "Accept")

        // Its links open in the browser by their keys; only http and https ones.
        XCTAssertEqual(PageActions.link(key: "o", on: [page]), URL(string: "https://github.com/mimbre/atlas/pull/605"))
        XCTAssertNil(PageActions.link(key: "e", on: [page]))
        XCTAssertNil(PageActions.link(key: "a", on: [page]))
    }

    func testTheBylineSaysHowLongAgoAfterItsTextOrAlone() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-26T12:05:00Z"))
        let byline = [ClauseModel(text: "W-1"), ClauseModel(text: "waiting", since: "2026-11-26T09:00:00Z"),
                      ClauseModel(text: "", since: "2026-11-26T12:00:00Z"), ClauseModel(text: "", since: "not a time")]

        XCTAssertEqual(Panel.byline(byline, now: now), "W-1 · waiting 3h · 5m")
        XCTAssertEqual(Panel.age(since: "2026-11-24T12:00:00Z", now: now), "2d")
        XCTAssertEqual(Panel.age(since: "2026-11-26T12:04:30.5Z", now: now), "now")
    }

    func testEachCheckStateHasItsGlyph() {
        XCTAssertEqual(["success", "error", "pending", "none", "other"].map(Panel.glyph), ["✓", "✗", "…", "—", "—"])
    }

    func testThePanelOnScreenTakesTheKeysUntilItIsGone() {
        let keys = PanelKeys()
        var taken: [String] = []
        XCTAssertFalse(keys.press(.down, isRepeat: false))
        keys.claim("a") { key, _ in taken.append("a\(key)"); return true }
        keys.claim("b") { key, _ in taken.append("b\(key)"); return true }
        keys.focusPanel()
        XCTAssertTrue(keys.press(.down, isRepeat: false))
        keys.release("b")
        XCTAssertTrue(keys.press(.up, isRepeat: false))
        XCTAssertEqual(taken, ["bdown", "aup"])
        keys.release("a")
        XCTAssertEqual(keys.focus, .list, "without a panel the list has the focus")
    }

    func testTheArrowsGoToTheFocusedColumnAndRightAndLeftMoveTheFocus() {
        let keys = PanelKeys()
        var taken: [PanelKey] = []
        var moves: [KeyColumn] = []
        keys.moved = { moves.append($0) }
        XCTAssertFalse(keys.press(column: .panel, isRepeat: false), "→ without a panel is the list's")

        // A page with a panel opens from a move in the list: the list keeps the arrows.
        keys.claim("panel") { key, _ in taken.append(key); return true }
        XCTAssertEqual(keys.focus, .list)
        XCTAssertFalse(keys.press(.down, isRepeat: false))
        XCTAssertFalse(keys.press(.enter, isRepeat: false))
        XCTAssertFalse(keys.press(column: .list, isRepeat: false), "← in the list is the list's")

        // → gives the panel the focus, once also when held; then the arrows are the panel's.
        XCTAssertTrue(keys.press(column: .panel, isRepeat: false))
        XCTAssertFalse(keys.press(column: .panel, isRepeat: true), "held, → moves it no further")
        XCTAssertEqual(keys.focus, .panel)
        XCTAssertTrue(keys.press(.down, isRepeat: false))
        XCTAssertTrue(keys.press(.up, isRepeat: true))

        // ← gives it back to the list.
        XCTAssertTrue(keys.press(column: .list, isRepeat: false))
        XCTAssertFalse(keys.press(.down, isRepeat: false))
        XCTAssertEqual(taken, [.down, .up])

        // A click in the panel gives it the focus; its page re-claiming keeps it; the next
        // row's page (another panel) leaves it to the list.
        keys.focusPanel()
        keys.claim("panel") { key, _ in taken.append(key); return true }
        XCTAssertEqual(keys.focus, .panel)
        keys.claim("next") { _, _ in true }
        XCTAssertEqual(keys.focus, .list)
        XCTAssertEqual(moves, [.panel, .list, .panel, .list])
    }

    func testLeftAndRightComeFromTheirKeyCodes() {
        XCTAssertEqual(KeyColumn(keyCode: 123), .list)
        XCTAssertEqual(KeyColumn(keyCode: 124), .panel)
        XCTAssertNil(KeyColumn(keyCode: 126))
    }
}
