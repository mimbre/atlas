import AtlasControlKit
@testable import BlockViews
import Foundation
import XCTest

/// A decision's `single_choice` block as Control projects it (`AtlasControl.Pages`,
/// `todo_item/3`): the recommended option first, each with its answer call, the decline
/// with a note. Choosing submits exactly that call; nothing else does.
final class SingleChoiceTests: XCTestCase {
    private static func answer(_ name: String, _ key: String) -> String {
        #"{"endpoint":"answer","params":{"answer":"\#(name)","key":"\#(key)","kind":"decision"}}"#
    }

    /// A page line, in the envelope of the captured lines in Fixtures/control/received.jsonl.
    private static func line(_ key: String) -> String { #"""
    {"at":"15:51:05","back":"/k/decision","blocks":[{"id":"choice","props":{"instructions":"Choose how to store this example.\n0 selects recommended choice 1.","options":[\#
    {"answer":\#(answer("adopt-sqlite", key)),"consequences":"One file per environment.","details":"Embedded, no server.","effect":"adopt","id":"sqlite","rule":"Store examples in SQLite.","shortcut":"1","text":"Use SQLite"},\#
    {"answer":\#(answer("adopt-postgres", key)),"consequences":"A server to run.","details":"Shared, networked.","effect":"adopt","id":"postgres","rule":"Store examples in Postgres.","shortcut":"2","text":"Use Postgres"},\#
    {"answer":\#(answer("decline", key)),"consequences":"","details":"Keep things as they are.","effect":"decline","id":"decline","note":true,"rule":"","shortcut":"3","text":"Decline"}\#
    ],"question":"How do we store examples?","rationale":"Nothing to run.","recommended":"sqlite","revision":"rev-3"},"type":"single_choice"}],\#
    "markup":[],"op":"page","path":"/k/decision/\#(key)","position":4,"reason":"open","title":"\#(key)"}
    """# }

    private func decoded(_ key: String = "D-7") throws -> SingleChoiceBlock {
        let message = try WireLine.decode(ControlMessage.self, from: Data(Self.line(key).utf8))
        guard case .pageOpen(let page) = message else { return try XCTUnwrap(nil, "not a page: \(message)") }
        guard case .singleChoice(let block)? = PagePresentation(page).entries.first?.item else {
            return try XCTUnwrap(nil, "not shown as a choice: \(PagePresentation(page).entries)")
        }
        return block
    }

    private func call(_ name: String, _ key: String = "D-7") -> CallModel {
        CallModel(endpoint: "answer", params: ["kind": "decision", "key": key, "answer": name])
    }

    func testAProjectedSingleChoiceDecodesAndIsShownNumberedRecommendedFirst() throws {
        let choice = SingleChoice(try decoded())

        XCTAssertEqual(choice.block.question, "How do we store examples?")
        XCTAssertEqual(choice.choices.map(\.number), ["1", "2", "3"])
        XCTAssertEqual(choice.choices.map(\.id), ["sqlite", "postgres", "decline"])
        XCTAssertEqual(choice.choices.map(\.recommended), [true, false, false])
        XCTAssertEqual(choice.choices.map(\.needsNote), [false, false, true])
        XCTAssertEqual(choice.block.rationale, "Nothing to run.")
    }

    func testZeroSubmitsTheRecommendedChoiceOnesCallAsOneDoes() throws {
        var choice = SingleChoice(try decoded())

        XCTAssertEqual(choice.key(.digit("0")), .submit(call("adopt-sqlite"), values: [:]))
        XCTAssertEqual(choice.key(.digit("1")), .submit(call("adopt-sqlite"), values: [:]))
        XCTAssertEqual(choice.key(.digit("2")), .submit(call("adopt-postgres"), values: [:]))
    }

    func testAClickSubmitsTheChoicesCall() throws {
        var choice = SingleChoice(try decoded())

        XCTAssertEqual(choice.choose(choice.choices[1]), .submit(call("adopt-postgres"), values: [:]))
    }

    func testADeclineOpensTheNoteFormAndSubmitsOnlyWithANote() throws {
        var choice = SingleChoice(try decoded())
        let decline = choice.choices[2]

        XCTAssertEqual(choice.key(.digit("3")), .askNote(decline))
        XCTAssertEqual(choice.noting, decline)
        // While the form is open, numbers are text, not choices.
        XCTAssertEqual(choice.key(.digit("1")), .nothing)
        XCTAssertEqual(choice.giveNote("  \n"), .nothing)
        XCTAssertEqual(choice.noting, decline)

        XCTAssertEqual(choice.giveNote("Not now."), .submit(call("decline"), values: ["note": "Not now."]))
        XCTAssertNil(choice.noting)
    }

    func testClickingADeclineAlsoAsksForTheNoteAndEscCloses() throws {
        var choice = SingleChoice(try decoded())

        XCTAssertEqual(choice.choose(choice.choices[2]), .askNote(choice.choices[2]))
        XCTAssertEqual(choice.key(.escape), .nothing)
        XCTAssertNil(choice.noting)
        XCTAssertEqual(choice.giveNote("late"), .nothing)
    }

    func testAnInvalidKeyDoesNothing() throws {
        var choice = SingleChoice(try decoded())
        let before = choice

        for key: SingleChoice.Key in [.digit("4"), .digit("9"), .digit("x"), .digit("٣"), .escape] {
            XCTAssertEqual(choice.key(key), .nothing, "\(key)")
        }
        XCTAssertEqual(choice, before)
    }

    func testMoreThanNineChoicesAreTypedThenConfirmed() throws {
        var block = try decoded()
        block.options = (1...10).map { n in
            ChoiceOptionModel(id: "o\(n)", text: "Option \(n)", details: "", effect: "adopt", rule: "r", consequences: "c",
                              answer: call("o\(n)"), shortcut: String(n))
        }
        block.recommended = "o1"
        var choice = SingleChoice(block)

        XCTAssertEqual(choice.key(.digit("1")), .nothing)
        XCTAssertEqual(choice.key(.digit("0")), .nothing)
        XCTAssertEqual(choice.key(.enter), .submit(call("o10"), values: [:]))
        XCTAssertEqual(choice.key(.digit("1")), .nothing)
        XCTAssertEqual(choice.key(.escape), .nothing)
        XCTAssertEqual(choice.key(.digit("0")), .nothing)
        XCTAssertEqual(choice.key(.enter), .submit(call("o1"), values: [:]))
        XCTAssertEqual(choice.key(.digit("4")), .nothing)
        XCTAssertEqual(choice.key(.digit("2")), .nothing)
        XCTAssertEqual(choice.key(.enter), .nothing)
    }

    func testSwitchingToAnotherDecisionClosesTheNoteFormAndForgetsTheNote() throws {
        var choice = SingleChoice(try decoded("D-7"))
        XCTAssertEqual(choice.key(.digit("3")), .askNote(choice.choices[2]))
        choice.note = "Half a reason for D-7"

        choice.update(try decoded("D-8"))

        XCTAssertNil(choice.noting)
        XCTAssertEqual(choice.note, "")
        XCTAssertEqual(choice.giveNote(), .nothing)
        XCTAssertEqual(choice.key(.digit("3")), .askNote(choice.choices[2]))
        XCTAssertEqual(choice.note, "")
        XCTAssertEqual(choice.giveNote("Why not D-8."), .submit(call("decline", "D-8"), values: ["note": "Why not D-8."]))
    }

    func testTheSameDecisionSentAgainKeepsTheOpenNoteForm() throws {
        var choice = SingleChoice(try decoded())
        _ = choice.key(.digit("3"))
        choice.note = "Not now."
        var again = try decoded()
        again.instructions = "Choose again."

        choice.update(again)

        XCTAssertEqual(choice.noting?.option.answer, call("decline"))
        XCTAssertEqual(choice.giveNote(), .submit(call("decline"), values: ["note": "Not now."]))
        XCTAssertEqual(choice.note, "")
    }

    func testEachDecisionPageAndRevisionIsAViewOfItsOwn() throws {
        let block = try decoded()
        var revised = block
        revised.revision = "rev-4"
        let identities = Set([
            SingleChoiceView.identity(path: "/k/decision/D-7", block: block),
            SingleChoiceView.identity(path: "/k/decision/D-8", block: block),
            SingleChoiceView.identity(path: "/k/decision/D-7", block: revised),
        ])
        XCTAssertEqual(identities.count, 3)
    }

    func testKeysTheBlockDoesNotUseGoOnToTheViewBelow() throws {
        var choice = SingleChoice(try decoded())

        // Nothing happens and no number is being typed: the key is not the block's.
        for key: SingleChoice.Key in [.digit("9"), .escape] {
            XCTAssertNil(choice.press(key), "\(key)")
        }
        // While the note form is open every key is the note field's, digits and Return too.
        XCTAssertEqual(choice.press(.digit("3")), .askNote(choice.choices[2]))
        for key: SingleChoice.Key in [.digit("1"), .digit("0"), .enter, .escape, .up, .down] {
            XCTAssertNil(choice.press(key), "\(key)")
        }
        XCTAssertEqual(choice.noting?.id, "decline")
        choice.cancelNote()
        XCTAssertEqual(choice.press(.digit("0")), .submit(call("adopt-sqlite"), values: [:]))
    }

    func testANumberBeingTypedKeepsItsKeys() throws {
        var block = try decoded()
        block.options = (1...10).map { n in
            ChoiceOptionModel(id: "o\(n)", text: "Option \(n)", details: "", effect: "adopt", rule: "r", consequences: "c",
                              answer: call("o\(n)"), shortcut: String(n))
        }
        var choice = SingleChoice(block)

        XCTAssertEqual(choice.press(.digit("1")), .nothing)
        XCTAssertEqual(choice.press(.escape), .nothing)
        XCTAssertNil(choice.press(.escape))
        // With nothing typed, Return answers the selected choice.
        XCTAssertEqual(choice.press(.enter), .submit(call("o1"), values: [:]))
    }

    func testTheRecommendedChoiceIsSelectedAndReturnAnswersIt() throws {
        var choice = SingleChoice(try decoded())

        XCTAssertEqual(choice.selectedChoice?.id, "sqlite")
        XCTAssertEqual(choice.press(.enter), .submit(call("adopt-sqlite"), values: [:]))
    }

    func testTheArrowsMoveTheSelectionAndReturnAnswersTheSelectedChoice() throws {
        var choice = SingleChoice(try decoded())

        XCTAssertEqual(choice.press(.down), .nothing)
        XCTAssertEqual(choice.selectedChoice?.id, "postgres")
        XCTAssertEqual(choice.press(.enter), .submit(call("adopt-postgres"), values: [:]))

        XCTAssertEqual(choice.press(.up), .nothing)
        XCTAssertEqual(choice.press(.enter), .submit(call("adopt-sqlite"), values: [:]))
    }

    func testTheSelectionStopsAtTheEndsAndKeepsTheArrowsFromTheList() throws {
        var choice = SingleChoice(try decoded())

        // At the first, Up is still the block's (it does not move the list's selection).
        XCTAssertEqual(choice.press(.up), .nothing)
        XCTAssertEqual(choice.selectedChoice?.id, "sqlite")
        for _ in 0..<5 { XCTAssertEqual(choice.press(.down), .nothing) }
        XCTAssertEqual(choice.selectedChoice?.id, "decline")
    }

    func testReturnOnTheSelectedDeclineAsksForItsNote() throws {
        var choice = SingleChoice(try decoded())
        _ = choice.press(.down)
        _ = choice.press(.down)

        XCTAssertEqual(choice.press(.enter), .askNote(choice.choices[2]))
        XCTAssertEqual(choice.giveNote("Not now."), .submit(call("decline"), values: ["note": "Not now."]))
    }

    func testAChoiceAnsweredByNumberOrClickBecomesTheSelectedOne() throws {
        var choice = SingleChoice(try decoded())

        _ = choice.key(.digit("2"))
        XCTAssertEqual(choice.selectedChoice?.id, "postgres")
        _ = choice.choose(choice.choices[2])
        XCTAssertEqual(choice.selectedChoice?.id, "decline")
    }

    func testTheSameDecisionSentAgainKeepsTheSelectionAnotherStartsAtTheRecommended() throws {
        var choice = SingleChoice(try decoded("D-7"))
        _ = choice.press(.down)

        var again = try decoded("D-7")
        again.instructions = "Choose again."
        choice.update(again)
        XCTAssertEqual(choice.selectedChoice?.id, "postgres")

        var other = try decoded("D-8")
        other.options.removeAll { $0.id == "postgres" }
        choice.update(other)
        XCTAssertEqual(choice.selectedChoice?.id, "sqlite")
    }
}
