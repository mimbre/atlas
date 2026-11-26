import AppKit
import AtlasControlKit
@testable import BlockViews
import Foundation
import XCTest

/// Instructions step by step (`steps`) as Control projects them (`AtlasControl.Pages`,
/// `steps_block/5`): where each step stands, Return and the arrows take the actions Control
/// keys `Enter`, `Down` and `Up` (each sets the step), the answers are the page's, and
/// Copy copies a command exactly as it is run.
final class StepsTests: XCTestCase {
    private static func step(_ n: Int) -> String {
        #"{"endpoint":"step","params":{"key":"C-7","kind":"chore","step":"\#(n)"}}"#
    }

    private static func action(_ label: String, _ key: String, _ n: Int) -> String {
        #"{"key":"\#(key)","label":"\#(label)","submit_to":\#(step(n)),"to":"/k/chore/C-7/step/\#(n)"}"#
    }

    /// A page line, in the envelope of the captured lines in Fixtures/control/received.jsonl.
    private static func line(current: Int, actions: [String]) -> String { #"""
    {"at":"15:51:05","back":"/","blocks":[{"id":"steps","props":{"actions":[\#(actions.joined(separator: ",")),\#
    {"key":"x","label":"Done","page":true,"to":"/k/chore/C-7/answer/x"}],"current":\#(current),"since":"2026-11-24T10:00:00Z",\#
    "steps":[{"commands":[],"n":1,"text":"Make a new key."},\#
    {"commands":["git tag -d v12","git tag -d v13"],"n":2,"text":"Drop the old tags.\nBoth of them."},\#
    {"commands":["rm old.key"],"n":3,"text":"Remove the old file."}],\#
    "title":"Rotate the key","why":"the old key leaked."},"type":"steps"}],\#
    "markup":[],"op":"page","path":"/k/chore/C-7","position":4,"reason":"open","title":"Chore C-7"}
    """# }

    private func page(current: Int = 2, actions: [String]? = nil) throws -> PageMessage {
        let actions = actions ?? [Self.action("Step \(current) done", "Enter", current + 1),
                                  Self.action("Next step", "Down", current + 1),
                                  Self.action("Previous step", "Up", current - 1)]
        let message = try WireLine.decode(ControlMessage.self, from: Data(Self.line(current: current, actions: actions).utf8))
        guard case .pageOpen(let page) = message else { return try XCTUnwrap(nil, "not a page: \(message)") }
        return page
    }

    private func panel(_ page: PageMessage) throws -> StepsPanel {
        guard case .steps(let block)? = PagePresentation(page).entries.first?.item else {
            return try XCTUnwrap(nil, "not shown as steps: \(PagePresentation(page).entries)")
        }
        return StepsPanel(block)
    }

    private func call(_ n: Int) -> CallModel {
        CallModel(endpoint: "step", params: ["kind": "chore", "key": "C-7", "step": String(n)])
    }

    func testTheStepsBeforeTheCurrentOneAreDoneItIsOpenTheRestToCome() throws {
        let panel = try panel(page())

        XCTAssertEqual(panel.block.steps.map(panel.place), [.done, .current, .later])
        XCTAssertEqual(panel.current?.n, 2)
        XCTAssertEqual(panel.progress, "step 2 of 3")
        XCTAssertEqual(StepsPanel.firstLine(panel.current?.text ?? ""), "Drop the old tags.")

        let now = ISO8601DateFormatter().date(from: "2026-11-26T10:00:00Z")!
        XCTAssertEqual(panel.whyLine(now: now), "Why: the old key leaked. · 2d ago")
    }

    func testReturnMarksTheStepDoneTheArrowsMoveItEachSettingTheStep() throws {
        let panel = try panel(page())

        XCTAssertEqual(panel.action(.enter)?.submitTo, call(3))
        XCTAssertEqual(panel.action(.down)?.submitTo, call(3))
        XCTAssertEqual(panel.action(.up)?.submitTo, call(1))

        // Past the last step every step is done and nothing moves forward.
        let done = try self.panel(page(current: 4, actions: [Self.action("Previous step", "Up", 3)]))
        XCTAssertNil(done.current)
        XCTAssertEqual(done.progress, "all 3 steps done")
        XCTAssertNil(done.action(.enter))
        XCTAssertEqual(done.action(.up)?.submitTo, call(3))
    }

    func testTheButtonsAreThisStepDoneThenThePagesAnswersAndTheArrowsAreKeysOnly() throws {
        let page = try page()
        let panel = try panel(page)

        XCTAssertEqual(PageActions.ofPage(page).map(\.key), ["x"])
        XCTAssertEqual(PageActions.action(key: "x", on: page)?.to, "/k/chore/C-7/answer/x")
        let more = ActionModel(label: "More…", key: ".", to: "/k/chore/C-7/more", page: true)
        XCTAssertEqual(panel.buttons(others: PageActions.ofPage(page) + [more]).map(\.key), ["Enter", "x", "."])
    }

    func testClickingStepThreeSendsTheStepActionForThree() throws {
        let line = Self.line(current: 1, actions: [Self.action("Step 1 done", "Enter", 2)])
            .replacingOccurrences(of: #""n":3,"text""#, with: #""n":3,"submit_to":\#(Self.step(3)),"text""#)
        let message = try WireLine.decode(ControlMessage.self, from: Data(line.utf8))
        guard case .pageOpen(let page) = message else { return XCTFail("not a page") }
        let panel = try panel(page)

        XCTAssertEqual(panel.select(panel.block.steps[2])?.submitTo, call(3))
        // The current step is not moved to; a step Control gives no call takes no click.
        XCTAssertNil(panel.select(panel.block.steps[0]))
        XCTAssertNil(panel.select(panel.block.steps[1]))
    }

    func testAKeyHeldDownMovesTheStepOnceAndTheArrowsComeFromTheirKeyCodes() throws {
        let panel = try panel(page())
        XCTAssertEqual(panel.press(.down, isRepeat: false)?.submitTo, call(3))
        XCTAssertNil(panel.press(.down, isRepeat: true))
        XCTAssertNil(panel.press(.enter, isRepeat: true))
        XCTAssertEqual(PanelKey(keyCode: 126), .up)
        XCTAssertEqual(PanelKey(keyCode: 125), .down)
        XCTAssertEqual(PanelKey(keyCode: 36), .enter)
        XCTAssertNil(PanelKey(keyCode: 0))
    }

    func testAFoldedStepDropsItsColonAndSaysHowManyCommandsItHolds() throws {
        let panel = try panel(page())
        XCTAssertEqual(StepsPanel.firstLine("Build the Mac app:\nIn the checkout."), "Build the Mac app")
        XCTAssertEqual(StepsPanel.holds(panel.block.steps[1]), "2 commands")
        XCTAssertEqual(StepsPanel.holds(panel.block.steps[2]), "1 command")
        XCTAssertNil(StepsPanel.holds(panel.block.steps[0]))
    }

    @MainActor
    func testThePanelOnScreenTakesTheKeysUntilItIsGone() {
        let keys = PanelKeys()
        var taken: [String] = []
        XCTAssertFalse(keys.press(.down, isRepeat: false))
        keys.claim("a") { key, _ in taken.append("a\(key)"); return true }
        keys.claim("b") { key, _ in taken.append("b\(key)"); return true }
        XCTAssertTrue(keys.press(.down, isRepeat: false))
        keys.release("b")
        XCTAssertTrue(keys.press(.up, isRepeat: false))
        XCTAssertEqual(taken, ["bdown", "aup"])
    }

    @MainActor
    func testCopyPutsTheCommandOnThePasteboardWithoutItsDollar() throws {
        let panel = try panel(page())
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        Clipboard.copy(try XCTUnwrap(panel.current?.commands.first), to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "git tag -d v12")

        Clipboard.copy(try XCTUnwrap(panel.allCommands), to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "git tag -d v12\ngit tag -d v13")
    }
}
