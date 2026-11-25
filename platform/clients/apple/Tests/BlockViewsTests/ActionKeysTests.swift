import AtlasControlKit
@testable import BlockViews
import ControlSession
import Foundation
import XCTest

/// What a page's action keys and buttons do (IS-Atlas-107): an `agent:<intent>` action has
/// its button and its key; a focused `single_choice` takes its own digits first, so one of
/// more than nine options can be typed, and a page action keeps its key where nothing is
/// typing; the button of the action taken shows that it is pending.
@MainActor
final class ActionKeysTests: XCTestCase {
    static let overrule = ActionModel(label: "Overrule", key: "x", to: "agent:overrule")
    static let pickUp = ActionModel(label: "Pick up", key: "1", to: "/k/widget/W-01/pick_up/r1")

    private static func page(_ path: String, blocks: [[String: Any]]) throws -> PageMessage {
        let object: [String: Any] = ["op": "page", "reason": "open", "path": path, "title": "Page", "at": "12:00:00",
                                     "position": 1, "blocks": blocks, "markup": []]
        let line = try JSONSerialization.data(withJSONObject: object)
        guard case .pageOpen(let page) = try WireLine.decode(ControlMessage.self, from: line) else {
            return try XCTUnwrap(nil, "not a page")
        }
        return page
    }

    private static func item(_ actions: [ActionModel]) -> [String: Any] {
        ["id": "item", "type": "item", "props": [
            "title": "Step W-01", "fields": [],
            "actions": actions.map { ["label": $0.label, "key": $0.key, "to": $0.to] },
        ]]
    }

    private static func answer(_ n: Int) -> [String: Any] {
        ["endpoint": "answer", "params": ["kind": "decision", "key": "D-12", "answer": "option-\(n)"]]
    }

    /// A decision with twelve options, numbered 1 to 12 by their place.
    private static let choice: [String: Any] = ["id": "choice", "type": "single_choice", "props": [
        "question": "Which one?", "recommended": "o1", "revision": "rev-1", "rationale": "",
        "options": (1...12).map { n -> [String: Any] in
            ["id": "o\(n)", "text": "Option \(n)", "answer": answer(n), "effect": "adopt",
             "details": "", "rule": "", "consequences": ""]
        },
    ]]

    private static func twelve() throws -> (PageMessage, SingleChoice) {
        let page = try page("/k/decision/D-12", blocks: [choice, item([pickUp])])
        guard case .singleChoice(let block)? = page.blocks.first?.content else { return try XCTUnwrap(nil, "no choice") }
        return (page, SingleChoice(block))
    }

    func testAnAgentActionHasAButtonAndItsKey() throws {
        let page = try Self.page("/k/step/S-01", blocks: [Self.item([Self.overrule, Self.pickUp])])

        XCTAssertEqual(PageActions.buttons(PageActions.all(page)), [Self.overrule, Self.pickUp])
        XCTAssertTrue(PageActions.doable(Self.overrule))
        XCTAssertEqual(PageActions.action(key: "x", on: [page], typing: TypingFocus()), Self.overrule)
        // An action that is neither a call, a page nor the agent's still has no button.
        XCTAssertEqual(PageActions.buttons([ActionModel(label: "Odd", key: "o", to: "elsewhere:x")]), [])
    }

    func testDigitsReachAFocusedSingleChoiceOfTwelveOptions() throws {
        let (page, start) = try Self.twelve()
        var choice = start
        let typing = TypingFocus()
        typing.focus("choice", choice)

        // "1" is also the page action's key: the choice, which has the focus, takes it.
        XCTAssertNil(PageActions.action(key: "1", on: [page], typing: typing))
        XCTAssertEqual(choice.press(.digit("1")), .nothing)
        typing.focus("choice", choice)
        XCTAssertNil(PageActions.action(key: "2", on: [page], typing: typing))
        XCTAssertEqual(choice.press(.digit("2")), .nothing)
        XCTAssertEqual(choice.typed, "12")
        XCTAssertEqual(choice.press(.enter), .submit(CallModel(endpoint: "answer", params: [
            "kind": "decision", "key": "D-12", "answer": "option-12"]), values: [:]))
    }

    func testAPageActionKeepsItsKeyWhereNothingIsTyping() throws {
        let (page, choice) = try Self.twelve()
        let typing = TypingFocus()

        // No choice has the focus: the digit is the action's.
        XCTAssertEqual(PageActions.action(key: "1", on: [page], typing: typing), Self.pickUp)
        typing.focus("choice", choice)
        XCTAssertNil(PageActions.action(key: "1", on: [page], typing: typing))
        typing.blur("other")
        XCTAssertNil(PageActions.action(key: "1", on: [page], typing: typing), "another view's blur leaves the focus")
        typing.blur("choice")
        XCTAssertEqual(PageActions.action(key: "1", on: [page], typing: typing), Self.pickUp)
    }

    func testAChoiceOfFewOptionsLeavesTheDigitsItHasNotToThePage() throws {
        let page = try Self.page("/k/decision/D-3", blocks: [
            ["id": "choice", "type": "single_choice", "props": [
                "question": "Which?", "recommended": "a", "revision": "r", "rationale": "",
                "options": [["id": "a", "text": "A", "answer": Self.answer(1), "effect": "adopt", "details": "", "rule": "", "consequences": ""],
                            ["id": "b", "text": "B", "answer": Self.answer(2), "effect": "adopt", "details": "", "rule": "", "consequences": ""]],
            ]],
            Self.item([ActionModel(label: "Seven", key: "7", to: "/k/widget/W-01/seven")]),
        ])
        guard case .singleChoice(let block)? = page.blocks.first?.content else { return XCTFail("no choice") }
        let typing = TypingFocus()
        typing.focus("choice", SingleChoice(block))

        XCTAssertNil(PageActions.action(key: "2", on: [page], typing: typing))
        XCTAssertEqual(PageActions.action(key: "7", on: [page], typing: typing)?.label, "Seven")
        XCTAssertNil(PageActions.action(key: "x", on: [page], typing: typing))
    }

    func testTheButtonOfThePendingActionIsMarkedAndSaysWhatIsSent() {
        let pending = SessionState.Pending(kind: .sending, label: "Pick up", action: Self.pickUp)
        let same = ActionModel(label: "Pick it up", key: "u", to: Self.pickUp.to)

        XCTAssertTrue(PageActions.isPending(Self.pickUp, pending))
        XCTAssertTrue(PageActions.isPending(same, pending), "one button stands for every action that does the same")
        XCTAssertFalse(PageActions.isPending(Self.overrule, pending))
        XCTAssertFalse(PageActions.isPending(Self.pickUp, nil))
        XCTAssertEqual(pending.text, "Sending “Pick up”…")
        XCTAssertEqual(SessionState.Pending(kind: .asking, label: "Overrule", action: Self.overrule).text,
                       "Asking the agent: “Overrule”…")
    }

    func testASubmitIsNamedInThePagesWords() throws {
        let call = CallModel(endpoint: "pick_up", params: ["kind": "widget", "key": "W-01"])
        let confirm = try Self.page("/k/widget/W-01/pick_up/r1", blocks: [["id": "confirm", "type": "confirm", "props": [
            "title": "Pick up W-01?", "text": "W-01", "confirm_label": "Pick up",
            "confirm_to": ["endpoint": "pick_up", "params": ["kind": "widget", "key": "W-01"]],
            "cancel_to": "/k/widget/W-01",
        ]]])
        let (choicePage, _) = try Self.twelve()

        XCTAssertEqual(PageActions.label(of: call, on: [nil, confirm]), "Pick up")
        XCTAssertEqual(PageActions.label(of: CallModel(endpoint: "answer", params: [
            "kind": "decision", "key": "D-12", "answer": "option-3"]), on: [choicePage]), "Option 3")
        XCTAssertNil(PageActions.label(of: CallModel(endpoint: "other"), on: [confirm]))
    }
}
