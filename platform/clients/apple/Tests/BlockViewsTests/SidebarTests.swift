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

    /// The shell after a boot with these tabs (and these other boot fields).
    private static func shell(_ tabs: [[String: Any]], boot extra: [String: Any] = [:],
                              blocks: [[String: Any]] = []) -> ShellViewModel {
        var state = SessionState(settings: SessionSettings(env: "test", host: "127.0.0.1", port: 7001))
        _ = state.handle(.start)
        _ = state.handle(.ready)
        _ = state.handle(.line(line(["op": "welcome", "env": "test", "spec": Contract.version, "surface": "console"])))
        _ = state.handle(.line(line(["op": "page", "path": "/", "reason": "open", "title": "Home", "at": "12:00:00",
                                     "blocks": blocks, "markup": [], "position": NSNull()])))
        let boot: [String: Any] = ["op": "boot", "env": "test", "spec": Contract.version, "revision": "r1",
                                   "title": "Console", "tabs": tabs, "initial_to": "/", "active_tab": "assigned",
                                   "name": "Ada"]
        _ = state.handle(.line(line(boot.merging(extra) { $1 })))
        XCTAssertNil(state.bootFailure)
        // The tab's page, as Control sends it after boot.
        _ = state.handle(.line(line(["op": "page", "path": "/", "reason": "open", "title": "Home", "at": "12:00:01",
                                     "blocks": blocks, "markup": [], "position": NSNull()])))
        return ShellViewModel(state)
    }

    private static var tabs: [[String: Any]] {
        [
            ["id": "assigned", "label": "Assigned to you", "to": "/", "section": "work", "icon": "assigned",
             "count": 3, "for_you": true],
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
        guard case .groups(let block) = page.blocks?.first?.content else { return XCTFail("groups missing") }
        let filters = GroupFilters(groups: block, selected: "/", filter: { _ in })
        XCTAssertEqual(PagePresentation(page).entries.count, 1)
        XCTAssertEqual(filters.groups.map(\.to), ["/", "/_g/assigned/decision"])
        XCTAssertEqual(filters.groups.map(\.count), [3, 2])
        XCTAssertEqual(filters.groups.first?.active, true)
        XCTAssertEqual(filters.selected, "/")
    }

    /// The foot marks only an environment that is not production: production is the plain
    /// word, any other its name capitalised in a warning tag.
    func testTheFootTagsOnlyAnEnvironmentThatIsNotProduction() {
        XCTAssertEqual(SidebarLook.environment("prod", production: true).label, "Production")
        XCTAssertFalse(SidebarLook.environment("prod", production: true).tagged)
        XCTAssertEqual(SidebarLook.environment("test", production: false).label, "Test")
        XCTAssertTrue(SidebarLook.environment("test", production: false).tagged)
        XCTAssertFalse(Self.shell(Self.tabs).isProduction)
    }

    /// A tab's page with a `header` block is a block page (one machine's): shown as an opened
    /// page, with no list column; a list page stays in the list column.
    func testATabsBlockPageIsShownAsAnOpenedPage() {
        let header: [String: Any] = ["id": "header", "type": "header",
                                     "props": ["eyebrow": "MACHINE", "key": "mac-mini", "title": "Mac mini"]]
        let text: [String: Any] = ["id": "state", "type": "text", "props": ["text": "Healthy"]]
        let page = Self.shell(Self.tabs, blocks: [header, text])
        XCTAssertEqual(page.index?.blocks?.count, 2)
        XCTAssertTrue(page.indexIsPage)
        XCTAssertFalse(Self.shell(Self.tabs, blocks: [text]).indexIsPage)
        XCTAssertFalse(Self.shell(Self.tabs).indexIsPage)
    }

    /// The assistant line Control sends reaches the foot in full; none (or empty) shows none.
    func testTheAssistantLineReachesTheFootWhenControlSendsOne() {
        XCTAssertEqual(Self.shell(Self.tabs, boot: ["assistant": "assistant: coordinator"]).assistant,
                       "assistant: coordinator")
        XCTAssertNil(Self.shell(Self.tabs).assistant)
        XCTAssertNil(Self.shell(Self.tabs, boot: ["assistant": ""]).assistant)
    }

    #if canImport(AppKit)
    /// The assistant line sits under the name: the foot is taller with it.
    @MainActor
    func testTheFootShowsTheAssistantLineUnderTheName() {
        func height(_ assistant: String?) -> CGFloat {
            NSHostingView(rootView: SidebarFoot(name: "Ada", assistant: assistant, env: "test", production: false,
                                                connection: SidebarConnection(mark: .connected, details: "")))
                .fittingSize.height
        }
        XCTAssertGreaterThan(height("assistant: coordinator"), height(nil))
    }
    #endif
}
