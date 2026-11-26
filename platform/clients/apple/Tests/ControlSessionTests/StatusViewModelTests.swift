import AtlasControlKit
@testable import ControlSession
import XCTest

/// The status bar's model follows the session.
@MainActor
final class StatusViewModelTests: XCTestCase {
    func testTheConnectionAsItGoes() {
        let h = Harness()
        XCTAssertEqual(StatusViewModel(h.state).connection, .idle)
        h.session.start()
        XCTAssertEqual(StatusViewModel(h.state).connection, .connecting)
        h.connection.ready()
        XCTAssertEqual(StatusViewModel(h.state).connection, .handshake)
        h.connection.receive(Lines.welcome())
        XCTAssertTrue(StatusViewModel(h.state).isConnected)
        h.connection.drop()
        XCTAssertEqual(StatusViewModel(h.state).connection, .retrying)
    }

    func testThePositionAndUpdateOfThePageOnScreen() {
        let h = Harness()
        h.connect(start: Lines.page("/k/widget", position: 4, at: "10:00:00"))
        var status = StatusViewModel(h.state)
        XCTAssertEqual(status.position, 4)
        XCTAssertEqual(status.lastUpdate?.reason, .open)
        XCTAssertEqual(status.lastUpdate?.at, "10:00:00")

        h.session.open("/k/widget/W-01")
        h.connection.receive(Lines.page("/k/widget/W-01", position: 6))
        status = StatusViewModel(h.state)
        XCTAssertEqual(status.position, 6)
    }

    func testTheLastHint() {
        let h = Harness()
        h.connect(start: Lines.page("/k/widget", position: 4))
        h.connection.receive(Lines.page("/k/widget", reason: "hint", position: 5, at: "10:00:05"))

        let status = StatusViewModel(h.state)
        XCTAssertEqual(status.lastHint?.position, 5)
        XCTAssertEqual(status.lastHint?.at, "10:00:05")
        XCTAssertEqual(status.lastUpdate?.reason, .hint)
    }

    func testTheReconcileIntervalAndTheLastNotice() {
        let h = Harness(settings: SessionSettings(env: "test", host: "h", port: 1, reconcileSeconds: 7))
        h.connect()
        h.connection.receive(Lines.notice("one", tone: "pending"))
        h.connection.receive(Lines.notice("two", tone: "error"))

        let status = StatusViewModel(h.state)
        XCTAssertEqual(status.reconcileSeconds, 7)
        XCTAssertEqual(status.notice?.tone, "error")
        XCTAssertEqual(status.notice?.text, h.state.notice?.text)
    }

    func testAnOpenThatFailedUntilTheNextOpen() {
        let h = Harness()
        h.connect()
        h.session.open("/k/widget/W-01")
        h.connection.receive(Lines.with(Lines.page("/k/widget/W-01"), "title", 1))
        XCTAssertEqual(StatusViewModel(h.state).openFailure?.path, "/k/widget/W-01")

        h.session.open("/k/widget/W-02")
        XCTAssertNil(StatusViewModel(h.state).openFailure)
    }

    func testAnEndedSession() {
        let h = Harness()
        h.connect()
        h.connection.receive(Lines.bye("closing"))
        XCTAssertEqual(StatusViewModel(h.state).connection, .ended(.bye("closing")))
        XCTAssertFalse(StatusViewModel(h.state).isConnected)
    }

    // Without Control the status bar says why and what happens next in plain words; the
    // window has no message of its own (the TUI's status line says the same).

    private func text(_ h: Harness) -> String {
        StatusViewModel(h.state).text(closedTooOld: { "closed for \($0)" })
    }

    func testConnectingSaysSoUntilSomethingFails() {
        let h = Harness()
        h.session.start()
        XCTAssertEqual(text(h), "connecting to Control…")
        XCTAssertEqual(StatusViewModel(h.state).mark, .connecting)
    }

    func testNothingAnswersWhereControlIs() {
        let h = Harness()
        h.session.start()
        h.connection.drop()
        let said = "not connected · Control cannot be reached; connects by itself once it answers · retries every 2 s"
        XCTAssertEqual(text(h), said)
        XCTAssertEqual(StatusViewModel(h.state).mark, .notConnected)
        // Trying again keeps the why, so the bar does not flicker to "connecting".
        h.clock.advance(by: SessionState.retrySeconds)
        XCTAssertEqual(h.state.connection, .connecting)
        XCTAssertEqual(text(h), said)
    }

    func testControlStopsAnswering() {
        let h = Harness()
        h.connect()
        h.connection.drop()
        XCTAssertEqual(text(h), "not connected · Control is down or restarting; connects once it answers · retries every 2 s")
    }

    func testThisAppNewerThanControl() {
        let h = Harness()
        h.session.start()
        h.connection.ready()
        h.connection.receive(Lines.welcome(spec: "0.1.0"))
        XCTAssertEqual(text(h), "not connected · this app is newer than test (\(Contract.version) vs 0.1.0); open it again once test is updated")
    }

    func testAnotherEnvironmentOrNoConsole() {
        let h = Harness()
        h.session.start()
        h.connection.ready()
        h.connection.receive(Lines.welcome(env: "prod"))
        XCTAssertEqual(text(h), "not connected · Control prod speaks contract \(Contract.version); this app implements \(Contract.version) for test")
    }

    func testClosedByControlSaysItsWordsOrTheUpdates() {
        let h = Harness()
        h.connect()
        h.connection.receive(Lines.bye("This is Control prod; it does not serve \"test\"."))
        XCTAssertEqual(text(h), "not connected · This is Control prod; it does not serve \"test\".")

        let old = Harness()
        old.connect()
        old.connection.receive(Lines.json(["op": "bye", "text": "too old", "reason": "too_old", "spec": "9.0.0"]))
        XCTAssertEqual(text(old), "not connected · closed for 9.0.0")
    }

    func testWelcomedAgainTheStateGoes() {
        let h = Harness()
        h.connect()
        h.connection.drop()
        h.clock.advance(by: SessionState.retrySeconds)
        h.connect()
        XCTAssertNil(h.state.lost)
        XCTAssertEqual(text(h), "connected")
        XCTAssertEqual(StatusViewModel(h.state).mark, .connected)
    }
}
