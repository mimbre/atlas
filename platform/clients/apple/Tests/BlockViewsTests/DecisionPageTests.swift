import AtlasControlKit
@testable import BlockViews
import Foundation
import XCTest

/// A decision page as Control sends it (`AtlasControl.Pages`, `decision_blocks/4`, D-0104):
/// a stack of simple blocks — its header, why, (stuck work: what went wrong), one `option`
/// block per alternative, the recommended one first, each with its own Choose, then the
/// page's answers (Decline all, the decline, its text as its detail) — and the details. One
/// proposal is one card `alone`, answered by Accept and Decline below it. Every option
/// shows what it means; its button (`Option.action`) and its key are the same answer; a
/// decline opens the form that asks its note. No button says what follows its click.
@MainActor
final class DecisionPageTests: XCTestCase {
    private static func call(_ answer: String) -> [String: Any] {
        ["endpoint": "answer", "params": ["kind": "decision", "key": "D-7", "answer": answer]]
    }

    private static func option(_ n: Int, _ text: String, badge: String? = nil, tone: String? = nil,
                               fields: [(String, String)], answer: [String: Any], alone: Bool? = nil) -> [String: Any] {
        var props: [String: Any] = ["n": n, "text": text, "answer": answer,
                                    "fields": fields.map { ["label": $0.0, "value": $0.1] }]
        props["badge"] = badge
        props["tone"] = tone
        props["alone"] = alone
        return ["id": "option-\(n)", "type": "option", "props": props]
    }

    private static let decision: [[String: Any]] = [
        ["id": "header", "type": "header", "props": ["eyebrow": "YOUR DECISION", "key": "D-7", "title": "How do we store examples?"]],
        ["id": "why", "type": "text", "props": ["label": "Why", "text": "Nothing to run."]],
        option(1, "Use SQLite", badge: "★ Recommended", tone: "success",
               fields: [("Rule", "Store examples in SQLite."), ("Then", "One file per environment.")],
               answer: ["label": "Choose", "key": "1", "to": "/k/decision/D-7/answer/1", "submit_to": call("adopt-sqlite"),
                        "weight": "main"]),
        option(2, "Use Postgres",
               fields: [("Rule", "Store examples in Postgres."), ("Then", "A server to run.")],
               answer: ["label": "Choose", "key": "2", "to": "/k/decision/D-7/answer/2", "submit_to": call("adopt-postgres"),
                        "weight": "other"]),
        ["id": "answers", "type": "answers", "props": ["answers": [
            ["label": "Decline all", "key": "3", "to": "/k/decision/D-7/answer/3", "note": true, "weight": "decline",
             "detail": "Keep things as they are."],
        ]]],
        ["id": "actions", "type": "actions", "props": ["actions": [["label": "Update decision", "key": "u", "to": "/k/decision/D-7/edit"]]]],
        ["id": "item", "type": "item", "props": ["title": "Decision D-7", "fields": [["label": "Id", "value": "D-7"]], "actions": []]],
    ]

    private static let stuck: [[String: Any]] = [
        ["id": "header", "type": "header", "props": ["eyebrow": "YOUR DECISION", "key": "W-1", "title": "W-1 is stuck: what now?"]],
        ["id": "why", "type": "text", "props": ["text": "inspect · attempt 2 failed · stuck", "since": "2026-11-26T09:00:00Z"]],
        ["id": "failure", "type": "text", "props": ["label": "What went wrong", "text": "The bulb did not fit.", "role": "error"]],
        option(1, "Retry", badge: "★ Recommended", tone: "success", fields: [("Then", "Inspects it again.")],
               answer: ["label": "Choose", "key": "r", "to": "/k/widget/W-1/answer/r", "weight": "main",
                        "submit_to": ["endpoint": "answer", "params": ["kind": "widget", "key": "W-1", "answer": "retry"]]],
               alone: true),
        ["id": "answers", "type": "answers", "props": ["answers": [
            ["label": "Accept", "key": "r", "to": "/k/widget/W-1/answer/r", "weight": "main",
             "submit_to": ["endpoint": "answer", "params": ["kind": "widget", "key": "W-1", "answer": "retry"]]],
            ["label": "Decline", "key": "c", "to": "/k/widget/W-1/answer/c", "note": true, "weight": "decline",
             "detail": "Close it"],
            ["label": "Inspector's log", "key": "l", "to": "/k/inspection/I-1"],
        ]]],
        ["id": "actions", "type": "actions", "props": ["actions": [
            ["label": "Delete widget", "key": "d", "to": "/k/widget/W-1/delete"],
        ]]],
        ["id": "item", "type": "item", "props": ["title": "Widget W-1", "fields": [["label": "Title", "value": "Lamp"]], "actions": []]],
    ]

    private static func page(_ path: String, _ blocks: [[String: Any]]) throws -> PageMessage {
        let object: [String: Any] = [
            "op": "page", "reason": "open", "path": path, "title": path, "at": "12:00:00", "position": 1,
            "blocks": blocks,
            "markup": [["kind": "part", "start": "item", "end": "item", "props": ["role": "details", "title": "Details"]]],
        ]
        let line = try JSONSerialization.data(withJSONObject: object)
        guard case .pageOpen(let page) = try WireLine.decode(ControlMessage.self, from: line) else {
            return try XCTUnwrap(nil, "not a page")
        }
        return page
    }

    private static func options(_ page: PageMessage) -> [OptionBlock] {
        PagePresentation(page).entries.compactMap { if case .option(let block) = $0.item { block } else { nil } }
    }

    private static func text(_ id: String, _ page: PageMessage) -> TextBlock? {
        PagePresentation(page).entries.lazy.compactMap { entry -> TextBlock? in
            if entry.id == id, case .text(let block) = entry.item { block } else { nil }
        }.first
    }

    func testTheBlocksKeepControlsOrderAndTheDetailsGoUnder() throws {
        let decision = PagePresentation(try Self.page("/k/decision/D-7", Self.decision))
        XCTAssertEqual(decision.groups.map(\.id),
                       ["block:header", "block:why", "block:option-1", "block:option-2", "block:answers", "block:actions"])
        XCTAssertEqual(decision.details?.title, "Details")
        XCTAssertTrue(decision.hasHeader, "the header block names the page")
        XCTAssertFalse(decision.hasPanel)

        let stuck = PagePresentation(try Self.page("/k/widget/W-1", Self.stuck))
        XCTAssertEqual(stuck.groups.map(\.id),
                       ["block:header", "block:why", "block:failure", "block:option-1", "block:answers",
                        "block:actions"])
        XCTAssertEqual(stuck.details?.title, "Details")
    }

    func testEveryOptionShowsItsNumberTextBadgeAndWhatItMeans() throws {
        let decision = Self.options(try Self.page("/k/decision/D-7", Self.decision))
        XCTAssertEqual(decision.map(\.n), [1, 2])
        XCTAssertEqual(decision.map(\.text), ["Use SQLite", "Use Postgres"])
        XCTAssertEqual(decision.map(\.badge), ["★ Recommended", nil])
        XCTAssertEqual(decision.map { $0.fields?.map(\.label) }, [["Rule", "Then"], ["Rule", "Then"]])
        XCTAssertEqual(decision.map { $0.fields?.map(\.value) }, [
            ["Store examples in SQLite.", "One file per environment."],
            ["Store examples in Postgres.", "A server to run."],
        ])

        let stuck = Self.options(try Self.page("/k/widget/W-1", Self.stuck))
        XCTAssertEqual(stuck.map(\.text), ["Retry"])
        XCTAssertEqual(stuck.map(\.alone), [true])
        XCTAssertEqual(stuck.map { $0.fields?.map(\.value) }, [["Inspects it again."]])
    }

    func testEachOptionsButtonSendsExactlyThatOptionsAnswerAsItsKeyDoes() throws {
        let page = try Self.page("/k/decision/D-7", Self.decision)

        for block in Self.options(page) {
            let button = try XCTUnwrap(Option.action(block))
            XCTAssertEqual(button.to, block.answer?.to, "option \(block.n ?? 0)")
            XCTAssertEqual(button.submitTo, block.answer?.submitTo, "option \(block.n ?? 0)")
            XCTAssertEqual(PageActions.action(key: try XCTUnwrap(block.answer?.key), on: [page]), button,
                           "its key takes the same")
        }
        let sqlite = CallModel(endpoint: "answer", params: ["kind": "decision", "key": "D-7", "answer": "adopt-sqlite"])
        let postgres = CallModel(endpoint: "answer", params: ["kind": "decision", "key": "D-7", "answer": "adopt-postgres"])
        XCTAssertEqual(PageActions.action(key: "1", on: [page])?.submitTo, sqlite)
        XCTAssertEqual(PageActions.action(key: "2", on: [page])?.submitTo, postgres)
        // `0` is the recommended option's answer too.
        let zero = try XCTUnwrap(PageActions.action(key: "0", on: [page]))
        XCTAssertEqual(zero.submitTo, sqlite)
        XCTAssertEqual(zero.to, "/k/decision/D-7/answer/1")
        XCTAssertEqual(PageActions.all(page).map(\.key), ["1", "0", "2", "3", "u"])
        // The options are not the page's own actions in its header again.
        XCTAssertEqual(PageActions.ofPage(page), [])

        // One proposal: its card holds only `0`; its key is the page's Accept, the same call.
        let stuck = try Self.page("/k/widget/W-1", Self.stuck)
        let retry = CallModel(endpoint: "answer", params: ["kind": "widget", "key": "W-1", "answer": "retry"])
        XCTAssertEqual(Option.actions(try XCTUnwrap(Self.options(stuck).first)).map(\.key), ["0"])
        XCTAssertEqual(PageActions.action(key: "0", on: [stuck])?.submitTo, retry)
        XCTAssertEqual(PageActions.action(key: "r", on: [stuck])?.submitTo, retry)
    }

    func testADeclineAsksItsNoteFirstAndItsTextExplainsIt() throws {
        for (path, blocks, key, to, detail) in [
            ("/k/decision/D-7", Self.decision, "3", "/k/decision/D-7/answer/3", "Decline all: Keep things as they are."),
            ("/k/widget/W-1", Self.stuck, "c", "/k/widget/W-1/answer/c", "Decline: Close it"),
        ] {
            let page = try Self.page(path, blocks)
            let answers = try XCTUnwrap(PagePresentation(page).entries.lazy.compactMap { entry -> AnswersBlock? in
                if case .answers(let block) = entry.item { block } else { nil }
            }.first)
            let decline = try XCTUnwrap(answers.answers?.first { $0.weight == "decline" })
            XCTAssertEqual(decline.note, true)
            let action = Panel.action(decline)
            XCTAssertNil(action.submitTo, "a decline submits nothing at once")
            XCTAssertEqual(action.to, to, "it opens the form that asks its note")
            XCTAssertTrue(PageActions.doable(action))
            XCTAssertEqual(PageActions.action(key: key, on: [page]), action)
            XCTAssertEqual(AnswersView.details(answers), [detail])
        }
    }

    /// Melle: no button says what follows its click — no "…", no "· note" — on any button
    /// of a decision page, Choose, Accept, Decline and Decline all alike.
    func testNoButtonLabelSaysWhatFollowsItsClick() throws {
        for (path, blocks) in [("/k/decision/D-7", Self.decision), ("/k/widget/W-1", Self.stuck)] {
            let page = try Self.page(path, blocks)
            var labels: [String] = []
            for entry in PagePresentation(page).entries {
                switch entry.item {
                case .option(let block): if block.alone != true, let a = block.answer { labels.append(AnswerLook.label(a)) }
                case .answers(let block): labels += (block.answers ?? []).map(AnswerLook.label)
                default: break
                }
            }
            XCTAssertFalse(labels.isEmpty)
            for label in labels {
                XCTAssertFalse(label.hasSuffix("…"), label)
                XCTAssertFalse(label.contains("· note"), label)
            }
        }
        let decision = try Self.page("/k/decision/D-7", Self.decision)
        XCTAssertEqual(Self.options(decision).compactMap { $0.answer.map(AnswerLook.label) }, ["Choose", "Choose"])
    }

    func testWhatWentWrongHasItsLabelAsHeadingAndItsTextUnder() throws {
        let page = try Self.page("/k/widget/W-1", Self.stuck)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-26T12:05:00Z"))

        let failure = try XCTUnwrap(Self.text("failure", page))
        XCTAssertEqual(failure.role, "error")
        XCTAssertEqual(failure.label, "What went wrong")
        XCTAssertEqual(TextLine.text(failure, now: now), "The bulb did not fit.", "the heading says the label")
        let why = try XCTUnwrap(Self.text("why", page))
        XCTAssertEqual(TextLine.line(why, now: now), "inspect · attempt 2 failed · stuck · 3h ago")
    }
}
