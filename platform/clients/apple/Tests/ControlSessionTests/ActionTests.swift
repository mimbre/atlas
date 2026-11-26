import AtlasControlKit
@testable import ControlSession
import XCTest

/// Actions as the TUI and the agent CLI take them: an action with `submit_to` submits it;
/// any other opens its page (a confirm, a form, more actions), shown over the page it was
/// taken on until Control stores it or the user leaves it.
@MainActor
final class ActionTests: XCTestCase {
    static let pickUpTo = "/k/widget/W-01/pick_up/r1"
    static let moreTo = "/k/widget/W-01/more"
    static let removeTo = "/k/widget/W-01/remove_item/r1"
    static let pickUp = ActionModel(label: "Pick up", key: "p", to: pickUpTo)
    static let more = ActionModel(label: "More…", key: "m", to: moreTo)
    static let remove = ActionModel(label: "Remove", key: "m", to: removeTo)
    static let call = ["endpoint": "pick_up", "params": ["kind": "widget", "key": "W-01", "run": "r1"]] as [String: Any]

    static func confirm(cancelTo: String = "/k/widget/W-01") -> [String: Any] {
        ["id": "confirm", "type": "confirm", "props": [
            "title": "Pick up W-01?", "text": "W-01", "confirm_label": "Pick up",
            "confirm_to": call, "cancel_to": cancelTo,
        ]]
    }

    static let item: [String: Any] = ["id": "item", "type": "item", "props": [
        "title": "Widget W-01", "fields": [],
        "actions": [["label": "Pick up", "key": "p", "to": pickUpTo], ["label": "More…", "key": "m", "to": moreTo]],
    ]]

    /// On the widget list, with W-01 opened.
    func onItem() -> Harness {
        let h = Harness()
        h.connect()
        h.session.open("/k/widget/W-01")
        h.connection.receive(Lines.page("/k/widget/W-01", blocks: [Self.item]))
        _ = h.connection.take()
        return h
    }

    func testAConfirmIsShownOverThePageAndStoringItShowsThePageAgain() {
        let h = onItem()
        h.session.act(Self.pickUp)
        XCTAssertEqual(h.connection.take(), [.open(OpenRequest(to: Self.pickUpTo))])
        // Until its page comes, the item stays, with no sheet.
        XCTAssertNil(ShellViewModel(h.state).sheet)

        h.connection.receive(Lines.page(Self.pickUpTo, blocks: [Self.confirm()]))
        var shell = ShellViewModel(h.state)
        XCTAssertEqual(shell.sheet?.path, Self.pickUp.to)
        XCTAssertEqual(shell.opened?.path, "/k/widget/W-01")
        XCTAssertEqual(shell.selectedPath, "/k/widget/W-01")

        h.session.submit(CallModel(endpoint: "pick_up", params: ["kind": "widget", "key": "W-01", "run": "r1"]))
        XCTAssertEqual(h.connection.take(), [.submit(SubmitRequest(
            endpoint: "pick_up", params: ["kind": "widget", "key": "W-01", "run": "r1"], values: [:]))])
        h.connection.receive(Lines.page("/k/widget/W-01", reason: "stored", blocks: [Self.item], title: "Picked up"))

        shell = ShellViewModel(h.state)
        XCTAssertNil(shell.sheet)
        XCTAssertNil(h.state.action)
        XCTAssertEqual(shell.opened?.title, "Picked up")
    }

    func testMoreActionsAreShownOverThePageAndOneOfThemReplacesThem() {
        let h = onItem()
        h.session.act(Self.more)
        h.connection.receive(Lines.page(Self.moreTo, blocks: [["id": "item", "type": "item", "props": [
            "title": "Widget W-01", "fields": [], "actions": [["label": "Remove", "key": "m", "to": Self.removeTo]],
        ]]]))
        XCTAssertEqual(ShellViewModel(h.state).sheet?.path, Self.more.to)
        _ = h.connection.take()

        h.session.act(Self.remove)
        XCTAssertEqual(h.connection.take(), [.open(OpenRequest(to: Self.removeTo))])
        h.connection.receive(Lines.page(Self.removeTo, blocks: [Self.confirm()]))
        let shell = ShellViewModel(h.state)
        XCTAssertEqual(shell.sheet?.path, Self.remove.to)
        // Still over the page the first action was taken on.
        XCTAssertEqual(shell.opened?.path, "/k/widget/W-01")
    }

    func testLeavingOpensCancelToAndShowsThePageUnderItAtOnce() {
        let h = onItem()
        h.session.act(Self.pickUp)
        h.connection.receive(Lines.page(Self.pickUpTo, blocks: [Self.confirm()]))
        _ = h.connection.take()

        h.session.leave()
        XCTAssertEqual(h.connection.take(), [.open(OpenRequest(to: "/k/widget/W-01"))])
        let shell = ShellViewModel(h.state)
        XCTAssertNil(shell.sheet)
        XCTAssertEqual(shell.opened?.path, "/k/widget/W-01")
        XCTAssertFalse(h.state.isEditing)
    }

    func testAnActionWithSubmitToIsSubmittedAsItIs() {
        let h = onItem()
        let call = CallModel(endpoint: "answer", params: ["key": "D-01", "answer": "accept"])
        h.session.act(ActionModel(label: "Accept", key: "a", to: "/k/decision/D-01/answer/accept", submitTo: call))

        XCTAssertEqual(h.connection.take(), [.submit(SubmitRequest(endpoint: "answer", params: call.params ?? [:], values: [:]))])
        XCTAssertNil(h.state.action)
    }

    func testARefusedConfirmStaysOverThePageWithWhatWasRefused() {
        let h = onItem()
        h.session.act(Self.pickUp)
        h.connection.receive(Lines.page(Self.pickUpTo, blocks: [Self.confirm()]))
        h.session.submit(CallModel(endpoint: "pick_up"))
        _ = h.connection.take()

        h.connection.receive(Lines.with(Lines.page(Self.pickUpTo, reason: "refused", blocks: [Self.confirm()]),
                                        "refused", ["Already picked up"]))
        let shell = ShellViewModel(h.state)
        XCTAssertEqual(shell.sheet?.refused, [.string("Already picked up")])
        XCTAssertFalse(shell.submitting)
    }
}
