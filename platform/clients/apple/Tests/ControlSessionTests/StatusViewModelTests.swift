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
}
