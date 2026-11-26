import Foundation
import Observation

/// Asks for the newest release (`ReleaseFeed`).
public protocol ReleaseFeed: Sendable {
    func newest(at url: URL) async -> Result<AppRelease, FeedProblem>
}

/// Takes a release: downloads it, verifies it (its digest, its signature by the same
/// developer as this app) and puts it in place of this app; then starts it.
public protocol ReleaseInstaller: Sendable {
    /// Throws `InstallProblem` with a plain reason when the release cannot be taken; the
    /// running app is then left as it was.
    func install(_ release: AppRelease) async throws
    /// Start the app now in place, on `page`, and quit this one; throws when it could not
    /// be started (this one then keeps running).
    @MainActor func relaunch(on page: String?) async throws
}

public struct InstallProblem: Error, Sendable, Equatable {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// The app's update (IS-Atlas-66): it asks the feed when the app starts, every
/// `UpdateStatus.checkMinutes` while it runs, and at once and then every minute once
/// Control's welcome says a newer contract than the app's (D-0105; the app stays
/// connected). A later release is taken when no form or confirm is open (`canTakeNow`),
/// and the app starts again on the page it showed (`page`).
@MainActor
@Observable
public final class Updater {
    public private(set) var status: UpdateStatus
    /// Control's contract, once its welcome said one newer than the app's.
    public private(set) var controlSpec: String?
    public let installed: InstalledApp?

    @ObservationIgnored private let feed: any ReleaseFeed
    @ObservationIgnored private let installer: any ReleaseInstaller
    @ObservationIgnored private let schedule: @MainActor (Double, @escaping @MainActor @Sendable () -> Void) -> Void
    @ObservationIgnored private var checking = false
    /// An ask came while one was on its way: ask again after it.
    @ObservationIgnored private var askAgain = false
    /// Only the latest scheduled ask runs: one chain of asks, however they started.
    @ObservationIgnored private var scheduled = 0
    @ObservationIgnored private var started = false
    /// Whether the release can be taken now: no form or confirm is open.
    @ObservationIgnored public var canTakeNow: @MainActor () -> Bool = { true }
    /// The page the app shows, for the new one to open.
    @ObservationIgnored public var page: @MainActor () -> String? = { nil }

    /// `schedule(seconds, action)` runs `action` once after `seconds`.
    public init(installed: InstalledApp?, feed: any ReleaseFeed, installer: any ReleaseInstaller,
                schedule: @escaping @MainActor (Double, @escaping @MainActor @Sendable () -> Void) -> Void) {
        self.installed = installed
        self.feed = feed
        self.installer = installer
        self.schedule = schedule
        status = installed == nil ? .notRelease : .quiet
    }

    /// The app started: ask now, then every `checkMinutes`.
    public func start() {
        guard !started, installed != nil else { return }
        started = true
        Task { await self.check() }
    }

    /// Control's welcome says `spec`, a newer contract than the app's: ask now, and every
    /// minute until the app is updated.
    public func controlIsNewer(spec: String) {
        let first = controlSpec == nil
        controlSpec = spec
        guard installed != nil, first else { return }
        Task { await self.check() }
    }

    /// A form or confirm closed: a release waiting for it is taken.
    public func pageChanged() {
        guard case .deferred = status, canTakeNow() else { return }
        Task { await self.check() }
    }

    /// Ask the feed once, act on the decision and schedule the next ask.
    public func check() async {
        guard let installed else { return }
        guard !checking else { askAgain = true; return }
        checking = true
        let answer = await feed.newest(at: installed.feed)
        let decision = UpdateDecision.decide(installed: installed, feed: answer, controlSpec: controlSpec)
        if case .update(let release) = decision {
            await take(release)
        } else {
            status = Self.status(decision)
        }
        checking = false
        if askAgain {
            askAgain = false
            await check()
            return
        }
        // Taken (it quits), or in place but not started: nothing more to ask.
        switch status {
        case .updating, .notStarted: return
        default: break
        }
        scheduled += 1
        let serial = scheduled
        let minutes = controlSpec == nil ? UpdateStatus.checkMinutes : UpdateStatus.newerControlCheckMinutes
        schedule(Double(minutes * 60)) { [weak self] in
            guard let self, self.scheduled == serial else { return }
            Task { await self.check() }
        }
    }

    private func take(_ release: AppRelease) async {
        guard canTakeNow() else {
            status = .deferred(release)
            return
        }
        status = .updating(release)
        do {
            try await installer.install(release)
        } catch {
            status = .failed(release, reason: Self.reason(error))
            return
        }
        do {
            try await installer.relaunch(on: page())
        } catch {
            status = .notStarted(release, reason: Self.reason(error))
        }
    }

    static func status(_ decision: UpdateDecision) -> UpdateStatus {
        switch decision {
        case .current: .quiet
        case .waiting(let newest, let control): .waiting(newest: newest, control: control)
        case .unreachable(let problem): .unreachable(problem)
        case .update(let release): .updating(release)
        }
    }

    static func reason(_ error: any Error) -> String {
        (error as? InstallProblem)?.reason ?? error.localizedDescription
    }
}

/// The feed over HTTPS: `feed.json`, at most 64 KB.
public struct URLSessionReleaseFeed: ReleaseFeed {
    public init() {}

    public func newest(at url: URL) async -> Result<AppRelease, FeedProblem> {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .failure(.unreachable("\(url.host() ?? url.absoluteString) answered \(code)"))
        }
        guard data.count <= 64 * 1024 else { return .failure(.unreadable) }
        do throws(FeedProblem) {
            return .success(try AppRelease.feed(data))
        } catch {
            return .failure(error)
        }
    }
}
