import AtlasControlKit
@testable import BlockViews
import XCTest

/// A form as Control sends it since contract 0.41.0: an input with `shown_when` is shown,
/// required and sent only while the input it names holds that value; Save waits until every
/// shown required input has a value; a required choice without a value starts with none
/// chosen (radio buttons). Delegate D-7 to… is one: `to` (the proposer or someone else,
/// `other`), and `whom` only for someone else.
@MainActor
final class FormViewTests: XCTestCase {
    private static let delegate = FormBlock(
        title: "Delegate D-7 to…",
        inputs: [
            InputModel(name: "to", label: "To", kind: "choice", required: true, choices: [
                ChoiceModel(value: "proposer", label: "The proposer (ada) — decides on your behalf",
                            help: "The proposer decides, as you delegate"),
                ChoiceModel(value: "other", label: "Someone else"),
            ]),
            InputModel(name: "whom", label: "Whom", kind: "choice", required: true,
                       choices: [ChoiceModel(value: "bob", label: "bob")],
                       shownWhen: InputConditionModel(name: "to", value: "other")),
            InputModel(name: "note", label: "Note", kind: "multiline"),
        ],
        submitLabel: "Delegate",
        submitTo: CallModel(endpoint: "answer", params: ["kind": "decision", "key": "D-7", "answer": "l"]))

    func testAnInputShownWhenAnotherHoldsAValueIsShownAndSentOnlyThen() {
        let none = FormView.shown(Self.delegate, [:]).map(\.name)
        XCTAssertEqual(none, ["to", "note"])
        XCTAssertEqual(FormView.shown(Self.delegate, ["to": "proposer"]).map(\.name), ["to", "note"])
        XCTAssertEqual(FormView.shown(Self.delegate, ["to": "other"]).map(\.name), ["to", "whom", "note"])

        // Someone chosen, then the proposer after all: whom is not sent.
        XCTAssertEqual(FormView.values(Self.delegate, ["to": "proposer", "whom": "bob"]),
                       ["to": "proposer", "note": ""])
        XCTAssertEqual(FormView.values(Self.delegate, ["to": "other", "whom": "bob"]),
                       ["to": "other", "whom": "bob", "note": ""])
    }

    func testSaveWaitsUntilEveryShownRequiredInputHasAValue() {
        XCTAssertFalse(FormView.complete(Self.delegate, [:]), "nothing chosen yet")
        XCTAssertTrue(FormView.complete(Self.delegate, ["to": "proposer"]), "whom is not shown, nor required")
        XCTAssertFalse(FormView.complete(Self.delegate, ["to": "other"]), "someone else, but who")
        XCTAssertTrue(FormView.complete(Self.delegate, ["to": "other", "whom": "bob"]))
        XCTAssertFalse(FormView.complete(Self.delegate, ["to": "  "]), "blank is no value")
    }

    func testARequiredChoiceWithoutAValueStartsWithNoneChosen() throws {
        let inputs = try XCTUnwrap(Self.delegate.inputs)
        XCTAssertTrue(FormView.radio(inputs[0]))
        XCTAssertEqual(FormView.value(inputs[0], [:]), "", "none chosen")
        XCTAssertFalse(FormView.radio(InputModel(name: "shade", kind: "choice", value: "light", required: true)))
        XCTAssertFalse(FormView.radio(InputModel(name: "shade", kind: "choice")))
        XCTAssertEqual(inputs[0].choices?.map(\.help), ["The proposer decides, as you delegate", nil])
    }
}
