import AtlasControlKit

/// The status bar, from the session: the connection, the position of the page on screen,
/// how and when it last changed, the last hint, the reconcile interval, the last notice and
/// an `open` that failed.
public struct StatusViewModel: Sendable, Equatable {
    public var connection: SessionState.Connection
    public var position: Int?
    public var lastUpdate: SessionState.Update?
    public var lastHint: SessionState.Update?
    public var reconcileSeconds: Double
    public var notice: NoticeMessage?
    /// The last `open` whose answer did not decode, until the next `open`.
    public var openFailure: SessionState.OpenFailure?

    public init(_ state: SessionState) {
        connection = state.connection
        position = state.pageOnScreen?.position
        lastUpdate = state.lastUpdate
        lastHint = state.lastHint
        reconcileSeconds = state.settings.reconcileSeconds
        notice = state.notice
        openFailure = state.openFailure
    }

    public var isConnected: Bool { connection == .connected }
}
