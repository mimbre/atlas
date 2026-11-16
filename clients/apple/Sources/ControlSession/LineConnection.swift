import Foundation

/// What a connection reports: it is ready, a line arrived (without its newline), or it
/// closed. After `closed` it reports nothing more.
public enum ConnectionEvent: Sendable, Equatable {
    case ready
    case line(Data)
    case closed
}

/// One TCP connection carrying JSON lines. `start` delivers its events on the main actor,
/// in order; `send` writes one line (with its newline); `cancel` closes it, after which
/// it reports nothing.
@MainActor
public protocol LineConnection: AnyObject {
    func start(_ events: @escaping @MainActor (ConnectionEvent) -> Void)
    func send(_ line: Data)
    func cancel()
}

/// Makes connections to an address: the real one on Network.framework, a fake in tests.
@MainActor
public protocol LineConnector: AnyObject {
    func connection(host: String, port: UInt16) -> any LineConnection
}
