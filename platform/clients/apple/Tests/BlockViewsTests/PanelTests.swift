import AtlasControlKit
@testable import BlockViews
import Foundation
import XCTest

/// A `panel` block as Control sends it where its owner decides (`AtlasControl.Pages`,
/// `panel_block/7`): to accept (items, a yes and a no), to merge (checks, actions, links)
/// and stuck work (a box, the answers as a choice). An answer is the page's action of its
/// key: a yes submits its call, a no opens the form that asks its note.
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

    /// Stuck: what went wrong, and a choice whose recommended answer is not the first.
    private static let stuck: [String: Any] = ["id": "panel", "type": "panel", "props": [
        "heading": "YOUR DECISION", "title": "IS-1 is stuck: what now?", "choose": true,
        "box": ["title": "What went wrong", "text": "The build failed.", "tone": "error"],
        "answers": [
            ["label": "Close it", "key": "c", "to": "/k/widget/IS-1/answer/c", "note": true, "detail": "Ends it."],
            ["label": "Retry", "key": "r", "to": "/k/widget/IS-1/answer/r", "submit_to": call("retry"),
             "recommended": true, "detail": "Builds it again."],
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
    private static let retryCall = CallModel(endpoint: "answer", params: ["kind": "widget", "key": "IS-1", "answer": "retry"])

    func testTheArrowsMoveTheItemSelectionAndReturnOpensTheSelectedItem() throws {
        var panel = Panel(try Self.panel(Self.accept))

        XCTAssertFalse(panel.choosing)
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
        // Without a choice no answer is selected: Return never answers.
        XCTAssertNil(panel.selectedAnswer)
    }

    func testAClickSelectsAnItemAndAClickOnTheSelectedOneOpensIt() throws {
        var panel = Panel(try Self.panel(Self.accept))
        let third = panel.items[2]

        XCTAssertEqual(panel.click(item: third), .nothing)
        XCTAssertEqual(panel.selectedItem, third)
        XCTAssertEqual(panel.click(item: third), .open("/k/widget/IS-3"))
    }

    func testAYesSubmitsItsCallAndANoOpensItsNoteFormInstead() throws {
        var panel = Panel(try Self.panel(Self.accept))

        guard case .act(let yes) = panel.answer(panel.answers[0]) else { return XCTFail("not an action") }
        XCTAssertEqual(yes.submitTo, Self.acceptCall)
        guard case .act(let no) = panel.answer(panel.answers[1]) else { return XCTFail("not an action") }
        XCTAssertNil(no.submitTo)
        XCTAssertEqual(no.to, "/k/gadget/UC-1/answer/n")
        XCTAssertTrue(PageActions.doable(no))
    }

    func testTheKeysAnswerAsThePanelSaysAndThePanelsAnswersAreNotInTheHeaderTwice() throws {
        let page = try Self.page([Self.accept, Self.itemBlock])
        let typing = TypingFocus()

        XCTAssertEqual(PageActions.action(key: "a", on: [page], typing: typing)?.submitTo, Self.acceptCall)
        let no = try XCTUnwrap(PageActions.action(key: "n", on: [page], typing: typing))
        XCTAssertNil(no.submitTo)
        XCTAssertEqual(no.to, "/k/gadget/UC-1/answer/n")
        XCTAssertEqual(PageActions.action(key: "i", on: [page], typing: typing)?.to, "/k/inspection/IN-2")
        XCTAssertEqual(PageActions.ofPage(page).map(\.key), ["m"])
        XCTAssertEqual(PageActions.label(of: Self.acceptCall, on: [page]), "Accept")

        // Its links open in the browser by their keys; only http and https ones.
        XCTAssertEqual(PageActions.link(key: "o", on: [page]), URL(string: "https://github.com/mimbre/atlas/pull/605"))
        XCTAssertNil(PageActions.link(key: "e", on: [page]))
        XCTAssertNil(PageActions.link(key: "a", on: [page]))
    }

    func testAChoiceStartsOnTheRecommendedAnswerAndReturnAnswersTheSelectedOne() throws {
        var panel = Panel(try Self.panel(Self.stuck))

        XCTAssertTrue(panel.choosing)
        XCTAssertNil(panel.selectedItem)
        XCTAssertEqual(panel.selectedAnswer?.label, "Retry")
        XCTAssertEqual(panel.selectedAnswer?.detail, "Builds it again.")
        guard case .act(let retry)? = panel.press(.enter) else { return XCTFail("Return answered nothing") }
        XCTAssertEqual(retry.submitTo, Self.retryCall)

        XCTAssertEqual(panel.press(.up), .nothing)
        XCTAssertEqual(panel.selectedAnswer?.label, "Close it")
        // A no: Return opens its note form, it does not submit.
        guard case .act(let close)? = panel.press(.enter) else { return XCTFail("Return answered nothing") }
        XCTAssertNil(close.submitTo)
        XCTAssertEqual(close.to, "/k/widget/IS-1/answer/c")
    }

    func testTheSelectionStaysOnTheSameAnswerWhenControlSendsThePanelAgain() throws {
        var panel = Panel(try Self.panel(Self.stuck))
        _ = panel.press(.up)
        var block = panel.block
        block.answers?.reverse()

        panel.update(block)
        XCTAssertEqual(panel.selectedAnswer?.label, "Close it")
        XCTAssertEqual(panel.selected, 1)
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
}
