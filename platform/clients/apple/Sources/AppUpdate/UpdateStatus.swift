/// Where the app's update stands, and what the app says about it: in the status bar
/// (`statusText`) and, when Control closed it as too old, in place of Control's bare
/// "too old" (`closedText`). Every text says what is true now and what happens next or
/// what to do (UC-Atlas-47).
public enum UpdateStatus: Sendable, Equatable {
    /// Not asked yet, or the newest release is this app: nothing to say.
    case quiet
    /// The app is no release (`swift run`, a local bundle): it does not update itself.
    case notRelease
    /// Downloading, verifying and putting the release in place.
    case updating(AppRelease)
    /// A release is there, but a form or confirm is open: it is taken once that closes.
    case deferred(AppRelease)
    /// Closed as too old, and the release for Control's contract is not published yet.
    case waiting(newest: AppRelease, control: String)
    /// The feed gave no release, and why.
    case unreachable(FeedProblem)
    /// The release could not be taken, and why; this app is as it was.
    case failed(AppRelease, reason: String)
    /// The release is in place, but could not be started, and why.
    case notStarted(AppRelease, reason: String)

    public enum Tone: String, Sendable { case info, pending, error }

    /// How often the app asks the feed while it runs, and while Control keeps it closed.
    public static let checkMinutes = 10
    public static let closedCheckMinutes = 1

    /// The status bar's line; nil when there is nothing to say.
    public func statusText(installed: InstalledApp?) -> (text: String, tone: Tone)? {
        switch self {
        case .quiet, .notRelease, .waiting:
            return nil
        case .updating(let release):
            return ("Updating to \(short(release.revision))…", .pending)
        case .deferred(let release):
            return ("\(short(release.revision)) is released; this app takes it once this form or confirm is closed.", .pending)
        case .unreachable(let problem):
            return ("Could not check for a newer app (\(Self.reason(problem))); \(Self.this(installed)) checks again in \(Self.checkMinutes) minutes.", .info)
        case .failed(let release, let reason):
            return ("Could not update to \(short(release.revision)): \(reason). \(Self.this(installed).capitalizedFirst) keeps running and tries again in \(Self.checkMinutes) minutes; or install it by hand from \(release.url.absoluteString).", .error)
        case .notStarted(let release, let reason):
            return ("Updated to \(short(release.revision)), but it could not be started (\(reason)): quit this app and open Atlas Console again.", .error)
        }
    }

    /// What the app says when Control closed it as too old: what each side speaks, where
    /// its update stands and what to do. Never Control's bare text alone.
    public func closedText(installed: InstalledApp?, env: String, control: String, ownContract: String) -> String {
        let said = "Control \(env) speaks contract \(control); \(Self.this(installed)) speaks \(ownContract)."
        switch self {
        case .notRelease:
            return "\(said) It is a local build and does not update itself: quit it, and build AtlasMac again from master or install the release (docs/guides/prod.md, \"The Mac app\")."
        case .quiet:
            return "\(said) Looking for a newer release…"
        case .updating(let release), .deferred(let release):
            return "\(said) Updating to \(short(release.revision))…"
        case .waiting(let newest, _):
            let newestSays = installed?.revision == newest.revision
                ? "It is the newest release published"
                : "The newest release published (\(short(newest.revision))) speaks \(newest.contract)"
            return "\(said) \(newestSays); the release of Control's build is still being published. This app checks every minute and updates itself."
        case .unreachable(let problem):
            return "\(said) The release feed could not be reached (\(Self.reason(problem))); this app tries again every minute and updates itself once it can."
        case .failed(let release, let reason):
            return "\(said) Updating to \(short(release.revision)) failed: \(reason). Quit this app and install it by hand from \(release.url.absoluteString); this app tries again every minute."
        case .notStarted(let release, let reason):
            return "\(said) Updated to \(short(release.revision)), but it could not be started (\(reason)): quit this app and open Atlas Console again."
        }
    }

    static func this(_ installed: InstalledApp?) -> String {
        installed.map { "this app (\(short($0.revision)))" } ?? "this app"
    }

    static func reason(_ problem: FeedProblem) -> String {
        switch problem {
        case .unreachable(let why): why
        case .unreadable: "the feed is not one this app reads"
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
