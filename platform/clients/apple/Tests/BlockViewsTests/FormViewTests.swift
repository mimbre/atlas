import AtlasControlKit
@testable import BlockViews
import XCTest

/// A form as Control sends it since contract 0.41.0: an input with `shown_when` is shown,
/// required and sent only while the input it names holds that value; Save waits until every
/// shown required input has a value; a required choice without a value starts with none
/// chosen (radio buttons). Delegate D-7 to… is one: `to` (the proposer or another person),
/// and `person` only for another person.
@MainActor
final class FormViewTests: XCTestCase {
    private static let delegate = FormBlock(
        title: "Delegate D-7 to…",
        inputs: [
            InputModel(name: "to", label: "To", kind: "choice", required: true, choices: [
                ChoiceModel(value: "proposer", label: "The proposer (ada) — decides on your behalf",
                            help: "The proposer decides, as you delegate"),
                ChoiceModel(value: "person", label: "Another person"),
            ]),
            InputModel(name: "person", label: "Person", kind: "choice", required: true,
                       choices: [ChoiceModel(value: "bob", label: "bob")],
                       shownWhen: InputConditionModel(name: "to", value: "person")),
            InputModel(name: "note", label: "Note", kind: "multiline"),
        ],
        submitLabel: "Delegate",
        submitTo: CallModel(endpoint: "answer", params: ["kind": "decision", "key": "D-7", "answer": "l"]))

    func testAnInputShownWhenAnotherHoldsAValueIsShownAndSentOnlyThen() {
        let none = FormView.shown(Self.delegate, [:]).map(\.name)
        XCTAssertEqual(none, ["to", "note"])
        XCTAssertEqual(FormView.shown(Self.delegate, ["to": "proposer"]).map(\.name), ["to", "note"])
        XCTAssertEqual(FormView.shown(Self.delegate, ["to": "person"]).map(\.name), ["to", "person", "note"])

        // A person chosen, then the proposer after all: the person is not sent.
        XCTAssertEqual(FormView.values(Self.delegate, ["to": "proposer", "person": "bob"]),
                       ["to": "proposer", "note": ""])
        XCTAssertEqual(FormView.values(Self.delegate, ["to": "person", "person": "bob"]),
                       ["to": "person", "person": "bob", "note": ""])
    }

    func testSaveWaitsUntilEveryShownRequiredInputHasAValue() {
        XCTAssertFalse(FormView.complete(Self.delegate, [:]), "nothing chosen yet")
        XCTAssertTrue(FormView.complete(Self.delegate, ["to": "proposer"]), "the person is not shown, nor required")
        XCTAssertFalse(FormView.complete(Self.delegate, ["to": "person"]), "another person, but who")
        XCTAssertTrue(FormView.complete(Self.delegate, ["to": "person", "person": "bob"]))
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
