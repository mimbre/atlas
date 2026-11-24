import AtlasControlKit
@testable import ControlSession
import XCTest

/// The shell's model: exactly the tabs boot sent, in its order, up to 64, none of its own;
/// a failed boot keeps the last good tabs.
@MainActor
final class ShellViewModelTests: XCTestCase {
    private func tabs(_ count: Int) -> [[String: Any]] {
        (0..<count).map { Lines.tab("t\($0)", "/k/kind\($0)") }
    }

    func testBeforeBootThereAreNoTabs() {
        let h = Harness()
        h.session.start()
        let shell = ShellViewModel(h.state)
        XCTAssertEqual(shell.tabs, [])
        XCTAssertNil(shell.title)
        XCTAssertEqual(shell.env, "test")
    }

    func testExactlyTheTabsBootSentInItsOrder() {
        let h = Harness()
        let sent = [Lines.tab("z", "/k/zeta"), Lines.tab("a", "/k/alpha"), Lines.tab("home", "/")]
        h.connect(boot: Lines.boot(tabs: sent, initialTo: "/k/zeta", activeTab: "z"), start: Lines.page("/k/zeta"))

        let shell = ShellViewModel(h.state)

        XCTAssertEqual(shell.tabs.map(\.id), ["z", "a", "home"])
        XCTAssertEqual(shell.tabs.map(\.to), ["/k/zeta", "/k/alpha", "/"])
        XCTAssertEqual(shell.tabs.map(\.label), sent.map { $0["label"] as? String })
        XCTAssertEqual(shell.activeTab, "z")
        XCTAssertEqual(shell.title, "Console")
        XCTAssertFalse(shell.stale)
    }

    func testTabsKeepTheirSectionAndShortcutsFollowBootOrder() {
        let h = Harness()
        let sent = [Lines.tab("mine", "/"), Lines.tab("shelves", "/k/shelf", section: "browse"),
                    Lines.tab("open", "/_open")]
        h.connect(boot: Lines.boot(tabs: sent, initialTo: "/", activeTab: "mine"), start: Lines.page("/"))

        let shell = ShellViewModel(h.state)

        XCTAssertEqual(shell.tabs.filter { $0.section == "work" }.map(\.id), ["mine", "open"])
        XCTAssertEqual(shell.tabs.filter { $0.section == "browse" }.map(\.id), ["shelves"])
        XCTAssertEqual(shell.tabs.map(\.shortcut), [1, 2, 3])
    }

    func testSixtyFourTabsAllShowAndOnlyTheFirstNineHaveShortcuts() {
        let h = Harness()
        h.connect(boot: Lines.boot(tabs: tabs(64), initialTo: "/k/kind0", activeTab: nil), start: Lines.page("/k/kind0"))

        let shell = ShellViewModel(h.state)

        XCTAssertEqual(shell.tabs.map(\.id), (0..<64).map { "t\($0)" })
        XCTAssertEqual(shell.tabs.compactMap(\.shortcut), Array(1...9))
        XCTAssertEqual(shell.tab(shortcut: 3)?.id, "t2")
        XCTAssertNil(shell.tab(shortcut: 10))
    }

    func testAShortcutSwitchesToItsTab() {
        let h = Harness()
        h.connect()
        let shell = ShellViewModel(h.state)

        h.session.selectTab(shell.tab(shortcut: 2)!.id)

        XCTAssertEqual(h.connection.take(), [.open(OpenRequest(to: "/k/part"))])
        XCTAssertEqual(h.state.activeTab, "parts")
    }

    func testSwitchingTabsClearsTheOpenedPage() {
        let h = Harness()
        h.connect()
        h.session.open("/k/widget/W-01")
        h.connection.receive(Lines.page("/k/widget/W-01"))

        h.session.selectTab("parts")
        h.connection.receive(Lines.page("/k/part"))

        let shell = ShellViewModel(h.state)
        XCTAssertEqual(shell.index?.path, "/k/part")
        XCTAssertNil(shell.opened)
        XCTAssertEqual(shell.activeTab, "parts")
    }

    func testATabBootDidNotSendCannotBeChosen() {
        let h = Harness()
        h.connect()
        h.session.selectTab("home")
        XCTAssertEqual(h.connection.take(), [])
        XCTAssertEqual(h.state.activeTab, "widgets")
    }

    func testMoreThanSixtyFourTabsIsRefusedAndTheLastGoodTabsStay() {
        let h = Harness()
        h.connect()
        h.clock.advance(by: 5)
        h.connection.receive(Lines.boot(tabs: tabs(65), initialTo: "/k/kind0", activeTab: nil))

        let shell = ShellViewModel(h.state)
        XCTAssertEqual(shell.tabs.map(\.id), ["widgets", "parts"])
        XCTAssertTrue(shell.stale)
        XCTAssertEqual(shell.bootFailure, .invalid(.tabCount))
    }

    func testABootErrorKeepsTheLastGoodTabsAsStale() {
        let h = Harness()
        h.connect()
        h.clock.advance(by: 5)
        h.connection.receive(Lines.bootError("Facts did not answer"))

        let shell = ShellViewModel(h.state)
        XCTAssertEqual(shell.tabs.map(\.id), ["widgets", "parts"])
        XCTAssertTrue(shell.stale)
        XCTAssertEqual(shell.bootFailure, .control("Facts did not answer"))
        XCTAssertEqual(shell.index?.path, "/k/widget")

        // The next good boot installs its tabs and is no longer stale.
        h.clock.advance(by: 5)
        h.connection.receive(Lines.boot(tabs: [Lines.tab("widgets", "/k/widget")]))
        XCTAssertEqual(ShellViewModel(h.state).tabs.map(\.id), ["widgets"])
        XCTAssertFalse(ShellViewModel(h.state).stale)
        XCTAssertNil(ShellViewModel(h.state).bootFailure)
    }

    func testAShellWithTwiceTheSameTabIsRefused() {
        let h = Harness()
        h.connect()
        h.clock.advance(by: 5)
        h.connection.receive(Lines.boot(tabs: [Lines.tab("a", "/k/a"), Lines.tab("a", "/k/b")]))
        XCTAssertEqual(h.state.bootFailure, .invalid(.duplicateTab))
        XCTAssertEqual(ShellViewModel(h.state).tabs.map(\.id), ["widgets", "parts"])
    }

    func testAShellForAnotherEnvironmentIsRefused() {
        let h = Harness()
        h.connect()
        h.clock.advance(by: 5)
        h.connection.receive(Lines.boot(env: "prod"))
        XCTAssertEqual(h.state.bootFailure, .invalid(.env))
    }

    func testAFailedFirstBootShowsNoTabsAndIsAskedAgainOnTheInterval() {
        let h = Harness()
        h.session.start()
        h.connection.ready()
        h.connection.receive(Lines.welcome())
        h.connection.receive(Lines.page("/"))
        _ = h.connection.take()
        h.connection.receive(Lines.bootError("No shell configured"))

        XCTAssertEqual(ShellViewModel(h.state).tabs, [])
        h.clock.advance(by: 5)
        XCTAssertEqual(h.connection.take(), [.boot(BootRequest(to: nil))])
    }

    func testABootThatDropsTheActiveTabReturnsToTheStart() {
        let h = Harness()
        h.connect()
        h.session.selectTab("parts")
        h.connection.receive(Lines.page("/k/part"))
        _ = h.connection.take()

        h.clock.advance(by: 5)
        _ = h.connection.take()
        h.connection.receive(Lines.boot(tabs: [Lines.tab("widgets", "/k/widget")], initialTo: "/k/widget", activeTab: "widgets"))

        XCTAssertEqual(h.connection.take(), [.open(OpenRequest(to: "/k/widget"))])
        XCTAssertEqual(h.state.activeTab, "widgets")
    }

    func testALaterBootDoesNotNavigate() {
        let h = Harness()
        h.connect()
        h.session.open("/k/widget/W-01")
        h.connection.receive(Lines.page("/k/widget/W-01"))
        h.clock.advance(by: 5)
        _ = h.connection.take()

        h.connection.receive(Lines.boot(initialTo: "/k/part", activeTab: "parts"))

        XCTAssertEqual(h.connection.take(), [])
        XCTAssertEqual(h.state.opened?.path, "/k/widget/W-01")
        XCTAssertEqual(h.state.activeTab, "widgets")
    }

    func testProductionWearsTheBadgeAndTestDoesNot() {
        let prod = Harness(settings: SessionSettings(env: "prod", host: "127.0.0.1", port: 7001))
        prod.session.start()
        XCTAssertTrue(ShellViewModel(prod.state).isProduction)

        let test = Harness()
        test.connect()
        XCTAssertFalse(ShellViewModel(test.state).isProduction)
        XCTAssertEqual(ShellViewModel(test.state).env, "test")
    }

    func testSelectionFollowsDisplayedIdentityThroughRedirectPushFailureAndTabChange() {
        let h = Harness()
        h.connect()
        XCTAssertEqual(ShellViewModel(h.state).selectedPath, "/k/widget")

        h.session.open("/k/widget/requested")
        XCTAssertEqual(h.connection.take(), [.open(OpenRequest(to: "/k/widget/requested"))])
        // Pending intent must not pretend that another item is already displayed.
        XCTAssertEqual(ShellViewModel(h.state).selectedPath, "/k/widget")
        h.connection.receive(Lines.page("/k/widget/redirected"))
        XCTAssertEqual(ShellViewModel(h.state).selectedPath, "/k/widget/redirected")

        h.connection.receive(Lines.page("/k/widget/redirected", reason: "reconcile", position: 2))
        XCTAssertEqual(ShellViewModel(h.state).selectedPath, "/k/widget/redirected")
        h.connection.receive(Lines.page("/k/widget/unrelated", reason: "hint"))
        XCTAssertEqual(ShellViewModel(h.state).selectedPath, "/k/widget/redirected")

        h.session.open("/k/widget/broken")
        _ = h.connection.take()
        h.connection.receive(Lines.with(Lines.page("/k/widget/broken"), "blocks", "invalid"))
        XCTAssertNotNil(h.state.openFailure)
        XCTAssertEqual(ShellViewModel(h.state).selectedPath, "/k/widget/redirected")

        h.session.open("/k/widget/next")
        XCTAssertEqual(h.connection.take(), [.open(OpenRequest(to: "/k/widget/next"))])
        h.connection.receive(Lines.page("/k/widget/next"))
        XCTAssertEqual(ShellViewModel(h.state).selectedPath, "/k/widget/next")

        h.session.selectTab("parts")
        XCTAssertNil(ShellViewModel(h.state).opened)
        XCTAssertNil(ShellViewModel(h.state).selectedPath)
        h.connection.receive(Lines.page("/k/part"))
        XCTAssertEqual(ShellViewModel(h.state).selectedPath, "/k/part")
    }

    func testEveryTabsGroupsAreItsSubItemsAndAnyGroupShowsInTheMiddleColumnOnItsTab() {
        let groups: (String) -> [String: Any] = { active in
            ["id": "groups", "type": "groups", "props": ["groups": [
                ["label": "All", "count": 3, "to": "/k/part", "active": active == "/k/part"],
                ["label": "Build", "count": 2, "to": "/_open/issue/build", "active": active == "/_open/issue/build"],
            ]]]
        }
        var parts = Lines.tab("parts", "/k/part")
        parts["icon"] = "inbox"
        parts["groups"] = [["label": "Build", "to": "/_open/issue/build"]]
        let h = Harness()
        h.connect(boot: Lines.boot(tabs: [Lines.tab("widgets", "/k/widget"), parts]))

        // The other tab's groups show while the widgets tab is shown; no count yet.
        var shell = ShellViewModel(h.state)
        XCTAssertEqual(shell.tabs.last?.icon, "inbox")
        XCTAssertEqual(shell.tabs.last?.groups, [ShellViewModel.Group(label: "Build", count: nil, to: "/_open/issue/build")])
        XCTAssertNil(shell.activeGroup)

        // Choosing it selects it at once, kept while its page loads, on its own tab; its
        // page opens in the middle column, with its counts.
        h.session.filter("/_open/issue/build")
        XCTAssertEqual(h.connection.take(), [.open(OpenRequest(to: "/_open/issue/build"))])
        shell = ShellViewModel(h.state)
        XCTAssertEqual(shell.activeGroup, "/_open/issue/build")
        XCTAssertEqual(shell.activeTab, "parts")
        h.connection.receive(Lines.page("/_open/issue/build", blocks: [groups("/_open/issue/build"), Lines.list([])]))
        shell = ShellViewModel(h.state)
        XCTAssertEqual(shell.index?.path, "/_open/issue/build")
        XCTAssertNil(shell.opened)
        XCTAssertEqual(shell.activeTab, "parts")
        XCTAssertEqual(shell.activeGroup, "/_open/issue/build")
        XCTAssertEqual(shell.tabs.last?.count, 3)
        XCTAssertEqual(shell.tabs.last?.groups.first?.count, 2)
    }

    func testBootsCountsShowBeforeTheTabIsOpenedAndTheLatestCountWins() {
        var parts = Lines.tab("parts", "/k/part")
        parts["count"] = 5
        parts["groups"] = [["label": "Build", "to": "/_open/issue/build", "count": 4], ["label": "Plan", "to": "/_open/plan"]]
        let h = Harness()
        h.connect(boot: Lines.boot(tabs: [Lines.tab("widgets", "/k/widget"), parts]))

        var shell = ShellViewModel(h.state)
        XCTAssertEqual(shell.tabs.last?.count, 5)
        XCTAssertEqual(shell.tabs.last?.groups.map(\.count), [4, nil])

        // A page's groups say it later: theirs show.
        h.session.selectTab("parts")
        _ = h.connection.take()
        h.connection.receive(Lines.page("/k/part", blocks: [
            ["id": "groups", "type": "groups", "props": ["groups": [
                ["label": "All", "count": 6, "to": "/k/part", "active": true],
                ["label": "Build", "count": 6, "to": "/_open/issue/build", "active": false],
            ]]],
            Lines.list([]),
        ]))
        shell = ShellViewModel(h.state)
        XCTAssertEqual(shell.tabs.last?.count, 6)
        XCTAssertEqual(shell.tabs.last?.groups.first?.count, 6)
    }

}
