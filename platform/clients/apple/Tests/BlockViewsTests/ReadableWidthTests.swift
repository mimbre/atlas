import AppKit
import AtlasControlKit
@testable import BlockViews
import SwiftUI
import XCTest

/// An opened page, in the room its column gives it: at most about 100 characters of the
/// body font wide, centred; its details under what is decided, at any width.
@MainActor
final class ReadableWidthTests: XCTestCase {
    func testTheMeasureIsAboutAHundredCharactersOfTheBodyFont() {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 3).prefix(100)
        let body = Prism.Typography.bodySmall
        let font = NSFont.systemFont(ofSize: body.size, weight: .light)
        let width = (String(text) as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(Prism.readableWidth, width, accuracy: width * 0.1)
    }

    private static let row: JSONValue = .object(["id": .string("W-01"), "label": .string("One")])
    private static let list: JSONValue = .object(["id": .string("list"), "type": .string("list"),
                                                  "props": .object(["title": .string("Widgets"), "rows": .array([row])])])
    private static let item: JSONValue = .object(["id": .string("item"), "type": .string("item"),
                                                  "props": .object(["title": .string("Widget W-01"), "fields": .array([])])])
    private static let details: JSONValue = .object([
        "kind": .string("part"), "start": .string("item"), "end": .string("item"),
        "props": .object(["title": .string("Details"), "role": .string("details")])])

    func testAPageIsCentredAtTheMeasureWhenWideAndFullWidthWhenNarrow() {
        let page = PageMessage(blocks: [Block(raw: Self.list)], markup: [], path: "/k/widget", title: "Widgets")
        for (column, expected) in [(1600.0, Prism.readableWidth), (500.0, 500.0)] {
            let lists = Self.lists(page, column)
            XCTAssertEqual(lists.count, 1)
            XCTAssertEqual(lists[0].width, expected, accuracy: 1, "column \(column)")
            XCTAssertEqual(lists[0].midX, column / 2, accuracy: 1, "column \(column)")
        }
    }

    func testDetailsStayUnderThePageAtEveryWidth() {
        let page = PageMessage(blocks: [Block(raw: Self.list), Block(raw: Self.item)],
                               markup: [MarkupEntry(raw: Self.details)], path: "/k/widget/W-01", title: "W-01")
        let presentation = PagePresentation(page)
        XCTAssertEqual(presentation.groups.map(\.id), ["block:list"])
        XCTAssertEqual(presentation.details?.title, "Details")
        XCTAssertEqual(presentation.details?.groups.map(\.id), ["block:item"])

        for column in [2400.0, 1200.0, 500.0] {
            let lists = Self.lists(page, column)
            XCTAssertEqual(lists.count, 1, "column \(column)")
            XCTAssertEqual(lists[0].width, min(column, Prism.readableWidth), accuracy: 1)
            XCTAssertEqual(lists[0].midX, column / 2, accuracy: 1)
        }
    }

    /// The frames of the page's lists, left to right, in a column `width` wide.
    private static func lists(_ page: PageMessage, _ width: CGFloat) -> [NSRect] {
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
