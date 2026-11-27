import AppKit
import AtlasControlKit
@testable import BlockViews
import Foundation
import XCTest

/// A scene's page as Control sends it (contract 0.41.0): its header with a state line, its
/// intro, what is already built as a calm block, its use cases as an in-page list of the
/// list column's row cards under a heading with how far they are, its answers, its details.
@MainActor
final class ScenePageTests: XCTestCase {
    private static let row: [String: Any] = [
        "id": "UC-Atlas-50", "kind": "Use case", "icon": "route", "label": "Ada sees what is hers",
        "detail": "Accepted", "tone": "done", "since": "2026-11-25T09:00:00Z",
        "to": "/k/use_case/UC-Atlas-50", "key": "UC-Atlas-50",
    ]

    private static func blocks(rows: [[String: Any]] = [row]) -> [[String: Any]] {
        [
            ["id": "header", "type": "header", "props": [
                "eyebrow": "SCENE", "key": "SC-Atlas-40", "icon": "frame", "title": "A newcomer finds their way around",
                "detail": "Break down · Refine", "since": "2026-11-24T09:00:00Z"]],
            ["id": "intro", "type": "text", "props": ["text": "Ada joins the team."]],
            ["id": "built", "type": "text", "props": [
                "label": "Already built", "role": "context", "text": "The Assigned to you tab and its counts."]],
            ["id": "items", "type": "list", "props": [
                "title": "Use cases", "aside": "2 of 3 done",
                "empty": "Once Design is picked up, its agent proposes the use cases here.", "rows": rows]],
            ["id": "answers", "type": "answers", "props": ["answers": [
                ["label": "Suggest a use case", "key": "s", "to": "/k/scene/SC-Atlas-40/answer/s", "note": true,
                 "weight": "main", "icon": "suggest"]]]],
            ["id": "item", "type": "item", "props": ["title": "", "fields": [["label": "Phase", "value": "Break down"]]]],
        ]
    }

    private static func page(_ blocks: [[String: Any]] = blocks()) throws -> PageMessage {
        let object: [String: Any] = [
            "op": "page", "reason": "open", "path": "/k/scene/SC-Atlas-40", "title": "Scene SC-Atlas-40",
            "at": "12:00:00", "position": 1, "blocks": blocks,
            "markup": [["kind": "part", "start": "item", "end": "item", "props": ["role": "details", "title": "Details"]]],
        ]
        let line = try JSONSerialization.data(withJSONObject: object)
        guard case .pageOpen(let page) = try WireLine.decode(ControlMessage.self, from: line) else {
            return try XCTUnwrap(nil, "not a page")
        }
        return page
    }

    private static let now = ISO8601DateFormatter().date(from: "2026-11-27T12:00:00Z")!

    func testTheHeadersStateLineIsItsDetailWithItsCompactAgeAndNothingWithoutADetail() throws {
        let presentation = PagePresentation(try Self.page())
        guard case .header(let header) = presentation.entries.first?.item else { return XCTFail("no header first") }

        XCTAssertEqual(HeaderState.line(header, now: Self.now), "Break down · Refine · 3d")
        XCTAssertEqual(HeaderState.line(header, now: Self.now.addingTimeInterval(-2 * 86_400 - 21 * 3_600)), "Break down · Refine · 6h",
                       "the age follows the clock")
        XCTAssertEqual(HeaderState.line(HeaderBlock(detail: "Refine"), now: Self.now), "Refine", "no since: the detail alone")
        XCTAssertNil(HeaderState.line(HeaderBlock(title: "T", since: "2026-11-24T09:00:00Z"), now: Self.now))
        XCTAssertNil(HeaderState.line(HeaderBlock(detail: "", since: "2026-11-24T09:00:00Z"), now: Self.now))
    }

    func testAContextTextIsACalmBlockNotAnErrorNorTheIntroLine() throws {
        let texts = PagePresentation(try Self.page()).entries.compactMap { entry -> TextBlock? in
            if case .text(let text) = entry.item { text } else { nil }
        }

        XCTAssertEqual(texts.map(TextLook.of), [.line, .context], "the intro a line, what is built a calm block")
        XCTAssertEqual(TextLook.of(TextBlock(text: "Boom", label: "Failed", role: "error")), .error)
        XCTAssertEqual(TextLook.of(TextBlock(text: "Odd", role: "something_new")), .line, "an unknown role shows plainly")
        XCTAssertEqual(TextLine.text(texts[1], now: Self.now), "The Assigned to you tab and its counts.",
                       "its text without its label, which is its heading")
    }

    func testAnItemPagesListIsAHeadingWithItsAsideOverTheListColumnsRowCards() throws {
        let lines = PageLine.lines(PagePresentation(try Self.page()), header: true)
        let list = lines.filter { $0.id.hasPrefix("block:items/") }

        XCTAssertEqual(list.map(\.content), [
            .heading("Use cases", aside: "2 of 3 done"),
            .row(RowModel(id: "UC-Atlas-50", label: "Ada sees what is hers", detail: "Accepted", to: "/k/use_case/UC-Atlas-50",
                          key: "UC-Atlas-50", tone: "done", since: "2026-11-25T09:00:00Z", kind: "Use case", icon: "route")),
        ])
        XCTAssertEqual(list.last?.to, "/k/use_case/UC-Atlas-50", "selecting the row opens its page")

        // The row's card is the list column's: what it is, how long, its title, its state.
        guard case .row(let row) = list.last?.content else { return XCTFail("no row") }
        XCTAssertEqual(RowCardText.top(row).text, "USE CASE · UC-Atlas-50")
        XCTAssertEqual(RowAge.text(since: row.since, now: Self.now), "2d")
        XCTAssertEqual(RowCardText.state(row.detail), "Accepted")
    }

    func testAnItemPagesEmptyListSaysItsEmptySentenceUnderItsHeading() throws {
        let lines = PageLine.lines(PagePresentation(try Self.page(Self.blocks(rows: []))), header: true)

        XCTAssertEqual(lines.filter { $0.id.hasPrefix("block:items/") }.map(\.content), [
            .heading("Use cases", aside: "2 of 3 done"),
            .empty("Once Design is picked up, its agent proposes the use cases here."),
        ])
    }

    func testTheListColumnKeepsItsTitle() throws {
        let lines = PageLine.lines(PagePresentation(try Self.page()), header: false)

        XCTAssertEqual(lines.first { $0.id == "block:items/title" }?.content, .title("Use cases"))
    }

    func testSuggestIsALightbulb() throws {
        XCTAssertEqual(ActionIcon.symbol("suggest"), "lightbulb")
        XCTAssertNotNil(NSImage(systemSymbolName: "lightbulb", accessibilityDescription: nil))
    }
}
