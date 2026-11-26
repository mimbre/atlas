import AtlasControlKit

/// The status bar, from the session: the connection, the position of the page on screen,
/// how and when it last changed, the last hint, the reconcile interval, the last notice, an
/// `open` that failed, and what is being sent (or opened, or asked) and not answered yet.
public struct StatusViewModel: Sendable, Equatable {
    public var connection: SessionState.Connection
    /// Why the last connection is gone, while it is tried again.
    public var lost: SessionState.Lost?
    public var env: String
    public var position: Int?
    public var lastUpdate: SessionState.Update?
    public var lastHint: SessionState.Update?
    public var reconcileSeconds: Double
    public var notice: NoticeMessage?
    /// The last `open` whose answer did not decode, until the next `open`.
    public var openFailure: SessionState.OpenFailure?
    /// What the user did that is not answered yet ("Sending “Pick up”…"), at once.
    public var pending: String?

    public init(_ state: SessionState) {
        connection = state.connection
        lost = state.lost
        env = state.settings.env
        position = state.pageOnScreen?.position
        lastUpdate = state.lastUpdate
        lastHint = state.lastHint
        reconcileSeconds = state.settings.reconcileSeconds
        notice = state.notice
        openFailure = state.openFailure
        pending = state.pending?.text
    }

    public var isConnected: Bool { connection == .connected }

    /// How the status bar marks the connection.
    public enum Mark: Sendable, Equatable { case connected, connecting, notConnected }

    public var mark: Mark {
        switch connection {
        case .connected: .connected
        case .ended: .notConnected
        case .retrying: .notConnected
        case .idle, .connecting, .handshake: lost == nil ? .connecting : .notConnected
        }
    }

    /// The connection in plain words, compact: connected, or not with why and what happens
    /// next, as the app knows it (the TUI's status line says the same). A session Control
    /// closed as too old is worded by the app's update (`closedTooOld`, given Control's
    /// contract): what each side speaks and what to do, also for a local build.
    public func text(ownContract: String = Contract.version, closedTooOld: (String) -> String) -> String {
        let retries = "retries every \(SessionState.retrySeconds.formatted()) s"
        switch connection {
        case .connected:
            return "connected"
        case .ended(.bye(let text)):
            return "not connected · \(text)"
        case .ended(.tooOld(let control, _)):
            return "not connected · \(closedTooOld(control))"
        case .ended(.incompatible(let welcome)):
            if welcome.env == env, welcome.surface == "console", Self.older(welcome.spec, than: ownContract) {
                return "not connected · this app is newer than \(env) (\(ownContract) vs \(welcome.spec)); open it again once \(env) is updated"
            }
            return "not connected · Control \(welcome.env) speaks contract \(welcome.spec); this app implements \(ownContract) for \(env)"
        case .ended(.unreadableWelcome(let reason)):
            return "not connected · Control's welcome could not be read (\(reason)); this app speaks contract \(ownContract)"
        case .ended(.stopped):
            return "stopped"
        case .idle, .connecting, .handshake, .retrying:
            switch lost {
            case nil: return "connecting to Control…"
            case .unreachable: return "not connected · Control cannot be reached; connects by itself once it answers · \(retries)"
            case .silent: return "not connected · Control is down or restarting; connects once it answers · \(retries)"
            }
        }
    }

    /// Whether contract version `spec` (x.y.z) is older than `own`.
    static func older(_ spec: String, than own: String) -> Bool {
        let parts = { (text: String) in text.split(separator: ".").map { Int($0) ?? 0 } }
        let theirs = parts(spec), ours = parts(own)
        guard theirs.count == 3, ours.count == 3 else { return false }
        return theirs.lexicographicallyPrecedes(ours)
    }
}
