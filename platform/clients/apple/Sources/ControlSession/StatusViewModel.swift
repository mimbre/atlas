import AtlasControlKit

/// The shell's state for the sidebar's foot, from the session: the connection, the position of the page on screen,
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
    /// Connected to a Control that speaks another contract version: which is newer, in
    /// plain words (D-0105: a difference never blocks, it is only said). Nil when the same.
    public var versionWarning: String?

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
        versionWarning = state.connection == .connected
            ? Self.versionWarning(env: state.settings.env, control: state.controlSpec, app: Contract.version)
            : nil
    }

    public var isConnected: Bool { connection == .connected }

    /// How the sidebar's foot marks the connection.
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
    /// next, as the app knows it (the TUI's status line says the same). A contract version
    /// never ends the session (D-0105): `versionWarning` says a difference.
    public func text(ownContract: String = Contract.version) -> String {
        let retries = "retries every \(SessionState.retrySeconds.formatted()) s"
        switch connection {
        case .connected:
            return "connected"
        case .ended(.bye(let text)):
            return "not connected · \(text)"
        case .ended(.incompatible(let welcome)):
            return "not connected · Control's welcome is for \(welcome.env ?? "another environment") (surface \(welcome.surface ?? "none")); this app is for \(env), surface console"
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

    /// "prod is newer (0.33 vs 0.32); some parts may look plain" when Control is newer,
    /// "this app is newer than prod (0.33 vs 0.32)" when the app is; nil when they match
    /// (or Control named no version).
    static func versionWarning(env: String, control: String?, app: String) -> String? {
        guard let control, control != app else { return nil }
        let theirs = short(control), ours = short(app)
        if newer(control, than: app) {
            return "\(env) is newer (\(theirs) vs \(ours)); some parts may look plain"
        }
        return "this app is newer than \(env) (\(ours) vs \(theirs))"
    }

    /// A version without a ".0" patch: 0.33.0 → 0.33.
    static func short(_ version: String) -> String {
        version.split(separator: ".").count == 3 && version.hasSuffix(".0") ? String(version.dropLast(2)) : version
    }

    /// Whether `a` is a later version than `b`, part by number (a missing part is 0).
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
