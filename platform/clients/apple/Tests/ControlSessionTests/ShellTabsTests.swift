import AtlasControlKit
@testable import ControlSession
import Foundation
import XCTest

/// The boot boundary between Control's shell (`AtlasControl.Shell.boot/4`) and the
/// client's check of it (the TUI's `AtlasTui.ShellTabsTest` is the same): every index
/// page Control serves as a tab is one the client takes, and the shell the product ships
/// boots. A tab Control serves that the client refuses leaves it without a shell for good.
final class ShellTabsTests: XCTestCase {
    private let settings = SessionSettings(env: "test", host: "127.0.0.1", port: 7001)

    /// The routes `AtlasControl.Shell` lets a tab open, one path each.
    private let tabPaths = ["/", "/k/widget", "/workers", "/_open", "/_supervised"]

    /// Welcomed and hello's page consumed: the first boot is on the wire.
    private func booting() -> SessionState {
        var state = SessionState(settings: settings)
        _ = state.handle(.start)
        _ = state.handle(.ready)
        _ = state.handle(.line(Lines.welcome()))
        _ = state.handle(.line(Lines.page("/", title: "Home")))
        return state
    }

    private func assertBoots(_ tabs: [[String: Any]], initialTo: String, line: UInt = #line) {
        var state = booting()
        let active = tabs.first { $0["to"] as? String == initialTo }?["id"] as? String
        _ = state.handle(.line(Lines.boot(tabs: tabs, initialTo: initialTo, activeTab: active)))
        XCTAssertNil(state.bootFailure, "tabs \(tabs.map { $0["to"] ?? "" })", line: line)
        XCTAssertEqual(state.shell?.tabs.map(\.to), tabs.map { $0["to"] as? String }, line: line)
    }

    func testEveryIndexPageControlServesAsATabBootsAloneAndOpenedFirst() {
        let tabs = tabPaths.enumerated().map { Lines.tab("t\($0.offset)", $0.element) }
        for tab in tabs {
            let to = tab["to"] as! String
            assertBoots([tab], initialTo: to)
            assertBoots(tabs, initialTo: to)
        }
    }

    func testAPageControlNeverServesAsATabIsStillRefused() {
        for to in ["/k/widget/W1", "/k/widget/new", "/_kinds", "/workers/m/w/t/a", "/faults"] {
            var state = booting()
            _ = state.handle(.line(Lines.boot(tabs: [Lines.tab("x", to), Lines.tab("w", "/workers")], initialTo: "/workers", activeTab: "w")))
            XCTAssertEqual(state.bootFailure, .invalid(.tab(index: 0)), to)
            XCTAssertNil(state.shell, to)
        }
    }

    /// The product's generated description (read only): the shell its Control serves.
    func testTheShellTheProductShipsBootsWithAndWithoutItsAssignedTab() throws {
        let product = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../../products/software_factory/model/targets/rela/atlas.json")
            .standardizedFileURL
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: product)) as? [String: Any])
        let shell = try XCTUnwrap(root["shell"] as? [String: Any])
        let tabs = try XCTUnwrap(shell["tabs"] as? [[String: Any]])
        XCTAssertFalse(tabs.isEmpty)
        let defaultTab = tabs.first { $0["id"] as? String == shell["default"] as? String } ?? tabs[0]

        // Control sends id, label, to and section; it leaves `assigned` tabs out for a client the
        // start page assigns nothing to.
        let all = tabs.map { ["id": $0["id"]!, "label": $0["label"]!, "to": $0["to"]!, "section": "work"] as [String: Any] }
        let unassigned = zip(tabs, all).filter { $0.0["assigned"] as? Bool != true }.map(\.1)
        for shown in [all, unassigned] where !shown.isEmpty {
            let defaultTo = defaultTab["to"] as! String
            let initial = shown.contains { $0["to"] as? String == defaultTo } ? defaultTo : shown[0]["to"] as! String
            assertBoots(shown, initialTo: initial)
        }
    }
}
