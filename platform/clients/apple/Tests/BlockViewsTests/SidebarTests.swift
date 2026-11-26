import AtlasControlKit
@testable import BlockViews
import ControlSession
import Foundation
import Prism
import XCTest

/// The sidebar in Next's style: a count's badge by what it means (none at 0), a tab's icon
/// from the name Control sends (none for a name the app does not know), and groups
/// indented under their tab, one size smaller.
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
             "groups": [["label": "Decisions", "to": "/_g/assigned/decision", "count": 2, "for_you": true],
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

        // What boot says reaches the rows: Assigned to you's count and its groups' wait for
        // you; Open for you's is plain.
        let shell = Self.shell(Self.tabs)
        XCTAssertEqual(shell.name, "Ada")
        let badges = SidebarItem.rows(shell, section: "work", folded: []).map {
            SidebarLook.badge(count: $0.count, forYou: $0.forYou)
        }
        XCTAssertEqual(badges, [.forYou(3), .forYou(2), nil, .plain(4)])
    }

    func testAnIconNameMapsToASymbolAndAnUnknownOneToNone() {
        for name in ["assigned", "supervised", "open", "scenes", "agents", "todos", "activity", "workers"] {
            XCTAssertNotNil(SidebarLook.symbol(name), name)
        }
        XCTAssertNil(SidebarLook.symbol("something-new"))
        XCTAssertNil(SidebarLook.symbol(nil))

        let browse = SidebarItem.rows(Self.shell(Self.tabs), section: "browse", folded: [])
        XCTAssertEqual(browse.map(\.label), ["Scenes"])
        XCTAssertNil(SidebarLook.symbol(browse[0].icon))
    }

    func testGroupsAreIndentedUnderTheirTabOneSizeSmallerAndFoldAway() {
        let shell = Self.shell(Self.tabs)
        let rows = SidebarItem.rows(shell, section: "work", folded: [])
        XCTAssertEqual(rows.map(\.id), [.tab("assigned"), .group("/_g/assigned/decision"),
                                        .group("/_g/assigned/to_do"), .tab("open")])
        XCTAssertEqual(rows.map(\.isGroup), [false, true, true, false])
        XCTAssertEqual(rows[0].open, true)

        XCTAssertEqual(SidebarLook.indent(group: false), 0)
        XCTAssertGreaterThan(SidebarLook.indent(group: true), 0)
        XCTAssertLessThan(SidebarLook.typography(group: true).size, SidebarLook.typography(group: false).size)
        XCTAssertEqual(SidebarLook.typography(group: false).emphasis, .strong)

        let folded = SidebarItem.rows(shell, section: "work", folded: ["assigned"])
        XCTAssertEqual(folded.map(\.id), [.tab("assigned"), .tab("open")])
        XCTAssertEqual(folded[0].open, false)
    }
}
