import AtlasControlKit
@testable import ControlSession
import Foundation
import XCTest

/// Mac app actions with their keys and a pending cue (IS-Atlas-107): from the click or key
/// to Control's answer the action is pending (its button, the sheet, the status bar); a
/// submit Control answers with a notice alone ends; an `agent:<intent>` action asks the
/// steer agent about its page, as the TUI does, with the same cue.
@MainActor
final class PendingActionTests: XCTestCase {
    static let overrule = ActionModel(label: "Overrule", key: "x", to: "agent:overrule")
    static let accept = ActionModel(label: "Accept", key: "a", to: "/k/widget/W-01/accept",
                                    submitTo: CallModel(endpoint: "accept", params: ["kind": "widget", "key": "W-01"]))

    static let item: [String: Any] = ["id": "item", "type": "item", "props": [
        "title": "Widget W-01", "fields": [],
        "actions": [
            ["label": "Pick up", "key": "p", "to": ActionTests.pickUp.to],
            ["label": "Overrule", "key": "x", "to": overrule.to],
        ],
    ]]

    func onItem() -> Harness {
        let h = Harness()
        h.connect()
        h.session.open("/k/widget/W-01")
        h.connection.receive(Lines.page("/k/widget/W-01", blocks: [Self.item]))
        _ = h.connection.take()
        return h
    }

    /// On W-01 with the pick-up confirm over it, its submit sent.
    func submitted() -> Harness {
        let h = onItem()
        h.session.act(ActionTests.pickUp)
        h.connection.receive(Lines.page(ActionTests.pickUpTo, blocks: [ActionTests.confirm()]))
        h.session.submit(CallModel(endpoint: "pick_up"), label: "Pick up")
        _ = h.connection.take()
        return h
    }

    static func steerLine(_ object: [String: Any]) -> Data { Lines.json(object) }

    static func plan(_ state: String, title: String, steps: [[String: Any]] = []) -> Data {
        steerLine(["op": "plan", "block": ["id": "plan", "type": "plan", "props": [
            "request": "Overrule", "state": state, "title": title, "steps": steps,
        ]]])
    }

    static func step(_ n: Int, state: String = "proposed", value: String = "One") -> [String: Any] {
        ["n": n, "label": "Create part \(n)", "state": state,
         "inputs": [["kind": "text", "label": "Title", "name": "title", "value": value]]]
    }

    // MARK: (1) pending from the act to the page or notice

    func testAnActionIsPendingFromTheClickUntilItsPageComes() {
        let h = onItem()
        h.session.act(ActionTests.pickUp)

        let pending = SessionState.Pending(kind: .opening, label: "Pick up", action: ActionTests.pickUp)
        XCTAssertEqual(h.state.pending, pending)
        XCTAssertEqual(ShellViewModel(h.state).pending, pending)
        XCTAssertEqual(StatusViewModel(h.state).pending, "Opening “Pick up”…")
        // A slow Control: time passes, the cue stays.
        h.clock.advance(by: 3)
        XCTAssertEqual(h.state.pending, pending)

        h.connection.receive(Lines.page(ActionTests.pickUpTo, blocks: [ActionTests.confirm()]))
        XCTAssertNil(h.state.pending)
        XCTAssertNil(StatusViewModel(h.state).pending)
    }

    func testASubmitIsPendingUntilControlStoresIt() {
        let h = onItem()
        h.session.act(Self.accept)

        XCTAssertEqual(h.state.pending, SessionState.Pending(kind: .sending, label: "Accept", action: Self.accept))
        XCTAssertEqual(StatusViewModel(h.state).pending, "Sending “Accept”…")
        // Control's own word that it waits for Facts is no answer yet.
        h.connection.receive(Lines.notice("Sent to Facts; waiting until it is stored…", tone: "pending"))
        XCTAssertTrue(h.state.submitting)
        XCTAssertNotNil(h.state.pending)

        h.connection.receive(Lines.page("/k/widget/W-01", reason: "stored", blocks: [Self.item]))
        XCTAssertNil(h.state.pending)
        XCTAssertFalse(h.state.submitting)
    }

    func testASubmitOnTheSheetIsPendingInItsWordsUntilRefused() {
        let h = submitted()
        XCTAssertEqual(StatusViewModel(h.state).pending, "Sending “Pick up”…")
        XCTAssertTrue(ShellViewModel(h.state).submitting)

        h.connection.receive(Lines.page(ActionTests.pickUpTo, reason: "refused", blocks: [ActionTests.confirm()]))
        XCTAssertNil(h.state.pending)
        XCTAssertEqual(ShellViewModel(h.state).sheet?.path, ActionTests.pickUp.to)
    }

    func testALostConnectionEndsTheCue() {
        let h = onItem()
        h.session.act(ActionTests.pickUp)
        h.connection.drop()
        XCTAssertNil(h.state.pending)
    }

    func testOpeningAnotherPageReplacesAnActionOnItsWay() {
        let h = onItem()
        h.session.act(ActionTests.pickUp)
        h.session.open("/k/widget/W-02")
        XCTAssertNil(h.state.pending)
    }

    // MARK: (2) a notice-only answer ends the sheet

    func testAnOkNoticeAloneEndsTheSubmitAndClosesTheSheet() {
        let h = submitted()

        h.connection.receive(Lines.notice("Picked up W-01."))
        let shell = ShellViewModel(h.state)
        XCTAssertNil(shell.sheet)
        XCTAssertFalse(shell.submitting)
        XCTAssertNil(shell.pending)
        XCTAssertNil(h.state.action)
        XCTAssertEqual(shell.opened?.path, "/k/widget/W-01")
        XCTAssertEqual(StatusViewModel(h.state).notice?.text, "Picked up W-01.")
        // A submit is taken again.
        h.session.act(Self.accept)
        XCTAssertEqual(h.connection.take().count, 1)
    }

    func testTheStoredPageAfterItsNoticeIsShownAsBefore() {
        let h = submitted()
        h.connection.receive(Lines.notice("Picked up W-01."))
        h.connection.receive(Lines.page("/k/widget/W-01", reason: "stored", blocks: [Self.item], title: "Picked up"))

        let shell = ShellViewModel(h.state)
        XCTAssertNil(shell.sheet)
        XCTAssertEqual(shell.opened?.title, "Picked up")
    }

    func testAStoredIndexPageAfterItsNoticeClosesTheOpenedPageAsBefore() {
        let h = submitted()
        h.connection.receive(Lines.notice("Picked up W-01."))
        h.connection.receive(Lines.page("/k/widget", reason: "stored", title: "Widgets"))

        XCTAssertNil(h.state.opened)
        XCTAssertEqual(h.state.index?.title, "Widgets")
    }

    func testAnErrorNoticeAloneEndsTheSubmitAndTheSheetSaysWhy() {
        let h = submitted()

        h.connection.receive(Lines.notice("Nothing to submit here.", tone: "error"))
        let shell = ShellViewModel(h.state)
        XCTAssertEqual(shell.sheet?.path, ActionTests.pickUp.to)
        XCTAssertFalse(shell.submitting)
        XCTAssertNil(shell.pending)
        XCTAssertEqual(shell.answer?.text, "Nothing to submit here.")

        // The refused page, when it follows, says why itself.
        h.connection.receive(Lines.page(ActionTests.pickUpTo, reason: "refused", blocks: [ActionTests.confirm()]))
        XCTAssertNil(ShellViewModel(h.state).answer)
    }

    func testANoticeWithNoSubmitOnItsWayChangesNothing() {
        let h = onItem()
        h.session.act(ActionTests.pickUp)
        h.connection.receive(Lines.page(ActionTests.pickUpTo, blocks: [ActionTests.confirm()]))
        h.connection.receive(Lines.notice("W-02 was stored."))
        XCTAssertEqual(ShellViewModel(h.state).sheet?.path, ActionTests.pickUp.to)
    }

    // MARK: (3) an agent action, through the steer agent

    func testAnAgentActionAsksTheAgentAboutItsPageAndIsPendingUntilItAnswers() throws {
        let h = onItem()
        h.session.act(Self.overrule)

        let agent = try XCTUnwrap(h.steer.last)
        XCTAssertEqual(agent.sent, [.ask(AskRequest(intent: "overrule", on: "/k/widget/W-01", request: "Overrule"))])
        XCTAssertEqual(h.connection.take(), [], "Control is not asked")
        // At once: the plan says it is being made, the button and the status bar that it is asked.
        XCTAssertEqual(ShellViewModel(h.state).plan?.state, "planning")
        XCTAssertEqual(ShellViewModel(h.state).plan?.title, "Planning…")
        XCTAssertEqual(h.state.pending, SessionState.Pending(kind: .asking, label: "Overrule", action: Self.overrule))
        XCTAssertEqual(StatusViewModel(h.state).pending, "Asking the agent: “Overrule”…")

        agent.say(Self.plan("proposed", title: "Proposed: 1 step", steps: [Self.step(1)]))
        XCTAssertNil(h.state.pending)
        XCTAssertEqual(h.state.plan?.title, "Proposed: 1 step")

        h.session.runPlan()
        XCTAssertEqual(agent.sent.last, .run(RunRequest(steps: [RunStepModel(n: 1, values: ["title": "One"])])))
        XCTAssertEqual(h.steer.made.count, 1, "one agent, started on first need")
    }

    func testAnAgentActionTakenByItsKeyIsTheSameAction() throws {
        // The key gives the action the page declares; acting on it is the same as a click.
        let h = onItem()
        let page = try XCTUnwrap(h.state.opened)
        let byKey = try XCTUnwrap(PageActionsForTest.action(key: "x", on: page))
        h.session.act(byKey)
        XCTAssertEqual(h.steer.last?.sent.first, .ask(AskRequest(intent: "overrule", on: "/k/widget/W-01", request: "Overrule")))
    }

    func testTheSteerFixturesReplayIntoThePlan() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../atlas_control/backend/targets/swift/Tests/Fixtures/steer/received.jsonl")
            .standardizedFileURL
        let lines = try String(contentsOf: fixtures, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
        XCTAssertFalse(lines.isEmpty)
        let h = onItem()
        h.session.act(Self.overrule)
        let agent = try XCTUnwrap(h.steer.last)

        var last: PlanBlock?
        for line in lines {
            agent.say(line)
            if case .plan(let message)? = try? WireLine.decode(SteerMessage.self, from: line),
               case .plan(let block)? = message.block?.content {
                last = block
                XCTAssertEqual(h.state.plan, block)
            }
        }
        XCTAssertNotNil(last)
        XCTAssertNil(h.state.pending)
    }

    func testADroppedStepDoesNotRunAndABlockedOneMustBeDropped() throws {
        let h = onItem()
        h.session.act(Self.overrule)
        let agent = try XCTUnwrap(h.steer.last)
        agent.say(Self.plan("proposed", title: "Proposed: 2 steps", steps: [Self.step(1), Self.step(2, state: "blocked")]))

        h.session.runPlan()
        XCTAssertEqual(agent.sent.count, 1)
        XCTAssertEqual(h.state.notice?.text, "Step 2 cannot run; drop it before running.")

        h.session.togglePlanStep(2)
        XCTAssertEqual(ShellViewModel(h.state).droppedSteps, [2])
        h.session.runPlan()
        XCTAssertEqual(agent.sent.last, .run(RunRequest(steps: [RunStepModel(n: 1, values: ["title": "One"])])))
    }

    func testRunningItStopsAndOnceOverItCloses() throws {
        let h = onItem()
        h.session.act(Self.overrule)
        let agent = try XCTUnwrap(h.steer.last)
        agent.say(Self.plan("running", title: "Running: 0 of 1 stored", steps: [Self.step(1, state: "running")]))

        h.session.closePlan()
        XCTAssertNotNil(h.state.plan, "a running plan is stopped, not closed")
        h.session.stopPlan()
        XCTAssertEqual(agent.sent.last, .stop)
        XCTAssertEqual(h.state.notice?.text, "Stopping after this step…")

        agent.say(Self.plan("stopped", title: "Stopped: 0 of 1 stored"))
        XCTAssertNil(h.state.notice)
        h.session.closePlan()
        XCTAssertNil(h.state.plan)
        XCTAssertEqual(agent.sent.last, .stop, "nothing is sent to close a plan that is over")
    }

    func testCancellingAPlanBeingMadeTellsTheAgent() throws {
        let h = onItem()
        h.session.act(Self.overrule)
        h.session.closePlan()
        XCTAssertNil(h.state.plan)
        XCTAssertNil(h.state.pending)
        XCTAssertEqual(h.steer.last?.sent.last, .cancel)
        // A plan the agent still sends after is not shown again.
        h.steer.last?.say(Self.plan("proposed", title: "Proposed: 1 step", steps: [Self.step(1)]))
        XCTAssertNil(h.state.plan)
    }

    func testAnAgentThatEndsSaysWhyAndThePlanIsLost() throws {
        let h = onItem()
        h.session.act(Self.overrule)
        h.steer.last?.exit("it exited with 1; see steer.log")

        XCTAssertNil(h.state.pending)
        XCTAssertEqual(h.state.plan?.state, "failed")
        XCTAssertEqual(h.state.plan?.title, "The agent stopped")
        XCTAssertEqual(h.state.notice, NoticeMessage(text: "The agent stopped: it exited with 1; see steer.log", tone: "error"))
        // Asked again, a new agent is started.
        h.session.closePlan()
        h.session.act(Self.overrule)
        XCTAssertEqual(h.steer.made.count, 2)
    }

    func testWithoutAnAgentTheActionSaysWhy() {
        let h = onItem()
        h.steer.unavailable = "atlas was not found"
        h.session.act(Self.overrule)

        XCTAssertNil(h.state.pending)
        XCTAssertEqual(h.state.plan?.state, "failed")
        XCTAssertEqual(StatusViewModel(h.state).notice?.text, "The agent stopped: atlas was not found")
    }

    func testStoppingTheSessionStopsTheAgent() throws {
        let h = onItem()
        h.session.act(Self.overrule)
        h.session.stop()
        XCTAssertEqual(h.steer.last?.stopped, true)
    }
}

/// The key lookup BlockViews does (`PageActions.action(key:on:)`), for a page's item
/// and list actions; ControlSession's tests do not link BlockViews.
enum PageActionsForTest {
    static func action(key: String, on page: PageMessage) -> ActionModel? {
        (page.blocks ?? []).flatMap { block -> [ActionModel] in
            switch block.content {
            case .item(let item): item.actions ?? []
            case .list(let list): list.actions ?? []
            default: []
            }
        }.first { $0.key == key }
    }
}
