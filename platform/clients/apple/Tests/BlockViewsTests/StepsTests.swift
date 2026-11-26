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
    "steps":[{"commands":[],"lines":[{"kind":"text","text":"Make a new key."}],"n":1,"routes":[],"text":"Make a new key."},\#
    {"commands":["git tag -d v12","git tag -d v13"],"lines":[{"kind":"text","text":"Drop the old tags.\nBoth of them."},\#
    {"kind":"route","parts":["Terminal","New Window"]},{"kind":"command","text":"git tag -d v12"},\#
    {"kind":"command","text":"git tag -d v13"}],"n":2,"routes":[["Terminal","New Window"]],"text":"Drop the old tags.\nBoth of them."},\#
    {"commands":["rm old.key"],"lines":[{"kind":"route","parts":["Finder","Home","old.key > backup"]},\#
    {"kind":"command","text":"rm old.key"}],"n":3,"routes":[["Finder","Home","old.key > backup"]],"text":""}],\#
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

    func testPastTheLastStepEveryStepIsDone() throws {
        let done = try self.panel(page(current: 4, actions: [Self.action("Previous step", "Up", 3)]))
        XCTAssertNil(done.current)
        XCTAssertEqual(done.progress, "all 3 steps done")
    }

    func testTheButtonsAreThisStepDoneThenThePagesAnswersAndTheArrowsAreKeysOnly() throws {
        let page = try page()
        let panel = try panel(page)

        XCTAssertEqual(PageActions.ofPage(page).map(\.key), ["x"])
        XCTAssertEqual(PageActions.action(key: "x", on: page)?.to, "/k/chore/C-7/answer/x")
        let more = ActionModel(label: "More…", key: ".", to: "/k/chore/C-7/more", page: true)
        XCTAssertEqual(panel.buttons(others: PageActions.ofPage(page) + [more]).map(\.key), ["Enter", "x", "."])
    }

    func testThePanelKeysComeFromTheirKeyCodes() {
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
        keys.focusPanel()
        XCTAssertTrue(keys.press(.down, isRepeat: false))
        keys.release("b")
        XCTAssertTrue(keys.press(.up, isRepeat: false))
        XCTAssertEqual(taken, ["bdown", "aup"])
        keys.release("a")
        XCTAssertEqual(keys.focus, .list, "without a panel the list has the focus")
    }

    @MainActor
    func testTheArrowsGoToTheFocusedColumnAndRightAndLeftMoveTheFocus() {
        let keys = PanelKeys()
        var taken: [PanelKey] = []
        var moves: [KeyColumn] = []
        keys.moved = { moves.append($0) }
        XCTAssertFalse(keys.press(column: .panel, isRepeat: false), "→ without a panel is the list's")

        // A page with a panel opens from a move in the list: the list keeps the arrows.
        keys.claim("steps") { key, _ in taken.append(key); return true }
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
        keys.claim("steps") { key, _ in taken.append(key); return true }
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

    func testAStepsLinesComeInTheOrderWrittenARouteAsItsParts() throws {
        let panel = try panel(page())
        let current = try XCTUnwrap(panel.current)

        XCTAssertEqual(current.lines.map(\.kind), ["text", "route", "command", "command"])
        XCTAssertEqual(current.lines[1].parts, ["Terminal", "New Window"])
        XCTAssertEqual(current.routes, [["Terminal", "New Window"]])
        // Copy all copies the commands only, never a route.
        XCTAssertEqual(panel.allCommands, "git tag -d v12\ngit tag -d v13")
        // A step not open shows its first line; one that starts with a route, its parts.
        XCTAssertEqual(StepsPanel.head(panel.block.steps[2]), "Finder › Home › old.key > backup")
        XCTAssertEqual(StepsPanel.head(panel.block.steps[0]), "Make a new key.")
    }
}
