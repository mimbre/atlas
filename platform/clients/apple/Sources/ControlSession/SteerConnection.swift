import Foundation

/// What the steer agent's process says: a line it wrote (one JSON message), or that it
/// ended, and why.
public enum SteerEvent: Sendable, Equatable {
    case line(Data)
    case exited(String)
}

/// The steer agent behind `agent:<intent>` actions (`atlas steer --env <env>`,
/// `AtlasAgent.Steer`): JSON lines to it and from it, as the TUI talks to it. Injected, so
/// tests play the agent.
@MainActor
public protocol SteerConnection: AnyObject {
    /// Start it; `events` gets its lines and its end, on the main actor.
    func start(_ events: @escaping @MainActor (SteerEvent) -> Void)
    /// Send one line (with its newline).
    func send(_ line: Data)
    /// Stop it; it reports nothing after.
    func stop()
}

/// Why the agent could not be started, in words for the status bar.
public struct SteerUnavailable: Error, Sendable, Equatable {
    public var why: String
    public init(_ why: String) { self.why = why }
}

/// Starts the agent for an environment, when it is first needed.
@MainActor
public protocol SteerConnector {
    func connection(env: String) throws(SteerUnavailable) -> any SteerConnection
}
