import AtlasControlKit
import ControlSession
import Foundation

/// A connection the test plays Control on: it sees what the session sent and says when
/// the connection is ready, what arrives and when it drops.
@MainActor
final class FakeConnection: LineConnection {
    private var events: (@MainActor (ConnectionEvent) -> Void)?
    private(set) var sent: [ControlRequest] = []
    private(set) var cancelled = false

    func start(_ events: @escaping @MainActor (ConnectionEvent) -> Void) {
        self.events = events
    }

    func send(_ line: Data) {
        // A request the session sends always decodes; one that does not fails the test.
        sent.append(try! WireLine.decode(ControlRequest.self, from: line))
    }

    func cancel() {
        cancelled = true
    }

    func ready() { events?(.ready) }

    func receive(_ line: Data) { events?(.line(line)) }

    func drop() { events?(.closed) }

    /// What was sent since the last call.
    func take() -> [ControlRequest] {
        defer { taken = sent.count }
        return Array(sent[taken...])
    }

    private var taken = 0
}

/// Hands out fake connections and keeps them, newest last.
@MainActor
final class FakeConnector: LineConnector {
    private(set) var made: [FakeConnection] = []
    private(set) var addresses: [String] = []

    func connection(host: String, port: UInt16) -> any LineConnection {
        let connection = FakeConnection()
        made.append(connection)
        addresses.append("\(host):\(port)")
        return connection
    }

    var last: FakeConnection { made.last! }
}

/// A clock that moves only when the test advances it; due actions run in time order.
@MainActor
final class FakeClock: SessionClock {
    private final class Item: ScheduledAction {
        let at: Double
        let order: Int
        let action: @MainActor () -> Void
        var cancelled = false

        init(at: Double, order: Int, action: @escaping @MainActor () -> Void) {
            self.at = at
            self.order = order
            self.action = action
        }

        func cancel() { cancelled = true }
    }

    private(set) var now: Double = 0
    private var items: [Item] = []
    private var order = 0

    func schedule(after seconds: Double, _ action: @escaping @MainActor () -> Void) -> any ScheduledAction {
        order += 1
        let item = Item(at: now + seconds, order: order, action: action)
        items.append(item)
        return item
    }

    func advance(by seconds: Double) {
        let target = now + seconds
        while let next = items.filter({ !$0.cancelled && $0.at <= target + 1e-9 }).min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            items.removeAll { $0 === next }
            now = max(now, next.at)
            next.action()
        }
        items.removeAll { $0.cancelled }
        now = target
    }
}

/// The steer agent, played by the test: it sees what the session sent and says what the
/// agent writes and when it ends.
@MainActor
final class FakeSteer: SteerConnection {
    private var events: (@MainActor (SteerEvent) -> Void)?
    private(set) var sent: [SteerRequest] = []
    private(set) var stopped = false

    func start(_ events: @escaping @MainActor (SteerEvent) -> Void) { self.events = events }

    func send(_ line: Data) {
        sent.append(try! WireLine.decode(SteerRequest.self, from: line))
    }

    func stop() { stopped = true }

    func say(_ line: Data) { events?(.line(line)) }

    func exit(_ why: String) { events?(.exited(why)) }
}

/// Starts fake agents and keeps them, newest last; `unavailable` says why none starts.
@MainActor
final class FakeSteerConnector: SteerConnector {
    private(set) var made: [FakeSteer] = []
    var unavailable: String?

    func connection(env: String) throws(SteerUnavailable) -> any SteerConnection {
        if let unavailable { throw SteerUnavailable(unavailable) }
        let agent = FakeSteer()
        made.append(agent)
        return agent
    }

    var last: FakeSteer? { made.last }
}
