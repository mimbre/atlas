import AtlasControlKit
@testable import BlockViews
import ControlSession
import Foundation
import XCTest

/// What a page's action keys and buttons do (IS-Atlas-107): an `agent:<intent>` action has
/// its button and its key; the button of the action taken shows that it is pending.
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

    func testAnAgentActionHasAButtonAndItsKey() throws {
        let page = try Self.page("/k/step/S-01", blocks: [Self.item([Self.overrule, Self.pickUp])])

        XCTAssertEqual(PageActions.buttons(PageActions.all(page)), [Self.overrule, Self.pickUp])
        XCTAssertTrue(PageActions.doable(Self.overrule))
        XCTAssertEqual(PageActions.action(key: "x", on: [page]), Self.overrule)
        // An action that is neither a call, a page nor the agent's still has no button.
        XCTAssertEqual(PageActions.buttons([ActionModel(label: "Odd", key: "o", to: "elsewhere:x")]), [])
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

        XCTAssertEqual(PageActions.label(of: call, on: [nil, confirm]), "Pick up")
        XCTAssertNil(PageActions.label(of: CallModel(endpoint: "other"), on: [confirm]))
    }
}
