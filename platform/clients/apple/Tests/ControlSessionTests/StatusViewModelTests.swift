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

    func testAnOpenThatFailedUntilTheNextOpen() throws {
        var state = SessionState(settings: SessionSettings(env: "test", host: "127.0.0.1", port: 7001))
        for input: SessionState.Input in [.start, .ready, .line(Lines.welcome()), .line(Lines.page("/")),
                                          .line(Lines.boot()), .line(Lines.page("/k/widget")),
                                          .open(to: "/k/widget/W-01")] {
            _ = state.handle(input)
        }
        // The package gives a page it cannot decode so (every field is optional, D-0105).
        let raw = try JSONDecoder().decode(JSONValue.self, from: Lines.page("/k/widget/W-01"))
        _ = state.receive(.undecodable(raw, .undecodable))
        XCTAssertEqual(StatusViewModel(state).openFailure?.path, "/k/widget/W-01")

        _ = state.handle(.open(to: "/k/widget/W-02"))
        XCTAssertNil(StatusViewModel(state).openFailure)
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
        StatusViewModel(h.state).text()
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

    func testAnotherEnvironmentOrNoConsole() {
        let h = Harness()
        h.session.start()
        h.connection.ready()
        h.connection.receive(Lines.welcome(env: "prod"))
        XCTAssertEqual(text(h), "not connected · Control's welcome is for prod (surface console); this app is for test, surface console")
    }

    func testClosedByControlSaysItsWords() {
        let h = Harness()
        h.connect()
        h.connection.receive(Lines.bye("This is Control prod; it does not serve \"test\"."))
        XCTAssertEqual(text(h), "not connected · This is Control prod; it does not serve \"test\".")
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

    private func welcomed(by spec: String) -> Harness {
        let h = Harness()
        h.session.start()
        h.connection.ready()
        h.connection.receive(Lines.welcome(spec: spec))
        return h
    }

    private var ours: String { StatusViewModel.short(Contract.version) }

    func testANewerControlConnectsAndTheStatusSaysSomePartsMayLookPlain() {
        let h = welcomed(by: "9.9.0")
        XCTAssertTrue(StatusViewModel(h.state).isConnected)
        XCTAssertEqual(StatusViewModel(h.state).versionWarning,
                       "test is newer (9.9 vs \(ours)); some parts may look plain")
    }

    func testAnOlderControlConnectsAndTheStatusSaysThisAppIsNewer() {
        let h = welcomed(by: "0.1.0")
        XCTAssertTrue(StatusViewModel(h.state).isConnected)
        XCTAssertEqual(StatusViewModel(h.state).versionWarning, "this app is newer than test (\(ours) vs 0.1)")
    }

    func testTheSameVersionHasNoWarning() {
        let h = welcomed(by: Contract.version)
        XCTAssertTrue(StatusViewModel(h.state).isConnected)
        XCTAssertNil(StatusViewModel(h.state).versionWarning)
    }

    func testTheWarningComparesVersionsByNumber() {
        XCTAssertEqual(StatusViewModel.versionWarning(env: "prod", control: "0.33.0", app: "0.32.0"),
                       "prod is newer (0.33 vs 0.32); some parts may look plain")
        XCTAssertEqual(StatusViewModel.versionWarning(env: "prod", control: "0.9.1", app: "0.10.0"),
                       "this app is newer than prod (0.10 vs 0.9.1)")
    }
}
