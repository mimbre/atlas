import Prism
import AppKit
import AtlasControlKit
@testable import BlockViews
import SwiftUI
import XCTest

/// The window's columns from the left, against each other: sidebar, list, the opened page's
/// main blocks at most about 100 characters wide, its details beside them when they fit
/// (else under them); what is left over only at the right, after the last column.
@MainActor
final class WindowLayoutTests: XCTestCase {
    func testThePageIsAboutAHundredCharactersOfTheBodyFont() {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 3).prefix(100)
        let body = Prism.Typography.bodysmall
        let font = NSFont.systemFont(ofSize: body.size, weight: .light)
        let width = (String(text) as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(WindowLayout.page, width, accuracy: width * 0.1)
    }

    func testTheColumnsAreAdjacentFromTheLeftAndTheRestIsAtTheRight() {
        for window in [2400.0, 1800.0, 1500.0, 1300.0, 1100.0] {
            XCTAssertTrue(WindowLayout.showsSidebar(window: window), "window \(window)")
            let room = window - WindowLayout.sidebar - WindowLayout.list
            let columns = WindowLayout.columns(width: room)
            // Sidebar from 0, the list right after it, the page right after that.
            var edges = [0, WindowLayout.sidebar, WindowLayout.sidebar + WindowLayout.list, WindowLayout.sidebar + WindowLayout.list + columns.page]
            XCTAssertLessThanOrEqual(columns.page, WindowLayout.page)
            if let details = columns.details {
                XCTAssertEqual(columns.page, WindowLayout.page, "window \(window)")
                XCTAssertTrue((WindowLayout.detailsMin...WindowLayout.detailsMax).contains(details), "window \(window)")
                edges.append(edges.last! + details)
            }
            XCTAssertEqual(edges, edges.sorted())
            XCTAssertLessThanOrEqual(edges.last!, window, "window \(window)")
        }
    }

    func testTheDetailsGoBesideOnlyWhenTheyFitAndGrowWithTheRoom() {
        XCTAssertNil(WindowLayout.columns(width: WindowLayout.page + WindowLayout.detailsMin - 1).details)
        XCTAssertEqual(WindowLayout.columns(width: WindowLayout.page + WindowLayout.detailsMin).details, WindowLayout.detailsMin)
        let narrow = WindowLayout.columns(width: WindowLayout.page + 300).details!
        let wider = WindowLayout.columns(width: WindowLayout.page + 400).details!
        XCTAssertLessThan(narrow, wider)
        XCTAssertEqual(WindowLayout.columns(width: 3000).details, WindowLayout.detailsMax)
        // The details grow as wide as the main blocks may be, no wider.
        XCTAssertEqual(WindowLayout.detailsMax, WindowLayout.page)
        XCTAssertEqual(WindowLayout.columns(width: WindowLayout.page + 600).details, 600)
        XCTAssertEqual(WindowLayout.columns(width: 500), .init(page: 500, details: nil))
    }

    func testTheSidebarFoldsAwayInANarrowWindow() {
        XCTAssertTrue(WindowLayout.showsSidebar(window: 1500))
        XCTAssertTrue(WindowLayout.showsSidebar(window: WindowLayout.sidebar + WindowLayout.list + WindowLayout.pageMin))
        XCTAssertFalse(WindowLayout.showsSidebar(window: WindowLayout.sidebar + WindowLayout.list + WindowLayout.pageMin - 1))
        XCTAssertFalse(WindowLayout.showsSidebar(window: 800))
    }

    func testLongRoutePartWrapsInsideNarrowColumn() {
        let part = "Open the very long developer certificate settings in the system configuration"
        func height(_ width: CGFloat) -> CGFloat {
            NSHostingView(rootView: RouteLine(parts: [part]).frame(width: width)).fittingSize.height
        }
        XCTAssertGreaterThan(height(140), height(350) + 20)
    }

    private static let row: JSONValue = .object(["id": .string("W-01"), "label": .string("One")])
    private static let list: JSONValue = .object(["id": .string("list"), "type": .string("list"),
                                                  "props": .object(["title": .string("Widgets"), "rows": .array([row])])])
    private static let item: JSONValue = .object(["id": .string("item"), "type": .string("item"),
                                                  "props": .object(["title": .string("Widget W-01"), "fields": .array([])])])
    private static let details: JSONValue = .object([
        "kind": .string("part"), "start": .string("item"), "end": .string("item"),
        "props": .object(["title": .string("Details"), "role": .string("details")])])

    func testAPageStartsAtTheLeftAtMostAPageWide() {
        let page = PageMessage(blocks: [Block(raw: Self.list)], markup: [], path: "/k/widget", title: "Widgets")
        for column in [1800.0, 1200.0, 900.0, 500.0] {
            let views = Self.scrollViews(page, column)
            XCTAssertEqual(views.count, 1, "column \(column)")
            XCTAssertEqual(views[0].minX, 0, accuracy: 1, "column \(column)")
            XCTAssertEqual(views[0].width, min(column, WindowLayout.page), accuracy: 1, "column \(column)")
        }
    }

    func testDetailsAreAColumnRightBesideThePageWhenWideAndUnderItWhenNarrow() {
        let page = PageMessage(blocks: [Block(raw: Self.list), Block(raw: Self.item)],
                               markup: [MarkupEntry(raw: Self.details)], path: "/k/widget/W-01", title: "W-01")
        let presentation = PagePresentation(page)
        XCTAssertEqual(presentation.groups.map(\.id), ["block:list"])
        XCTAssertEqual(presentation.details?.title, "Details")
        XCTAssertEqual(presentation.details?.groups.map(\.id), ["block:item"])

        for column in [1800.0, 1200.0, 1100.0] {
            let views = Self.scrollViews(page, column)
            XCTAssertEqual(views.count, 2, "column \(column)")
            XCTAssertEqual(views[0].minX, 0, accuracy: 1, "column \(column)")
            XCTAssertEqual(views[0].width, WindowLayout.page, accuracy: 1, "column \(column)")
            XCTAssertEqual(views[1].minX, views[0].maxX, accuracy: 1, "column \(column): details right after the page")
            XCTAssertGreaterThanOrEqual(views[1].width, WindowLayout.detailsMin - 1, "column \(column)")
            XCTAssertLessThanOrEqual(views[1].width, WindowLayout.detailsMax + 1, "column \(column)")
            XCTAssertLessThanOrEqual(views[1].maxX, column + 1, "column \(column)")
        }
        for column in [900.0, 500.0] {
            let views = Self.scrollViews(page, column)
            XCTAssertEqual(views.count, 1, "column \(column): details under the page")
            XCTAssertEqual(views[0].minX, 0, accuracy: 1, "column \(column)")
            XCTAssertEqual(views[0].width, min(column, WindowLayout.page), accuracy: 1, "column \(column)")
        }
    }

    /// The frames of the page's scroll views, left to right, in a column `width` wide.
    private static func scrollViews(_ page: PageMessage, _ width: CGFloat) -> [NSRect] {
        let host = NSHostingView(rootView: PageView(page: page, open: { _ in }).frame(width: width, height: 400))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.layoutSubtreeIfNeeded()
        return all(NSScrollView.self, in: host).map { $0.convert($0.bounds, to: host) }.sorted { $0.minX < $1.minX }
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        if let match = view as? T { return [match] }
        return view.subviews.flatMap { all(type, in: $0) }
    }
}
