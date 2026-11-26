import AppKit
import AtlasControlKit
@testable import BlockViews
import Foundation
import XCTest

/// A to-do page as Control sends it (`AtlasControl.Pages`, `todo_blocks/4`): a stack of
/// simple blocks — its header, why, each step as an `instruction` shown in full, its
/// answers — then the details. No step is tracked: there is no current step, no progress
/// and no key that moves between steps; the answers are the page's actions on their keys.
@MainActor
final class TodoPageTests: XCTestCase {
    private static let doneCall: [String: Any] =
        ["endpoint": "answer", "params": ["kind": "chore", "key": "TD-12", "answer": "done"]]

    private static func step(_ n: Int, _ lines: [[String: Any]]) -> [String: Any] {
        ["id": "step-\(n)", "type": "instruction", "props": ["n": n, "lines": lines]]
    }

    private static let blocks: [[String: Any]] = [
        ["id": "header", "type": "header", "props": ["eyebrow": "TO DO FOR YOU", "key": "TD-12", "title": "Rotate the key"]],
        ["id": "why", "type": "text", "props": ["label": "Why", "text": "the old key leaked.", "since": "2026-11-26T09:00:00Z"]],
        step(1, [["kind": "text", "text": "Make a new key."]]),
        step(2, [["kind": "text", "text": "Drop the old tags.\nBoth of them."],
                 ["kind": "route", "parts": ["Terminal", "New Window"]],
                 ["kind": "command", "text": "git tag -d v12"],
                 ["kind": "command", "text": "git tag -d v13"]]),
        step(3, [["kind": "route", "parts": ["Finder", "Home", "old.key > backup"]],
                 ["kind": "command", "text": "rm old.key"]]),
        ["id": "answers", "type": "answers", "props": ["answers": [
            ["label": "Done", "key": "x", "to": "/k/chore/TD-12/answer/x", "submit_to": doneCall, "weight": "main"],
            ["label": "Won't do", "key": "n", "to": "/k/chore/TD-12/answer/n", "note": true, "weight": "no"],
        ]]],
        ["id": "actions", "type": "actions", "props": ["actions": [
            ["label": "Update chore", "key": "u", "to": "/k/chore/TD-12/edit", "icon": "edit"],
        ]]],
        ["id": "item", "type": "item", "props": ["title": "Chore TD-12", "fields": [["label": "Id", "value": "TD-12"]],
                                                 "actions": []]],
    ]

    private static func page(_ blocks: [[String: Any]] = blocks) throws -> PageMessage {
        let object: [String: Any] = [
            "op": "page", "reason": "open", "path": "/k/chore/TD-12", "title": "Chore TD-12",
            "at": "12:00:00", "position": 1, "blocks": blocks,
            "markup": [["kind": "part", "start": "item", "end": "item", "props": ["role": "details", "title": "Details"]]],
        ]
        let line = try JSONSerialization.data(withJSONObject: object)
        guard case .pageOpen(let page) = try WireLine.decode(ControlMessage.self, from: line) else {
            return try XCTUnwrap(nil, "not a page")
        }
        return page
    }

    private static func instructions(_ page: PageMessage) -> [InstructionBlock] {
        PagePresentation(page).entries.compactMap { if case .instruction(let block) = $0.item { block } else { nil } }
    }

    func testEveryStepIsAnEntryOfItsOwnWithAllItsLinesInOrder() throws {
        let presentation = PagePresentation(try Self.page())

        XCTAssertEqual(presentation.groups.map(\.id),
                       ["block:header", "block:why", "block:step-1", "block:step-2", "block:step-3", "block:answers",
                        "block:actions"])
        XCTAssertEqual(presentation.details?.title, "Details")
        XCTAssertTrue(presentation.hasHeader, "the header block names the page in place of its title")
        XCTAssertFalse(presentation.hasPanel)

        let steps = Self.instructions(try Self.page())
        XCTAssertEqual(steps.map(\.n), [1, 2, 3])
        XCTAssertEqual(steps[1].lines?.map(\.kind), ["text", "route", "command", "command"])
        XCTAssertEqual(steps[1].lines?.map(Instruction.shown),
                       ["Drop the old tags.\nBoth of them.", "Terminal › New Window", "git tag -d v12", "git tag -d v13"])
        XCTAssertEqual(steps[2].lines?.map(Instruction.shown), ["Finder › Home › old.key > backup", "rm old.key"])
    }

    func testTheAnswersAreThePageActionsOnTheirKeysAndNoKeyMovesBetweenSteps() throws {
        let page = try Self.page()

        XCTAssertEqual(PageActions.all(page).map(\.key), ["x", "n", "u"])
        let done = try XCTUnwrap(PageActions.action(key: "x", on: [page]))
        XCTAssertEqual(done.submitTo, CallModel(endpoint: "answer", params: ["kind": "chore", "key": "TD-12", "answer": "done"]))
        let wont = try XCTUnwrap(PageActions.action(key: "n", on: [page]))
        XCTAssertNil(wont.submitTo, "a no opens its note form")
        XCTAssertEqual(wont.to, "/k/chore/TD-12/answer/n")
        XCTAssertEqual(PageActions.action(key: "u", on: [page])?.to, "/k/chore/TD-12/edit", "an other action keeps its key")
        for key in ["Enter", "Up", "Down"] {
            XCTAssertNil(PageActions.action(key: key, on: [page]), "\(key) moves no step")
        }
        XCTAssertEqual(PageActions.label(of: try XCTUnwrap(done.submitTo), on: [page]), "Done")
    }

    func testTheAnswersAreNotInThePageHeaderAgain() throws {
        var blocks = Self.blocks
        blocks[blocks.count - 1] = ["id": "item", "type": "item", "props": ["title": "Chore TD-12", "fields": [], "actions": [
            ["label": "Done", "key": "x", "to": "/k/chore/TD-12/answer/x", "submit_to": Self.doneCall, "page": true],
            ["label": "Hand over", "key": "h", "to": "/k/chore/TD-12/hand_over", "page": true],
        ]]]

        XCTAssertEqual(PageActions.ofPage(try Self.page(blocks)).map(\.key), ["h"])
        XCTAssertEqual(PageActions.ofPage(try Self.page()), [])
    }

    func testATextSaysItsLabelAndHowLongAgoOrOnlyItsText() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-26T12:05:00Z"))

        XCTAssertEqual(TextLine.line(TextBlock(text: "the old key leaked.", label: "Why", since: "2026-11-26T09:00:00Z"), now: now),
                       "Why: the old key leaked. · 3h ago")
        XCTAssertEqual(TextLine.line(TextBlock(text: "Fresh.", since: "2026-11-26T12:04:30Z"), now: now), "Fresh. · just now")
        XCTAssertEqual(TextLine.line(TextBlock(text: "Plain."), now: now), "Plain.")
        XCTAssertEqual(TextLine.line(TextBlock(text: "Odd.", since: "not a time"), now: now), "Odd.")
    }

    func testCopyPutsExactlyThatCommandOnThePasteboard() throws {
        let command = try XCTUnwrap(Self.instructions(try Self.page())[1].lines?[3].text)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        Clipboard.copy(command, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "git tag -d v13")
    }
}
