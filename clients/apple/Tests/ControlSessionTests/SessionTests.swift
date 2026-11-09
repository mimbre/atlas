import AtlasControlKit
@testable import ControlSession
import XCTest

/// The session against a fake connection and clock (S1's acceptance): the handshake, the
/// end by bye or an incompatible welcome, reconnecting every 2 s, refresh on the interval
/// and the draft, one open on the wire.
@MainActor
final class SessionTests: XCTestCase {
    // MARK: Welcome, then the first page

    func testHelloSaysTheEnvironmentTheContractVersionAndTheConsoleSurface() {
        let h = Harness()
        h.session.start()
        XCTAssertEqual(h.connector.addresses, ["127.0.0.1:7001"])
        XCTAssertEqual(h.state.connection, .connecting)

        h.connection.ready()

        XCTAssertEqual(h.connection.take(), [
            .hello(HelloRequest(client: "tui", env: "test", spec: Contract.version, surface: "console"))
        ])
        XCTAssertEqual(h.state.connection, .handshake)
    }

    func testWelcomeThenHellosPageThenBootThenTheStartPage() {
        let h = Harness()
        h.session.start()
        h.connection.ready()
        _ = h.connection.take()

        h.connection.receive(Lines.welcome())
        XCTAssertEqual(h.state.connection, .connected)
        XCTAssertEqual(h.connection.take(), [])

        // The page hello brings is consumed, not shown; the shell comes from boot.
        h.connection.receive(Lines.page("/", title: "Home"))
        XCTAssertNil(h.state.pageOnScreen)
        XCTAssertEqual(h.connection.take(), [.boot(BootRequest(to: nil))])

        h.connection.receive(Lines.boot(initialTo: "/k/widget", activeTab: "widgets"))
        XCTAssertEqual(h.connection.take(), [.open(OpenRequest(to: "/k/widget"))])

        h.connection.receive(Lines.page("/k/widget", position: 3))
        XCTAssertEqual(h.state.index?.path, "/k/widget")
        XCTAssertNil(h.state.opened)
        XCTAssertEqual(h.state.activeTab, "widgets")
        XCTAssertFalse(h.state.shellStale)
    }

    func testAPageBeforeWelcomeIsNotShown() {
        let h = Harness()
        h.session.start()
        h.connection.ready()
        h.connection.receive(Lines.page("/k/widget"))
        XCTAssertNil(h.state.pageOnScreen)
        XCTAssertEqual(h.state.connection, .handshake)
    }

    func testAnOpenedRowGoesToTheRightColumnAndTheIndexStays() {
        let h = Harness()
        h.connect()

        h.session.open("/k/widget/W-01")
        XCTAssertEqual(h.connection.take(), [.open(OpenRequest(to: "/k/widget/W-01"))])
        h.connection.receive(Lines.page("/k/widget/W-01"))

        XCTAssertEqual(h.state.index?.path, "/k/widget")
        XCTAssertEqual(h.state.opened?.path, "/k/widget/W-01")
        XCTAssertEqual(h.state.pageOnScreen?.path, "/k/widget/W-01")
    }

    func testOnlyPathsOfTheContractsPagesAreOpened() {
        let h = Harness()
        h.connect()
        h.session.open("not a path")
        XCTAssertEqual(h.connection.take(), [])
    }

    // MARK: Bye and an incompatible welcome end the session

    func testByeEndsTheSessionWithItsTextAndIsNotRetried() {
        let h = Harness()
        h.session.start()
        h.connection.ready()
        let text = "This client implements contract 0.1.0; Control test speaks 9.9.9. It is too old."

        h.connection.receive(Lines.bye(text))

        XCTAssertEqual(h.state.connection, .ended(.bye(text)))
        XCTAssertTrue(h.connection.cancelled)
        h.clock.advance(by: 60)
        XCTAssertEqual(h.connector.made.count, 1)
    }

    func testByeForAnotherEnvironmentEndsTheSession() {
        let h = Harness(settings: SessionSettings(env: "prod", host: "127.0.0.1", port: 7001))
        h.session.start()
        h.connection.ready()
        let text = "This is Control test; it does not serve \"prod\"."

        h.connection.receive(Lines.bye(text))

        XCTAssertEqual(h.state.connection, .ended(.bye(text)))
        h.clock.advance(by: 60)
        XCTAssertEqual(h.connector.made.count, 1)
    }

    func testAWelcomeWithAnotherVersionEndsTheSession() {
        let h = Harness()
        h.session.start()
        h.connection.ready()
        h.connection.receive(Lines.welcome(spec: "0.0.1"))

        guard case .ended(.incompatible(let welcome)) = h.state.connection else {
            return XCTFail("not ended: \(h.state.connection)")
        }
        XCTAssertEqual(welcome.spec, "0.0.1")
        XCTAssertTrue(h.connection.cancelled)
        h.clock.advance(by: 60)
        XCTAssertEqual(h.connector.made.count, 1)
    }

    func testAWelcomeForAnotherEnvironmentOrWithoutTheConsoleSurfaceEndsTheSession() {
        for welcome in [Lines.welcome(env: "prod"), Lines.welcome(surface: nil)] {
            let h = Harness()
            h.session.start()
            h.connection.ready()
            h.connection.receive(welcome)
            guard case .ended(.incompatible) = h.state.connection else {
                return XCTFail("not ended: \(h.state.connection)")
            }
        }
    }

    func testAByeAfterPagesEndsTheSessionAndKeepsThePages() {
        let h = Harness()
        h.connect()
        h.connection.receive(Lines.bye("Control closes."))
        XCTAssertEqual(h.state.connection, .ended(.bye("Control closes.")))
        XCTAssertEqual(h.state.index?.path, "/k/widget")
    }

    // MARK: A dropped connection retries every 2 s and reopens the page

    func testADroppedConnectionRetriesEveryTwoSecondsUntilItIsBack() {
        let h = Harness()
        h.connect()

        h.connection.drop()
        XCTAssertEqual(h.state.connection, .retrying)
        XCTAssertTrue(h.state.shellStale)
        XCTAssertEqual(h.state.index?.path, "/k/widget", "the page stays on screen")

        h.clock.advance(by: 1.9)
        XCTAssertEqual(h.connector.made.count, 1)
        h.clock.advance(by: 0.1)
        XCTAssertEqual(h.connector.made.count, 2)
        XCTAssertEqual(h.state.connection, .connecting)

        // Control is still away: the attempt fails, and the next is 2 s later.
        h.connection.drop()
        h.clock.advance(by: 1.9)
        XCTAssertEqual(h.connector.made.count, 2)
        h.clock.advance(by: 0.1)
        XCTAssertEqual(h.connector.made.count, 3)
    }

    func testOnReturnItSaysHelloBootsForThePageItWasOnAndOpensItAgain() {
        let h = Harness()
        h.connect()
        h.session.open("/k/widget/W-01")
        h.connection.receive(Lines.page("/k/widget/W-01"))
        _ = h.connection.take()

        h.connection.drop()
        h.clock.advance(by: 2)
        h.connection.ready()
        XCTAssertEqual(h.connection.take(), [
            .hello(HelloRequest(client: "tui", env: "test", spec: Contract.version, surface: "console"))
        ])
        h.connection.receive(Lines.welcome())
        h.connection.receive(Lines.page("/", title: "Home"))
        XCTAssertEqual(h.connection.take(), [.boot(BootRequest(to: "/k/widget/W-01"))])

        h.connection.receive(Lines.boot(initialTo: "/k/widget/W-01", activeTab: "widgets"))
        XCTAssertEqual(h.connection.take(), [.open(OpenRequest(to: "/k/widget/W-01"))])

        h.connection.receive(Lines.page("/k/widget/W-01", position: 9))
        XCTAssertEqual(h.state.connection, .connected)
        XCTAssertEqual(h.state.opened?.position, 9)
        XCTAssertEqual(h.state.index?.path, "/k/widget")
        XCTAssertFalse(h.state.shellStale)
    }

    func testEventsOfAConnectionGivenUpAreIgnored() {
        let h = Harness()
        h.connect()
        let old = h.connection
        old.drop()
        h.clock.advance(by: 2)

        old.receive(Lines.notice("late"))
        old.drop()

        XCTAssertNil(h.state.notice)
        XCTAssertEqual(h.state.connection, .connecting)
        XCTAssertEqual(h.connector.made.count, 2)
    }

    func testNoWelcomeWithinTheHandshakeDeadlineClosesAndRetries() {
        let h = Harness()
        h.session.start()
        h.connection.ready()

        h.clock.advance(by: SessionState.handshakeSeconds)

        XCTAssertTrue(h.connection.cancelled)
        XCTAssertEqual(h.state.connection, .retrying)
        h.clock.advance(by: SessionState.retrySeconds)
        XCTAssertEqual(h.connector.made.count, 2)
    }

    func testNoBootReplyWithinItsDeadlineClosesAndRetries() {
        let h = Harness()
        h.session.start()
        h.connection.ready()
        h.connection.receive(Lines.welcome())
        h.connection.receive(Lines.page("/"))

        h.clock.advance(by: SessionState.bootSeconds)

        XCTAssertTrue(h.connection.cancelled)
        XCTAssertEqual(h.state.bootFailure, .timedOut)
        XCTAssertEqual(h.state.connection, .retrying)
    }

    // MARK: Refresh every interval; nothing replaces a draft

    func testEachIntervalItBootsAgainAndSendsRefresh() {
        let h = Harness(settings: SessionSettings(env: "test", host: "127.0.0.1", port: 7001, reconcileSeconds: 5))
        h.connect()

        h.clock.advance(by: 4.9)
        XCTAssertEqual(h.connection.take(), [])
        h.clock.advance(by: 0.1)
        XCTAssertEqual(h.connection.take(), [.boot(BootRequest(to: "/k/widget")), .refresh])
        h.connection.receive(Lines.boot())

        h.clock.advance(by: 5)
        XCTAssertEqual(h.connection.take(), [.boot(BootRequest(to: "/k/widget")), .refresh])
    }

    func testTheIntervalComesFromTheSettings() {
        let h = Harness(settings: SessionSettings(env: "test", host: "127.0.0.1", port: 7001, reconcileSeconds: 2))
        h.connect()
        h.clock.advance(by: 2)
        XCTAssertTrue(h.connection.take().contains(.refresh))
    }

    func testAReconcilePageReplacesThePageOnScreen() {
        let h = Harness()
        h.connect()
        h.clock.advance(by: 5)
        h.connection.receive(Lines.boot())
        h.connection.receive(Lines.page("/k/widget", reason: "reconcile", position: 4, title: "Again"))

        XCTAssertEqual(h.state.index?.title, "Again")
        XCTAssertEqual(h.state.lastUpdate?.reason, .reconcile)
    }

    func testNoRefreshWhileAFormIsBeingEditedAndAPushNeverReplacesTheDraft() {
        let h = Harness()
        h.connect()
        h.session.open("/k/widget/W-01/edit")
        h.connection.receive(Lines.page("/k/widget/W-01/edit", position: 1, blocks: [Lines.form]))
        _ = h.connection.take()
        XCTAssertTrue(h.state.isEditing)

        h.session.edit("title", "Typed")
        h.clock.advance(by: 5)
        XCTAssertFalse(h.connection.take().contains(.refresh))

        h.connection.receive(Lines.page("/k/widget/W-01/edit", reason: "hint", position: 2, blocks: [Lines.form]))
        XCTAssertEqual(h.state.opened?.position, 2)
        XCTAssertEqual(h.state.draft, ["title": "Typed"])
    }

    func testOnReturnWhileEditingItReopensThePageItWasOnAndKeepsTheDraft() {
        let h = Harness()
        h.connect()
        h.session.open("/k/widget/W-01/edit")
        h.connection.receive(Lines.page("/k/widget/W-01/edit", blocks: [Lines.form]))
        h.session.edit("title", "Typed")

        h.connection.drop()
        h.clock.advance(by: 2)
        h.connection.ready()
        h.connection.receive(Lines.welcome())
        h.connection.receive(Lines.page("/"))
        _ = h.connection.take()
        // Boot falls back to the first tab; the draft's page is opened again all the same.
        h.connection.receive(Lines.boot(initialTo: "/k/widget"))

        XCTAssertEqual(h.connection.take(), [.open(OpenRequest(to: "/k/widget/W-01/edit"))])
        h.connection.receive(Lines.page("/k/widget/W-01/edit", blocks: [Lines.form]))
        XCTAssertEqual(h.state.draft, ["title": "Typed"])
    }

    func testLeavingThePageDropsItsDraft() {
        let h = Harness()
        h.connect()
        h.session.open("/k/widget/W-01/edit")
        h.connection.receive(Lines.page("/k/widget/W-01/edit", blocks: [Lines.form]))
        h.session.edit("title", "Typed")

        h.session.open("/k/widget/W-01")
        h.connection.receive(Lines.page("/k/widget/W-01"))

        XCTAssertEqual(h.state.draft, [:])
    }

    func testNoRefreshWhileDisconnected() {
        let h = Harness()
        h.connect()
        h.connection.drop()
        let dropped = h.connection
        h.clock.advance(by: 5)
        XCTAssertFalse(dropped.take().contains(.refresh))
    }

    // MARK: Pages: one open on the wire, pushes where their path is shown

    func testOneOpenOnTheWireAndTheNewestWishWins() {
        let h = Harness()
        h.connect()

        h.session.open("/k/widget/W-01")
        h.session.open("/k/widget/W-02")
        XCTAssertEqual(h.connection.take(), [.open(OpenRequest(to: "/k/widget/W-01"))])

        h.connection.receive(Lines.page("/k/widget/W-01"))
        XCTAssertNil(h.state.opened)
        XCTAssertEqual(h.connection.take(), [.open(OpenRequest(to: "/k/widget/W-02"))])

        h.connection.receive(Lines.page("/k/widget/W-02"))
        XCTAssertEqual(h.state.opened?.path, "/k/widget/W-02")
    }

    func testAHintForAPathNotShownIsNotDrawn() {
        let h = Harness()
        h.connect()
        h.connection.receive(Lines.page("/k/part", reason: "hint", position: 5))
        XCTAssertEqual(h.state.index?.path, "/k/widget")
        XCTAssertNil(h.state.lastHint)
    }

    func testAHintForTheIndexIsDrawnWhileAPageIsOpenedAndAnOlderPageIsNot() {
        let h = Harness()
        h.connect(start: Lines.page("/k/widget", position: 5))
        h.session.open("/k/widget/W-01")
        h.connection.receive(Lines.page("/k/widget/W-01", position: 5))

        h.connection.receive(Lines.page("/k/widget", reason: "hint", position: 7, title: "Newer"))
        XCTAssertEqual(h.state.index?.title, "Newer")
        XCTAssertEqual(h.state.lastHint?.position, 7)

        h.connection.receive(Lines.page("/k/widget", reason: "pending", position: 6, title: "Older"))
        XCTAssertEqual(h.state.index?.title, "Newer")
    }

    func testANoticeIsTheLastNotice() {
        let h = Harness()
        h.connect()
        h.connection.receive(Lines.notice("Stored by Facts (position 1).", tone: "ok"))
        XCTAssertEqual(h.state.notice?.tone, "ok")
    }

    func testLinesItCannotReadAreSkipped() {
        let h = Harness()
        h.connect()
        h.connection.receive(Data("not json".utf8))
        h.connection.receive(Lines.json(["op": "something_new", "x": 1]))
        h.connection.receive(Lines.json(["op": "notice", "tone": 1]))
        XCTAssertEqual(h.state.connection, .connected)
        XCTAssertEqual(h.state.index?.path, "/k/widget")
        XCTAssertNil(h.state.notice)
    }

    func testStopClosesAndNothingFollows() {
        let h = Harness()
        h.connect()
        h.session.stop()
        XCTAssertEqual(h.state.connection, .ended(.stopped))
        XCTAssertTrue(h.connection.cancelled)
        h.clock.advance(by: 30)
        XCTAssertEqual(h.connector.made.count, 1)
        XCTAssertEqual(h.connection.take(), [])
    }
}
