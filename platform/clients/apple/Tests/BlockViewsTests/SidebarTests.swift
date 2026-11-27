import AppKit
import AtlasControlKit
@testable import BlockViews
import ControlSession
import Foundation
import Prism
import SwiftUI
import XCTest

/// The sidebar's top-level tabs and their counts.
final class SidebarTests: XCTestCase {
    private static func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object) + Data("\n".utf8)
    }

    /// The shell after a boot with these tabs.
    private static func shell(_ tabs: [[String: Any]]) -> ShellViewModel {
        var state = SessionState(settings: SessionSettings(env: "test", host: "127.0.0.1", port: 7001))
        _ = state.handle(.start)
        _ = state.handle(.ready)
        _ = state.handle(.line(line(["op": "welcome", "env": "test", "spec": Contract.version, "surface": "console"])))
        _ = state.handle(.line(line(["op": "page", "path": "/", "reason": "open", "title": "Home", "at": "12:00:00",
                                     "blocks": [], "markup": [], "position": NSNull()])))
        _ = state.handle(.line(line(["op": "boot", "env": "test", "spec": Contract.version, "revision": "r1",
                                     "title": "Console", "tabs": tabs, "initial_to": "/", "active_tab": "assigned",
                                     "name": "Ada"])))
        XCTAssertNil(state.bootFailure)
        return ShellViewModel(state)
    }

    private static var tabs: [[String: Any]] {
        [
            ["id": "assigned", "label": "Assigned to you", "to": "/", "section": "work", "icon": "assigned",
             "count": 3, "for_you": true,
             "groups": [["label": "Decisions", "to": "/_g/assigned/decision", "count": 2, "for_you": true,
                         "icon": "scales"],
                        ["label": "To-Dos", "to": "/_g/assigned/to_do", "count": 0, "for_you": true]]],
            ["id": "open", "label": "Open for you", "to": "/_open", "section": "work", "icon": "open", "count": 4,
             "for_you": false],
            ["id": "scenes", "label": "Scenes", "to": "/k/scene", "section": "browse", "icon": "something-new"],
        ]
    }

    func testABadgeIsPrimaryForWhatWaitsForYouGreyForAPlainCountAndNoneAtZero() {
        XCTAssertEqual(SidebarLook.badge(count: 3, forYou: true), .forYou(3))
        XCTAssertEqual(SidebarLook.badge(count: 4, forYou: false), .plain(4))
        XCTAssertNil(SidebarLook.badge(count: 0, forYou: true))
        XCTAssertNil(SidebarLook.badge(count: 0, forYou: false))
        XCTAssertNil(SidebarLook.badge(count: nil, forYou: true))

        // Boot's tab counts retain their meaning.
        let shell = Self.shell(Self.tabs)
        XCTAssertEqual(shell.name, "Ada")
        let badges = SidebarItem.rows(shell, section: "work").map {
            SidebarLook.badge(count: $0.count, forYou: $0.forYou)
        }
        XCTAssertEqual(badges, [.forYou(3), .plain(4)])
    }

    func testAnIconNameMapsToASymbolAndAnUnknownOneToNone() {
        // The pages' names and every kind the model names an icon for; each a symbol the
        // system has (one it lacks would show no icon at all).
        for name in ["assigned", "supervised", "open", "workers", "scales", "checklist", "frame", "route",
                     "ticket", "sparkles", "gears", "figure", "hammer", "merge", "magnifier", "flask",
                     "upgrade", "history"] {
            let symbol = SidebarLook.symbol(name)
            XCTAssertNotNil(symbol, name)
            XCTAssertNotNil(NSImage(systemSymbolName: symbol ?? "", accessibilityDescription: nil), name)
        }
        XCTAssertNil(SidebarLook.symbol("something-new"))
        XCTAssertNil(SidebarLook.symbol(nil))

        let work = SidebarItem.rows(Self.shell(Self.tabs), section: "work")
        XCTAssertEqual(work.map(\.icon), ["assigned", "open"])

        let browse = SidebarItem.rows(Self.shell(Self.tabs), section: "browse")
        XCTAssertEqual(browse.map(\.label), ["Scenes"])
        XCTAssertNil(SidebarLook.symbol(browse[0].icon))
    }

    /// Every icon an environment's configured tabs name is one the Mac draws (Workers
    /// named `machines`, which it did not know, and so showed none).
    func testEveryEnvironmentTabIconMapsToASymbol() throws {
        let environments = URL(fileURLWithPath: #filePath)
            .appendingPathComponent("../../../../../../products/software_factory/environments").standardized
        let files = ["test.json", "prod.json", "test/core.json", "prod/core.json"]
        for file in files {
            let data = try Data(contentsOf: environments.appendingPathComponent(file))
            let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let control = try XCTUnwrap(config["control"] as? [String: Any], file)
            for tab in control["tabs"] as? [[String: Any]] ?? [] {
                XCTAssertNotNil(SidebarLook.symbol(tab["icon"] as? String), "\(file): \(tab["id"] ?? "")")
            }
        }
        XCTAssertEqual(SidebarLook.symbol("workers"), "cpu")
    }

    #if canImport(AppKit)
    /// A tab without an icon keeps the icon's column, so its label lines up with the rest.
    @MainActor
    func testATabWithoutAnIconKeepsTheIconColumn() {
        func width(_ icon: String?) -> CGFloat {
            let item = SidebarItem(id: .tab("t"), label: "Workers", icon: icon, count: nil, forYou: false)
            return NSHostingView(rootView: SidebarRow(item: item, selected: false, stale: false, select: {}))
                .fittingSize.width
        }
        XCTAssertEqual(width(nil), width("workers"))
        XCTAssertEqual(width("something-new"), width("workers"))
    }
    #endif

    func testSidebarContainsOnlyTopLevelTabs() {
        let rows = SidebarItem.rows(Self.shell(Self.tabs), section: "work")
        XCTAssertEqual(rows.map(\.id), [.tab("assigned"), .tab("open")])
    }

    @MainActor
    func testPageGroupsKeepControlDestinationsCountsAndActiveState() {
        let raw: JSONValue = .object(["type": .string("groups"), "props": .object([
            "groups": .array([
                .object(["label": .string("All"), "to": .string("/"), "count": .number(3), "active": .bool(true)]),
                .object(["label": .string("Decisions"), "to": .string("/_g/assigned/decision"), "count": .number(2)])
            ])
        ])])
        let page = PageMessage(blocks: [Block(raw: raw)], path: "/", title: "Assigned")
        let filters = GroupFilters(page: page, selected: "/", filter: { _ in })
        XCTAssertEqual(filters.groups.map(\.to), ["/", "/_g/assigned/decision"])
        XCTAssertEqual(filters.groups.map(\.count), [3, 2])
        XCTAssertEqual(filters.groups.first?.active, true)
        XCTAssertEqual(filters.selected, "/")
    }
}
