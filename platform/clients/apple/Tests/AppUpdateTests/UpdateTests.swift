import AppUpdate
import Foundation
import XCTest

/// The update decision (a newer feed entry, the same entry, an unreachable feed) and the
/// texts the app shows (IS-Atlas-66).
final class UpdateDecisionTests: XCTestCase {
    func testANewerFeedEntryIsTaken() {
        XCTAssertEqual(UpdateDecision.decide(installed: installed, feed: .success(newer), controlSpec: nil), .update(newer))
        XCTAssertEqual(UpdateDecision.decide(installed: installed, feed: .success(newer), controlSpec: "0.25.0"), .update(newer))
    }

    func testTheSameEntryIsCurrent() {
        XCTAssertEqual(UpdateDecision.decide(installed: installed, feed: .success(same), controlSpec: nil), .current)
    }

    func testAnEarlierEntryIsNeverTaken() {
        var earlier = same
        earlier.build = 40
        earlier.revision = "0123456789abcdef0123456789abcdef01234567"
        XCTAssertEqual(UpdateDecision.decide(installed: installed, feed: .success(earlier), controlSpec: nil), .current)
    }

    func testANewerControlWithNoNewerEntryWaitsForTheRelease() {
        XCTAssertEqual(UpdateDecision.decide(installed: installed, feed: .success(same), controlSpec: "0.25.0"),
                       .waiting(newest: same, control: "0.25.0"))
    }

    func testAnUnreachableFeedIsSaid() {
        XCTAssertEqual(UpdateDecision.decide(installed: installed, feed: .failure(.unreachable("offline")), controlSpec: nil),
                       .unreachable(.unreachable("offline")))
    }
}

final class UpdateTextTests: XCTestCase {
    func testUpdatingSaysTheRevision() {
        XCTAssertEqual(UpdateStatus.updating(newer).statusText(installed: installed)?.text, "Updating to bbbbbbb…")
        XCTAssertEqual(UpdateStatus.updating(newer).statusText(installed: installed)?.tone, .pending)
    }

    func testCurrentSaysNothing() {
        XCTAssertNil(UpdateStatus.quiet.statusText(installed: installed))
    }

    func testAnUnreachableFeedSaysWhatIsTrueAndWhatHappens() {
        XCTAssertEqual(UpdateStatus.unreachable(.unreachable("offline")).statusText(installed: installed)?.text,
                       "Could not check for a newer app (offline); this app (aaaaaaa) checks again in 10 minutes.")
    }

    func testAFailedUpdateSaysWhyAndWhatToDo() {
        let text = UpdateStatus.failed(newer, reason: "the download answered 404").statusText(installed: installed)
        XCTAssertEqual(text?.text, "Could not update to bbbbbbb: the download answered 404. This app (aaaaaaa) keeps running and tries again in 10 minutes; or install it by hand from https://example.test/b.zip.")
        XCTAssertEqual(text?.tone, .error)
    }

    func testWaitingForANewerControlsReleaseSaysWhatIsTrueAndWhatHappens() {
        let text = UpdateStatus.waiting(newest: same, control: "0.25.0").statusText(installed: installed)
        XCTAssertEqual(text?.text, "Control speaks contract 0.25.0; its release of this app is still being published. This app (aaaaaaa) checks every minute and updates itself.")
        XCTAssertEqual(text?.tone, .info)
    }
}

final class ReleaseTests: XCTestCase {
    func testTheBundleNamesItsRelease() {
        let info: [String: Any] = ["AtlasRevision": installed.revision, "CFBundleVersion": "41", "AtlasContract": "0.24.0",
                                   "AtlasUpdateFeed": "https://example.test/feed.json"]
        XCTAssertEqual(InstalledApp(info: info), installed)
        XCTAssertNil(InstalledApp(info: ["CFBundleVersion": "41"]), "a local build is no release")
        var plain = info
        plain["AtlasUpdateFeed"] = "http://example.test/feed.json"
        XCTAssertNil(InstalledApp(info: plain), "the feed is HTTPS only")
    }

    func testTheFeedIsRead() throws {
        let data = try JSONEncoder().encode(newer)
        XCTAssertEqual(try AppRelease.feed(data), newer)
        XCTAssertThrowsError(try AppRelease.feed(Data("{}".utf8)))
        var bad = newer
        bad.sha256 = "nothex"
        XCTAssertThrowsError(try AppRelease.feed(try JSONEncoder().encode(bad)))
    }
}

/// The updater on a fake feed and installer, with the clock in the test's hand.
@MainActor
final class UpdaterTests: XCTestCase {
    func testANewerReleaseIsTakenAndTheAppStartsOnThePageItShowed() async {
        let installer = FakeInstaller()
        let (updater, timers) = make(feed: .success(newer), installer: installer)
        updater.page = { "/k/issue/IS-1" }
        await updater.check()
        XCTAssertEqual(installer.installed, [newer])
        XCTAssertEqual(installer.relaunchedOn, ["/k/issue/IS-1"])
        XCTAssertEqual(timers.count, 0, "an app that takes a release asks no more")
    }

    func testAReleaseWaitsForAnOpenForm() async {
        let installer = FakeInstaller()
        let (updater, _) = make(feed: .success(newer), installer: installer)
        updater.canTakeNow = { false }
        await updater.check()
        XCTAssertEqual(updater.status, .deferred(newer))
        XCTAssertEqual(installer.installed, [])
    }

    func testTheSameEntryAsksAgainInTenMinutes() async {
        let (updater, timers) = make(feed: .success(same), installer: FakeInstaller())
        await updater.check()
        XCTAssertEqual(updater.status, .quiet)
        XCTAssertEqual(timers.seconds, [600])
    }

    func testANewerControlAsksEveryMinute() async {
        let (updater, timers) = make(feed: .success(same), installer: FakeInstaller())
        updater.controlIsNewer(spec: "0.25.0")
        await updater.check()
        XCTAssertEqual(updater.status, .waiting(newest: same, control: "0.25.0"))
        XCTAssertEqual(timers.seconds.last, 60)
    }

    func testANewerControlsReleaseStillWaitsForAnOpenForm() async {
        let installer = FakeInstaller()
        let (updater, _) = make(feed: .success(newer), installer: installer)
        updater.canTakeNow = { false }
        updater.controlIsNewer(spec: "0.25.0")
        await updater.check()
        XCTAssertEqual(updater.status, .deferred(newer))
        XCTAssertEqual(installer.installed, [])
    }

    func testAFailedInstallSaysWhyAndKeepsTheApp() async {
        let installer = FakeInstaller()
        installer.problem = InstallProblem("the download answered 404")
        let (updater, _) = make(feed: .success(newer), installer: installer)
        await updater.check()
        XCTAssertEqual(updater.status, .failed(newer, reason: "the download answered 404"))
        XCTAssertEqual(installer.relaunchedOn, [])
    }

    func testALocalBuildNeverAsks() async {
        let feed = FakeFeed(.success(newer))
        let updater = Updater(installed: nil, feed: feed, installer: FakeInstaller()) { _, _ in }
        updater.start()
        await updater.check()
        XCTAssertEqual(updater.status, .notRelease)
        XCTAssertEqual(feed.asked, 0)
    }

    private func make(feed answer: Result<AppRelease, FeedProblem>, installer: FakeInstaller) -> (Updater, Timers) {
        let timers = Timers()
        let updater = Updater(installed: installed, feed: FakeFeed(answer), installer: installer) { seconds, _ in
            timers.seconds.append(seconds)
        }
        return (updater, timers)
    }
}

@MainActor
private final class Timers {
    var seconds: [Double] = []
    var count: Int { seconds.count }
}

private final class FakeFeed: ReleaseFeed, @unchecked Sendable {
    let answer: Result<AppRelease, FeedProblem>
    var asked = 0
    init(_ answer: Result<AppRelease, FeedProblem>) { self.answer = answer }
    func newest(at url: URL) async -> Result<AppRelease, FeedProblem> {
        asked += 1
        return answer
    }
}

private final class FakeInstaller: ReleaseInstaller, @unchecked Sendable {
    var installed: [AppRelease] = []
    var relaunchedOn: [String?] = []
    var problem: InstallProblem?
    func install(_ release: AppRelease) async throws {
        if let problem { throw problem }
        installed.append(release)
    }
    @MainActor func relaunch(on page: String?) async throws { relaunchedOn.append(page) }
}

private let installed = InstalledApp(revision: String(repeating: "a", count: 40), build: 41, contract: "0.24.0",
                                     feed: URL(string: "https://example.test/feed.json")!)
private let same = AppRelease(revision: installed.revision, build: 41, contract: "0.24.0",
                              url: URL(string: "https://example.test/a.zip")!, sha256: String(repeating: "0", count: 64))
private let newer = AppRelease(revision: String(repeating: "b", count: 40), build: 42, contract: "0.25.0",
                               url: URL(string: "https://example.test/b.zip")!, sha256: String(repeating: "1", count: 64))
