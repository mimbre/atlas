/// Where the app's update stands, and what the sidebar's foot says about it (`statusText`).
/// Every text says what is true now and what happens next or what to do (UC-Atlas-47).
public enum UpdateStatus: Sendable, Equatable {
    /// Not asked yet, or the newest release is this app: nothing to say.
    case quiet
    /// The app is no release (`swift run`, a local bundle): it does not update itself.
    case notRelease
    /// Downloading, verifying and putting the release in place.
    case updating(AppRelease)
    /// A release is there, but a form or confirm is open: it is taken once that closes.
    case deferred(AppRelease)
    /// Control speaks a newer contract, and the release for it is not published yet.
    case waiting(newest: AppRelease, control: String)
    /// The feed gave no release, and why.
    case unreachable(FeedProblem)
    /// The release could not be taken, and why; this app is as it was.
    case failed(AppRelease, reason: String)
    /// The release is in place, but could not be started, and why.
    case notStarted(AppRelease, reason: String)

    public enum Tone: String, Sendable { case info, pending, error }

    /// How often the app asks the feed while it runs, and while Control speaks a newer contract.
    public static let checkMinutes = 10
    public static let newerControlCheckMinutes = 1

    /// The sidebar's foot's line; nil when there is nothing to say.
    public func statusText(installed: InstalledApp?) -> (text: String, tone: Tone)? {
        switch self {
        case .quiet, .notRelease:
            return nil
        case .waiting(_, let control):
            return ("Control speaks contract \(control); its release of this app is still being published. \(Self.this(installed).capitalizedFirst) checks every minute and updates itself.", .info)
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
