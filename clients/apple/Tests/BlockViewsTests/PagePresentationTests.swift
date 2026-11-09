import AtlasControlKit
@testable import BlockViews
import XCTest

final class PagePresentationTests: XCTestCase {
    private func page(_ blocks: [JSONValue]) throws -> PageMessage {
        PageMessage(blocks: blocks.map(Block.init(raw:)), markup: [], path: "/k/widget", title: "Widgets")
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
