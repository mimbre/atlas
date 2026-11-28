import AppKit
import AtlasControlKit
import SwiftUI
import XCTest
@testable import BlockViews

@MainActor final class RowShadowTests: XCTestCase {
    func testNativeRowsAllowShadowsWithoutChangingViewportOrHitTesting() throws {
        _ = NSApplication.shared
        let rows: [JSONValue] = (1...30).map { n in
            .object(["label": .string("Row \(n)"), "to": .string("/row/\(n)")])
        }
        let blocks: [JSONValue] = [
            .object(["id": .string("item"), "type": .string("item"),
                     "props": .object(["title": .string("Item")])]),
            .object(["id": .string("list"), "type": .string("list"),
                     "props": .object(["title": .string("Rows"), "rows": .array(rows)])])
        ]
        let page = PageMessage(blocks: blocks.map(Block.init(raw:)), path: "/test", title: "Test")
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 700, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: PageView(page: page, header: true, open: { _ in })
            .frame(width: 700, height: 600))
        window.contentView = host
        window.display()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        let clip = try XCTUnwrap(table.enclosingScrollView?.contentView)
        XCTAssertTrue(try XCTUnwrap(clip.layer).masksToBounds)
        let rowViews = (0..<table.numberOfRows).compactMap { table.rowView(atRow: $0, makeIfNecessary: false) }
        XCTAssertGreaterThanOrEqual(rowViews.count, 4)
        for row in rowViews {
            XCTAssertFalse(try XCTUnwrap(row.layer).masksToBounds)
        }
        let row = try XCTUnwrap(rowViews.last)
        let frame = row.frame
        let point = NSPoint(x: row.frame.midX, y: row.frame.midY)
        let hit = table.hitTest(point)
        XCTAssertNotNil(hit)
        row.layer?.masksToBounds = true
        XCTAssertEqual(row.frame, frame)
        XCTAssertFalse(String(describing: type(of: try XCTUnwrap(hit))).contains("RowOverflowView"))
        XCTAssertTrue(table.hitTest(point) === hit)
        table.scrollRowToVisible(table.numberOfRows - 1)
        window.display()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let last = try XCTUnwrap(table.rowView(atRow: table.numberOfRows - 1, makeIfNecessary: false))
        XCTAssertFalse(try XCTUnwrap(last.layer).masksToBounds)
        XCTAssertTrue(try XCTUnwrap(clip.layer).masksToBounds)
    }
}
