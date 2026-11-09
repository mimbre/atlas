import AtlasControlKit
@testable import ControlSession
import XCTest

/// `SessionState` on its own, input by input: a line of a known op that does not decode
/// still answers what the session waits for (the TUI goes by `op` alone), and only an
/// `open` answers an `open`.
final class SessionStateTests: XCTestCase {
    private let settings = SessionSettings(env: "test", host: "127.0.0.1", port: 7001)

    /// Connected, at the handshake: hello sent, no welcome yet.
    private func handshake() -> SessionState {
        var state = SessionState(settings: settings)
        _ = state.handle(.start)
        _ = state.handle(.ready)
        return state
    }

    /// Welcomed and hello's page consumed: the first boot is on the wire.
    private func booting() -> SessionState {
        var state = handshake()
        _ = state.handle(.line(Lines.welcome()))
        _ = state.handle(.line(Lines.page("/", title: "Home")))
        return state
    }

    /// Showing the first tab's index page, nothing on its way.
    private func ready() -> SessionState {
        var state = booting()
        _ = state.handle(.line(Lines.boot()))
        _ = state.handle(.line(Lines.page("/k/widget")))
        return state
    }

    // MARK: Welcome

    func testAWelcomeThatDoesNotDecodeEndsTheSessionWithoutRetrying() {
        var state = handshake()

        let effects = state.handle(.line(Lines.with(Lines.welcome(), "env", 1)))

        XCTAssertEqual(state.connection, .ended(.unreadableWelcome(.wrongType(path: ["env"]))))
        XCTAssertEqual(effects, [.close])
        XCTAssertEqual(state.handle(.handshakeTimedOut), [])
        XCTAssertEqual(state.handle(.retry), [])
    }

    // MARK: Boot

    func testABootReplyThatDoesNotDecodeFailsTheBootAndKeepsTheConnectionAndTheShell() {
        for reply in [Lines.with(Lines.boot(title: "Other"), "tabs", "none"), Lines.json(["op": "boot", "error": 1])] {
            var state = ready()
            let shell = state.shell
            let serial = state.bootSerial
            XCTAssertEqual(state.handle(.tick), [.send(.boot(BootRequest(to: "/k/widget"))), .bootDeadline(serial: serial + 1), .send(.refresh)])

            XCTAssertEqual(state.handle(.line(reply)), [])

            guard case .unreadable = state.bootFailure else { return XCTFail("boot failure: \(String(describing: state.bootFailure))") }
            XCTAssertTrue(state.shellStale)
            XCTAssertEqual(state.shell, shell)
            XCTAssertEqual(state.connection, .connected)
            // The deadline of the boot answered is no longer one.
            XCTAssertEqual(state.handle(.bootTimedOut(serial: serial + 1)), [])
            XCTAssertEqual(state.connection, .connected)
        }
    }

    func testAFirstBootThatDoesNotDecodeIsAskedAgainOnTheNextInterval() {
        var state = booting()

        XCTAssertEqual(state.handle(.line(Lines.with(Lines.boot(), "tabs", "none"))), [])
        XCTAssertEqual(state.bootFailure, .unreadable(.wrongType(path: ["tabs"])))
        XCTAssertEqual(state.connection, .connected)

        let serial = state.bootSerial
        XCTAssertEqual(state.handle(.tick), [.send(.boot(BootRequest(to: nil))), .bootDeadline(serial: serial + 1)])
        XCTAssertEqual(state.handle(.line(Lines.boot())), [.send(.open(OpenRequest(to: "/k/widget")))])
        XCTAssertNil(state.bootFailure)
    }

    // MARK: Open

    func testAnOpenAnsweredByAPageThatDoesNotDecodeEndsThatOpenAsAFailure() {
        var state = ready()
        XCTAssertEqual(state.handle(.open(to: "/k/widget/W-01")), [.send(.open(OpenRequest(to: "/k/widget/W-01")))])

        let effects = state.handle(.line(Lines.with(Lines.page("/k/widget/W-01"), "title", 1)))

        XCTAssertEqual(effects, [])
        XCTAssertEqual(state.openFailure, SessionState.OpenFailure(path: "/k/widget/W-01", reason: .wrongType(path: ["title"])))
        XCTAssertNil(state.expected)
        XCTAssertNil(state.opened)
        XCTAssertEqual(state.index?.path, "/k/widget")
        XCTAssertEqual(state.connection, .connected)

        // Nothing waits any more: the interval boots and refreshes, and the next open goes out.
        XCTAssertEqual(state.handle(.tick).filter { $0 == .send(.refresh) }, [.send(.refresh)])
        XCTAssertEqual(state.handle(.open(to: "/k/widget/W-02")), [.send(.open(OpenRequest(to: "/k/widget/W-02")))])
        XCTAssertNil(state.openFailure)
    }

    func testAnUnreadableAnswerToAnOpenNoLongerWantedAsksForTheNewestWish() {
        var state = ready()
        _ = state.handle(.open(to: "/k/widget/W-01"))
        XCTAssertEqual(state.handle(.open(to: "/k/widget/W-02")), [])

        let effects = state.handle(.line(Lines.with(Lines.page("/k/widget/W-01"), "title", 1)))

        XCTAssertEqual(effects, [.send(.open(OpenRequest(to: "/k/widget/W-02")))])
        XCTAssertNil(state.openFailure)
        XCTAssertEqual(state.handle(.line(Lines.page("/k/widget/W-02"))), [])
        XCTAssertEqual(state.opened?.path, "/k/widget/W-02")
    }

    func testTheStartPageThatDoesNotDecodeLeavesTheSessionReady() {
        var state = booting()
        _ = state.handle(.line(Lines.boot()))

        XCTAssertEqual(state.handle(.line(Lines.with(Lines.page("/k/widget"), "title", 1))), [])

        XCTAssertEqual(state.openFailure?.path, "/k/widget")
        XCTAssertNil(state.expected)
        XCTAssertEqual(state.handle(.selectTab(id: "parts")), [.send(.open(OpenRequest(to: "/k/part")))])
    }

    func testHellosPageIsConsumedEvenWhenItDoesNotDecode() {
        var state = handshake()
        _ = state.handle(.line(Lines.welcome()))

        let effects = state.handle(.line(Lines.with(Lines.page("/", title: "Home"), "title", 1)))

        XCTAssertEqual(effects, [.send(.boot(BootRequest(to: nil))), .bootDeadline(serial: state.bootSerial)])
        XCTAssertNil(state.openFailure)
    }

    func testAPushThatDoesNotDecodeIsSkipped() {
        var state = ready()
        let before = state

        XCTAssertEqual(state.handle(.line(Lines.with(Lines.page("/k/widget", reason: "hint", position: 9), "title", 1))), [])

        XCTAssertEqual(state, before)
    }

    // MARK: Only an open answers an open

    func testCurrentContractConfirmationWithoutAnOfferStillSuppressesRefresh() {
        var state = ready()
        _ = state.handle(.open(to: "/k/widget/W-01"))
        let confirm: [String: Any] = [
            "id": "confirm", "type": "confirm", "props": [
                "title": "Unavailable", "text": "No offer is available",
                "cancel_to": "/k/widget/W-01",
            ],
        ]
        _ = state.handle(.line(Lines.page("/k/widget/W-01", blocks: [confirm])))

        XCTAssertTrue(state.isEditing)
        let shown = state.pageOnScreen
        let effects = state.handle(.tick)
        XCTAssertFalse(effects.contains(.send(.refresh)))
        XCTAssertEqual(state.handle(.selectTab(id: "parts")), [])
        XCTAssertEqual(state.pageOnScreen, shown)
    }

    func testWhileAnOpenIsOnTheWireOtherPagesWaitAndDoNotAnswerIt() {
        var state = ready()
        _ = state.handle(.open(to: "/k/widget/W-01"))

        for reason in ["stored", "refused", "hint", "pending", "reconcile"] {
            XCTAssertEqual(state.handle(.line(Lines.page("/k/widget/W-01", reason: reason, position: 2))), [])
            XCTAssertEqual(state.handle(.line(Lines.page("/k/widget", reason: reason, position: 2, title: "Pushed"))), [])
        }

        XCTAssertNil(state.opened)
        XCTAssertEqual(state.index?.title, "Page")
        XCTAssertEqual(state.expected, "/k/widget/W-01")
        XCTAssertEqual(state.handle(.line(Lines.page("/k/widget/W-01"))), [])
        XCTAssertEqual(state.opened?.path, "/k/widget/W-01")
        XCTAssertNil(state.expected)
    }

    // MARK: Submit

    func testASubmittedCallIsSentAsItIsWithItsValues() {
        var state = ready()
        let call = CallModel(endpoint: "answer", params: ["kind": "decision", "key": "D-7", "answer": "decline"])

        XCTAssertEqual(state.handle(.submit(call: call, values: ["note": "Not now."])), [
            .send(.submit(SubmitRequest(endpoint: "answer", params: ["kind": "decision", "key": "D-7", "answer": "decline"],
                                        values: ["note": "Not now."]))),
        ])
    }

    func testNothingIsSubmittedBeforeTheSessionShowsPages() {
        var state = booting()

        XCTAssertEqual(state.handle(.submit(call: CallModel(endpoint: "answer"), values: [:])), [])
    }

    func testNoSubmitIsSentWhileAPageIsOnItsWay() {
        var state = ready()
        let call = CallModel(endpoint: "answer", params: ["kind": "decision", "key": "D-7", "answer": "adopt"])
        _ = state.handle(.open(to: "/k/decision/D-7"))

        XCTAssertEqual(state.handle(.submit(call: call, values: [:])), [])
        XCTAssertFalse(state.submitting)

        _ = state.handle(.line(Lines.page("/k/decision/D-7")))
        XCTAssertEqual(state.handle(.submit(call: call, values: [:])), [
            .send(.submit(SubmitRequest(endpoint: "answer", params: call.params!, values: [:]))),
        ])
    }

    func testARepeatSubmitWaitsUntilControlRepliesStoredOrRefused() {
        for reply in ["stored", "refused"] {
            var state = ready()
            let call = CallModel(endpoint: "answer", params: ["kind": "decision", "key": "D-7", "answer": "adopt"])
            let sent: [SessionState.Effect] = [.send(.submit(SubmitRequest(endpoint: "answer", params: call.params!, values: [:])))]

            XCTAssertEqual(state.handle(.submit(call: call, values: [:])), sent)
            XCTAssertEqual(state.handle(.submit(call: call, values: [:])), [], reply)
            // A page Control pushes is not the reply.
            _ = state.handle(.line(Lines.page("/k/widget", reason: "reconcile", position: 3)))
            XCTAssertEqual(state.handle(.submit(call: call, values: [:])), [], reply)

            _ = state.handle(.line(Lines.page("/k/widget", reason: reply, position: 4)))
            XCTAssertEqual(state.index?.path, "/k/widget", reply)
            XCTAssertEqual(state.handle(.submit(call: call, values: [:])), sent, reply)
        }
    }

    func testASubmitAwaitingItsReplyEndsWithAPageOpenedOrTheConnection() {
        let call = CallModel(endpoint: "answer", params: ["answer": "adopt"])

        var opened = ready()
        _ = opened.handle(.submit(call: call, values: [:]))
        _ = opened.handle(.open(to: "/k/widget/W-01"))
        _ = opened.handle(.line(Lines.page("/k/widget/W-01")))
        XCTAssertFalse(opened.submitting)

        var dropped = ready()
        _ = dropped.handle(.submit(call: call, values: [:]))
        _ = dropped.handle(.closed)
        XCTAssertFalse(dropped.submitting)
    }
}
