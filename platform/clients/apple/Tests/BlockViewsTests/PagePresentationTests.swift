import AtlasControlKit
@testable import BlockViews
import XCTest

final class PagePresentationTests: XCTestCase {
    private func page(_ blocks: [JSONValue], markup: [JSONValue] = [], path: String = "/k/widget") throws -> PageMessage {
        PageMessage(blocks: blocks.map(Block.init(raw:)), markup: markup.map(MarkupEntry.init(raw:)),
                    path: path, title: "Widgets")
    }

    private func section(_ start: String, _ end: String, _ title: String, collapsible: Bool? = nil) -> JSONValue {
        var props: [String: JSONValue] = ["title": .string(title)]
        if let collapsible { props["collapsible"] = .bool(collapsible) }
        return .object(["kind": .string("section"), "start": .string(start), "end": .string(end),
                        "props": .object(props)])
    }

    private func lists(_ ids: [String]) -> [JSONValue] {
        ids.map { block("list", ["rows": .array([])], id: $0) }
    }

    /// Groups as ids: a block's id, or "title[ids]" (with "▸" when it folds) for a section.
    private func shape(_ presentation: PagePresentation) -> [String] {
        presentation.groups.map { group in
            switch group {
            case .entry(let entry): entry.id
            case .section(let section):
                (section.collapsible ? "▸" : "") + section.title + "[" + section.entries.map(\.id).joined(separator: ",") + "]"
            }
        }
    }

    private func flattened(_ presentation: PagePresentation) -> [String] {
        presentation.groups.flatMap { group -> [String] in
            switch group {
            case .entry(let entry): [entry.id]
            case .section(let section): section.entries.map(\.id)
            }
        }
    }

    private func block(_ type: String, _ props: [String: JSONValue], id: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string(type), "props": .object(props)]
        if let id { object["id"] = .string(id) }
        return .object(object)
    }

    func testAListIsShownWithItsRows() throws {
        let rows: JSONValue = .array([.object(["label": .string("One"), "to": .string("/k/widget/W-01")])])
        let presentation = PagePresentation(try page([block("list", ["rows": rows], id: "list")]))

        XCTAssertEqual(presentation.entries.map(\.id), ["list"])
        guard case .list(let list) = presentation.entries[0].item else { return XCTFail("not a list") }
        XCTAssertEqual(list.rows.map(\.to), ["/k/widget/W-01"])
    }

    func testValidItemsKeepFullFieldsAlongsideMalformedAndUnknownBlocks() throws {
        let full = "First line\n\n" + String(repeating: "complete detail ", count: 100) + "\nLast line"
        let item = block("item", [
            "title": .string(full),
            "fields": .array([
                .object(["label": .string("State"), "value": .string("running")]),
                .object(["label": .string(""), "value": .string(full)]),
                .object(["label": .string("Absent")]),
            ]),
            "actions": .array([.object([
                "label": .string("Unsupported operation"), "key": .string("x"), "to": .string("/unused"),
            ])]),
        ], id: "item")
        let broken = block("item", ["title": .string("Broken")], id: "broken")
        let unknown = block("future", [:], id: "future")
        let list = block("list", ["rows": .array([.object([
            "id": .string(full), "label": .string(full), "detail": .string(full),
            "to": .string("/workers/example"),
        ])])], id: "list")
        let presentation = PagePresentation(try page([item, broken, unknown, list]))
        guard case .item(let detail) = presentation.entries[0].item,
              case .fallback(let malformed) = presentation.entries[1].item,
              case .fallback(let future) = presentation.entries[2].item,
              case .list(let summary) = presentation.entries[3].item
        else { return XCTFail("valid blocks lost") }
        XCTAssertEqual(detail.title, full)
        XCTAssertEqual(detail.fields[1].label, "")
        XCTAssertEqual(detail.fields[1].value, full)
        XCTAssertNil(detail.fields[2].value)
        XCTAssertEqual(detail.actions?.map(\.label), ["Unsupported operation"])
        XCTAssertEqual(malformed.reason, .missing(path: ["fields"]))
        XCTAssertEqual(future.reason, .unknownType)
        XCTAssertEqual(summary.rows[0].id, full)
        XCTAssertEqual(summary.rows[0].label, full)
        XCTAssertEqual(summary.rows[0].detail, full)
        XCTAssertEqual(summary.rows[0].to, "/workers/example")
    }

    func testWorkerPayloadShapeShowsAllFourItemsInOrder() throws {
        let page = try JSONDecoder().decode(PageMessage.self, from: Data(workerPage.utf8))
        let presentation = PagePresentation(page)
        XCTAssertEqual(presentation.entries.map(\.id),
                       ["worker", "worker-output", "worker-output-details", "guidance-history", "worker-record"])
        let items = presentation.entries.compactMap { entry -> ItemBlock? in
            guard case .item(let item) = entry.item else { return nil }
            return item
        }
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.map(\.title), ["Example task", "Worker messages", "Output stream", "Execution"])
        XCTAssertEqual(items.map { $0.fields.count }, [10, 1, 1, 6])
        XCTAssertEqual(items[0].fields[0], PairModel(label: "State", value: "running"))
        XCTAssertEqual(items[1].fields[0], PairModel(label: "", value: "Reading the worker's output…"))
        XCTAssertEqual(items[2].fields[0].value, "available for this exact execution")
        guard case .list(let guidance) = presentation.entries[3].item else {
            return XCTFail("guidance list lost")
        }
        XCTAssertEqual(guidance.empty, "No durable guidance is recorded.")
        XCTAssertTrue(guidance.rows.isEmpty)
        // Details nests in the Conversation part and folds output details through the record.
        XCTAssertEqual(shape(presentation),
                       ["worker", "worker-output", "▸Details[worker-output-details,guidance-history,worker-record]"])
    }

    func testSectionsGroupTheirBlocksAndOnlyCollapsibleOnesFold() throws {
        let presentation = PagePresentation(try page(lists(["a", "b", "c", "d", "e"]), markup: [
            section("b", "c", "Related"),
            section("e", "e", "Details", collapsible: true),
        ]))
        XCTAssertEqual(shape(presentation), ["a", "Related[b,c]", "d", "▸Details[e]"])
        XCTAssertEqual(presentation.entries.map(\.id), ["a", "b", "c", "d", "e"])
    }

    func testASectionWithoutCollapsibleOrWithFalseIsAHeading() throws {
        let presentation = PagePresentation(try page(lists(["a", "b"]), markup: [
            section("a", "a", "One"), section("b", "b", "Two", collapsible: false),
        ]))
        XCTAssertEqual(shape(presentation), ["One[a]", "Two[b]"])
    }

    func testANestedSectionShowsInsideTheOutermostOne() throws {
        // The inner section is listed first: containment, not list order, decides.
        let presentation = PagePresentation(try page(lists(["a", "b", "c", "d"]), markup: [
            section("c", "c", "Inner", collapsible: true),
            section("b", "d", "Outer", collapsible: true),
        ]))
        XCTAssertEqual(shape(presentation), ["a", "▸Outer[b,c,d]"])
    }

    func testOtherKindsOfMarkupLeaveTheBlocksFlat() throws {
        let part: JSONValue = .object(["kind": .string("part"), "start": .string("a"), "end": .string("c"),
                                       "props": .object(["title": .string("Main"), "role": .string("main")])])
        let future: JSONValue = .object(["kind": .string("future"), "start": .string("x"), "end": .string("y")])
        let presentation = PagePresentation(try page(lists(["a", "b", "c"]), markup: [part, future]))
        XCTAssertEqual(shape(presentation), ["a", "b", "c"])
    }

    func testAPageWithoutMarkupIsUnchanged() throws {
        let presentation = PagePresentation(try page(lists(["a", "b"])))
        XCTAssertEqual(presentation.groups, presentation.entries.map(PagePresentation.Group.entry))
    }

    func testMarkupThatIsNotOneTreeShowsEveryBlockFlatAndOnce() throws {
        let ids = ["a", "b", "c", "d"]
        let crossingPart: JSONValue = .object([
            "kind": .string("part"), "start": .string("c"), "end": .string("d"),
            "props": .object(["title": .string("P"), "role": .string("main")]),
        ])
        let cases: [String: [JSONValue]] = [
            "unknown id": [section("b", "zz", "Details", collapsible: true)],
            "end before start": [section("c", "b", "Details", collapsible: true)],
            "crossing sections": [section("a", "b", "One"), section("b", "c", "Two", collapsible: true)],
            "section crossing a part": [section("b", "c", "Details", collapsible: true), crossingPart],
            "valid and invalid": [section("a", "a", "One"), section("d", "a", "Two")],
        ]
        for (name, markup) in cases {
            let presentation = PagePresentation(try page(lists(ids), markup: markup))
            XCTAssertEqual(shape(presentation), ids, name)
        }
        var twice = lists(["a", "b", "b"])
        twice.append(block("list", ["rows": .array([])], id: "c"))
        let presentation = PagePresentation(try page(twice, markup: [section("b", "c", "Details", collapsible: true)]))
        XCTAssertEqual(flattened(presentation), ["a", "b", "b", "c"], "an id used twice")
        XCTAssertEqual(shape(presentation), ["a", "b", "b", "c"], "an id used twice")
    }

    func testABlockLeftOutOfTheViewDoesNotShiftASection() throws {
        let action = ConsoleActionBlock(
            label: "Show or hide details", keys: ["d"], operation: ConsoleOperationModel(name: "sections_toggle"),
            scope: ConsoleScopeModel(page: "/k/widget", revision: "r", context: "page"), available: true)
        var page = try self.page(lists(["a", "b", "c"]), markup: [section("b", "c", "Details", collapsible: true)])
        page.blocks.insert(Block(id: "action", content: .consoleAction(action)), at: 1)
        XCTAssertEqual(shape(PagePresentation(page)), ["a", "▸Details[b,c]"])
    }

    func testTheSectionKeyIsThePagePathAndItsStartBlock() throws {
        let markup = [section("details", "details", "Details", collapsible: true)]
        let one = PagePresentation(try page(lists(["details"]), markup: markup, path: "/"))
        let other = PagePresentation(try page(lists(["details"]), markup: markup, path: "/workers"))
        guard case .section(let section) = one.groups[0] else { return XCTFail("no section") }
        XCTAssertEqual(section.id, "details")
        XCTAssertNotEqual(one.path, other.path)
    }

    func testTheCalmStartPageIsASummaryACalmListAndFoldedDetails() throws {
        let page = try JSONDecoder().decode(PageMessage.self, from: Data(calmStartPage.utf8))
        let presentation = PagePresentation(page)
        XCTAssertEqual(shape(presentation), ["summary", "list", "▸Details[details]"])
        guard case .entry(let first) = presentation.groups[0], case .item(let summary) = first.item,
              case .entry(let second) = presentation.groups[1], case .list(let list) = second.item,
              case .section(let details) = presentation.groups[2], case .item(let technical) = details.entries[0].item
        else { return XCTFail("\(presentation.groups)") }
        XCTAssertEqual(summary.title, "Overview")
        XCTAssertEqual(summary.fields, [PairModel(label: "To do", value: "2"), PairModel(label: "Late", value: "1")])
        XCTAssertEqual(list.rows.map(\.id), [nil, nil])
        XCTAssertEqual(list.rows.map(\.label), ["Write the summary", "Check the import"])
        XCTAssertEqual(list.rows[0].detail, "review · Expected: a decision · late")
        XCTAssertEqual(technical.title, "Technical details")
        XCTAssertEqual(technical.fields.map(\.label), ["W-1", "W-2"])
    }

    func testAPageWithoutRowsHasNoDetailsToFold() throws {
        let page = try JSONDecoder().decode(PageMessage.self, from: Data(calmEmptyPage.utf8))
        XCTAssertEqual(shape(PagePresentation(page)), ["summary", "list"])
    }

    func testAnUnknownOrBrokenBlockIsAFallbackAndTheRestStillShows() throws {
        let unknown = block("chart", [:], id: "chart")
        let broken = block("list", [:], id: "broken")
        let good = block("list", ["rows": .array([])], id: "good")
        let presentation = PagePresentation(try page([unknown, broken, good]))

        XCTAssertEqual(presentation.entries.map(\.id), ["chart", "broken", "good"])
        guard case .fallback(let first) = presentation.entries[0].item,
              case .fallback(let second) = presentation.entries[1].item,
              case .list = presentation.entries[2].item
        else { return XCTFail("\(presentation.entries)") }
        XCTAssertEqual(first.reason, .unknownType)
        XCTAssertEqual(second.reason, .missing(path: ["rows"]))
    }

    func testConsoleActionsAreNotBlocksOnThePage() throws {
        let action = ConsoleActionBlock(
            label: "Open", keys: ["enter"], operation: ConsoleOperationModel(name: "open"),
            scope: ConsoleScopeModel(page: "/k/widget", revision: "r", context: "page"), available: true)
        var page = try self.page([block("list", ["rows": .array([])], id: "list")])
        page.blocks.append(Block(id: "action", content: .consoleAction(action)))

        XCTAssertEqual(PagePresentation(page).entries.map(\.id), ["list"])
    }

    func testABlockWithoutAnIdIsKeyedByItsPlace() throws {
        let presentation = PagePresentation(try page([block("list", ["rows": .array([])])]))
        XCTAssertEqual(presentation.entries.map(\.id), ["#0"])
    }

    func testCurrentContractConfirmationWithoutAnOfferRemainsAKnownFallback() throws {
        // Control can explain an unavailable restart without offering an action. In the
        // current contract confirm_label and confirm_to are optional, cancel_to is not.
        let confirm = block("confirm", [
            "title": .string("Unavailable"), "text": .string("No offer is available"),
            "cancel_to": .string("/k/widget/W-01"),
        ], id: "confirm")
        let page = try page([confirm])
        guard case .confirm(let value) = page.blocks[0].content else {
            return XCTFail("confirmation did not decode against the generated contract")
        }
        XCTAssertNil(value.confirmLabel)
        XCTAssertNil(value.confirmTo)
        XCTAssertEqual(PagePresentation(page).entries.map(\.item), [.notShown(type: "confirm")])
    }
}

// The calm start page as the shared contract brief composes it (synthetic values).
private let calmStartPage = #"""
{
  "op": "page", "path": "/", "title": "Assigned to you", "reason": "open",
  "blocks": [
    {"id": "summary", "type": "item", "props": {"title": "Overview", "fields": [
      {"label": "To do", "value": "2"}, {"label": "Late", "value": "1"}]}},
    {"id": "list", "type": "list", "props": {"title": "Assigned to you", "empty": "Nothing to do.", "actions": [],
      "rows": [
        {"label": "Write the summary", "detail": "review · Expected: a decision · late", "to": "/k/work/W-1", "key": "W-1"},
        {"label": "Check the import", "detail": "Expected: a check", "to": "/k/work/W-2", "key": "W-2"}]}},
    {"id": "details", "type": "item", "props": {"title": "Technical details", "fields": [
      {"label": "W-1", "value": "Work · flow review · state open · since 2026-11-16T09:00:00Z"},
      {"label": "W-2", "value": "Work · flow import · owner A-1"}]}}
  ],
  "markup": [
    {"kind": "section", "start": "details", "end": "details", "props": {"title": "Details", "collapsible": true}}
  ]
}
"""#

private let calmEmptyPage = #"""
{
  "op": "page", "path": "/", "title": "Assigned to you", "reason": "open",
  "blocks": [
    {"id": "summary", "type": "item", "props": {"title": "Overview", "fields": [{"label": "To do", "value": "0"}]}},
    {"id": "list", "type": "list", "props": {"title": "Assigned to you", "empty": "Nothing to do.", "rows": []}}
  ],
  "markup": []
}
"""#

// Synthetic identities; same received worker page/block/field/markup shape.
private let workerPage = #"""
{
  "at": "12:00:00",
  "back": "/workers",
  "blocks": [
    {
      "id": "worker",
      "props": {
        "actions": [],
        "fields": [
          {
            "label": "State",
            "value": "running"
          },
          {
            "label": "Started",
            "value": "example started"
          },
          {
            "label": "Duration",
            "value": "example duration"
          },
          {
            "label": "Backend",
            "value": "example backend"
          },
          {
            "label": "Model",
            "value": "example model"
          },
          {
            "label": "Activity",
            "value": "example activity"
          },
          {
            "label": "Worker",
            "value": "example worker"
          },
          {
            "label": "Machine",
            "value": "example machine"
          },
          {
            "label": "Environment",
            "value": "example environment"
          },
          {
            "label": "Turn",
            "value": "example turn"
          }
        ],
        "title": "Example task"
      },
      "type": "item"
    },
    {
      "id": "worker-output",
      "props": {
        "fields": [
          {
            "label": "",
            "value": "Reading the worker's output…"
          }
        ],
        "title": "Worker messages"
      },
      "type": "item"
    },
    {
      "id": "worker-output-details",
      "props": {
        "fields": [
          {
            "label": "Status",
            "value": "available for this exact execution"
          }
        ],
        "title": "Output stream"
      },
      "type": "item"
    },
    {
      "id": "guidance-history",
      "props": {
        "empty": "No durable guidance is recorded.",
        "rows": [],
        "title": "Durable guidance"
      },
      "type": "list"
    },
    {
      "id": "worker-record",
      "props": {
        "fields": [
          {
            "label": "Attempt",
            "value": "example attempt"
          },
          {
            "label": "Guidance",
            "value": "example guidance"
          },
          {
            "label": "State value",
            "value": "example state value"
          },
          {
            "label": "Configured model",
            "value": "example configured model"
          },
          {
            "label": "Lease until",
            "value": "example lease until"
          },
          {
            "label": "Confirmed at",
            "value": "example confirmed at"
          }
        ],
        "title": "Execution"
      },
      "type": "item"
    }
  ],
  "count": "0 assigned to you",
  "markup": [
    {
      "end": "worker",
      "kind": "part",
      "props": {
        "role": "main",
        "title": "Worker"
      },
      "start": "worker"
    },
    {
      "end": "worker-record",
      "kind": "part",
      "props": {
        "role": "related",
        "title": "Conversation"
      },
      "start": "worker-output"
    },
    {
      "end": "worker-record",
      "kind": "section",
      "props": {
        "collapsible": true,
        "title": "Details"
      },
      "start": "worker-output-details"
    }
  ],
  "op": "page",
  "path": "/workers/example-host/example-worker/example-turn/example-attempt",
  "position": null,
  "reason": "open",
  "title": "Worker example"
}
"""#
