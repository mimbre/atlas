#if canImport(Network)
import Foundation
import Network

/// `LineConnection` on Network.framework (`NWConnection`, `.tcp`), the same on macOS and
/// iOS. Incoming bytes are framed into lines (`LineFramer`); events reach the main actor
/// in order. A connection that cannot be made within its timeout, fails, ends, or gets a
/// line over the limit reports `closed` once.
public final class NetworkLineConnection: LineConnection {
    private let core: Core

    public init(host: String, port: UInt16, connectTimeout: Int = 2) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = connectTimeout
        tcp.noDelay = true
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: NWParameters(tls: nil, tcp: tcp))
        core = Core(connection: connection)
    }

    public func start(_ events: @escaping @MainActor (ConnectionEvent) -> Void) {
        core.start(events)
    }

    public func send(_ line: Data) {
        core.send(line)
    }

    public func cancel() {
        core.cancel()
    }

    /// Everything that runs on the connection's queue; its state is touched only there.
    private final class Core: @unchecked Sendable {
        let connection: NWConnection
        let queue = DispatchQueue(label: "ControlSession.NetworkLineConnection")
        var framer = LineFramer()
        var deliver: (@MainActor (ConnectionEvent) -> Void)?
        var closed = false
        var cancelled = false

        init(connection: NWConnection) {
            self.connection = connection
        }

        func start(_ events: @escaping @MainActor (ConnectionEvent) -> Void) {
            queue.async { [self] in
                deliver = events
                connection.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        report(.ready)
                        receive()
                    case .waiting, .failed:
                        // Not reachable now: the session retries on its own clock.
                        close()
                    case .cancelled:
                        close()
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }

        func send(_ line: Data) {
            queue.async { [self] in
                guard !closed else { return }
                connection.send(content: line, completion: .contentProcessed { [self] error in
                    if error != nil { close() }
                })
            }
        }

        func cancel() {
            queue.async { [self] in
                cancelled = true
                close()
            }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
                if let data, !data.isEmpty {
                    do {
                        for line in try framer.append(data) { report(.line(line)) }
                    } catch {
                        close()
                        return
                    }
                }
                if complete || error != nil {
                    close()
                } else if !closed {
                    receive()
                }
            }
        }

        // Called on `queue`.
        private func close() {
            guard !closed else { return }
            closed = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            report(.closed)
        }

        // Called on `queue`; after a cancel nothing is reported.
        private func report(_ event: ConnectionEvent) {
            guard !cancelled, let deliver else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { deliver(event) }
            }
        }
    }
}

/// Makes `NetworkLineConnection`s.
public final class NetworkLineConnector: LineConnector {
    public init() {}

    public func connection(host: String, port: UInt16) -> any LineConnection {
        NetworkLineConnection(host: host, port: port)
    }
}
#endif
