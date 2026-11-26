import AtlasControlKit

/// The status bar, from the session: the connection, the position of the page on screen,
/// how and when it last changed, the last hint, the reconcile interval, the last notice, an
/// `open` that failed, and what is being sent (or opened, or asked) and not answered yet.
public struct StatusViewModel: Sendable, Equatable {
    public var connection: SessionState.Connection
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
