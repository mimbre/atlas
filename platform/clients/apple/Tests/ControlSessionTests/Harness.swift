import AtlasControlKit
@testable import ControlSession
import Foundation

/// A session on a fake connector and clock, and the steps to bring it to a page.
@MainActor
final class Harness {
    let connector = FakeConnector()
    let clock = FakeClock()
    let steer = FakeSteerConnector()
    let session: Session

    init(settings: SessionSettings = SessionSettings(env: "test", host: "127.0.0.1", port: 7001)) {
        session = Session(settings: settings, connector: connector, clock: clock, agent: steer)
    }

    var connection: FakeConnection { connector.last }
    var state: SessionState { session.state }

    /// Start, or on an open connection: ready, welcome, hello's page, `boot` and the page
    /// boot opens. What was sent is taken.
    func connect(boot: Data = Lines.boot(), start: Data = Lines.page("/k/widget")) {
        if connector.made.isEmpty { session.start() }
        connection.ready()
        connection.receive(Lines.welcome())
        connection.receive(Lines.page("/", title: "Home"))
        connection.receive(boot)
        connection.receive(start)
        _ = connection.take()
    }
}
