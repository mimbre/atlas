/// What to do after asking the feed (IS-Atlas-66): the rule alone, no network and no time,
/// so tests cover it.
public enum UpdateDecision: Sendable, Equatable {
    /// The feed names a later release than this app: take it.
    case update(AppRelease)
    /// The feed names this release (or an earlier one), and Control is not newer.
    case current
    /// Control speaks a newer contract, and the newest release is still this one or one
    /// older than Control's: its release is being published; ask again shortly.
    case waiting(newest: AppRelease, control: String)
    /// The feed gave no release.
    case unreachable(FeedProblem)

    /// The decision for `installed`, given what the feed answered and, when Control's
    /// welcome said a newer contract, that contract.
    public static func decide(installed: InstalledApp, feed: Result<AppRelease, FeedProblem>,
                              controlSpec: String?) -> UpdateDecision {
        let newest: AppRelease
        switch feed {
        case .failure(let problem): return .unreachable(problem)
        case .success(let release): newest = release
        }
        // Builds count up with each release; the feed only moves forward, so a later
        // build is a newer release, and the same or an earlier one is not.
        if newest.build > installed.build, newest.revision != installed.revision {
            return .update(newest)
        }
        if let controlSpec { return .waiting(newest: newest, control: controlSpec) }
        return .current
    }
}
