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

    public init(_ state: SessionState) {
        connection = state.connection
        position = state.pageOnScreen?.position
        lastUpdate = state.lastUpdate
        lastHint = state.lastHint
        reconcileSeconds = state.settings.reconcileSeconds
        notice = state.notice
        openFailure = state.openFailure
        pending = state.pending?.text
    }

    public var isConnected: Bool { connection == .connected }
}
